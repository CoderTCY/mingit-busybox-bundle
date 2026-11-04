# Uses the runner's existing real Edge browser, never a replacement opener/browser.
# A disposable profile and per-user HTML association route ShellExecute to that browser.
function Start-AcceptanceBrowser([string] $Root) {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    Assert-Acceptance ([bool]$edge) 'Real Microsoft Edge is required for automated offline UI evidence.'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $profile = Join-Path $Root 'browser-profile'
    $state = @{ Port = $port; Profile = $profile; Registry = @(); Process = $null; ProgId = ('MinGitBundleAcceptanceHtml.' + [Guid]::NewGuid().ToString('N')) }
    try {
    $classes = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes')
    try {
        foreach ($extension in @('.html', '.htm')) {
            $prior = $classes.OpenSubKey($extension)
            $keyExisted = $null -ne $prior
            if ($prior) { $prior.Dispose() }
            $key = $classes.CreateSubKey($extension)
            $exists = '' -in $key.GetValueNames()
            $kind = if ($exists) { $key.GetValueKind('') } else { [Microsoft.Win32.RegistryValueKind]::String }
            $state.Registry += @{ Extension = $extension; KeyExisted = $keyExisted; Exists = $exists; Kind = $kind; Value = $key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            $key.SetValue('', $state.ProgId, [Microsoft.Win32.RegistryValueKind]::String)
            $key.Dispose()
        }
        $command = $classes.CreateSubKey("$($state.ProgId)\shell\open\command")
        $command.SetValue('', ('"{0}" --user-data-dir="{1}" --remote-debugging-port={2} --no-first-run --proxy-server="http://127.0.0.1:9" --proxy-bypass-list="<-loopback>" "%1"' -f $edge, $profile, $port))
        $command.Dispose()
    } finally { $classes.Dispose() }
    $info = [Diagnostics.ProcessStartInfo]::new($edge)
    $info.UseShellExecute = $false
    foreach ($argument in @("--user-data-dir=$profile", "--remote-debugging-port=$port", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>', 'about:blank')) { $info.ArgumentList.Add($argument) }
    $state.Process = [Diagnostics.Process]::Start($info)
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        try { $null = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 2; return $state } catch { Start-Sleep -Milliseconds 300 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Real browser did not expose its local inspection endpoint.'
    } catch {
        Stop-AcceptanceBrowser $state
        throw
    }
}

function Stop-AcceptanceBrowser($State) {
    if (-not $State) { return }
    try {
        if ($State.Process -and -not $State.Process.HasExited) { $State.Process.Kill($true); $State.Process.WaitForExit() }
    } finally {
        foreach ($saved in $State.Registry) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\$($saved.Extension)")
            if ($saved.Exists) { $key.SetValue('', $saved.Value, $saved.Kind) } else { $key.DeleteValue('', $false) }
            $removeKey = -not $saved.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            $key.Dispose()
            if ($removeKey) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey("Software\Classes\$($saved.Extension)", $false) }
        }
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("Software\Classes\$($State.ProgId)", $false)
        if ($State.Process) { $State.Process.Dispose() }
    }
}

function Invoke-BrowserProtocol([string] $WebSocket, [string] $Method, [hashtable] $Parameters = @{}) {
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new(30000)
    try {
        $socket.ConnectAsync([Uri]$WebSocket, $cancel.Token).GetAwaiter().GetResult()
        $request = [Text.Encoding]::UTF8.GetBytes((@{ id = 1; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 12 -Compress))
        $socket.SendAsync([ArraySegment[byte]]::new($request), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
        do {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $buffer = [byte[]]::new(65536)
                    $message = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cancel.Token).GetAwaiter().GetResult()
                    Assert-Acceptance ($message.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Close) 'Browser inspection socket closed.'
                    $stream.Write($buffer, 0, $message.Count)
                } until ($message.EndOfMessage)
                $response = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json -AsHashtable
            } finally { $stream.Dispose() }
        } until ($response.ContainsKey('id') -and $response.id -eq 1)
        Assert-Acceptance (-not $response.ContainsKey('error')) "Browser inspection failed: $($response | ConvertTo-Json -Compress -Depth 8)"
        return $response.result
    } finally { $socket.Dispose(); $cancel.Dispose() }
}

function Wait-BrowserPage($State, [string] $LocalPath, [string] $TargetId = '') {
    $expected = [Uri]::new([IO.Path]::GetFullPath($LocalPath)).AbsoluteUri
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        $targets = @(Invoke-RestMethod "http://127.0.0.1:$($State.Port)/json/list" -TimeoutSec 5)
        $matches = @($targets | Where-Object { $_.type -eq 'page' -and (-not $TargetId -or $_.id -eq $TargetId) -and [Uri]::UnescapeDataString($_.url).TrimEnd('/') -ieq [Uri]::UnescapeDataString($expected).TrimEnd('/') })
        foreach ($target in $matches) {
            $ready = Invoke-BrowserProtocol $target.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = "document.readyState==='complete' && document.visibilityState==='visible'"; returnByValue = $true }
            if ($ready.result.value -eq $true) { return $target }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The actual default browser did not display $expected. Check HTML default association and desktop access."
}

function Save-BrowserPageEvidence($State, [string] $LocalPath, [string] $OutputRoot, [string] $Name, [string] $TargetId = '') {
    $target = Wait-BrowserPage $State $LocalPath $TargetId
    $expression = @'
JSON.stringify({url:location.href,title:document.title,text:document.body.innerText,
  visible:document.visibilityState, width:innerWidth,height:innerHeight,
  styles:Array.from(document.styleSheets).map(s=>({href:s.href,rules:s.cssRules.length})),
  images:Array.from(document.images).map(i=>({src:i.src,loaded:i.complete&&i.naturalWidth>0})),
  bodyFont:getComputedStyle(document.body).fontFamily,
  resources:performance.getEntriesByType('resource').map(r=>r.name),
  links:Array.from(document.links).map(a=>({href:a.href,text:a.innerText}))})
'@
    $result = Invoke-BrowserProtocol $target.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = $expression; returnByValue = $true }
    Assert-Acceptance (-not $result.ContainsKey('exceptionDetails')) 'Browser could not inspect local document/stylesheets.'
    $page = $result.result.value | ConvertFrom-Json
    Assert-Acceptance ($page.text.Length -gt 200) 'Browser displayed no meaningful manual body.'
    Assert-Acceptance ($page.width -gt 0 -and $page.height -gt 0 -and $page.visible -eq 'visible') 'Manual page is not visibly rendered.'
    Assert-Acceptance (@($page.styles | Where-Object { $_.rules -gt 0 }).Count -gt 0) 'No embedded or local manual stylesheet was parsed by the browser.'
    Assert-Acceptance (@($page.images | Where-Object { -not $_.loaded }).Count -eq 0) 'Manual contains failed image loads.'
    Assert-Acceptance (@($page.styles | Where-Object { $_.href -and $_.href -notlike 'file:*' }).Count -eq 0) 'Manual loaded a nonlocal stylesheet.'
    Assert-Acceptance (@($page.resources | Where-Object { $_ -match '^https?://' }).Count -eq 0) 'Offline manual attempted to load an HTTP(S) resource.'
    $capture = Invoke-BrowserProtocol $target.webSocketDebuggerUrl 'Page.captureScreenshot' @{ format = 'png'; captureBeyondViewport = $false }
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    $screenshot = Join-Path $OutputRoot "$Name.png"
    [IO.File]::WriteAllBytes($screenshot, [Convert]::FromBase64String($capture.data))
    Write-Utf8 (Join-Path $OutputRoot "$Name.json") ($page | ConvertTo-Json -Depth 8)
    return @{ Target = $target; Page = $page; Screenshot = $screenshot; Sha256 = Get-Sha256 $screenshot }
}

function Test-ActualBrowserManual($State, [string] $HtmlRoot, [string] $OutputRoot, [scriptblock] $OpenIndex) {
    $commit = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'git-commit.html') $OutputRoot 'commit'
    Assert-Acceptance ($commit.Page.text -match 'git-commit' -and $commit.Page.text -match 'DESCRIPTION') 'Wrong commit manual body displayed.'
    & $OpenIndex
    $index = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'index.html') $OutputRoot 'index'
    $click = Invoke-BrowserProtocol $index.Target.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = "(()=>{const a=Array.from(document.links).find(a=>new URL(a.href).pathname.endsWith('/git-commit.html'));if(!a)throw Error('Missing real internal commit link');a.click();return true})()"; returnByValue = $true }
    Assert-Acceptance (-not $click.ContainsKey('exceptionDetails')) 'Manual internal link activation failed.'
    $linked = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'git-commit.html') $OutputRoot 'internal-link' $index.Target.id
    return @{ method = 'real-default-Edge-CDP'; network = 'HTTP(S) blocked by dead loopback proxy; resource URLs asserted local'; commit = $commit.Screenshot; index = $index.Screenshot; internalLink = $linked.Screenshot; address = $linked.Page.url; css = $index.Page.styles }
}
