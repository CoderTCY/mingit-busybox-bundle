#requires -Version 5.1
# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$BrowserProcessId,
    [Parameter(Mandatory)][string]$ExpectedPath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This helper runs in inbox Windows PowerShell, not the parent's PowerShell 7.
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BundleBrowserWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$expected = [IO.Path]::GetFullPath($ExpectedPath)
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)))
$processes = New-Object 'Collections.Generic.HashSet[int]'
$null = $processes.Add($BrowserProcessId)
$window = $null
$address = $null
$observations = @{}
$deadline = [DateTime]::UtcNow.AddSeconds(20)
do {
    $snapshot = @(Get-CimInstance Win32_Process)
    do {
        $added = $false
        foreach ($process in $snapshot) {
            if ($processes.Contains([int]$process.ParentProcessId) -and $processes.Add([int]$process.ProcessId)) { $added = $true }
        }
    } while ($added)
    $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
    foreach ($candidate in $windows) {
        if (-not $processes.Contains($candidate.Current.ProcessId) -or $candidate.Current.IsOffscreen) { continue }
        $controls = $candidate.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit))
        foreach ($control in $controls) {
            $pattern = $null
            $supportsValue = $control.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)
            $key = "$($candidate.Current.ProcessId)|$($control.Current.AutomationId)|$($control.Current.Name)"
            $observations[$key] = @{ pid=$candidate.Current.ProcessId; name=$control.Current.Name; automationId=$control.Current.AutomationId; offscreen=$control.Current.IsOffscreen; supportsValue=$supportsValue; value=$(if ($supportsValue) { $pattern.Current.Value } else { $null }) }
            if ($control.Current.IsOffscreen -or -not $supportsValue) { continue }
            $value = $pattern.Current.Value
            try {
                $uri = $null
                # Edge omits file: in its address bar but retains URL escaping.
                if ($value.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase) -and [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and $uri.IsFile) { $path = $uri.LocalPath }
                else { $path = [Uri]::UnescapeDataString($value) }
                if ([IO.Path]::GetFullPath($path) -ieq $expected) { $window = $candidate; $address = $value; break }
            } catch { continue }
        }
        if ($window) { break }
    }
    if ($window) { break }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $window) {
    $failure = @{ expectedPath=$expected; browserProcessId=$BrowserProcessId; processIds=@($processes | ForEach-Object { $_ }); controls=@($observations.Values); windows=@($windows | ForEach-Object { @{title=$_.Current.Name;pid=$_.Current.ProcessId;offscreen=$_.Current.IsOffscreen} }) }
    [IO.File]::WriteAllText(($OutputPath + '.failure.json'), ($failure | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $screen = [Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)
        $bitmap.Save([IO.Path]::ChangeExtension($OutputPath, '.failed.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    throw "No visible real browser address bar contains the local manual path: $expected"
}
$handle = [IntPtr]$window.Current.NativeWindowHandle
$null = [BundleBrowserWindow]::SetForegroundWindow($handle)
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while ([BundleBrowserWindow]::GetForegroundWindow() -ne $handle) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Browser window could not be foregrounded for a real desktop screenshot' }
    Start-Sleep -Milliseconds 100
}
$rect = $window.Current.BoundingRectangle
$screen = [Windows.Forms.SystemInformation]::VirtualScreen
$left = [Math]::Max([int]$rect.Left, $screen.Left)
$top = [Math]::Max([int]$rect.Top, $screen.Top)
$right = [Math]::Min([int]$rect.Right, $screen.Right)
$bottom = [Math]::Min([int]$rect.Bottom, $screen.Bottom)
if ($right - $left -lt 100 -or $bottom - $top -lt 100) { throw 'Browser window has no usable visible desktop bounds' }
$bitmap = New-Object Drawing.Bitmap(($right - $left), ($bottom - $top))
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
    $bitmap.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose(); $bitmap.Dispose() }
$record = @{ expectedPath = $expected; addressBar = $address; title = $window.Current.Name; browserProcessId = $BrowserProcessId; observedUtc = [DateTime]::UtcNow.ToString('o'); screenshot = [IO.Path]::GetFileName($OutputPath) }
[IO.File]::WriteAllText(($OutputPath + '.window.json'), ($record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "Observed real browser address bar and captured local manual: $address"
