[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location $PSScriptRoot
try {
    Write-Host '[1/5] Python compilation'
    & python -m py_compile switch_provider.py
    if ($LASTEXITCODE -ne 0) { throw 'Python compilation failed.' }

    Write-Host '[2/5] Unit tests'
    & python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed.' }

    Write-Host '[3/5] PowerShell parser checks'
    foreach ($file in @('CodexProviderSwitcher.ps1', 'Install-DesktopShortcut.ps1', 'Test-Switcher.ps1')) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $file), [ref]$tokens, [ref]$errors
        ) | Out-Null
        if ($errors.Count -gt 0) {
            $errors | Format-List -Force
            throw "PowerShell parse failed: $file"
        }
    }

    Write-Host '[4/5] CLI dry-run against isolated data'
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-switch-test-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $config = Join-Path $tempRoot 'config.toml'
        Set-Content -LiteralPath $config -Encoding UTF8 -Value @'
model = "test"
model_provider = "openai"

[plugins.test]
enabled = true
'@
        $state = Join-Path $tempRoot 'missing-state.sqlite'
        & python switch_provider.py --config $config --state-db $state switch qilin --dry-run | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Isolated CLI dry-run failed.' }
        if (Test-Path (Join-Path $tempRoot 'backups')) { throw 'Dry-run unexpectedly created backups.' }
    }
    finally {
        if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }

    Write-Host '[5/5] Embedded API key pattern scan'
    $sourceFiles = Get-ChildItem -File -Recurse | Where-Object {
        $_.Extension -in @('.py', '.ps1', '.cmd', '.md') -and $_.FullName -notmatch '\\__pycache__\\'
    }
    $matches = $sourceFiles | Select-String -Pattern 'sk-[A-Za-z0-9_-]{20,}' -CaseSensitive
    if ($matches) {
        $matches | Format-Table Path, LineNumber -AutoSize
        throw 'A possible embedded API key was found.'
    }

    Write-Host 'PASS: all switcher checks completed successfully.' -ForegroundColor Green
}
finally {
    Pop-Location
}
