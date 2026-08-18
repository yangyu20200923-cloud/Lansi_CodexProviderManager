[CmdletBinding()]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lansi Codex Provider Manager.lnk')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Start-CodexProviderSwitcher.cmd'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}
$icon = Join-Path $PSScriptRoot 'LansiObserve.ico'
if (-not (Test-Path -LiteralPath $icon)) {
    throw "Application icon not found: $icon"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Lansi Codex Provider Manager'
$shortcut.IconLocation = "$icon,0"
$shortcut.Save()

Write-Host "Desktop shortcut created: $shortcutPath"
