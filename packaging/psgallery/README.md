Publish to PowerShell Gallery (optional)

Two options:

1) Publish the module `src/WSLProfileSwitcher` so users can `Install-Module WSLProfileSwitcher` and import helpers (e.g., `Get-WslActiveProfile`).
   - Update `src/WSLProfileSwitcher.psd1` with your `Author`, `ProjectUri`, `LicenseUri`, `Tags`.
   - Test: `Test-ModuleManifest src/WSLProfileSwitcher.psd1`
   - Publish: `Publish-Module -Path src -NuGetApiKey <APIKEY>`

2) Publish the tray script as a script package so users can `Install-Script WSLProfileTray` and run it without cloning.
   - Extract the tray logic in `scripts/WSLProfileTray.ps1` to a top-level script `WSLProfileTray.ps1` with a proper comment-based help.
   - Publish: `Publish-Script -Path .\WSLProfileTray.ps1 -NuGetApiKey <APIKEY>`

Notes
- PowerShell Gallery is great for admins/Power users; non-admin installs are supported with `-Scope CurrentUser`.
- For the GUI tray, WinGet or a ZIP release is friendlier for broader audiences.

