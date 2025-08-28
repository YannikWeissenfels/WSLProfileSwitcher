# WSL Profile Switcher

Lightweight tray app to switch WSL2 resource profiles (processors/memory), gracefully restart WSL, and reopen VS Code. Packaged as a console-less EXE; ships portable or via a simple install script.

## Why
- Prevents WSL from hogging resources during calls/meetings (fixes audio glitches, echo, and noise suppression issues).
- One-click or hotkey profiles: Meeting (low), Balanced, Dev (high).
- Zero learning curve: no terminal needed, no admin required for install.

## Features
- Tray icon with quick profile switching (Meeting/Balanced/Dev)
- Global hotkeys (Ctrl+Alt+P/D/B/M)
- Startup toggle and settings dialog (per-profile CPUs/Memory)
- Portable build via PS2EXE, with verification (SHA-256)

## Building
Run `scripts/build.ps1`. Artifacts are placed in `dist/`.

## Installation
- Portable: download from GitHub Releases and run `WSLProfileTray.exe` (no installer needed).
- Installer-less install: `scripts/install.ps1` copies into `%LocalAppData%\Programs\WSLProfileTray` and creates Start Menu / optional Startup shortcuts.
- WinGet: planned (coming soon). Once published: `winget install yweis.WSLProfileSwitcher`.

## Contributing
Please read `CODE_OF_CONDUCT.md`. Open issues and PRs welcome.

## License
MIT — see `LICENSE`.
# WSL Profile Switcher Tray

A lightweight Windows tray to switch between WSL profiles (Dev Extreme, Balanced, Meeting). It cleanly closes VS Code, applies the selected `.wslconfig`, restarts WSL, and reopens the same VS Code windows.

## Features
- Tray menu with three profiles: Dev Extreme, Balanced, Meeting
- Graceful VS Code restart (quit + reopen last windows)
- Supports custom icons per profile in `scripts/icons`
- Windows-like dark/light themed menu with subtle hover
- PowerShell 5.1 compatible, prefers PowerShell 7 (`pwsh`) if installed

## Quick start (no console window)
Double-click `scripts/Start-WSLProfileTray.vbs` to start the tray silently.

To autostart at login, create a shortcut to that VBS in `shell:startup`.

## Install (recommended)
- Install to your user profile with Start Menu entry and optional autostart:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

- Uninstall:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

## Shortcuts
- Open menu: Ctrl+Alt+P
- Switch to Dev Extreme: Ctrl+Alt+D
- Switch to Balanced: Ctrl+Alt+B
- Switch to Meeting: Ctrl+Alt+M

Enable/disable in the tray: Shortcuts → “Enable global hotkeys”.

## Custom icons
Place `.ico` files in `scripts/icons`:
- `dev.ico` (optional `dev-active.ico`)
- `balanced.ico` (optional `balanced-active.ico`)
- `desktop.ico` (optional `desktop-active.ico`) — Meeting

Recommended: include a 16×16 size (and optionally 20/24/32) inside the `.ico`.

## Build a console-less EXE
We use PS2EXE to package the tray script into an EXE without a console window.

1) Open PowerShell (pwsh recommended) and run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
.\scripts\build.ps1
```

Output: `dist\WSLProfileTray.exe`

Optional: supply an icon parameter in the script, then pin the EXE to Start/Taskbar.

## Repo layout
- `scripts/WSLProfileTray.ps1` — tray app
- `scripts/Switch-WSLProfile.ps1` — switching logic (close VS Code, apply profile, restart WSL, reopen)
- `scripts/Start-WSLProfileTray.vbs` — silent starter (windowless)
- `scripts/icons/` — profile icons
- `dist/` — build artifacts (after running build)

## Troubleshooting
- If the tray doesn’t appear, check `scripts/tray.log` and `%TEMP%\WSLProfileSwitcher.log`.
- If VS Code doesn’t reopen, ensure the VS Code setting "Window: Restore Windows" is enabled.
- If hover looks wrong, the tray falls back to system renderer; see logs for `CalmRenderer applied`.

## Verify the download
For releases that include an EXE, verify integrity before running:

```powershell
Get-FileHash .\dist\WSLProfileTray.exe -Algorithm SHA256
Get-AuthenticodeSignature .\dist\WSLProfileTray.exe | Format-List
```

 - Compare the SHA-256 to `dist/SHA256SUMS.txt` (or the value shown on the release page).
- If a signature is present, the Status should be `Valid`.

## Security & privacy
- No network calls, no telemetry.
- Writes `%UserProfile%\\.wslconfig` to swap profiles.
- Executes `wsl --shutdown` and VS Code CLI to quit/reopen.
- Reads Windows theme (read-only) for tray appearance.

Details: see `SECURITY.md` and `PRIVACY.md`.

## SmartScreen & Defender
Unsigned EXEs can trigger “Unknown publisher”. This is expected for personal tools. You can:
- Verify the hash (and signature if provided).
- Use “More info” → “Run anyway”.

Tip: Running via the provided VBS or the PowerShell script avoids SmartScreen for the EXE itself.
