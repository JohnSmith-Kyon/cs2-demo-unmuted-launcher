@echo off
setlocal EnableExtensions
set "CLEANER=%~dp0Clear-CS2LocalDemos.ps1"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
    set "POWERSHELL_EXE=pwsh.exe"
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%CLEANER%" %*

set "CLEAN_EXIT=%ERRORLEVEL%"
echo.
if not "%CLEAN_EXIT%"=="0" (
    echo Cleanup failed. Review the error above.
) else (
    echo Cleanup finished.
)
pause
exit /b %CLEAN_EXIT%
