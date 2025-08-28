' Launch the tray without a console window (try pwsh, fallback to Windows PowerShell)
Dim shell
Set shell = CreateObject("WScript.Shell")
Dim ps1Path, cmd
ps1Path = Replace(WScript.ScriptFullName, "Start-WSLProfileTray.vbs", "WSLProfileTray.ps1")
cmd = "cmd /c (pwsh -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File """ & ps1Path & """) || (powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File """ & ps1Path & """)"
shell.Run cmd, 0, False
Set shell = Nothing
