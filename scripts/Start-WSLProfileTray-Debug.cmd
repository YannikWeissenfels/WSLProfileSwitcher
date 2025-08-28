@echo on
REM Debug starter: Prefer PowerShell 7, fallback to Windows PowerShell; keeps console open to show errors
setlocal
where pwsh >nul 2>&1
if %errorlevel%==0 (
	pwsh -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WSLProfileTray.ps1"
) else (
	powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WSLProfileTray.ps1"
)
endlocal
echo.
echo If the icon did not appear, review any errors above.
pause
