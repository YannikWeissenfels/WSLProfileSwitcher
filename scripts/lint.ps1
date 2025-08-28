param(
  [string]$PathToAnalyze = (Split-Path -Parent $PSCommandPath)
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
}
$root = Split-Path -Parent $PSCommandPath
$settings = Join-Path (Split-Path -Parent $root) 'PSScriptAnalyzerSettings.psd1'
$targets = @(
  (Join-Path (Split-Path -Parent $root) 'scripts'),
  (Join-Path (Split-Path -Parent $root) 'src')
) | Where-Object { Test-Path $_ }
Invoke-ScriptAnalyzer -Path $targets -Settings $settings -Recurse -Severity @('Error','Warning')
