param(
  [string]$Version,
  [string]$DistDir = (Join-Path (Split-Path -Parent $PSCommandPath) '..\dist')
)

$ErrorActionPreference = 'Stop'

function Get-ProjectVersion {
  if ($Version) { return $Version }
  try {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $psd1 = Join-Path $repoRoot 'src/WSLProfileSwitcher.psd1'
    if (Test-Path $psd1) {
      $data = Import-PowerShellDataFile -Path $psd1
      if ($data.ModuleVersion) { return [string]$data.ModuleVersion }
    }
  } catch {}
  return '1.0.0'
}

function Ensure-Built {
  $exe = Join-Path $DistDir 'WSLProfileTray.exe'
  if (-not (Test-Path $exe)) {
    Write-Host 'dist missing or no EXE found. Building...'
    & (Join-Path (Split-Path -Parent $PSCommandPath) 'build.ps1')
  }
}

Ensure-Built

$ver = Get-ProjectVersion
Write-Host "Packaging portable ZIP for version $ver"

$zipName = "WSLProfileTray-$ver-portable.zip"
$zipPath = Join-Path $DistDir $zipName
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

# Include EXE, icons, checksum, and minimal license/readme if present
$items = @()
foreach ($name in @('WSLProfileTray.exe','icons','SHA256SUMS.txt')) {
  $p = Join-Path $DistDir $name
  if (Test-Path $p) { $items += $p }
}

Compress-Archive -Path $items -DestinationPath $zipPath -Force
Write-Host "Created: $zipPath"

