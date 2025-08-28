#requires -Version 5.1
<#
Synopsis: Switch WSL2 resource profile, gracefully close VS Code, shutdown WSL, and relaunch VS Code (restoring previous windows).

Usage examples:
  pwsh -ExecutionPolicy Bypass -File .\Switch-WSLProfile.ps1 -Profile balanced
  pwsh -ExecutionPolicy Bypass -File .\Switch-WSLProfile.ps1 -Profile dev -NoVSCodeRestore

Notes:
  - Expects three .wslconfig variants in $env:USERPROFILE\.wslprofiles: desktop.wslconfig, balanced.wslconfig, dev.wslconfig
  - Copies the chosen file to %UserProfile%\.wslconfig
  - Ensures C:\wsl exists for the configured swapfile path
  - Attempts a graceful VS Code quit via vscode://command/workbench.action.quit, then force-kills as fallback
  - Relies on VS Code setting "window.restoreWindows" (default: all) to reopen previous windows
  - Logs activity to %TEMP%\WSLProfileSwitcher.log
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $false)]
  [ValidateSet('desktop', 'balanced', 'dev')]
  [string]$Profile,

  [switch]$NoGUI,
  [switch]$NoVSCodeRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts][$Level] $Message"
  Write-Host $line
  Add-Content -Path (Join-Path $env:TEMP 'WSLProfileSwitcher.log') -Value $line
}

function Get-CodeCommand {
  # Try PATH first
  try {
    $null = & code --version 2>$null
    return 'code'
  }
  catch {}

  # Common install locations
  $candidates = @(
    Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd')
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}

function Export-VSCodeStatus {
  $statusPath = Join-Path $env:TEMP 'vscode_status_before_switch.txt'
  $codeCmd = Get-CodeCommand
  if ($codeCmd) {
    try {
      Write-Log "Collecting 'code --status' to $statusPath"
      & $codeCmd --status | Out-String | Set-Content -Path $statusPath -Encoding UTF8
    }
    catch {
      Write-Log "Failed to run 'code --status': $($_.Exception.Message)" 'WARN'
    }
  }
  else {
    Write-Log "VS Code 'code' CLI not found in PATH; skipping status export" 'WARN'
  }
}

function Close-VSCode {
  $processNames = @('Code', 'Code - Insiders')
  $running = Get-Process | Where-Object { $_.Name -in $processNames } -ErrorAction SilentlyContinue
  if (-not $running) { Write-Log 'VS Code not running'; return }

  Write-Log 'Attempting graceful VS Code quit via vscode://command/workbench.action.quit'
  try {
    # Use cmd start to ensure protocol handler is invoked properly
    Start-Process -FilePath cmd.exe -ArgumentList '/c', 'start', '""', 'vscode://command/workbench.action.quit' -WindowStyle Hidden
    Start-Sleep -Seconds 2
  }
  catch {
    Write-Log "Failed to invoke vscode:// command: $($_.Exception.Message)" 'WARN'
  }

  # Wait up to a few seconds for shutdown
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 6) {
    $still = Get-Process | Where-Object { $_.Name -in $processNames } -ErrorAction SilentlyContinue
    if (-not $still) { Write-Log 'VS Code exited gracefully'; return }
    Start-Sleep -Milliseconds 300
  }

  # Fallback: force kill
  Write-Log 'VS Code still running; force-stopping processes' 'WARN'
  foreach ($p in (Get-Process | Where-Object { $_.Name -in $processNames } -ErrorAction SilentlyContinue)) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Write-Log "Stop-Process failed for PID $($p.Id): $($_.Exception.Message)" 'WARN' }
  }
}

function Ensure-SwapFolder {
  $swapDir = 'C:\wsl'
  if (-not (Test-Path -LiteralPath $swapDir)) {
    Write-Log "Creating swap directory $swapDir"
    New-Item -ItemType Directory -Path $swapDir -Force | Out-Null
  }
}

function Apply-WSLProfile {
  param([Parameter(Mandatory)] [ValidateSet('desktop', 'balanced', 'dev')] [string]$Name)

  $src = Join-Path $env:USERPROFILE ".wslprofiles\$Name.wslconfig"
  $dst = Join-Path $env:USERPROFILE '.wslconfig'
  if (-not (Test-Path -LiteralPath $src)) { throw "Profile file not found: $src" }
  Write-Log "Copying $src -> $dst"
  Copy-Item -Path $src -Destination $dst -Force
}

function Restart-WSL {
  Write-Log 'Shutting down WSL: wsl --shutdown'
  try { wsl --shutdown | Out-Null } catch { Write-Log "wsl --shutdown error: $($_.Exception.Message)" 'WARN' }
  # The docs recommend ~8 seconds to pick up .wslconfig changes
  Start-Sleep -Seconds 8
}

function Reopen-VSCode {
  if ($NoVSCodeRestore) { Write-Log 'Skipping VS Code relaunch per flag'; return }
  $codeCmd = Get-CodeCommand
  if (-not $codeCmd) { Write-Log 'VS Code CLI not found; skipping relaunch' 'WARN'; return }
  Write-Log "Launching VS Code ($codeCmd) (will restore previous windows if configured)"
  try {
    Start-Process -FilePath $codeCmd -ArgumentList @() -WindowStyle Hidden | Out-Null
  }
  catch {
    Write-Log "Failed to launch 'code': $($_.Exception.Message)" 'WARN'
  }
}

function Show-GuiAndSelectProfile {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'WSL Profile Switcher'
  $form.Size = New-Object System.Drawing.Size(330, 155)
  $form.StartPosition = 'CenterScreen'

  $label = New-Object System.Windows.Forms.Label
  $label.Text = 'Profil wählen:'
  $label.AutoSize = $true
  $label.Location = New-Object System.Drawing.Point(12, 12)
  $form.Controls.Add($label)

  $btns = @(
    @{Name = 'desktop'; Text = 'Desktop (2C/8G)'; X = 12 },
    @{Name = 'balanced'; Text = 'Balanced (4C/16G)'; X = 112 },
    @{Name = 'dev'; Text = 'Dev (8C/22G)'; X = 222 }
  )
  $selected = $null
  foreach ($b in $btns) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Size = New-Object System.Drawing.Size(90, 30)
    $btn.Location = New-Object System.Drawing.Point($b.X, 50)
    $btn.Add_Click({ $script:selected = $b.Name; $form.Close() })
    $form.Controls.Add($btn)
  }

  [void]$form.ShowDialog()
  return $selected
}

try {
  if (-not $Profile -and -not $NoGUI) {
    $Profile = Show-GuiAndSelectProfile
  }
  if (-not $Profile) { throw 'No profile selected. Use -Profile or omit -NoGUI.' }

  Write-Log "Selected profile: $Profile"
  Export-VSCodeStatus
  Close-VSCode
  Ensure-SwapFolder
  Apply-WSLProfile -Name $Profile
  Restart-WSL
  Reopen-VSCode
  Write-Log 'Done.'
}
catch {
  Write-Log "Error: $($_.Exception.Message)" 'ERROR'
  exit 1
}
