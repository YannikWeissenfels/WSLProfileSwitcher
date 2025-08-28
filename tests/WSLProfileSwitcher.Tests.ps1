# Pester tests (basic smoke)
Describe 'Get-WslActiveProfile' {
  It 'returns null when no .wslconfig exists' {
    Mock Test-Path { $false }
    Get-WslActiveProfile | Should -Be $null
  }
}
