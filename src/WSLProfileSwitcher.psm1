# Public functions that could be shared across scripts
. "$PSScriptRoot\..\scripts\Switch-WSLProfile.ps1"

function Get-WslActiveProfile {
  try {
    $dst = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path -LiteralPath $dst)) { return $null }
    $dstText = (Get-Content -LiteralPath $dst -Raw)
    foreach ($p in 'desktop', 'balanced', 'dev') {
      $src = Join-Path $env:USERPROFILE ".wslprofiles\$p.wslconfig"
      if (Test-Path -LiteralPath $src) {
        if ((Get-Content -LiteralPath $src -Raw) -eq $dstText) { return $p }
      }
    }
    return $null
  }
  catch { return $null }
}

Export-ModuleMember -Function *
