@echo off
chcp 65001 >nul

REM Git i GCM dolaze u WorkBuddy-evom PortableGit-u, koji nije na sistemskom
REM PATH-u. Dodajemo bin direktorijum pre poziva.
set "GITBIN=%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\mingw64\bin"
if not exist "%GITBIN%\git.exe" (
  REM Ako se verzija promeni, probaj automatski da je nadjes
  for /d %%D in ("%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\*") do set "GITBIN=%%~fD\mingw64\bin"
)
set "PATH=%GITBIN%;%PATH%"

cd /d "%~dp0"

set GHUSER=pnkiro62-max
set REPO=KiRo-PC-Diagnostic

echo ==========================================================
echo   KiRo PC Diagnostic - push to GitHub
echo   https://github.com/%GHUSER%/%REPO%
echo ==========================================================
echo.
echo If the repository does not exist yet, create it first at
echo github.com/new  ->  name : KiRo-PC-Diagnostic
echo                 ->  type : Private
echo                 ->  do NOT add README, .gitignore or license
echo.
pause

git remote remove origin 2>nul
git remote add origin https://github.com/%GHUSER%/%REPO%.git
git branch -M main

echo.
echo Pushing branch main. If a window opens, sign in to GitHub.
echo.

git push -u origin main

echo.
pause
