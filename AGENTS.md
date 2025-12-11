# AGENTS.md

## Build/Test Commands
```powershell
.\Import-LzAws.ps1                    # Load module for development
.\Tests\Test-KVSChunking.ps1          # Run single test (KVS chunking)
Deploy-TestError                      # Test error handling
```

## Code Style
- **One function per file**, filename matches function name exactly
- **Public functions**: `Public/Verb-NounAws.ps1` - return `$true`/`$false`, catch errors with `Write-Host`
- **Private functions**: `Private/Verb-Noun.ps1` - throw errors with here-string format
- **Naming**: PascalCase for parameters/variables, approved PowerShell verbs only
- **AWS calls**: Always include `-ProfileName $script:ProfileName -Region $script:Region`

## Error Handling
- **Private**: `throw` with format: `Error:`, `Function:`, `Hints:` (2-3 actionable items)
- **Public**: `try/catch`, display `$_.Exception.Message`, return `$false` on error

## Key Patterns
- Use `Get-SystemConfig` at function start to load config
- Use `Write-LzAwsVerbose` (not `Write-Verbose`) for logging
- Use `Find-FileUp` to locate `systemconfig.yaml`
- Add new public functions to `FunctionsToExport` in `LzAws.psd1`
- Validate params: `[Parameter(Mandatory=$true)]`, `[ValidateNotNullOrEmpty()]`
