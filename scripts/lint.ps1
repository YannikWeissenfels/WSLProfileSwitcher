param(
  [string]$PathToAnalyze = (Split-Path -Parent $PSCommandPath)
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
}
$root = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $root
$settingsPath = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
$settingsData = $null
if (Test-Path $settingsPath) {
  try { $settingsData = Import-PowerShellDataFile -Path $settingsPath } catch {}
}
$targets = @(
  (Join-Path $repo 'scripts'),
  (Join-Path $repo 'src')
) | Where-Object { Test-Path $_ } | ForEach-Object { [string]$_ }

# Run per-target for compatibility with older PSScriptAnalyzer signatures
$all = @()
foreach ($t in $targets) {
  $params = @{ Path = $t; Recurse = $true; Severity = @('Error','Warning') }
  if ($settingsData) { $params.Settings = $settingsData }
  $all += Invoke-ScriptAnalyzer @params
}

if ($all -and $all.Count -gt 0) {
  $all | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
  Write-Error ("PSScriptAnalyzer found {0} issue(s)." -f $all.Count)
  exit 1
}
Write-Host 'PSScriptAnalyzer: no issues found.'
