@{
  Severity = @('Error', 'Warning')
  Rules    = @{
    PSAvoidUsingWriteHost         = $false
    PSUseToExportFieldsInManifest = $true
    PSUseConsistentIndentation    = $true
    PSPlaceOpenBrace              = 'SameLine'
    PSPlaceCloseBrace             = 'SameLine'
    PSUseConsistentWhitespace     = $true
    PSUseCorrectCasing            = $true
    PSAvoidUsingCmdletAliases     = $false
  }
}
