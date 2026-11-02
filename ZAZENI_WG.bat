@echo off
rem Dvoklik za zagon. Skripta sama zahteva admin pravice, najde .conf v tej mapi
rem in vprasa za mail. Ce gumbov VPN_ON/VPN_OFF ne rabis, zbrisi -CreateDesktopButtons.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0skriptaWG.ps1" -CreateDesktopButtons
