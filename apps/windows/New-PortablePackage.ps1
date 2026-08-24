[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$Replace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}

$bundleName = 'Lansi_CodexProviderManager'
$executableFileName = 'Lansi_CodexProviderManager.exe'
$bundleDirectory = Join-Path $OutputDirectory $bundleName
$archivePath = Join-Path $OutputDirectory ($bundleName + '-windows-portable.zip')
$sourceFiles = @(
    'README.md',
    'LansiObserve.ico',
    'Start-CodexProviderSwitcher.cmd',
    'Install-DesktopShortcut.ps1',
    'Install-Lansi_CodexProviderManager.cmd',
    'Install-Lansi_CodexProviderManager.ps1',
    'Uninstall-Lansi_CodexProviderManager.cmd',
    'Uninstall-Lansi_CodexProviderManager.ps1'
)

foreach ($file in $sourceFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {
        throw "Package source is incomplete: $file"
    }
}
$executableBuilder = Join-Path $PSScriptRoot 'New-WindowsExecutable.ps1'
if (-not (Test-Path -LiteralPath $executableBuilder)) {
    throw "Executable build script is missing: $executableBuilder"
}
if ((Test-Path -LiteralPath $bundleDirectory) -or (Test-Path -LiteralPath $archivePath)) {
    if (-not $Replace) {
        throw "Package output already exists. Re-run with -Replace to update: $OutputDirectory"
    }
    if (Test-Path -LiteralPath $bundleDirectory) { Remove-Item -LiteralPath $bundleDirectory -Recurse -Force }
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
}

$executablePath = Join-Path $OutputDirectory $executableFileName
if ($Replace) {
    & $executableBuilder -OutputDirectory $OutputDirectory -Replace
}
elseif (-not (Test-Path -LiteralPath $executablePath)) {
    & $executableBuilder -OutputDirectory $OutputDirectory
}
if (-not (Test-Path -LiteralPath $executablePath)) {
    throw "Executable build completed without the expected output: $executablePath"
}

New-Item -ItemType Directory -Path $bundleDirectory -Force | Out-Null
foreach ($file in $sourceFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $bundleDirectory $file) -Force
}
$packageExecutable = Join-Path $bundleDirectory $executableFileName
Copy-Item -LiteralPath $executablePath -Destination $packageExecutable -Force

$secretPattern = 'sk-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9_-]{20,}'
$textFiles = Get-ChildItem -LiteralPath $bundleDirectory -File | Where-Object { $_.Extension -in @('.cmd', '.md', '.ps1') }
if ($textFiles | Select-String -Pattern $secretPattern -CaseSensitive) {
    throw 'Portable package contains a possible embedded API key.'
}

Compress-Archive -LiteralPath $bundleDirectory -DestinationPath $archivePath -CompressionLevel Optimal
Write-Host "Portable package created: $archivePath"
Write-Host 'The package contains no Codex home, profile catalog, backup, session, Skill, MCP, plugin, or credential data.'
