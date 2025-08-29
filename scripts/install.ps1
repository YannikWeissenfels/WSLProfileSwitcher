param(
  [string]$InstallDir = "$env:LocalAppData\Programs\WSLProfileTray",
  [string]$SourceDir,
  [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

function New-Shortcut($Path, $TargetPath, $WorkingDirectory, $IconLocation) {
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($Path)
  $lnk.TargetPath = $TargetPath
  if ($WorkingDirectory) { $lnk.WorkingDirectory = $WorkingDirectory }
  if ($IconLocation) { $lnk.IconLocation = $IconLocation }
  $lnk.Save()
}

if (-not $SourceDir) {
  # Default to repo dist folder next to this script
  $SourceDir = Join-Path (Split-Path -Parent $PSCommandPath) '..\dist'
}

if (-not (Test-Path $SourceDir)) {
  throw "Source directory not found: $SourceDir. Build first via scripts\\build.ps1."
}

$exe = Join-Path $SourceDir 'WSLProfileTray.exe'
if (-not (Test-Path $exe)) { throw "Executable not found: $exe" }

Write-Host "Installing to: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $SourceDir '*') -Destination $InstallDir

# Create Start Menu shortcut
$startMenu = Join-Path $env:AppData 'Microsoft\Windows\Start Menu\Programs'
$appLink = Join-Path $startMenu 'WSL Profile Switcher.lnk'
New-Shortcut -Path $appLink -TargetPath (Join-Path $InstallDir 'WSLProfileTray.exe') -WorkingDirectory $InstallDir -IconLocation (Join-Path $InstallDir 'WSLProfileTray.exe')
Write-Host "Start Menu shortcut: $appLink"

# Optional autostart
if (-not $NoAutoStart) {
  $startup = [Environment]::GetFolderPath('Startup')
  $autoLink = Join-Path $startup 'WSL Profile Switcher.lnk'
  New-Shortcut -Path $autoLink -TargetPath (Join-Path $InstallDir 'WSLProfileTray.exe') -WorkingDirectory $InstallDir -IconLocation (Join-Path $InstallDir 'WSLProfileTray.exe')
  Write-Host "Startup shortcut: $autoLink"
}

# Ensure default profile files exist in %USERPROFILE%\.wslprofiles on first install
try {
  $profDir = Join-Path $env:USERPROFILE '.wslprofiles'
  if (-not (Test-Path -LiteralPath $profDir)) { New-Item -ItemType Directory -Force -Path $profDir | Out-Null }
  $defaults = @{
    desktop  = @{ processors = 2; memory = '8GB';  swap = '2GB' }
    balanced = @{ processors = 4; memory = '16GB'; swap = '4GB' }
    dev      = @{ processors = 8; memory = '22GB'; swap = '6GB' }
  }
  foreach ($name in $defaults.Keys) {
    $dst = Join-Path $profDir ("$name.wslconfig")
    if (-not (Test-Path -LiteralPath $dst)) {
      $cfg = $defaults[$name]
      @('[wsl2]', "processors=$($cfg.processors)", "memory=$($cfg.memory)", "swap=$($cfg.swap)", 'swapFile=C:\\wsl\\swap.vhdx') | Out-File -LiteralPath $dst -Encoding UTF8 -Force
    }
  }
  Write-Host "Ensured default profiles in: $profDir"
}
catch { Write-Warning ("Failed to ensure default profiles: " + $_.Exception.Message) }

Write-Host 'Done.'
