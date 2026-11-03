@echo off
rem LAN Switcher: запускаем на PowerShell 7 (pwsh), если установлен, иначе на Windows PowerShell 5.1
where pwsh.exe >nul 2>&1
if %errorlevel%==0 (
    start "" pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0LAN-Switcher.ps1"
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0LAN-Switcher.ps1"
)
