#requires -Version 5.1
# SPDX-License-Identifier: GPL-2.0-only
# Select the real browser in Windows' native HTML chooser; never forge UserChoice.
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Default-browser fixture is restricted to disposable GitHub runners.' }
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$record = [ordered]@{ selected = $false; browser = 'Microsoft Edge'; mechanism = 'native HTML chooser UI Automation'; observedUtc = [DateTime]::UtcNow.ToString('o') }
$deadline = [DateTime]::UtcNow.AddSeconds(10)
$chooser = $null
while (-not $chooser -and [DateTime]::UtcNow -lt $deadline) {
    $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
    foreach ($window in $windows) {
        if ($window.Current.IsOffscreen -or $window.Current.ClassName -ne 'Shell_LightDismissOverlay') { continue }
        $question = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'How do you want to open this file?'))
        if ($question) { $chooser = $window; break }
    }
    if (-not $chooser) { Start-Sleep -Milliseconds 200 }
}
if ($chooser) {
    $elements = $chooser.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $record.controls = @($elements | ForEach-Object { @{ name=$_.Current.Name; type=$_.Current.ControlType.ProgrammaticName; id=$_.Current.AutomationId } })
    [IO.File]::WriteAllText($OutputPath, ($record | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $always = @($elements | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::CheckBox -and $_.Current.Name -like '*Always use*this app*.html*' })
    if ($always.Count -ne 1) { throw 'Native chooser is not the expected HTML default-app prompt.' }
    $toggle = $always[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On) { $toggle.Toggle() }
    $edge = @($elements | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name -match '^Microsoft Edge(?:\s|,|$)' })
    $selected = $false
    foreach ($candidate in $edge) {
        $node = $candidate
        for ($level = 0; $node -and $level -lt 6; $level++) {
            $pattern = $null
            if ($node.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select(); $selected = $true; break }
            if ($node.Current.Name -match '^Microsoft Edge(?:\s|,|$)' -and $node.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); $selected = $true; break }
            $node = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
        }
        if ($selected) { break }
    }
    if (-not $selected) { throw 'Cannot select the real Microsoft Edge entry in the native chooser.' }
    $ok = $chooser.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button), [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'OK')))
    if ($ok) { $ok.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $record.selected = $true
}
$choice = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice')
if ($choice) { try { $record.progId = $choice.GetValue('ProgId') } finally { $choice.Dispose() } }
[IO.File]::WriteAllText($OutputPath, ($record | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
