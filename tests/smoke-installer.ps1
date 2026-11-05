#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][string] $InputsPath,
    [Parameter(Mandatory)][ValidateSet('CurrentUser', 'AllUsers')][string] $Scope,
    [Parameter(Mandatory)][string] $ScratchRoot,
    [string] $UpgradeInstaller,
    [string] $UiEvidencePath,
    [switch] $AutomateBrowser
)
. "$PSScriptRoot/acceptance-common.ps1"
$Installer = [IO.Path]::GetFullPath($Installer)
$InputsPath = [IO.Path]::GetFullPath($InputsPath)
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
if ($UpgradeInstaller) { $UpgradeInstaller = [IO.Path]::GetFullPath($UpgradeInstaller) }
Assert-Acceptance (-not (Test-Path -LiteralPath $ScratchRoot)) 'ScratchRoot must be new.'
[IO.Directory]::CreateDirectory($ScratchRoot) | Out-Null
$script:AcceptanceLogRoot = Join-Path $ScratchRoot 'commands'
$script:AcceptanceCommands = [Collections.Generic.List[object]]::new()
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
$admin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$report = [ordered]@{ schemaVersion = 1; passed = $false; fullAcceptance = $false; scope = $Scope; identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name; elevated = $admin; releaseTag = $inputs.releaseTag; installerSha256 = Get-Sha256 $Installer; fixtures = @(); unverified = @(); failure = $null }
$script:ProductKey = 'Software\MinGitBusyBoxBundle'
$script:UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\MinGitBusyBoxBundle_is1'
$script:TargetHive = if ($Scope -eq 'CurrentUser') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
$script:OtherHive = if ($Scope -eq 'CurrentUser') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
$script:EnvironmentKey = if ($Scope -eq 'CurrentUser') { 'Environment' } else { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
$script:OtherEnvironmentKey = if ($Scope -eq 'CurrentUser') { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { 'Environment' }
$script:InstallDirectory = Join-Path $ScratchRoot 'MinGit 安装 中文 空格'
$script:InstallerLogNumber = 0
$originalPath = $null
$otherPath = $null

function Get-PathValue($Hive, [string] $KeyPath) {
    $key = $Hive.OpenSubKey($KeyPath)
    try {
        if ($null -eq $key -or 'Path' -notin $key.GetValueNames()) { return @{ exists = $false; kind = $null; value = $null } }
        return @{ exists = $true; kind = $key.GetValueKind('Path').ToString(); value = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    } finally { if ($key) { $key.Dispose() } }
}

function Set-PathValue($Snapshot) {
    $key = $script:TargetHive.CreateSubKey($script:EnvironmentKey)
    try {
        if ($Snapshot.exists) { $key.SetValue('Path', [string]$Snapshot.value, [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], $Snapshot.kind))) }
        else { $key.DeleteValue('Path', $false) }
    } finally { $key.Dispose() }
}

function Assert-PathSnapshot($Actual, $Expected, [string] $Context) {
    Assert-Acceptance ($Actual.exists -eq $Expected.exists) "$Context`: PATH presence changed."
    if ($Expected.exists) {
        Assert-Acceptance ($Actual.kind -eq $Expected.kind) "$Context`: PATH registry type changed."
        Assert-Acceptance ($Actual.value -ceq $Expected.value) "$Context`: PATH token text/order changed.`nExpected: $($Expected.value)`nActual: $($Actual.value)"
    }
}

function Get-ProductValues($Hive = $script:TargetHive) {
    $key = $Hive.OpenSubKey($script:ProductKey)
    if (-not $key) { return $null }
    try {
        return @{ InstallScope = $key.GetValue('InstallScope'); InstallDir = $key.GetValue('InstallDir'); PathToken = $key.GetValue('PathToken'); PathOwned = $key.GetValue('PathOwned') }
    } finally { $key.Dispose() }
}

function Invoke-Install([string] $Exe = $Installer, [string] $Directory = $script:InstallDirectory, [string] $Tasks = 'addtopath', [switch] $MustFail, [string] $InstallScope = $Scope, [switch] $OmitDirectory) {
    $script:InstallerLogNumber++
    $log = Join-Path $ScratchRoot ('inno-{0:D3}.log' -f $script:InstallerLogNumber)
    $args = @('/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/' + $InstallScope.ToUpperInvariant()), "/TASKS=$Tasks", "/LOG=$log")
    if (-not $OmitDirectory) { $args += "/DIR=$Directory" }
    $result = Invoke-AcceptanceProcess -File $Exe -Arguments $args -Directory $ScratchRoot -ExpectedExit @() -TimeoutSeconds 600
    if ($MustFail) { Assert-Acceptance ($result.exit -ne 0) 'Installer accepted a forbidden ownership/scope/directory operation.' }
    else { Assert-Acceptance ($result.exit -eq 0) "Installer failed ($($result.exit)); inspect $log" }
    Assert-Acceptance (Test-Path -LiteralPath $log) "Installer did not save its native log: $log"
    return $result
}

function Invoke-Uninstall {
    $key = $script:TargetHive.OpenSubKey($script:UninstallKey)
    Assert-Acceptance ($null -ne $key) 'Product uninstall registration is missing.'
    try { $command = [string]$key.GetValue('UninstallString') } finally { $key.Dispose() }
    Assert-Acceptance ($command -match '^"([^"\r\n]+\.exe)"(?:\s.*)?$') "Unsafe or unexpected registered uninstall command: $command"
    $exe = $Matches[1]
    Assert-WithinRoot $exe $script:InstallDirectory
    $script:InstallerLogNumber++
    $log = Join-Path $ScratchRoot ('uninstall-{0:D3}.log' -f $script:InstallerLogNumber)
    $null = Invoke-AcceptanceProcess -File $exe -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$log") -Directory $ScratchRoot -TimeoutSeconds 600
    Assert-Acceptance ($null -eq (Get-ProductValues)) 'Product ownership registration survived uninstall.'
    $remaining = $script:TargetHive.OpenSubKey($script:UninstallKey)
    if ($remaining) { $remaining.Dispose(); throw 'Product uninstall registration survived uninstall.' }
    Assert-Acceptance (-not (Test-Path -LiteralPath (Join-Path $script:InstallDirectory 'cmd/git.exe'))) 'Git program survived uninstall.'
    Assert-Acceptance (-not (Test-Path -LiteralPath (Join-Path $script:InstallDirectory 'ucrt64/bin/git-lfs.exe'))) 'LFS program survived uninstall.'
}

function Assert-OtherScopeUnchanged {
    Assert-PathSnapshot (Get-PathValue $script:OtherHive $script:OtherEnvironmentKey) $otherPath 'Other registry scope'
    Assert-Acceptance ($null -eq (Get-ProductValues $script:OtherHive)) 'Installer wrote product ownership to the other scope.'
}

function Invoke-InstalledGit([string[]] $Arguments, [string] $Directory = $ScratchRoot) {
    return Invoke-AcceptanceProcess -File (Join-Path $script:InstallDirectory 'cmd/git.exe') -Arguments $Arguments -Directory $Directory -Environment (New-IsolatedEnvironment $script:InstallDirectory (Join-Path $ScratchRoot 'lifecycle-home'))
}

function Test-MaliciousManifests {
    $manifest = Join-Path $script:InstallDirectory 'payload-files.txt'
    $original = [IO.File]::ReadAllBytes($manifest)
    $outside = Join-Path $ScratchRoot 'outside-owned-delete-guard'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $victim = Join-Path $outside 'victim.txt'
    Write-Utf8 $victim 'must survive every malicious manifest'
    $hash = Get-Sha256 $victim
    $stale = Join-Path $script:InstallDirectory 'stale-before-malicious.txt'
    Write-Utf8 $stale 'must not be deleted before whole manifest validation'
    $junction = Join-Path $script:InstallDirectory 'escape-junction'
    try {
        $entries = @('..\outside-owned-delete-guard\victim.txt', $victim, '\outside-owned-delete-guard\victim.txt', 'escape-junction\victim.txt', 'cmd\..\stale-before-malicious.txt', 'C:relative-drive.txt')
        foreach ($bad in $entries) {
            if ($bad -eq 'escape-junction\victim.txt') { New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null }
            $text = [Text.Encoding]::UTF8.GetString($original).TrimEnd("`r", "`n") + "`nstale-before-malicious.txt`n$bad`n"
            Write-Utf8 $manifest $text
            $null = Invoke-Install -MustFail
            Assert-Acceptance ((Get-Sha256 $victim) -ceq $hash) "Manifest escaped installation: $bad"
            Assert-Acceptance (Test-Path -LiteralPath $stale) 'Stale file was removed before complete manifest validation.'
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        }
    } finally {
        [IO.File]::WriteAllBytes($manifest, $original)
        # Delete the link itself, never recurse into its external target.
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    }
    $text = [Text.Encoding]::UTF8.GetString($original).TrimEnd("`r", "`n") + "`nstale-before-malicious.txt`n"
    Write-Utf8 $manifest $text
    $null = Invoke-Install
    Assert-Acceptance (-not (Test-Path -LiteralPath $stale)) 'Upgrade retained an obsolete installer-owned file.'
    Assert-Acceptance ((Get-Sha256 $victim) -ceq $hash) 'Valid stale cleanup touched an external file.'
}

try {
    Assert-Acceptance (($Scope -eq 'CurrentUser' -and -not $admin) -or ($Scope -eq 'AllUsers' -and $admin)) 'CurrentUser acceptance requires a genuinely restricted token; AllUsers requires elevation. Use invoke-verify.ps1 on a disposable runner.'
    Assert-Acceptance ($null -eq (Get-ProductValues) -and $null -eq (Get-ProductValues $script:OtherHive)) 'A product installation already exists; refusing to modify it.'
    foreach ($hive in @($script:TargetHive, $script:OtherHive)) {
        $existing = $hive.OpenSubKey($script:UninstallKey)
        if ($existing) { $existing.Dispose(); throw 'Existing product uninstall registration: refusing takeover.' }
    }
    if ($env:CI -eq 'true') { Assert-Acceptance ([bool]$UpgradeInstaller) 'Full CI requires -UpgradeInstaller containing a genuinely older locked LFS release.' }
    if (-not $UpgradeInstaller) { $report.unverified += 'Older LFS upgrade (no UpgradeInstaller supplied)' }
    if (-not $UiEvidencePath) {
        $wizardRoot = Join-Path $ScratchRoot 'wizard'
        $wizardArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'smoke-wizard.ps1'), '-Installer', $Installer, '-InputsPath', $InputsPath, '-ScratchRoot', $wizardRoot)
        if ($env:CI -ne 'true') { $wizardArguments += '-AllowDesktopObservation' }
        $null = Invoke-AcceptanceProcess -File (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments $wizardArguments -Directory $ScratchRoot -TimeoutSeconds 240
        $UiEvidencePath = Join-Path $wizardRoot 'ui-evidence.json'
    }
    $originalPath = Get-PathValue $script:TargetHive $script:EnvironmentKey
    $otherPath = Get-PathValue $script:OtherHive $script:OtherEnvironmentKey
    $globalFiles = @((Join-Path $HOME '.gitconfig'), (Join-Path $HOME '.config/git/config'))
    $globalBefore = @{}
    foreach ($path in $globalFiles) { $globalBefore[$path] = if (Test-Path -LiteralPath $path) { Get-Sha256 $path } else { $null } }
    $token = Join-Path $script:InstallDirectory 'cmd'
    $basePath = 'C:\Other Git\cmd;;%SystemRoot%\System32'
    $fixtures = @(
        @{ Name = 'absent'; exists = $false; kind = $null; value = $null; preowned = $false },
        @{ Name = 'reg-sz'; exists = $true; kind = 'String'; value = $basePath; preowned = $false },
        @{ Name = 'reg-expand-sz'; exists = $true; kind = 'ExpandString'; value = $basePath; preowned = $false },
        @{ Name = 'preexisting-equivalent'; exists = $true; kind = 'ExpandString'; value = $basePath + ';"' + $token.ToUpperInvariant() + '\"'; preowned = $true }
    )
    foreach ($fixture in $fixtures) {
        Set-PathValue $fixture
        $first = $fixture.Name -eq 'absent'
        if ($first -and $UpgradeInstaller) {
            $null = Invoke-Install -Exe $UpgradeInstaller
            $oldVersion = (Invoke-InstalledGit @('lfs', 'version')).stdout.Trim()
            Assert-Acceptance ($oldVersion -match ('^git-lfs/' + [Regex]::Escape($inputs.upgradeFixture.lfs.version) + ' \(' + [Regex]::Escape($inputs.upgradeFixture.lfs.vendor) + ';')) 'Upgrade fixture does not contain the locked older real LFS executable.'
            Assert-Acceptance ([version]$inputs.upgradeFixture.lfs.version -lt [version]$inputs.lfs.version) 'Upgrade fixture LFS version is not older.'
            $gitExe = Join-Path $script:InstallDirectory 'ucrt64/bin/git.exe'
            $beforeGitHash = Get-Sha256 $gitExe
            $beforePeVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($gitExe).FileVersion
        } else { $null = Invoke-Install }
        $config = Join-Path $script:InstallDirectory 'etc/gitconfig'
        $customConfig = [IO.File]::ReadAllText($config) + "`n[acceptance]`n    preserved = user-system-value`n"
        Write-Utf8 $config $customConfig
        $extra = Join-Path $script:InstallDirectory 'user-created-file.txt'
        Write-Utf8 $extra "untracked user content $($fixture.Name)"
        $extraHash = Get-Sha256 $extra
        $null = Invoke-Install
        if ($first -and $UpgradeInstaller) {
            Assert-Acceptance ((Get-Sha256 $gitExe) -ceq $beforeGitHash) 'LFS-only upgrade unexpectedly changed Git binary.'
            Assert-Acceptance ([Diagnostics.FileVersionInfo]::GetVersionInfo($gitExe).FileVersion -ceq $beforePeVersion) 'LFS-only upgrade changed Git PE version.'
            $newVersion = (Invoke-InstalledGit @('lfs', 'version')).stdout.Trim()
            Assert-Acceptance ($newVersion -match ('^git-lfs/' + [Regex]::Escape($inputs.lfs.version) + ' \(' + [Regex]::Escape($inputs.lfs.vendor) + ';') -and $newVersion -cne $oldVersion) 'LFS-only upgrade did not replace the real LFS executable.'
        }
        Assert-Acceptance ([IO.File]::ReadAllText($config) -ceq $customConfig) 'Upgrade overwrote user system configuration.'
        Assert-Acceptance ((Get-Sha256 $extra) -ceq $extraHash) 'Upgrade modified an unowned file.'
        $product = Get-ProductValues
        Assert-Acceptance ($product.InstallScope -ceq $Scope -and $product.InstallDir -ieq $script:InstallDirectory -and $product.PathToken -ieq $token) 'Persisted ownership scope/path differs.'
        Assert-Acceptance ([int]$product.PathOwned -eq [int](-not $fixture.preowned)) 'Installer claimed a preexisting PATH token or lost its own token.'
        $afterInstall = Get-PathValue $script:TargetHive $script:EnvironmentKey
        $expectedValue = if ($fixture.preowned) { $fixture.value } elseif ($fixture.exists) { $fixture.value + ';' + $token } else { $token }
        Assert-Acceptance ($afterInstall.value -ceq $expectedValue) 'Repeated installation duplicated/reordered/rewrote PATH tokens.'
        if ($fixture.exists) { Assert-Acceptance ($afterInstall.kind -ceq $fixture.kind) 'Installation changed the PATH value type.' }
        Assert-OtherScopeUnchanged
        if ($first) {
            $null = Invoke-Install -OmitDirectory
            Assert-Acceptance ((Get-ProductValues).InstallDir -ieq $script:InstallDirectory) 'Upgrade without /DIR did not retain the registered installation directory.'
        }
        $null = Invoke-Install -Directory (Join-Path $ScratchRoot 'forbidden changed directory') -MustFail
        if ($Scope -eq 'AllUsers' -and $first) { $null = Invoke-Install -InstallScope 'CurrentUser' -MustFail }
        if ($first) {
            Test-MaliciousManifests
            $repository = Join-Path $ScratchRoot 'user repository must survive'
            $null = Invoke-InstalledGit @('init', '--initial-branch=main', $repository)
            Write-Utf8 (Join-Path $repository 'untracked.txt') 'repository must survive uninstall'
            $repoHash = Get-Sha256 (Join-Path $repository 'untracked.txt')
            $payloadArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'smoke-payload.ps1'), '-InstallRoot', $script:InstallDirectory, '-ScratchRoot', (Join-Path $ScratchRoot 'payload'), '-InputsPath', $InputsPath)
            if ($AutomateBrowser) { $payloadArgs += '-AutomateBrowser' }
            if ($UiEvidencePath) { $payloadArgs += @('-UiEvidencePath', $UiEvidencePath) }
            $null = Invoke-AcceptanceProcess -File (Join-Path $PSHOME 'pwsh.exe') -Arguments $payloadArgs -Directory $ScratchRoot -TimeoutSeconds 1200
        }
        # Unchecking the sole task must remove only the token we own.
        $null = Invoke-Install -Tasks ''
        Assert-PathSnapshot (Get-PathValue $script:TargetHive $script:EnvironmentKey) $fixture 'Deselected addtopath'
        Assert-Acceptance ([int](Get-ProductValues).PathOwned -eq 0) 'Deselected task retained PATH ownership.'
        $null = Invoke-Install
        $current = Get-PathValue $script:TargetHive $script:EnvironmentKey
        $late = 'C:\Added After Installation\bin'
        $noncmd = Join-Path $script:InstallDirectory 'user-tools'
        $current.value += ";$late;$noncmd"
        Set-PathValue $current
        Invoke-Uninstall
        $expectedAfter = @{ exists = $true; kind = $current.kind; value = if ($fixture.exists) { $fixture.value + ";$late;$noncmd" } else { "$late;$noncmd" } }
        Assert-PathSnapshot (Get-PathValue $script:TargetHive $script:EnvironmentKey) $expectedAfter 'Uninstall exact-token ownership'
        Assert-Acceptance ([IO.File]::ReadAllText($config) -ceq $customConfig) 'Uninstall deleted or modified user system configuration.'
        Assert-Acceptance ((Get-Sha256 $extra) -ceq $extraHash) 'Uninstall deleted an unowned file.'
        if ($first) { Assert-Acceptance ((Get-Sha256 (Join-Path $repository 'untracked.txt')) -ceq $repoHash) 'Uninstall touched the user repository.' }
        Assert-OtherScopeUnchanged
        $report.fixtures += @{ name = $fixture.Name; initial = $fixture; afterInstall = $afterInstall; afterUninstall = Get-PathValue $script:TargetHive $script:EnvironmentKey; passed = $true }
    }
    $absent = @{ exists = $false; kind = $null; value = $null }
    Set-PathValue $absent
    $null = Invoke-Install
    Invoke-Uninstall
    Assert-PathSnapshot (Get-PathValue $script:TargetHive $script:EnvironmentKey) $absent 'Uninstall originally absent PATH without later additions'
    Assert-OtherScopeUnchanged
    $report.fixtures += @{ name = 'absent-uninstall-no-additions'; passed = $true }
    foreach ($path in $globalFiles) {
        $after = if (Test-Path -LiteralPath $path) { Get-Sha256 $path } else { $null }
        Assert-Acceptance ($after -ceq $globalBefore[$path]) "Installer modified global user config: $path"
    }
    $null = Assert-ObservedUi $UiEvidencePath $inputs.releaseTag @('wizard-default-current-user', 'wizard-integrated-components') $report.installerSha256
    $report.passed = $true
    $report.fullAcceptance = $report.unverified.Count -eq 0
} catch {
    $report.failure = $_.Exception.ToString()
    throw
} finally {
    # Preserve logs/installed files on failure. Restore only the PATH fixture we changed;
    # never silently uninstall an installation whose failure needs investigation.
    try {
        if ($null -ne $originalPath) { Set-PathValue $originalPath }
    } catch {
        $report.passed = $false
        $report.fullAcceptance = $false
        $report.cleanupFailure = $_.Exception.ToString()
        throw
    } finally {
        $report.commands = $script:AcceptanceCommands.Count
        Write-Utf8 (Join-Path $ScratchRoot 'installer-evidence.json') ($report | ConvertTo-Json -Depth 12)
    }
}
