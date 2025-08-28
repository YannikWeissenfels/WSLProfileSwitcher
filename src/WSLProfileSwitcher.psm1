# Public functions that could be shared across scripts
# NOTE: Do NOT dot-source interactive scripts here to avoid side effects on Import-Module
# (e.g., CI runners or headless environments). Keep this module side-effect free.

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
