@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "INSTALLER=%~dp0Install-Lansi_CodexProviderManager.ps1"
if not exist "%INSTALLER%" (
  echo Installer not found: "%INSTALLER%"
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
set "LANSI_EXIT=%ERRORLEVEL%"
if not "%LANSI_EXIT%"=="0" (
  echo.
  echo Installation failed. Read the message above, then try again.
) else (
  echo.
  echo Installation complete. Use the desktop shortcut to launch Lansi Codex Provider Manager.
)
pause
endlocal & exit /b %LANSI_EXIT%
