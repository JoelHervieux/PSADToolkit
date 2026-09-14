@echo off
setlocal
set "ADT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ADT_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ADT_POWERSHELL%" (
  echo Windows PowerShell 2.0 minimum est requis. Consulter README.md.
  pause
  exit /b 1
)
"%ADT_POWERSHELL%" -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Start-PSADToolkit.ps1"
if errorlevel 1 (
  echo.
  echo Lancement impossible. Lire le message ci-dessus et README.md.
  pause
)
endlocal
