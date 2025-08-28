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

# Helper that tries multiple settings modes for best compatibility
function Invoke-AnalyzerCompat {
  param([string]$Target)
  $sev = @('Error','Warning')
  # 1) Hashtable settings (preferred)
  if ($settingsData) {
    try { return Invoke-ScriptAnalyzer -Path $Target -Settings $settingsData -Recurse -Severity $sev } catch {}
    # 2) Settings as path
    try { return Invoke-ScriptAnalyzer -Path $Target -Settings $settingsPath -Recurse -Severity $sev } catch {}
  }
  # 3) No settings fallback
  try { return Invoke-ScriptAnalyzer -Path $Target -Recurse -Severity $sev } catch { throw }
}

# Run per-target for compatibility
$all = @()
foreach ($t in $targets) {
  $all += Invoke-AnalyzerCompat -Target $t
}

if ($all -and $all.Count -gt 0) {
  $all | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
  Write-Error ("PSScriptAnalyzer found {0} issue(s)." -f $all.Count)
  exit 1
}
Write-Host 'PSScriptAnalyzer: no issues found.'
