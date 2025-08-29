param(
  [switch]$SelfContained
)

$ErrorActionPreference = 'Stop'

# Simple packaging via PS2EXE (PowerShell script to exe). Installs if missing.
function Install-PS2EXEModule {
  if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing PS2EXE module...'
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module ps2exe -Force
}

# Paths
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $root
$tray = Join-Path $root 'WSLProfileTray.ps1'
$outDir = Join-Path $root '..\dist'
$outExe = Join-Path $outDir 'WSLProfileTray.exe'

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Install-PS2EXEModule

function Get-ProjectVersion {
  try {
    $psd1 = Join-Path $repoRoot 'src/WSLProfileSwitcher.psd1'
    if (Test-Path $psd1) {
      $data = Import-PowerShellDataFile -Path $psd1
      if ($data.ModuleVersion) { return [string]$data.ModuleVersion }
    }
  } catch {}
  return '1.0.0'
}

$version = Get-ProjectVersion

# Convert tray to EXE with no console window
# If scripts/icons/app.ico exists, embed it into the EXE
$iconsSrc = Join-Path $root 'icons'
$appIcon = Join-Path $iconsSrc 'app.ico'

$ps2Params = @{
  inputFile  = $tray
  outputFile = $outExe
  noConsole  = $true
  title      = 'WSL Profile Switcher'
  product    = 'WSL Profile Switcher'
  version    = $version
}
if (Test-Path $appIcon) { $ps2Params.iconFile = $appIcon }

Invoke-ps2exe @ps2Params

Write-Host "Built: $outExe"

# Copy icons next to the EXE for runtime lookup (flatten contents, no nested folder)
if (Test-Path $iconsSrc) {
  $iconsDst = Join-Path $outDir 'icons'
  New-Item -ItemType Directory -Force -Path $iconsDst | Out-Null
  Copy-Item -Recurse -Force -Path (Join-Path $iconsSrc '*') -Destination $iconsDst
  Write-Host "Copied icons to: $iconsDst"
}

# Copy switching script next to EXE so the tray can invoke it
try {
  $switchSrc = Join-Path $root 'Switch-WSLProfile.ps1'
  if (Test-Path $switchSrc) {
    Copy-Item -Force -Path $switchSrc -Destination $outDir
    Write-Host "Included: $(Split-Path $switchSrc -Leaf)"
  }
} catch { Write-Warning ("Failed to copy Switch-WSLProfile.ps1: " + $_.Exception.Message) }

# Emit SHA-256 checksum file for verification
try {
  $hash = Get-FileHash -Algorithm SHA256 -Path $outExe
  $sumPath = Join-Path $outDir 'SHA256SUMS.txt'
  "${($hash.Hash)} *$([IO.Path]::GetFileName($outExe))" | Out-File -Encoding ASCII -FilePath $sumPath -Force
  Write-Host "Wrote checksum: $sumPath"
}
catch {
  Write-Warning "Failed to write SHA256SUMS.txt: $_"
}
