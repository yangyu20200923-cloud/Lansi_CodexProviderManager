[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Start-CodexProviderSwitcher.cmd'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Codex API Provider Switcher.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcher
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Switch Codex Desktop between OpenAI, Qilin, and VectorEngine'
$shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,65"
$shortcut.Save()

Write-Host "Desktop shortcut created: $shortcutPath"
