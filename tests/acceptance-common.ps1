Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Acceptance([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Write-Utf8([string] $Path, [string] $Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-IsolatedEnvironment([string] $InstallRoot, [string] $HomeRoot) {
    [IO.Directory]::CreateDirectory($HomeRoot) | Out-Null
    $result = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ($entry.Key -match '^(GIT_|GCM_|LFS_|SSH_|SHELL$|BASH_ENV$|ENV$|CDPATH$|LANG$|LANGUAGE$|LC_|TEXTDOMAINDIR$|MSYSTEM$|MINGW_PREFIX$)') { continue }
        $result[[string]$entry.Key] = [string]$entry.Value
    }
    $result.PATH = "$InstallRoot\cmd;$env:SystemRoot\System32;$env:SystemRoot"
    $result.HOME = $HomeRoot
    $result.USERPROFILE = $HomeRoot
    $result.XDG_CONFIG_HOME = Join-Path $HomeRoot 'xdg'
    $result.LANG = 'C'
    $result.LC_ALL = 'C'
    $result.GIT_TERMINAL_PROMPT = '0'
    $result.GCM_INTERACTIVE = 'Never'
    return $result
}

function Invoke-AcceptanceProcess {
    param([string] $File, [string[]] $Arguments = @(), [string] $Directory,
          [hashtable] $Environment, [int[]] $ExpectedExit = @(0), [int] $TimeoutSeconds = 240)
    $id = $script:AcceptanceCommands.Count + 1
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($Directory) { $info.WorkingDirectory = $Directory }
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    if ($Environment) {
        $info.Environment.Clear()
        foreach ($entry in $Environment.GetEnumerator()) { $info.Environment[$entry.Key] = $entry.Value }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $record = [ordered]@{ id = $id; file = $File; arguments = $Arguments; directory = $Directory; started = [DateTime]::UtcNow.ToString('o'); exit = $null; stdout = ''; stderr = ''; timedOut = $false }
    try {
        Assert-Acceptance ($process.Start()) "Failed to start $File"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $record.timedOut = $true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $record.stdout = $stdout.GetAwaiter().GetResult()
        $record.stderr = $stderr.GetAwaiter().GetResult()
        $record.exit = $process.ExitCode
    } finally {
        $process.Dispose()
        $script:AcceptanceCommands.Add([pscustomobject]$record)
        Write-Utf8 (Join-Path $script:AcceptanceLogRoot ('command-{0:D4}.json' -f $id)) ($record | ConvertTo-Json -Depth 8)
    }
    Assert-Acceptance (-not $record.timedOut) "Timed out: $File $($Arguments -join ' ')"
    if ($ExpectedExit.Count) {
        Assert-Acceptance ($record.exit -in $ExpectedExit) "Exit $($record.exit), expected $($ExpectedExit -join ','): $File $($Arguments -join ' ')`n$($record.stderr)"
    }
    return [pscustomobject]$record
}

function Get-Sha256([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Assert-FileContent([string] $Path, [string] $Hash, [long] $Length) {
    Assert-Acceptance (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    Assert-Acceptance ((Get-Item -LiteralPath $Path).Length -eq $Length) "Incorrect length: $Path"
    Assert-Acceptance ((Get-Sha256 $Path) -ceq $Hash) "Incorrect SHA-256: $Path"
}

function ConvertTo-ComparablePath([string] $Path) {
    return [IO.Path]::GetFullPath($Path.Replace('/', '\')).TrimEnd('\')
}

function Assert-WithinRoot([string] $Path, [string] $Root) {
    $full = ConvertTo-ComparablePath $Path
    $prefix = (ConvertTo-ComparablePath $Root) + '\'
    Assert-Acceptance ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) "Path escaped installation: $Path (root $Root)"
}

# Browser display and CSS rendering cannot be inferred from ShellExecute's return value.
# A human supplies this separately after observing the real product on a desktop.
# Evidence JSON: { releaseTag, installerSha256, observer, observedUtc,
#   checks: [{ name, screenshot, sha256, notes }] }.
# screenshot paths are relative to the JSON file. The release pipeline must preserve
# this JSON and its screenshots alongside machine-generated evidence.
function Assert-ObservedUi {
    param([string] $EvidencePath, [string] $ReleaseTag, [string[]] $Checks, [string] $InstallerHash = '')
    Assert-Acceptance (-not [string]::IsNullOrWhiteSpace($EvidencePath)) 'UI is UNVERIFIED: supply -UiEvidencePath with real desktop observations and screenshots; successful opener exit alone is insufficient.'
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    Assert-Acceptance ($evidence.releaseTag -ceq $ReleaseTag) 'UI evidence belongs to a different release.'
    Assert-Acceptance (-not [string]::IsNullOrWhiteSpace($evidence.observer)) 'UI evidence lacks an observer.'
    $observed = [DateTimeOffset]::Parse($evidence.observedUtc)
    Assert-Acceptance ($observed -le [DateTimeOffset]::UtcNow) 'UI evidence has a future observation time.'
    if ($InstallerHash) { Assert-Acceptance ($evidence.installerSha256 -ceq $InstallerHash) 'UI evidence is not bound to this installer SHA-256.' }
    foreach ($name in $Checks) {
        $check = @($evidence.checks | Where-Object name -CEQ $name)
        Assert-Acceptance ($check.Count -eq 1) "UI evidence missing or ambiguous: $name"
        Assert-Acceptance (-not [string]::IsNullOrWhiteSpace($check[0].notes)) "UI observation lacks notes: $name"
        $image = Join-Path (Split-Path -Parent $EvidencePath) $check[0].screenshot
        Assert-Acceptance ((Get-Sha256 $image) -ceq $check[0].sha256) "UI screenshot checksum mismatch: $name"
        Assert-Acceptance ((Get-Item -LiteralPath $image).Length -gt 1024) "UI screenshot is empty: $name"
    }
    return $evidence
}
