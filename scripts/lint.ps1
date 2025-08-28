param(
  [string]$PathToAnalyze = (Split-Path -Parent $PSCommandPath)
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
}
$root = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $root
$settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
$targets = @(
  (Join-Path $repo 'scripts'),
  (Join-Path $repo 'src')
) | Where-Object { Test-Path $_ } | ForEach-Object { [string]$_ }

# Run per-target for compatibility with older PSScriptAnalyzer signatures
$all = @()
foreach ($t in $targets) {
  $all += Invoke-ScriptAnalyzer -Path $t -Settings $settings -Recurse -Severity @('Error','Warning')
}

if ($all -and $all.Count -gt 0) {
  $all | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
  Write-Error ("PSScriptAnalyzer found {0} issue(s)." -f $all.Count)
  exit 1
}
Write-Host 'PSScriptAnalyzer: no issues found.'
