param(
  [string]$InstallDir = "$env:LocalAppData\Programs\WSLProfileTray"
)

$ErrorActionPreference = 'Stop'

function Remove-IfExists($Path) { if (Test-Path $Path) { Remove-Item -Force -Recurse -Path $Path } }

# Remove shortcuts
$startMenu = Join-Path $env:AppData 'Microsoft\Windows\Start Menu\Programs\WSL Profile Switcher.lnk'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'WSL Profile Switcher.lnk'
foreach ($lnk in @($startMenu, $startup)) {
  if (Test-Path $lnk) { Remove-Item -Force $lnk }
}

# Remove installed files
if (Test-Path $InstallDir) {
  Remove-Item -Force -Recurse -Path $InstallDir
}

Write-Host 'Uninstall complete.'
