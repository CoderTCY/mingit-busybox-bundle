# Uses the runner's existing real Edge browser, never a replacement opener/browser.
# A disposable Edge profile and its real HTML ProgID keep ShellExecute observable.
function Start-AcceptanceBrowser([string] $Root) {
    Assert-Acceptance ($env:GITHUB_ACTIONS -eq 'true') 'Default-browser fixtures require a disposable GitHub runner.'
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    Assert-Acceptance ([bool]$edge) 'Real Microsoft Edge is required for automated offline UI evidence.'
    if (-not ('BundleBrowserAssociation' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BundleBrowserAssociation {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
    }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $profile = Join-Path $Root 'browser-profile'
    $state = @{ Port = $port; Profile = $profile; Registry = @(); Process = $null }
    try {
        $info = [Diagnostics.ProcessStartInfo]::new($edge)
        $info.UseShellExecute = $false
        foreach ($argument in @("--user-data-dir=$profile", "--remote-debugging-port=$port", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>', 'about:blank')) { $info.ArgumentList.Add($argument) }
        $state.Process = [Diagnostics.Process]::Start($info)
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        $ready = $false
        do {
            try { $null = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 2; $ready = $true; break } catch { Start-Sleep -Milliseconds 300 }
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-Acceptance $ready 'Real browser did not expose its local inspection endpoint.'

        # Do not rewrite extension defaults or fabricate a UserChoice hash.
        # Temporarily configure Edge's actual ProgID command so the existing
        # Windows default reaches this real browser's disposable profile.
        $commandPath = 'Software\Classes\MSEdgeHTM\shell\open\command'
        foreach ($path in @('Software\Classes\MSEdgeHTM', 'Software\Classes\MSEdgeHTM\shell', 'Software\Classes\MSEdgeHTM\shell\open', $commandPath)) {
            $prior = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
            $saved = @{ Path = $path; KeyExisted = $null -ne $prior; Values = @() }
            if ($prior) { $prior.Dispose() }
            $state.Registry += $saved
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
            try {
                if ($path -ceq $commandPath) {
                    foreach ($name in @('', 'DelegateExecute')) {
                        $exists = $name -in $key.GetValueNames()
                        $saved.Values += @{ Name = $name; Exists = $exists; Kind = $(if ($exists) { $key.GetValueKind($name) } else { [Microsoft.Win32.RegistryValueKind]::String }); Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                    }
                    $key.SetValue('', ('"{0}" --user-data-dir="{1}" --remote-debugging-port={2} --no-first-run --no-default-browser-check --proxy-server="http://127.0.0.1:9" --proxy-bypass-list="<-loopback>" "%1"' -f $edge, $profile, $port), [Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('DelegateExecute', '', [Microsoft.Win32.RegistryValueKind]::String)
                }
            } finally { $key.Dispose() }
        }
        [BundleBrowserAssociation]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        return $state
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
        for ($i = $State.Registry.Count - 1; $i -ge 0; $i--) {
            $saved = $State.Registry[$i]
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($saved.Path, $true)
            if (-not $key) { continue }
            try {
                foreach ($value in $saved.Values) {
                    if ($value.Exists) { $key.SetValue($value.Name, $value.Value, $value.Kind) } else { $key.DeleteValue($value.Name, $false) }
                }
                $removeKey = -not $saved.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            } finally { $key.Dispose() }
            if ($removeKey) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($saved.Path, $false) }
        }
        [BundleBrowserAssociation]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($State.Process) { $State.Process.Dispose() }
    }
}

function Invoke-BrowserProtocol([string] $WebSocket, [string] $Method, [hashtable] $Parameters = @{}) {
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new(30000)
    try {
        $null = $socket.ConnectAsync([Uri]$WebSocket, $cancel.Token).GetAwaiter().GetResult()
        $request = [Text.Encoding]::UTF8.GetBytes((@{ id = 1; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 12 -Compress))
        $null = $socket.SendAsync([ArraySegment[byte]]::new($request), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
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
        $targets = Invoke-RestMethod "http://127.0.0.1:$($State.Port)/json/list" -TimeoutSec 5
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
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
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
    $screenshot = Join-Path $OutputRoot "$Name.png"
    $null = Invoke-AcceptanceProcess -File (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'capture-browser-window.ps1'), '-BrowserProcessId', "$($State.Process.Id)", '-ExpectedPath', $LocalPath, '-OutputPath', $screenshot) -Directory $OutputRoot -TimeoutSeconds 60
    Write-Utf8 (Join-Path $OutputRoot "$Name.json") ($page | ConvertTo-Json -Depth 8)
    return @{ Target = $target; Page = $page; Screenshot = $screenshot; Sha256 = Get-Sha256 $screenshot }
}

function Test-ActualBrowserManual($State, [string] $HtmlRoot, [string] $OutputRoot, [scriptblock] $OpenIndex) {
    $commit = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'git-commit.html') $OutputRoot 'commit'
    Assert-Acceptance ($commit.Page.text -match 'git-commit') 'Wrong commit manual body displayed.'
    & $OpenIndex
    $index = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'index.html') $OutputRoot 'index'
    $click = Invoke-BrowserProtocol $index.Target.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = "(()=>{const a=Array.from(document.links).find(a=>new URL(a.href).pathname.endsWith('/git-commit.html'));if(!a)throw Error('Missing real internal commit link');a.click();return true})()"; returnByValue = $true }
    Assert-Acceptance (-not $click.ContainsKey('exceptionDetails')) 'Manual internal link activation failed.'
    $linked = Save-BrowserPageEvidence $State (Join-Path $HtmlRoot 'git-commit.html') $OutputRoot 'internal-link' $index.Target.id
    return @{ method = 'real-default-Edge-CDP'; network = 'HTTP(S) blocked by dead loopback proxy; resource URLs asserted local'; commit = $commit.Screenshot; index = $index.Screenshot; internalLink = $linked.Screenshot; address = $linked.Page.url; css = $index.Page.styles }
}
