# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

LzAws is a PowerShell module for deploying and managing multi-tenant SaaS applications on AWS. It provides cmdlets for deploying system infrastructure, tenant resources, authentication systems, web applications, and static assets.

## Development Commands

### Loading the Module for Development
```powershell
# Use the Import-LzAws.ps1 script during development
.\Import-LzAws.ps1

# Or manually import
Import-Module ./LzAws.psd1 -Force
```

### Installing the Module
```powershell
# Install for current user
.\Install-LzAws.ps1 -Scope CurrentUser

# Install for all users (requires admin)
.\Install-LzAws.ps1 -Scope AllUsers
```

### Key Deployment Commands
These are the deployment commands, listed in their typical order of execution.
```powershell
# Deploy system infrastructure (from Service/AwsTemplates folder)
Deploy-SystemAws

# Deploy policies (from Service/AwsTemplates folder)
Deploy-PoliciesAws

# Deploy permissions (from Service/AwsTemplates folder)
Deploy-PermsAws

# Deploy authentication resources (from Service/AwsTemplates folder)
Deploy-AuthsAws

# Deploy services (Lambda functions) (from Service/AwsTemplates folder)
Deploy-ServiceAws -ServiceKey "myservice"

# Deploy web application (from App's solution folder)
Deploy-WebappAws

# Deploy Assets to S3 (from Tenancies solution folder)
Deploy-AssetsAws

# Deploy all tenants (from Service/AwsTemplates folder)
Deploy-TenantsAws
# Or deploy a specific tenant
Deploy-TenantAws -TenantKey "tenant1"
```

## Architecture

### Module Structure
- **Public/**: User-facing cmdlets that are exported from the module
- **Private/**: Internal helper functions not exposed to users
- **LzAws.psm1**: Main module file that loads functions and manages dependencies
- **LzAws.psd1**: Module manifest defining exports and dependencies

### Configuration
The module uses YAML configuration files (`systemconfig.yaml`) that must include:
- System configuration with AWS settings
- Tenant definitions with domains and certificates
- Service configurations

Configuration files are discovered by searching up the directory tree using `Find-FileUp`.

### AWS Integration
- Automatically manages AWS PowerShell module dependencies
- Supports AWS SSO profiles and standard credentials
- Uses SAM/CloudFormation for infrastructure deployment
- Integrates with S3, DynamoDB, CloudFront, and Cognito

### Error Handling Pattern
- **Private functions**: Throw errors with formatted messages including hints
- **Public functions**: Catch errors, display with Write-Host, return boolean
- Error format includes Function name, Error description, and Helpful hints

Example error format:
```powershell
$errorMessage = @"
Error: Brief description of what went wrong
Function: FunctionName
Hints:
  - Check your AWS credentials
  - Verify the systemconfig.yaml exists
  - Ensure you have the necessary permissions
"@
```

### Module-Scoped Variables
- `$script:LzAwsVerbosePreference`: Controls verbosity separate from PowerShell's $VerbosePreference
- `$script:awsModulesRemoved`: Tracks if conflicting AWS modules have been removed
- `$script:LzConfig`: Cached configuration data

### Deployment Hierarchy
1. **System Resources** → Core AWS infrastructure (Deploy-SystemAws)
2. **Policies** → CloudFront and caching policies (Deploy-PoliciesAws)
3. **Permissions** → Permission policies (Deploy-PermsAws)
4. **Authentication** → Cognito user pools and identity providers (Deploy-AuthsAws)
5. **Services** → Lambda functions and APIs (Deploy-ServiceAws)
6. **Web Applications** → Frontend deployment (Deploy-WebappAws)
7. **Assets** → Static files to S3 buckets (Deploy-AssetsAws)
8. **Tenant Resources** → Per-tenant infrastructure (Deploy-TenantsAws/Deploy-TenantAws)

### Testing
The module includes test error deployment functionality:
```powershell
Deploy-TestError  # Tests error handling
Get-TestError     # Retrieves test error
```

## Important Notes

- Always check for existing AWS modules before importing to avoid conflicts
- The module requires PowerShell 5.1 or higher
- SAM CLI must be installed for deployment operations
- Configuration files use YAML format and must have proper structure
- Tenant deployments require system deployment to be completed first
- Use `Get-AwsCommands` to see all available commands
- Use `Get-LzAwsHelp` for detailed help on any command

## Detailed Development Tips for LLMs

### 1. Module Initialization Patterns
- The module automatically removes conflicting AWS modules on load to prevent assembly conflicts
- AWS modules are lazy-loaded on first use via `Initialize-LzAwsModules`
- Module state is maintained in script-scoped variables (e.g., `$script:Config`, `$script:ProfileName`)
- Always use `Get-SystemConfig` at the start of functions to ensure configuration is loaded

### 2. Error Handling Requirements
**Private Functions MUST:**
- Create detailed error messages using here-strings with the exact format shown above
- Always include: Error description, Function name, and 2-3 actionable Hints
- Use `throw $errorMessage` to propagate errors up
- Never use Write-Host or return values for errors

**Public Functions MUST:**
- Wrap all operations in try/catch blocks
- Catch errors and display with `Write-Host ($_.Exception.Message)`
- Return `$false` on error or use `exit 1` for critical failures
- Return `$true` on success
- Never re-throw errors (to avoid showing stack traces to users)

### 3. Parameter Handling Patterns
- Always validate mandatory parameters with `[Parameter(Mandatory=$true)]`
- Use validation attributes: `[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, `[ValidatePattern()]`
- Check for required configuration properties early in the function
- Use the fallback pattern for optional values:
  ```powershell
  $Value = $DefaultValue
  if($Config.ContainsKey('Property') -and ![string]::IsNullOrWhiteSpace($Config.Property)) {
      $Value = $Config.Property
  }
  ```

### 4. Configuration Management
- Configuration flows from system → tenant → subtenant levels
- Use `Find-FileUp` to locate `systemconfig.yaml` from any directory
- Configuration is cached in `$script:Config` after first load
- Stack outputs are retrieved via `Get-StackOutputs` and merged into parameters
- Always check `if ($null -eq $Config)` before using configuration

### 5. AWS Service Integration
- Always include `-ProfileName $script:ProfileName -Region $script:Region` on AWS cmdlets
- Use structured error handling with AWS-specific hints
- For S3 operations: Check bucket existence before creation
- For DynamoDB: Wait for table to become ACTIVE
- For CloudFormation: Handle "No changes to deploy" as non-error
- Use SAM CLI for deployments with proper parameter formatting via `ConvertTo-ParameterOverrides`

### 6. Naming Conventions
**Functions:**
- Public: `Verb-NounAws` (e.g., `Deploy-SystemAws`)
- Private: `Verb-Noun` (e.g., `Get-SystemConfig`)
- Use approved PowerShell verbs only

**Variables:**
- Parameters: PascalCase (e.g., `$TenantKey`)
- Local variables: PascalCase (e.g., `$StackName`)
- Script-scoped: camelCase with prefix (e.g., `$script:profileName`)

### 7. Verbose Logging
- Use the custom `Write-LzAwsVerbose` function, NOT Write-Verbose
- Enable with `Set-LzAwsVerbosity -Preference "Continue"`
- Log all AWS operations, configuration loading, and major steps
- Verbose output uses Write-Host with "VERBOSE:" prefix in yellow

### 8. Output Patterns
- **Write-Host**: User-facing messages, errors (in public functions), success confirmations
- **Write-LzAwsVerbose**: Internal operations, debugging info, AWS API calls
- **Return values**: Boolean for success/failure, data objects for Get- functions
- **Write-OutputDictionary**: Structured key-value output with color formatting

### 9. File Organization
- One function per file, filename matches function name exactly
- Public functions go in `/Public`, private in `/Private`
- Always include the function in `FunctionsToExport` in LzAws.psd1 for new public functions

### 10. Common Pitfalls to Avoid
- Don't use PowerShell's built-in `-Verbose` parameter - use the module's custom system
- Don't catch and re-throw in public functions - display and return false
- Don't forget to validate AWS profile credentials in functions that use AWS services
- Don't assume resources exist - always check first (idempotent operations)
- Don't use relative paths - configuration discovery handles working directory changes

### 11. Testing New Functions
- Use `Deploy-TestError` to verify error handling works correctly
- Test from different directories to ensure `Find-FileUp` works
- Verify verbose output with `Set-LzAwsVerbosity -Preference "Continue"`
- Check that all AWS operations include profile and region parameters

### 12. Module Dependencies
Required modules with minimum versions:
- `powershell-yaml`: 0.4.2
- `AWS.Tools.Common`: 4.1.748
- `AWS.Tools.S3`: 4.1.748
- `AWS.Tools.CloudFormation`: 4.1.748
- `AWS.Tools.CloudFrontKeyValueStore`: 4.1.748
- `AWS.Tools.DynamoDBv2`: 4.1.136