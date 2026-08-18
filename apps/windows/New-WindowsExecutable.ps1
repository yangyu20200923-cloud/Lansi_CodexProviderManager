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

$applicationName = 'Lansi_CodexProviderManager'
$executableFileName = 'Lansi_CodexProviderManager.exe'
$entryPoint = Join-Path $PSScriptRoot 'desktop_app.py'
$iconPath = Join-Path $PSScriptRoot 'LansiObserve.ico'
$executablePath = Join-Path $OutputDirectory $executableFileName

foreach ($path in @($entryPoint, $iconPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Windows executable source is missing: $path"
    }
}

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$pythonArguments = @()
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command py.exe -ErrorAction SilentlyContinue
    $pythonArguments = @('-3')
}
if ($null -eq $pythonCommand) {
    throw 'Python 3.10 or later is required only to build the Windows executable. Install Python with python.exe or py.exe, then run this script again.'
}
$pythonExe = $pythonCommand.Source
$versionText = (& $pythonExe @pythonArguments --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'Python\s+(\d+\.\d+\.\d+)') {
    throw "Could not determine the Python version used for the executable build: $versionText"
}
if ([version]$matches[1] -lt [version]'3.10.0') {
    throw "Python 3.10 or later is required to build the executable; found $versionText."
}

if (Test-Path -LiteralPath $executablePath) {
    if (-not $Replace) {
        throw "Executable output already exists. Re-run with -Replace to update: $executablePath"
    }
    Remove-Item -LiteralPath $executablePath -Force
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$buildRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.Lansi_CodexProviderManager-build-' + [guid]::NewGuid())
$virtualEnvironment = Join-Path $buildRoot 'venv'
$venvPython = Join-Path $virtualEnvironment 'Scripts\python.exe'
$stagingDirectory = Join-Path $buildRoot 'dist'

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
try {
    & $pythonExe @pythonArguments -m venv $virtualEnvironment
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
        throw 'Could not create the temporary Python build environment for PyInstaller.'
    }

    & $venvPython -m pip install --disable-pip-version-check --no-input --quiet 'pyinstaller>=6,<7'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not install the build-only PyInstaller dependency. Check the build machine network and Python pip configuration.'
    }

    # PyInstaller bundles Tcl/Tk for the native desktop surface; no browser assets or listener are required.
    & $venvPython -m PyInstaller --noconfirm --clean --onefile --windowed `
        --name $applicationName --icon $iconPath --add-data "$iconPath;." `
        --distpath $stagingDirectory --workpath (Join-Path $buildRoot 'work') `
        --specpath (Join-Path $buildRoot 'spec') $entryPoint
    if ($LASTEXITCODE -ne 0) {
        throw 'PyInstaller failed to create Lansi_CodexProviderManager.exe. Read the PyInstaller output above before retrying.'
    }

    $stagedExecutable = Join-Path $stagingDirectory $executableFileName
    if (-not (Test-Path -LiteralPath $stagedExecutable)) {
        throw "PyInstaller completed without the expected executable: $stagedExecutable"
    }
    Copy-Item -LiteralPath $stagedExecutable -Destination $executablePath -Force
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}

Write-Host "Windows executable created: $executablePath"
Write-Host 'The executable is self-contained for end users and does not require an installed Python runtime.'
