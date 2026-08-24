[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Lansi_CodexProviderManager'),
    [switch]$Replace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-InstallRoot {
    param([string]$Path)
    if ((Split-Path -Leaf $Path) -ne 'Lansi_CodexProviderManager') {
        throw 'InstallRoot must end with Lansi_CodexProviderManager.'
    }
}

Assert-InstallRoot -Path $InstallRoot

$requiredFiles = @(
    'LansiObserve.ico',
    'Lansi_CodexProviderManager.exe',
    'Start-CodexProviderSwitcher.cmd',
    'Install-DesktopShortcut.ps1',
    'Install-Lansi_CodexProviderManager.cmd',
    'Uninstall-Lansi_CodexProviderManager.cmd',
    'Uninstall-Lansi_CodexProviderManager.ps1'
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {
        throw "Installer source is incomplete: $file"
    }
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lansi Codex Provider Manager.lnk'
$parent = Split-Path -Parent $InstallRoot
$staging = Join-Path $parent ('.Lansi_CodexProviderManager-staging-' + [guid]::NewGuid())

if (Test-Path -LiteralPath $InstallRoot) {
    if (-not $Replace) {
        throw "Already installed: $InstallRoot. Re-run with -Replace to update it."
    }
}

New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    foreach ($file in $requiredFiles) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $staging $file) -Force
    }
    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
    Move-Item -LiteralPath $staging -Destination $InstallRoot
    & (Join-Path $InstallRoot 'Install-DesktopShortcut.ps1') -ShortcutPath $shortcutPath
    Write-Host "Installed: $InstallRoot"
    Write-Host 'Codex homes, profiles, sessions, Skills, MCP, plugins, backups, and credentials were not changed.'
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
