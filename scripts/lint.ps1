param(
  [string]$PathToAnalyze = (Split-Path -Parent $PSCommandPath),
  [switch]$Strict
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
  param([string]$Target, [string[]]$Sev)
  if (-not $Sev -or $Sev.Count -eq 0) { $Sev = @('Error','Warning') }
  # 1) Hashtable settings (preferred)
  if ($settingsData) {
    try { return Invoke-ScriptAnalyzer -Path $Target -Settings $settingsData -Recurse -Severity $Sev } catch {}
    # 2) Settings as path
    try { return Invoke-ScriptAnalyzer -Path $Target -Settings $settingsPath -Recurse -Severity $Sev } catch {}
  }
  # 3) No settings fallback
  try { return Invoke-ScriptAnalyzer -Path $Target -Recurse -Severity $Sev } catch { throw }
}

# Run per-target for compatibility
$all = @()
$sevForRun = @('Error','Warning')
foreach ($t in $targets) {
  $all += Invoke-AnalyzerCompat -Target $t -Sev $sevForRun
}

# Summarize and choose failure policy
$err = @($all | Where-Object { $_.Severity -eq 'Error' })
$warn = @($all | Where-Object { $_.Severity -eq 'Warning' })

if ($all -and $all.Count -gt 0) {
  $all | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
}

$strictMode = $Strict -or ($env:CI_LINT_STRICT -eq '1')
if ($err.Count -gt 0 -or ($strictMode -and $warn.Count -gt 0)) {
  $msg = "PSScriptAnalyzer found {0} error(s) and {1} warning(s)." -f $err.Count, $warn.Count
  Write-Error $msg
  exit 1
}

Write-Host ("PSScriptAnalyzer: {0} warning(s), 0 error(s)." -f $warn.Count)
