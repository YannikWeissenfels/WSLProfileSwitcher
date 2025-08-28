# Privacy Notice

This utility does not collect, transmit, or sell any personal data. It operates locally on your machine.

## Data processing
- Network: none. No outbound requests, no telemetry.
- Files written:
  - `%UserProfile%\\.wslconfig` — profile content is swapped when you switch.
  - `scripts\\tray.log` and `%TEMP%\\WSLProfileSwitcher.log` — local diagnostic logs. You may delete these at any time.
- Files read:
  - Windows theme setting (read-only) to adapt the tray menu.
  - Local `.ico` files in `scripts\\icons` if provided by you.

## Permissions
- Runs as your standard user. No administrator privileges required.
- Uses `wsl.exe` and the VS Code CLI under your user context.

## User controls
- You can disable or delete logs by removing the log files. They are only created locally.
- Quit the tray from its context menu to stop all activity.

## Contact
For privacy questions, open an issue or use the same confidential channel as in SECURITY.md if available.