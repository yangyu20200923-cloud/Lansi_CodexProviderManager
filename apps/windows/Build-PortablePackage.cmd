@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "PACKAGER=%~dp0New-PortablePackage.ps1"
set "ARCHIVE=%~dp0dist\Lansi_CodexProviderManager-windows-portable.zip"
set "EXECUTABLE=%~dp0dist\Lansi_CodexProviderManager.exe"

if not exist "%PACKAGER%" (
  echo Portable package script not found: "%PACKAGER%"
  pause
  endlocal & exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACKAGER%" -Replace
set "LANSI_EXIT=%ERRORLEVEL%"
if not "%LANSI_EXIT%"=="0" (
  echo.
  echo Packaging failed. Read the error above and correct it before retrying.
  pause
  endlocal & exit /b %LANSI_EXIT%
)

if not exist "%ARCHIVE%" (
  echo.
  echo Packaging completed without the expected archive: "%ARCHIVE%"
  pause
  endlocal & exit /b 1
)
if not exist "%EXECUTABLE%" (
  echo.
  echo Packaging completed without the expected executable: "%EXECUTABLE%"
  pause
  endlocal & exit /b 1
)

echo.
echo Windows executable created: "%EXECUTABLE%"
echo Portable package created: "%ARCHIVE%"
echo The archive contains application files only. No Codex data or credentials were included.
pause
endlocal & exit /b 0
