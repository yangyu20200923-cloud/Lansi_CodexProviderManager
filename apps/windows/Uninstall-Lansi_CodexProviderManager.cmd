@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "UNINSTALLER=%~dp0Uninstall-Lansi_CodexProviderManager.ps1"
if not exist "%UNINSTALLER%" (
  echo Uninstaller not found: "%UNINSTALLER%"
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALLER%" %*
set "LANSI_EXIT=%ERRORLEVEL%"
if not "%LANSI_EXIT%"=="0" (
  echo.
  echo Uninstall failed. Read the message above, then try again.
) else (
  echo.
  echo Uninstall complete. Codex data was not changed.
)
pause
endlocal & exit /b %LANSI_EXIT%
