@echo off
setlocal
rem PSADToolkit 3.x : l interface est batie sur GliderUI et exige PowerShell 7.4 ou
rem superieur. Windows PowerShell (powershell.exe) ne convient plus. Voir README.md.
set "ADT_PWSH="
for /f "delims=" %%I in ('where pwsh 2^>nul') do if not defined ADT_PWSH set "ADT_PWSH=%%I"
if not defined ADT_PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "ADT_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined ADT_PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "ADT_PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined ADT_PWSH (
  echo PowerShell 7.4 ou superieur est requis : pwsh.exe est introuvable.
  echo Installer PowerShell 7, puis le module GliderUI. Consulter README.md.
  pause
  exit /b 1
)
"%ADT_PWSH%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Start-PSADToolkit.ps1"
if errorlevel 1 (
  echo.
  echo Lancement impossible. Lire le message ci-dessus et README.md.
  pause
)
endlocal
