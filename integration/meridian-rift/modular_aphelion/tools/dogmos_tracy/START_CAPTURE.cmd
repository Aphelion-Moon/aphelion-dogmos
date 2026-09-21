@echo off
setlocal
rem Use Windows PowerShell's built-in modules even when launched from PowerShell 7.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
set "capture_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "capture_powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%capture_powershell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DogmosCapture.ps1" %*
set "capture_exit=%ERRORLEVEL%"
if not "%capture_exit%"=="0" echo Capture failed. Review the error above and any saved launch.json or capture.json.
pause
exit /b %capture_exit%
