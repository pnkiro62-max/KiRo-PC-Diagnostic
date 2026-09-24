@echo off
chcp 65001 >nul
REM -----------------------------------------------------------------
REM  RTK omotnica za KiRo PC Diagnostic projekat.
REM  Rtk komprimuje ispis gustih shell/git komandi (status, log, diff,
REM  ls, grep) da stedi kontekst. Ova skripta podesava PATH (rtk + git)
REM  i pokrece rtk iz korena projekta.
REM
REM  Koriscenje:
REM     rtk.bat git status
REM     rtk.bat git log -n 10
REM     rtk.bat git diff
REM     rtk.bat ls
REM     rtk.bat grep "pattern" .
REM -----------------------------------------------------------------

REM WorkBuddy-ev PortableGit (git nije na sistemskom PATH-u)
set "GITBIN=%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\mingw64\bin"
if not exist "%GITBIN%\git.exe" (
  for /d %%D in ("%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\*") do set "GITBIN=%%~fD\mingw64\bin"
)

REM RTK binary (winget) ili .cmd wrapper
set "RTKBIN=%LOCALAPPDATA%\Microsoft\WinGet\Packages\rtk-ai.rtk_Microsoft.Winget.Source_8wekyb3d8bbwe\rtk.exe"
if not exist "%RTKBIN%" set "RTKBIN=%USERPROFILE%\.local\bin\rtk.cmd"
if not exist "%RTKBIN%" (
  echo RTK nije pronadjen. Instaliraj:  winget install rtk-ai.rtk
  echo Ili ga dodaj u PATH.
  pause
  exit /b 1
)

set "PATH=%GITBIN%;%RTKBIN:~0,-7%;%PATH%"
cd /d "%~dp0"

"%RTKBIN%" %*
