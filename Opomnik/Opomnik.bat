@echo off
rem Zazene Opomnik v ozadju (brez crnega okna PowerShella).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Opomnik.ps1"
