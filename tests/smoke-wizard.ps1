#requires -Version 5.1
# Run with the inbox Windows PowerShell so native UIAutomation uses its supported
# .NET Framework desktop assemblies. This observes the real installer and cancels
# at Ready to Install; it never substitutes dialogs or invokes installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][string] $InputsPath,
    [Parameter(Mandatory)][string] $ScratchRoot,
    [switch] $AllowDesktopObservation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Do not autoload PowerShell 7 modules inherited through PSModulePath into 5.1.
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($env:CI -ne 'true' -and -not $AllowDesktopObservation) { throw 'Wizard automation requires disposable CI or explicit -AllowDesktopObservation on the local desktop.' }
if (Test-Path -LiteralPath $ScratchRoot) { throw 'Wizard ScratchRoot must be new.' }
$null = [IO.Directory]::CreateDirectory($ScratchRoot)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BundleWizardWindow {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
}
'@
$utf8 = New-Object Text.UTF8Encoding($false)
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
$report = [ordered]@{ releaseTag = $inputs.releaseTag; installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant(); observer = 'real-installer-UIAutomation'; observedUtc = [DateTime]::UtcNow.ToString('o'); passed = $false; checks = @(); pages = @(); failure = $null }
$process = $null
$knownProcesses = New-Object 'Collections.Generic.HashSet[int]'

function Get-InstallerWindow([switch]$AllowExit) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($AllowExit -and $process.HasExited) { return $null }
        $allProcesses = @(Get-CimInstance Win32_Process)
        do {
            $added = $false
            foreach ($p in $allProcesses) { if ($knownProcesses.Contains([int]$p.ParentProcessId) -and $knownProcesses.Add([int]$p.ProcessId)) { $added = $true } }
        } while ($added)
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
        foreach ($window in $windows) {
            if ($knownProcesses.Contains($window.Current.ProcessId) -and -not $window.Current.IsOffscreen -and $window.Current.IsEnabled) { return $window }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'No visible real installer window appeared. An interactive desktop is required.'
}

function Get-Controls($Window) {
    return @($Window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
}

function Save-WindowEvidence($Window, [string] $Name) {
    $null = [BundleWizardWindow]::SetForegroundWindow([IntPtr]$Window.Current.NativeWindowHandle)
    $rect = $Window.Current.BoundingRectangle
    if ($rect.Width -lt 100 -or $rect.Height -lt 100) { throw 'Installer window has no visible bounds.' }
    $bitmap = New-Object Drawing.Bitmap([int]$rect.Width, [int]$rect.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try {
            if (-not [BundleWizardWindow]::PrintWindow([IntPtr]$Window.Current.NativeWindowHandle, $dc, 2)) { throw 'Unable to capture the real installer window.' }
        } finally { $graphics.ReleaseHdc($dc) }
        $file = Join-Path $ScratchRoot ($Name + '.png')
        $bitmap.Save($file, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $tree = @(Get-Controls $Window | ForEach-Object { @{ name = $_.Current.Name; controlType = $_.Current.ControlType.ProgrammaticName; enabled = $_.Current.IsEnabled; offscreen = $_.Current.IsOffscreen; focused = $_.Current.HasKeyboardFocus; automationId = $_.Current.AutomationId } })
    [IO.File]::WriteAllText((Join-Path $ScratchRoot ($Name + '.json')), ($tree | ConvertTo-Json -Depth 6), $utf8)
    return @{ screenshot = $Name + '.png'; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(); title = $Window.Current.Name; controls = $tree }
}

function Invoke-UiControl($Control) {
    $pattern = $null
    if ($Control.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
    if ($Control.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select(); return }
    throw "Real UI control is not invokable: $($Control.Current.Name)"
}

function Find-Button($Controls, [string] $Pattern) {
    return @($Controls | Where-Object { $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and $_.Current.Name -match $Pattern -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button }) | Select-Object -First 1
}

try {
    $target = Join-Path $ScratchRoot 'wizard must not install'
    $process = Start-Process -FilePath $Installer -ArgumentList @('/SP-', '/NORESTART', ('/DIR="' + $target + '"')) -PassThru
    $null = $knownProcesses.Add($process.Id)
    $window = Get-InstallerWindow
    $controls = Get-Controls $window
    $currentUser = Find-Button $controls '(?i)(me only|current user|just me)'
    if (-not $currentUser) { throw 'Real install-scope dialog did not expose the current-user choice before installation.' }
    $style = [BundleWizardWindow]::GetWindowLongPtr([IntPtr]$currentUser.Current.NativeWindowHandle, -16).ToInt64() -band 15
    $isDefault = $currentUser.Current.HasKeyboardFocus -or $style -in @(1, 15)
    if (-not $isDefault) { throw 'The real privilege dialog did not default to the current user.' }
    $scopeEvidence = Save-WindowEvidence $window 'default-current-user'
    $report.checks += @{ name = 'wizard-default-current-user'; screenshot = $scopeEvidence.screenshot; sha256 = $scopeEvidence.sha256; notes = 'Real privilege dialog current-user button had keyboard focus or native default-button style; no /CURRENTUSER flag was supplied.' }
    Invoke-UiControl $currentUser
    Start-Sleep -Milliseconds 400
    $ready = $false
    for ($step = 0; $step -lt 12; $step++) {
        $window = Get-InstallerWindow
        $controls = Get-Controls $window
        $names = @($controls | Where-Object { -not $_.Current.IsOffscreen } | ForEach-Object { $_.Current.Name })
        if (($names -join "`n") -match '(?i)select components') { throw 'Installer exposed a component selection page; all four payload components must be mandatory.' }
        $optionalComponent = @($controls | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::CheckBox -and $_.Current.Name -match '(?i)(Git LFS|documentation|localization|translation)' })
        if ($optionalComponent.Count) { throw 'A required payload component is optional in the real wizard.' }
        $page = Save-WindowEvidence $window ('wizard-page-{0:D2}' -f $step)
        $report.pages += $page
        if (($names -join "`n") -match '(?i)ready to install') {
            $ready = $true
            $report.checks += @{ name = 'wizard-integrated-components'; screenshot = $page.screenshot; sha256 = $page.sha256; notes = 'Traversed every real wizard page up to Ready to Install: no component page or optional required component.' }
            break
        }
        $accept = $controls | Where-Object { $_.Current.Name -match '(?i)^I accept the agreement' -and -not $_.Current.IsOffscreen } | Select-Object -First 1
        if ($accept) { Invoke-UiControl $accept }
        $next = Find-Button $controls '(?i)^&?Next\s*>?$'
        if (-not $next) { throw "Wizard cannot advance from real page: $($window.Current.Name)" }
        Invoke-UiControl $next
        Start-Sleep -Milliseconds 400
    }
    if (-not $ready) { throw 'Wizard did not reach Ready to Install.' }
    $cancel = Find-Button (Get-Controls $window) '(?i)^&?Cancel$'
    if (-not $cancel) { throw 'Real wizard Cancel button missing.' }
    Invoke-UiControl $cancel
    $cancelDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $process.HasExited) {
        $confirmation = Get-InstallerWindow -AllowExit
        if (-not $confirmation) { break }
        $yes = Find-Button (Get-Controls $confirmation) '(?i)^&?Yes$'
        if ($yes) { Invoke-UiControl $yes }
        if ([DateTime]::UtcNow -gt $cancelDeadline) { throw 'Wizard did not complete cancellation.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not $process.WaitForExit(30000)) { throw 'Wizard failed to exit after cancellation.' }
    $report.cancelExitCode = $process.ExitCode
    # Inno cancellation before installation conventionally returns 2.
    if ($process.ExitCode -notin @(0, 2)) { throw "Unexpected installer cancellation exit: $($process.ExitCode)" }
    if (Test-Path -LiteralPath (Join-Path $target 'cmd/git.exe')) { throw 'Wizard UI probe unexpectedly installed the product.' }
    $report.passed = $true
} catch {
    $report.failure = $_.Exception.ToString()
    throw
} finally {
    if ($process) {
        foreach ($id in $knownProcesses) {
            $alive = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($alive) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
        $process.Dispose()
    }
    [IO.File]::WriteAllText((Join-Path $ScratchRoot 'ui-evidence.json'), ($report | ConvertTo-Json -Depth 12), $utf8)
}
