@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title KiRo v4.2 - pokreni i snimi greske

set "LOGDIR=%USERPROFILE%\OneDrive\Documents\KiRo_PC_Diagnostic_Logs"
if not exist "%LOGDIR%" set "LOGDIR=%USERPROFILE%\Documents\KiRo_PC_Diagnostic_Logs"

echo.
echo  ============================================================
echo   KiRo v4.2 - POKRETAC SA SNIMANJEM GRESKE
echo  ============================================================
echo.
echo  1) Sklanja stari KiRo_GUI_error.log u .prev.log
echo     (da znamo da je sve sto ostane NOVA greska)
echo  2) Pokrece KiRo v4.2 GUI
echo  3) Kada ZATVORIS KiRo prozor, vrati se ovde i pritisni ENTER
echo     - ako je bilo greske, otvara se log u Notepad-u
echo.

if exist "%LOGDIR%\KiRo_GUI_error.log" (
  move /y "%LOGDIR%\KiRo_GUI_error.log" "%LOGDIR%\KiRo_GUI_error.prev.log" >nul 2>&1
  echo  [OK] Stari log premesten u KiRo_GUI_error.prev.log
) else (
  echo  [--] Nije bilo starog loga - krecemo od nule.
)

echo.
echo  Pokrecem KiRo v4.2 GUI...
echo  (ako Windows pita za Administratora, prihvati)
echo.
call "%~dp0POKRENI_KiRo_PC_Diagnostic_v4_2_GUI.bat"

echo.
echo  ============================================================
echo   Pritisni ENTER tek kada ZATVORIS KiRo prozor.
echo  ============================================================
pause >nul

echo.
if exist "%LOGDIR%\KiRo_GUI_error.log" (
  echo  PRONADJENA GRESKA.
  echo  Log: %LOGDIR%\KiRo_GUI_error.log
  echo.
  echo  Otvaram ga u Notepad-u...
  echo.
  start "" notepad.exe "%LOGDIR%\KiRo_GUI_error.log"
) else (
  echo  NEMA GRESKE - KiRo_GUI_error.log ne postoji.
  echo  Program je prosao cisto (ili se greska nije javila).
)
echo.
echo  Folder sa logovima:
echo  %LOGDIR%
echo.
pause
exit /b 0
