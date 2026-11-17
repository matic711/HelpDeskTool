@echo off
setlocal
title Odstranitev Opomnika
set "DEST=%LOCALAPPDATA%\Programs\Opomnik"
echo.
echo  Odstranjujem Opomnik ...

taskkill /im Opomnik.exe /f >nul 2>&1
timeout /t 1 /nobreak >nul

rem odstrani samodejni zagon ter bliznjici v meniju Start in na namizju
if exist "%DEST%\Opomnik.exe" start "" /wait "%DEST%\Opomnik.exe" /odstrani

rmdir /s /q "%DEST%" >nul 2>&1

echo.
echo  Opomnik je odstranjen.
echo  Tvoja opravila so ostala v %APPDATA%\Opomnik - to mapo lahko izbrises rocno.
echo.
pause
