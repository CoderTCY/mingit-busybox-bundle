#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][string] $UpgradeInstaller,
    [Parameter(Mandatory)][string] $InputsPath,
    [Parameter(Mandatory)][ValidateSet('CurrentUser', 'AllUsers')][string] $Scope,
    [Parameter(Mandatory)][string] $ScratchRoot,
    [string] $UiEvidencePath
)
. "$PSScriptRoot/acceptance-common.ps1"
Assert-Acceptance ($env:GITHUB_ACTIONS -eq 'true' -and $env:CI -eq 'true' -and -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) 'Account/registry lifecycle orchestration is allowed only on a disposable GitHub Actions runner. Run smoke-installer directly under an already restricted account for local testing.'
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
Assert-WithinRoot $ScratchRoot $env:RUNNER_TEMP
Assert-Acceptance (-not (Test-Path -LiteralPath $ScratchRoot)) 'ScratchRoot must be new.'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-Acceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Disposable runner orchestrator requires an elevated parent to provision a restricted account or run AllUsers.'
[IO.Directory]::CreateDirectory($ScratchRoot) | Out-Null
$script:AcceptanceLogRoot = Join-Path $ScratchRoot 'orchestrator-commands'
$script:AcceptanceCommands = [Collections.Generic.List[object]]::new()
$report = [ordered]@{ passed = $false; scope = $Scope; restrictedAccount = $null; childExitCode = $null; failure = $null }
$user = $null
$child = $null
try {
    # The test account receives only offline artifacts and scripts, no build SDK/cache.
    $artifacts = Join-Path $ScratchRoot 'offline-artifacts'
    $scripts = Join-Path $artifacts 'tests'
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Copy-Item -Destination $scripts
    Copy-Item -LiteralPath $Installer -Destination (Join-Path $artifacts 'bundle.exe')
    Copy-Item -LiteralPath $UpgradeInstaller -Destination (Join-Path $artifacts 'older-lfs.exe')
    Copy-Item -LiteralPath $InputsPath -Destination (Join-Path $artifacts 'inputs.json')
    if ($UiEvidencePath) {
        $ui = Join-Path $artifacts 'observed-ui'
        [IO.Directory]::CreateDirectory($ui) | Out-Null
        Copy-Item -LiteralPath $UiEvidencePath -Destination (Join-Path $ui 'evidence.json')
        $uiData = Get-Content -LiteralPath $UiEvidencePath -Raw | ConvertFrom-Json
        foreach ($check in $uiData.checks) {
            $relative = [string]$check.screenshot
            Assert-Acceptance (-not [IO.Path]::IsPathRooted($relative) -and '..' -notin ($relative -split '[/\\]')) 'UI screenshot must be a safe relative artifact path.'
            $destination = Join-Path $ui $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $UiEvidencePath) $relative) -Destination $destination -Force
        }
    }
    $parameters = @{
        Installer = Join-Path $artifacts 'bundle.exe'
        UpgradeInstaller = Join-Path $artifacts 'older-lfs.exe'
        InputsPath = Join-Path $artifacts 'inputs.json'
        Scope = $Scope
        ScratchRoot = Join-Path $ScratchRoot 'lifecycle'
        AutomateBrowser = $true
    }
    if ($UiEvidencePath) { $parameters.UiEvidencePath = Join-Path $ui 'evidence.json' }
    $launch = @{ script = Join-Path $scripts 'smoke-installer.ps1'; parameters = $parameters }
    Write-Utf8 (Join-Path $artifacts 'launch.json') ($launch | ConvertTo-Json -Depth 6)
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$env:CI = 'true'
$context = [ordered]@{ identity = $null; sid = $null; administrator = $null }
# Resolve the loaded profile by the real token SID. Environment.GetFolderPath
# can reuse inherited USERPROFILE/APPDATA values under secondary logon.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $sid = $identity.User.Value
    $context.sid = $sid
    $context.identity = $identity.Name
    $context.administrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} finally { $identity.Dispose() }
$profileKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid")
if (-not $profileKey) { throw 'Current token has no registered Windows profile.' }
try { $profile = [string]$profileKey.GetValue('ProfileImagePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
finally { $profileKey.Dispose() }
$profile = [Environment]::ExpandEnvironmentVariables($profile)
if (-not $profile -or -not [IO.Path]::IsPathRooted($profile)) { throw 'Current token has no valid Windows profile path.' }
$env:USERPROFILE = $profile
$env:HOME = $profile
Set-Variable -Name HOME -Value $profile -Force
$env:APPDATA = Join-Path $profile 'AppData/Roaming'
$env:LOCALAPPDATA = Join-Path $profile 'AppData/Local'
$env:TEMP = Join-Path $env:LOCALAPPDATA 'Temp'
$env:TMP = $env:TEMP
[IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
$context.profile = $profile
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-context.json'), ($context | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
'@
    # CreateProcessWithLogonW limits its command line to 1024 characters.
    # Put the bootstrap and data in files rather than an oversized Base64 argument.
    $launcher = Join-Path $artifacts 'run-acceptance.ps1'
    $bootstrap += "`n" + @'
$launch = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launch.json') -Raw | ConvertFrom-Json -AsHashtable
try {
    $parameters = $launch.parameters
    & $launch.script @parameters
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
    Write-Utf8 $launcher $bootstrap
    $childArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher)
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    if ($Scope -eq 'CurrentUser') {
        $name = 'mgb' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $random = [byte[]]::new(36)
        [Security.Cryptography.RandomNumberGenerator]::Fill($random)
        $secret = [Convert]::ToBase64String($random) + 'aA9!'
        $password = ConvertTo-SecureString $secret -AsPlainText -Force
        $secret = $null
        $user = New-LocalUser -Name $name -Password $password -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Disposable MinGit Bundle acceptance account'
        Add-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')) -Member $user
        $report.restrictedAccount = $user.SID.Value
        $acl = Get-Acl -LiteralPath $ScratchRoot
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($user.SID, [Security.AccessControl.FileSystemRights]::Modify, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $ScratchRoot -AclObject $acl
        $credential = [Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$name", $password)
        $child = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $launcher + '"')) -Credential $credential -LoadUserProfile -WorkingDirectory $artifacts -RedirectStandardOutput (Join-Path $ScratchRoot 'restricted-stdout.log') -RedirectStandardError (Join-Path $ScratchRoot 'restricted-stderr.log') -PassThru
        if (-not $child.WaitForExit(3600000)) { $child.Kill($true); $child.WaitForExit(); throw 'Restricted account acceptance exceeded one hour.' }
        $report.childExitCode = $child.ExitCode
        Assert-Acceptance ($child.ExitCode -eq 0) "Restricted CurrentUser acceptance failed: exit $($child.ExitCode). See restricted-stderr.log and lifecycle evidence."
    } else {
        $result = Invoke-AcceptanceProcess -File $pwsh -Arguments $childArguments -Directory $artifacts -TimeoutSeconds 3600
        $report.childExitCode = $result.exit
    }
    $evidence = Get-Content -LiteralPath (Join-Path $parameters.ScratchRoot 'installer-evidence.json') -Raw | ConvertFrom-Json
    Assert-Acceptance ($evidence.passed -and $evidence.fullAcceptance) 'Lifecycle script returned without complete acceptance evidence.'
    $payload = Get-Content -LiteralPath (Join-Path $parameters.ScratchRoot 'payload/payload-evidence.json') -Raw | ConvertFrom-Json
    Assert-Acceptance ($payload.passed) 'Payload acceptance evidence is not passing.'
    $report.passed = $true
} catch {
    $report.failure = $_.Exception.ToString()
    throw
} finally {
    try {
        if ($child) { $child.Dispose() }
        if ($user) { Remove-LocalUser -SID $user.SID }
    } catch {
        $report.passed = $false
        $report.cleanupFailure = $_.Exception.ToString()
        throw
    } finally {
        Write-Utf8 (Join-Path $ScratchRoot 'verify-evidence.json') ($report | ConvertTo-Json -Depth 8)
    }
}
