@echo off
rem Пересборка LAN-Switcher.exe из исходников. Запускать НЕ от админа.
where pwsh.exe >nul 2>&1 && (set "PS=pwsh.exe") || (set "PS=powershell.exe")
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build.ps1"
echo.
pause
