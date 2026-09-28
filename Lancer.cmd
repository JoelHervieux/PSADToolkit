@echo off
setlocal
rem PSADToolkit : meme lanceur que PSADToolkit.exe. Launcher.ps1 s execute avec
rem Windows PowerShell 5.1, present sur tout Windows 10, 11 et Server 2016 ou plus
rem recent ; il installe au besoin PowerShell 7 et GliderUI, puis ouvre l interface.
rem Voir README.md.
set "ADT_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ADT_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%ADT_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Launcher.ps1" %*
if errorlevel 1 (
  echo.
  echo Lancement impossible. Journal : %LOCALAPPDATA%\PSADToolkit\Logs\launcher.log
  pause
)
endlocal
