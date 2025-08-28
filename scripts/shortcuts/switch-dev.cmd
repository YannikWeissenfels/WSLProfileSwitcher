@echo off
REM Single-click: Dev profile (prefer PowerShell 7)
setlocal
where pwsh >nul 2>&1
if %errorlevel%==0 (
	pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.wslprofiles\scripts\Switch-WSLProfile.ps1" -Profile dev
) else (
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.wslprofiles\scripts\Switch-WSLProfile.ps1" -Profile dev
)
endlocal
