# Security Policy

This project is a local Windows tray utility for switching WSL profiles. It runs under your user account and does not require admin rights.

## Scope and threat model
- Local-only utility. No network connections and no telemetry.
- Writes: `%UserProfile%\.wslconfig` to swap profiles.
- Executes: `wsl --shutdown` to restart WSL, VS Code CLI to quit/reopen windows.
- Reads: Windows theme setting (read-only) to adapt tray theme.
- No services or background installers. The tray exits when you quit it.

## Reporting a vulnerability
Please open a private issue or contact via a confidential channel if available. If none is available, create a new GitHub issue with minimal details and request a private follow-up.

Provide:
- Version (Release tag) and how you launched it (VBS/EXE/PowerShell).
- Steps to reproduce.
- Expected vs. actual behavior.
- Environment (Windows version, PowerShell version).

## Build and verification
- Builds are produced from `scripts/WSLProfileTray.ps1` using PS2EXE.
- Each release should include a SHA-256 checksum. Optionally a code signature.
- Users can verify:
  - Hash: `Get-FileHash .\WSLProfileTray.exe -Algorithm SHA256`
  - Signature: `Get-AuthenticodeSignature .\WSLProfileTray.exe | Format-List`

## Update policy
- Semantic Versioning (MAJOR.MINOR.PATCH).
- Changes that affect behavior or touched files will be documented in the release notes.

## Hardening guidance for users
- Download from the official release page only.
- Verify SHA-256 (and signature if present) before running.
- Keep Windows Defender/SmartScreen enabled; expect a warning for unsigned binaries.