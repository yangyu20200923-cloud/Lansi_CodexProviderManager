[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Lansi_CodexProviderManager'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lansi Codex Provider Manager.lnk')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ((Split-Path -Leaf $InstallRoot) -ne 'Lansi_CodexProviderManager') {
    throw 'InstallRoot must end with Lansi_CodexProviderManager.'
}

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
}
if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    Write-Host "Removed: $InstallRoot"
}
else {
    Write-Host "Not installed: $InstallRoot"
}
Write-Host 'Codex homes, profiles, sessions, Skills, MCP, plugins, backups, and credentials were not changed.'
