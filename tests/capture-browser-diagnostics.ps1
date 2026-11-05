#requires -Version 5.1
# Failure-only CI observation; never changes associations or opens a substitute page.
param([Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class BundleAssociationProbe {
    [DllImport("shlwapi.dll", CharSet=CharSet.Unicode, EntryPoint="AssocQueryStringW")]
    public static extern uint Query(uint flags, uint kind, string association,
        string extra, StringBuilder output, ref uint length);
}
'@
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$record = [ordered]@{ associations = @(); windows = @(); browsers = @() }
foreach ($extension in @('.html', '.htm')) {
    $entry = [ordered]@{ extension = $extension; userChoice = $null; command = $null; executable = $null; errors = @() }
    $choice = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$extension\UserChoice")
    if ($choice) { try { $entry.userChoice = $choice.GetValue('ProgId') } finally { $choice.Dispose() } }
    foreach ($query in @(@{name='command';kind=1}, @{name='executable';kind=2})) {
        [uint32]$length = 0
        $status = [BundleAssociationProbe]::Query(0, $query.kind, $extension, 'open', $null, [ref]$length)
        if ($length -gt 0 -and $length -lt 65536) {
            $buffer = New-Object Text.StringBuilder([int]$length)
            $status = [BundleAssociationProbe]::Query(0, $query.kind, $extension, 'open', $buffer, [ref]$length)
            if ($status -eq 0) { $entry[$query.name] = $buffer.ToString() }
        }
        if ($status -ne 0) { $entry.errors += @{query=$query.name;status=$status} }
    }
    $record.associations += $entry
}
$windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
foreach ($window in $windows) {
    try { $record.windows += @{ title=$window.Current.Name; pid=$window.Current.ProcessId; offscreen=$window.Current.IsOffscreen; class=$window.Current.ClassName; bounds=[string]$window.Current.BoundingRectangle } } catch { }
}
$record.browsers = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('msedge.exe','chrome.exe','firefox.exe','iexplore.exe') } | Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine)
[IO.File]::WriteAllText((Join-Path $OutputRoot 'windows-browser-state.json'), ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$screen = [Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object Drawing.Bitmap($screen.Width, $screen.Height)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $OutputRoot 'desktop.png'), [Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose(); $bitmap.Dispose() }
