@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexProviderSwitcher.ps1"
if errorlevel 1 (
  echo.
  echo The Codex provider switcher exited with an error.
  pause
)
endlocal
