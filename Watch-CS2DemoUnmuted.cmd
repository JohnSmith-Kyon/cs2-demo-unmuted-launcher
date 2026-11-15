@echo off
setlocal EnableExtensions
set "LAUNCHER=%~dp0Watch-CS2DemoUnmuted.ps1"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
    set "POWERSHELL_EXE=pwsh.exe"
)

if "%~1"=="" (
    "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%"
) else (
    "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" -DemoPath "%~f1"
)

set "LAUNCH_EXIT=%ERRORLEVEL%"
echo.
if not "%LAUNCH_EXIT%"=="0" (
    echo Launcher failed. Review the error above.
) else (
    echo Launcher finished.
)
pause
exit /b %LAUNCH_EXIT%
