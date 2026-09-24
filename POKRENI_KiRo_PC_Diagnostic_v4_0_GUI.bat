@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title KiRo PC Diagnostic ^& Repair v4.0 GUI

set "GUI=%~dp0KiRo_PC_Diagnostic_Repair_v4_0_GUI.ps1"
set "ENGINE=%~dp0KiRo_PC_Diagnostic_Repair_v4_0_ENGINE.ps1"

if not exist "%GUI%" (
  echo GRESKA: Nedostaje GUI fajl.
  pause
  exit /b 1
)
if not exist "%ENGINE%" (
  echo GRESKA: Nedostaje ENGINE fajl.
  pause
  exit /b 1
)

set "KIRO_FILE=%GUI%"
call :CHECK_PS
if errorlevel 1 goto :BADCODE
set "KIRO_FILE=%ENGINE%"
call :CHECK_PS
if errorlevel 1 goto :BADCODE

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo KiRo GUI se zaustavio sa greskom. Kod: %RC%
  echo Pogledaj logove u Documents\KiRo_PC_Diagnostic_Logs.
  pause
)
exit /b %RC%

:CHECK_PS
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($env:KIRO_FILE,[ref]$t,[ref]$e)|Out-Null;if($e.Count){Write-Host '';Write-Host ('GRESKA U '+$env:KIRO_FILE) -ForegroundColor Red;$e|ForEach-Object{Write-Host ('Linija '+$_.Extent.StartLineNumber+': '+$_.Message) -ForegroundColor Red};exit 90}else{exit 0}"
exit /b %ERRORLEVEL%

:BADCODE
echo.
echo KiRo nije pokrenut zbog PowerShell greske prikazane iznad.
pause
exit /b 90
