@echo off
REM Starts the WSL Profile Tray (prefer PowerShell 7, fallback to Windows PowerShell)
setlocal

where pwsh >nul 2>&1
if %errorlevel%==0 (
	pwsh -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WSLProfileTray.ps1"
) else (
	powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WSLProfileTray.ps1"
)

endlocal
