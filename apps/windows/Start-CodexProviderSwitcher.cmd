@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "LANSI_SWITCHER_LOG=%TEMP%\Lansi_CodexProviderManager-startup.log"
> "%LANSI_SWITCHER_LOG%" (
  echo # Lansi Codex Provider Manager native desktop startup log
  echo [%DATE% %TIME%] [launcher.begin] entry=Start-CodexProviderSwitcher.cmd
)
if not exist "%LANSI_SWITCHER_LOG%" (
  set "LANSI_SWITCHER_LOG=%~dp0Lansi_CodexProviderManager-startup.log"
  > "%LANSI_SWITCHER_LOG%" echo [%DATE% %TIME%] [launcher.begin] temp_unavailable=true
)

set "LANSI_SWITCHER_APP=%~dp0Lansi_CodexProviderManager.exe"
if not exist "%LANSI_SWITCHER_APP%" (
  >> "%LANSI_SWITCHER_LOG%" echo [%DATE% %TIME%] [launcher.app_missing]
  echo The Windows executable is missing: "%LANSI_SWITCHER_APP%"
  pause
  endlocal & exit /b 1
)

>> "%LANSI_SWITCHER_LOG%" echo [%DATE% %TIME%] [launcher.executable_start]
"%LANSI_SWITCHER_APP%" --debug-log "%LANSI_SWITCHER_LOG%"
set "LANSI_EXIT=%ERRORLEVEL%"
>> "%LANSI_SWITCHER_LOG%" echo [%DATE% %TIME%] [launcher.application_exit] exitCode=%LANSI_EXIT%
if not "%LANSI_EXIT%"=="0" (
  echo.
  echo The native desktop UI exited with an error.
  echo Diagnostic log: "%LANSI_SWITCHER_LOG%"
  pause
)
endlocal & exit /b %LANSI_EXIT%
