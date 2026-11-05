#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallRoot,
    [Parameter(Mandatory)][string] $ScratchRoot,
    [string] $InputsPath,
    [string] $UiEvidencePath,
    [switch] $AutomateBrowser,
    [string] $SourceLocaleManifest
)
. "$PSScriptRoot/acceptance-common.ps1"
. "$PSScriptRoot/browser-evidence.ps1"
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
Assert-Acceptance (-not (Test-Path -LiteralPath $ScratchRoot)) 'ScratchRoot must not already exist; evidence must not mix runs.'
Assert-Acceptance (-not $ScratchRoot.StartsWith($InstallRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) 'ScratchRoot must be outside InstallRoot so relocation cannot recursively copy itself.'
[IO.Directory]::CreateDirectory($ScratchRoot) | Out-Null
$script:AcceptanceLogRoot = Join-Path $ScratchRoot 'commands'
$script:AcceptanceCommands = [Collections.Generic.List[object]]::new()
$report = [ordered]@{ schemaVersion = 1; passed = $false; installRoot = $InstallRoot; isolatedPath = ''; checks = @(); browser = @(); failure = $null }
$browser = $null

function Invoke-Git([string[]] $Arguments, [string] $Directory = $script:RunRoot, [int[]] $ExpectedExit = @(0), [hashtable] $ExtraEnvironment = @{}) {
    $environment = $script:GitEnvironment.Clone()
    foreach ($entry in $ExtraEnvironment.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    return Invoke-AcceptanceProcess -File $script:Git -Arguments $Arguments -Directory $Directory -Environment $environment -ExpectedExit $ExpectedExit
}

function Initialize-Repository([string] $Path, [switch] $Bare) {
    $arguments = @('init', '--initial-branch=main')
    if ($Bare) { $arguments += '--bare' }
    $arguments += $Path
    $null = Invoke-Git $arguments
    if (-not $Bare) {
        $null = Invoke-Git @('config', 'user.name', 'Bundle Acceptance') $Path
        $null = Invoke-Git @('config', 'user.email', 'bundle-acceptance@example.invalid') $Path
        $null = Invoke-Git @('config', 'commit.gpgsign', 'false') $Path
        $null = Invoke-Git @('config', 'tag.gpgsign', 'false') $Path
    }
}

function Test-CorePayload([string] $Root, [string] $Label) {
    $script:RunRoot = Join-Path $ScratchRoot $Label
    [IO.Directory]::CreateDirectory($script:RunRoot) | Out-Null
    $script:Git = Join-Path $Root 'cmd/git.exe'
    Assert-Acceptance (Test-Path -LiteralPath $script:Git) 'Installed Git entry point is absent.'
    $script:GitEnvironment = New-IsolatedEnvironment $Root (Join-Path $script:RunRoot 'home')
    $script:GitEnvironment.GIT_TRACE = Join-Path $script:RunRoot 'git-trace.log'
    $script:GitEnvironment.GIT_TRACE2_EVENT = Join-Path $script:RunRoot 'git-trace2.jsonl'
    $report.isolatedPath = $script:GitEnvironment.PATH
    $globalConfig = Join-Path $script:GitEnvironment.HOME '.gitconfig'
    $globalText = "[acceptance]`n    sentinel = untouched`n"
    Write-Utf8 $globalConfig $globalText
    $version = (Invoke-Git @('--version')).stdout.Trim()
    $expectedVersion = 'git version ' + $script:Inputs.git.tag.Substring(1) + '.busyboxbundle.' + $script:Inputs.recipeCommit.Substring(0, 12)
    Assert-Acceptance ($version -ceq $expectedVersion) "Custom Git version mismatch: $version != $expectedVersion"
    $busyboxVersion = (Invoke-AcceptanceProcess -File (Join-Path $Root 'ucrt64/bin/busybox.exe') -Arguments @('--version') -Directory $script:RunRoot -Environment $script:GitEnvironment).stdout.Trim()
    $expectedBusyboxVersion = $script:Inputs.toolchain.busybox.version + '.busyboxbundle.' + $script:Inputs.recipeCommit.Substring(0, 12)
    Assert-Acceptance ($busyboxVersion -match ('^BusyBox v' + [Regex]::Escape($expectedBusyboxVersion) + '(?:\s|$)')) "Custom BusyBox version mismatch: $busyboxVersion"
    Assert-WithinRoot (Invoke-Git @('--exec-path')).stdout.Trim() $Root
    $shell = (Invoke-Git @('var', 'GIT_SHELL_PATH')).stdout.Trim()
    Assert-WithinRoot $shell $Root
    Assert-Acceptance ((ConvertTo-ComparablePath $shell) -ieq (ConvertTo-ComparablePath (Join-Path $Root 'ucrt64/bin/ash.exe'))) "Unexpected runtime shell: $shell"
    $lfsVersion = (Invoke-Git @('lfs', 'version')).stdout.Trim()
    Assert-Acceptance ($lfsVersion -match ('^git-lfs/' + [Regex]::Escape($script:Inputs.lfs.version) + ' \(' + [Regex]::Escape($script:Inputs.lfs.vendor) + '; windows amd64;')) "Wrong installed LFS build: $lfsVersion"
    foreach ($pair in @{ clean = 'git-lfs clean -- %f'; smudge = 'git-lfs smudge -- %f'; process = 'git-lfs filter-process'; required = 'true' }.GetEnumerator()) {
        $value = (Invoke-Git @('config', '--system', '--includes', '--get', "filter.lfs.$($pair.Key)")).stdout.Trim()
        Assert-Acceptance ($value -ceq $pair.Value) "Missing product system LFS filter: $($pair.Key)"
    }
    $origins = (Invoke-Git @('config', '--system', '--includes', '--show-origin', '--null', '--list')).stdout
    Assert-Acceptance ($origins -match 'gitconfig.bundle') 'Product defaults are not included by system configuration.'
    $fields = $origins -split "`0"
    for ($field = 0; $field -lt $fields.Count - 1; $field += 2) {
        $origin = $fields[$field]
        Assert-Acceptance ($origin.StartsWith('file:')) "Unexpected system config source: $origin"
        Assert-WithinRoot $origin.Substring(5) $Root
    }
    $alias = (Invoke-Git @('-c', 'alias.hello=!echo Hello World', 'hello')).stdout.TrimEnd("`r", "`n")
    Assert-Acceptance ($alias -ceq 'Hello World') '#5184: shell alias did not execute.'
    $argv = @('space argument', '中文参数', 'double"quote', "single'quote", 'ending\', '')
    $argvAlias = 'alias.argv=!f() { printf "<%s>\n" "$@"; }; f'
    $result = Invoke-Git (@('-c', $argvAlias, 'argv') + $argv)
    $expected = ($argv | ForEach-Object { '<' + $_ + '>' }) -join "`n"
    Assert-Acceptance ($result.stdout.Replace("`r`n", "`n").TrimEnd("`n") -ceq $expected) "Shell argv corruption: $($result.stdout)"

    $source = Join-Path $script:RunRoot 'source 空格 中文 #仓库'
    Initialize-Repository $source
    Write-Utf8 (Join-Path $source 'readme.txt') "tracked source`n"
    $null = Invoke-Git @('add', 'readme.txt') $source
    $null = Invoke-Git @('commit', '-m', 'initial source') $source
    $head = (Invoke-Git @('rev-parse', 'HEAD') $source).stdout.Trim()
    $trailing = $source.TrimEnd('\') + '\\'
    $uri = [Uri]::new([IO.Path]::GetFullPath($source)).AbsoluteUri
    foreach ($transport in @(@{ Name = 'local'; Source = $trailing }, @{ Name = 'file'; Source = $uri })) {
        $clone = Join-Path $script:RunRoot ("clone $($transport.Name) 中文")
        $null = Invoke-Git @('clone', '--no-hardlinks', $transport.Source, $clone)
        Assert-Acceptance ((Invoke-Git @('rev-parse', 'HEAD') $clone).stdout.Trim() -ceq $head) "#5469: $($transport.Name) clone HEAD differs."
        $refs = (Invoke-Git @('ls-remote', $transport.Source)).stdout
        Assert-Acceptance ($refs -match ('(?m)^' + [Regex]::Escape($head) + '\s+refs/heads/main\r?$')) "#5469: $($transport.Name) ls-remote lost main."
    }
    $nativeConfig = 'space 中文 "double" and ''single'' \tail\'
    $nested = Invoke-Git @('-c', 'alias.native-config=!git config --get bundle.probe', '-c', "bundle.probe=$nativeConfig", 'native-config')
    Assert-Acceptance ($nested.stdout.TrimEnd("`r", "`n") -ceq $nativeConfig) 'Shell alias corrupted inherited config or failed to locate its native Git child.'
    foreach ($interpreter in @('sh', 'bash')) {
        $hook = "#!/bin/$interpreter`nprintf '%s\n' '$interpreter' > 'hook-$interpreter.marker'`n"
        Write-Utf8 (Join-Path $source '.git/hooks/pre-commit') $hook
        $null = Invoke-Git @('commit', '--allow-empty', '-m', "real $interpreter hook") $source
        Assert-Acceptance ((Get-Content -LiteralPath (Join-Path $source "hook-$interpreter.marker") -Raw).Trim() -ceq $interpreter) "Real $interpreter hook did not run."
    }
    $before = (Invoke-Git @('rev-parse', 'HEAD') $source).stdout.Trim()
    Write-Utf8 (Join-Path $source '.git/hooks/pre-commit') "#!/bin/sh`nprintf rejected > rejected.marker`nexit 7`n"
    $failure = Invoke-Git @('commit', '--allow-empty', '-m', 'must not commit') $source @()
    Assert-Acceptance ($failure.exit -ne 0) 'A failing pre-commit hook did not reject commit.'
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $source 'rejected.marker')) 'Rejecting hook never ran.'
    Assert-Acceptance ((Invoke-Git @('rev-parse', 'HEAD') $source).stdout.Trim() -ceq $before) 'HEAD advanced despite hook failure.'
    $invalid = Invoke-Git @('-c', ('core.shell=' + (Join-Path $script:RunRoot 'does-not-exist/ash.exe')), '-c', 'alias.hello=!echo must-not-run', 'hello') $script:RunRoot @()
    Assert-Acceptance ($invalid.exit -ne 0 -and $invalid.stdout -notmatch 'must-not-run') 'Invalid core.shell silently fell back to a host shell.'

    $probe = '__l10n_probe__'
    $zh = Invoke-Git @('-c', "help.format=$probe", 'help', 'status') $script:RunRoot @(128) @{ LANG = 'zh_CN.UTF-8'; LC_ALL = 'zh_CN.UTF-8'; LANGUAGE = 'zh_CN' }
    $english = Invoke-Git @('-c', "help.format=$probe", 'help', 'status') $script:RunRoot @(128) @{ LANG = 'C'; LC_ALL = 'C'; LANGUAGE = '' }
    Assert-Acceptance ($zh.stderr -match '[\p{IsCJKUnifiedIdeographs}]' -and $zh.stderr.Contains($probe)) 'Native gettext Chinese diagnostic missing or wrong.'
    Assert-Acceptance ($english.stderr -notmatch '[\p{IsCJKUnifiedIdeographs}]' -and $english.stderr.Contains($probe) -and $english.stderr -match '[A-Za-z]') 'C locale diagnostic was not English.'
    foreach ($locale in $script:SourceLocales) {
        $mo = Join-Path $Root "ucrt64/share/locale/$locale/LC_MESSAGES/git.mo"
        Assert-Acceptance ((Test-Path -LiteralPath $mo) -and (Get-Item -LiteralPath $mo).Length -gt 28) "Source catalog missing in payload: $locale"
    }
    $html = (Invoke-Git @('--html-path')).stdout.Trim()
    Assert-WithinRoot $html $Root
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $html 'git-commit.html')) 'Offline commit manual is missing.'
    Assert-Acceptance ((Invoke-Git @('config', '--get', 'browser.mingit-bundle.cmd')).stdout.Trim() -ceq 'mingit-open.exe') 'Actual packaged opener is not configured.'
    $null = Invoke-Git @('help', '-w', 'commit')
    $trace = Get-Content -LiteralPath $script:GitEnvironment.GIT_TRACE -Raw
    Assert-Acceptance ($trace -notmatch '(?i)([A-Z]:[/\\](?:git-sdk|msys64)[/\\]|Program Files[/\\]Git[/\\].*(?:sh|bash)\.exe)') 'Trace borrowed a host SDK/Git shell.'
    $openIndex = {
        $null = Invoke-AcceptanceProcess -File (Join-Path $Root 'ucrt64/bin/mingit-open.exe') -Arguments @((Join-Path $html 'index.html')) -Directory $script:RunRoot -Environment $script:GitEnvironment
    }
    if ($browser) {
        $report.browser += Test-ActualBrowserManual $browser $html (Join-Path $script:RunRoot 'browser-evidence') $openIndex
    } else {
        & $openIndex
        $null = Assert-ObservedUi $UiEvidencePath $script:Inputs.releaseTag @('commit-page', 'index-page', 'stylesheet', 'internal-link', 'relocated-manual')
        $report.browser += @{ method = 'human-observation'; evidence = [IO.Path]::GetFullPath($UiEvidencePath); testedHtmlRoot = $html }
    }
    Assert-Acceptance ((Get-Content -LiteralPath $globalConfig -Raw) -ceq $globalText) 'Product changed user global configuration.'
    $report.checks += "$Label`: version, config origins, alias argv, local/file clone+ls-remote, sh/bash hooks, rejection, invalid shell, gettext, all catalogs, actual help"
}

function Test-LfsRoundtrip {
    $remote = Join-Path $script:RunRoot 'LFS remote 中文 #.git'
    $writer = Join-Path $script:RunRoot 'LFS writer 中文'
    $reader = Join-Path $script:RunRoot 'LFS reader 中文'
    Initialize-Repository $remote -Bare
    Initialize-Repository $writer
    $null = Invoke-Git @('lfs', 'install', '--local') $writer
    $null = Invoke-Git @('lfs', 'track', '*.bin') $writer
    $hook = Join-Path $writer '.git/hooks/pre-push'
    Assert-Acceptance (Test-Path -LiteralPath $hook) 'LFS local installation did not create a real pre-push hook.'
    $bytes = [byte[]]::new(1048576)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 31 + ($i -shr 8) + 17) -band 255) }
    $file = Join-Path $writer 'payload.bin'
    [IO.File]::WriteAllBytes($file, $bytes)
    $oid = Get-Sha256 $file
    $length = $bytes.LongLength
    $null = Invoke-Git @('add', '.gitattributes', 'payload.bin') $writer
    $null = Invoke-Git @('commit', '-m', 'real LFS content') $writer
    $pointer = (Invoke-Git @('show', 'HEAD:payload.bin') $writer).stdout.Replace("`r`n", "`n")
    $expectedPointer = "version https://git-lfs.github.com/spec/v1`noid sha256:$oid`nsize $length`n"
    Assert-Acceptance ($pointer -ceq $expectedPointer) 'Committed blob is not the exact expected LFS pointer.'
    $url = [Uri]::new([IO.Path]::GetFullPath($remote)).AbsoluteUri
    $null = Invoke-Git @('remote', 'add', 'origin', $url) $writer
    $objectSuffix = "lfs/objects/$($oid.Substring(0, 2))/$($oid.Substring(2, 2))/$oid"
    $invalidShell = Join-Path $script:RunRoot 'missing LFS shell/ash.exe'
    $blocked = Invoke-Git @('-c', "core.shell=$invalidShell", 'lfs', 'push', 'origin', 'main') $writer @()
    Assert-Acceptance ($blocked.exit -ne 0) 'LFS silently fell back from an unavailable configured shell.'
    Assert-Acceptance (-not (Test-Path -LiteralPath (Join-Path $remote $objectSuffix))) 'LFS uploaded an object despite its unavailable configured shell.'
    $null = Invoke-Git @('push', '--set-upstream', 'origin', 'main') $writer
    Assert-FileContent (Join-Path $remote $objectSuffix) $oid $length
    Assert-FileContent (Join-Path $writer ".git/$objectSuffix") $oid $length
    $null = Invoke-Git @('clone', '--branch', 'main', $url, $reader)
    Assert-FileContent (Join-Path $reader 'payload.bin') $oid $length
    Assert-FileContent (Join-Path $reader ".git/$objectSuffix") $oid $length
    $null = Invoke-Git @('lfs', 'fsck') $reader
    $trace = Get-Content -LiteralPath $script:GitEnvironment.GIT_TRACE -Raw
    Assert-Acceptance ($trace -match 'pre-push' -and $trace -match 'git-lfs filter-process') 'Real LFS hook/filter chain was not observed.'
    Write-Utf8 (Join-Path $script:RunRoot 'lfs-roundtrip.json') (@{ oid = $oid; length = $length; remote = $url; pointer = $pointer; transport = 'standalone-file'; prePush = $hook; reader = $reader } | ConvertTo-Json)
    $report.checks += 'LFS: configured shell, invalid-shell rejection, pointer, normal push/pre-push, remote+writer+reader objects, automatic clone checkout, fsck'
}

try {
    $manifest = Get-Content -LiteralPath (Join-Path $InstallRoot 'build-manifest.json') -Raw | ConvertFrom-Json
    $script:Inputs = if ($InputsPath) { Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json } else { $manifest.inputs }
    Assert-Acceptance ($manifest.inputs.releaseTag -ceq $script:Inputs.releaseTag) 'Installed manifest identity differs from fixed inputs.'
    $script:SourceLocales = if ($SourceLocaleManifest) { @(Get-Content -LiteralPath $SourceLocaleManifest -Raw | ConvertFrom-Json) } else { @($manifest.sourceLocales) }
    Assert-Acceptance ($script:SourceLocales.Count -gt 0 -and 'zh_CN' -in $script:SourceLocales) 'Missing independent source po catalog inventory.'
    if ($AutomateBrowser) { $browser = Start-AcceptanceBrowser (Join-Path $ScratchRoot 'browser') }
    Test-CorePayload $InstallRoot 'installed'
    Test-LfsRoundtrip
    $relocated = Join-Path $ScratchRoot 'relocated 安装 含空格'
    [IO.Directory]::CreateDirectory($relocated) | Out-Null
    Get-ChildItem -LiteralPath $InstallRoot -Force | Copy-Item -Destination $relocated -Recurse -Force
    Test-CorePayload $relocated 'relocation'
    # Removing only the relocated catalog must remove its translation even while
    # the original installation remains intact: detect an accidentally baked-in
    # original/SDK gettext directory without touching the original installation.
    $relocatedCatalog = Join-Path $relocated 'ucrt64/share/locale/zh_CN/LC_MESSAGES/git.mo'
    $heldCatalog = $relocatedCatalog + '.acceptance-held'
    [IO.File]::Move($relocatedCatalog, $heldCatalog)
    try {
        $withoutCatalog = Invoke-Git @('-c', 'help.format=__l10n_probe__', 'help', 'status') $script:RunRoot @(128) @{ LANG = 'zh_CN.UTF-8'; LC_ALL = 'zh_CN.UTF-8'; LANGUAGE = 'zh_CN' }
        Assert-Acceptance ($withoutCatalog.stderr -notmatch '[\p{IsCJKUnifiedIdeographs}]' -and $withoutCatalog.stderr.Contains('__l10n_probe__')) 'Relocated Git borrowed a catalog from the original installation or SDK.'
    } finally {
        [IO.File]::Move($heldCatalog, $relocatedCatalog)
    }
    $report.checks += 'Relocated gettext lookup proved by catalog removal and restoration'
    $report.passed = $true
} catch {
    $report.failure = $_.Exception.ToString()
    throw
} finally {
    try {
        Stop-AcceptanceBrowser $browser
    } catch {
        $report.passed = $false
        $report.cleanupFailure = $_.Exception.ToString()
        throw
    } finally {
        $report.commands = $script:AcceptanceCommands.Count
        Write-Utf8 (Join-Path $ScratchRoot 'payload-evidence.json') ($report | ConvertTo-Json -Depth 12)
    }
}
