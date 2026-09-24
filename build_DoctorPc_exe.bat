@echo off
setlocal
title DoctorPc - pravim .exe
set "CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo Nije nadjen csc.exe (.NET Framework). Instaliraj .NET Framework 4.x.
  pause
  exit /b 1
)
"%CSC%" /nologo /target:winexe /r:System.Windows.Forms.dll /out:"%~dp0DoctorPc.exe" "%~dp0DoctorPc_src.cs"
if errorlevel 1 (
  echo.
  echo GRESKA pri kompajliranju. Pogledaj poruku iznad.
  pause
  exit /b 1
)
echo.
echo DoctorPc.exe je napravljen u istom folderu.
echo Posalji taj .exe prijatelju.
pause
