# Pester tests (basic smoke)

BeforeAll {
  # Import module under test explicitly for reliability
  $moduleManifest = Join-Path $PSScriptRoot '..\src\WSLProfileSwitcher.psd1'
  if (Test-Path $moduleManifest) {
    Import-Module $moduleManifest -Force
  }
}

Describe 'Get-WslActiveProfile' {
  It 'returns null when no .wslconfig exists' {
    # Isolate USERPROFILE to a temp directory to avoid host interference
    $orig = $env:USERPROFILE
    $tmp = Join-Path $env:TEMP ("pester-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      $env:USERPROFILE = $tmp
      Get-WslActiveProfile | Should -Be $null
    }
    finally {
      $env:USERPROFILE = $orig
      try { Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue } catch {}
    }
  }
}
