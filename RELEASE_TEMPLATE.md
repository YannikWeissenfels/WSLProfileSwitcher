# Release vX.Y.Z

## Changes
- Short bullet points of what changed.

## What this app does
- Switches WSL profiles by writing `%UserProfile%\.wslconfig`.
- Restarts WSL via `wsl --shutdown`.
- Closes and reopens VS Code using its CLI to restore previous windows.
- Optional: reads Windows theme (read-only) for tray styling.
- No network, no telemetry, no admin rights.

## Download
- WSLProfileTray.exe (SHA-256 and optional signature below)
- SHA256SUMS.txt

## Verify integrity
Windows PowerShell (copy/paste):

```powershell
Get-FileHash .\WSLProfileTray.exe -Algorithm SHA256
Get-AuthenticodeSignature .\WSLProfileTray.exe | Format-List
```

Compare the hash to `SHA256SUMS.txt`. If a signature is present, the Status should be `Valid` and the signer should match the publisher.

## Notes
- Windows SmartScreen may warn for unsigned binaries (“Unknown publisher”). Verify hash/signature, then use “More info” → “Run anyway”.
- Switching profiles stops running WSL instances (your Linux processes will be terminated).
