@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\hermes.ps1" start -Open
if errorlevel 1 pause
