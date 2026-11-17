@echo off
setlocal
cd /d "%~dp0"
title Namestitev Opomnika
echo.
echo  Namescam Opomnik ...
echo.

rem C# prevajalnik, ki je ze vgrajen v Windows (.NET Framework 4)
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" goto :nocsc

set "DEST=%LOCALAPPDATA%\Programs\Opomnik"
if not exist "%DEST%" mkdir "%DEST%"

rem ce Opomnik ze tece, ga ugasnemo, da ga lahko zamenjamo z novo razlicico
taskkill /im Opomnik.exe /f >nul 2>&1
timeout /t 1 /nobreak >nul

"%CSC%" /nologo /codepage:65001 /target:winexe /optimize+ /out:"%DEST%\Opomnik.exe" /win32icon:Opomnik.ico /resource:Opomnik.ico,Opomnik.ico /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /r:System.Management.dll Opomnik.cs
if errorlevel 1 goto :failed

start "" "%DEST%\Opomnik.exe" /namesti

echo.
echo  ------------------------------------------------------------
echo   Opomnik je namescen in zagnan.
echo   Najdes ga v meniju Start in na namizju (ikona z rdecim klicajem).
echo   Sam se bo zagnal ob vsaki prijavi v Windows.
echo.
echo   Mapo, iz katere si ga namestil, lahko zdaj izbrises.
echo  ------------------------------------------------------------
echo.
pause
exit /b 0

:nocsc
echo  Na tem racunalniku ni najden prevajalnik csc.exe iz .NET Framework 4.
echo  Poslji mi to sporocilo, pa poiscemo drugo resitev.
echo.
pause
exit /b 1

:failed
echo.
echo  Prevajanje ni uspelo - zgoraj je izpis napake.
echo  Poslji mi ga, pa popravim.
echo.
pause
exit /b 1
