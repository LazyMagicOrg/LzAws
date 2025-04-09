function Get-TenantKVSEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SystemKey,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SystemSuffix,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Environment,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Region,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$SystemBehaviorsHash,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Tenant,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$ServiceStackOutputDict
    )

    Write-LzAwsVerbose "Generating KVS entry for tenant '$TenantKey'"

    if ($null -eq $SystemBehaviorsHash) {
        $errorMessage = @"
Error: System behaviors hash is required
Function: Get-TenantKVSEntry
Hints:
- Check if system behaviors are properly configured
- Verify the behaviors hash is not null
- Ensure system configuration is loaded correctly
- Review the system behavior configuration
"@
        throw $errorMessage
    }

    if ($null -eq $Tenant) {
        $errorMessage = @"
Error: Tenant configuration is required for tenant '$TenantKey'
Function: Get-TenantKVSEntry
Hints:
- Check if tenant configuration exists
- Verify the tenant object is not null
- Ensure tenant is properly defined in systemconfig.yaml
- Review the tenant configuration structure
"@
        throw $errorMessage
    }

    if ($null -eq $ServiceStackOutputDict) {
        $errorMessage = @"
Error: Service stack outputs are required for system '$SystemKey'
Function: Get-TenantKVSEntry
Hints:
- Check if service stack exists
- Verify stack outputs are available
- Ensure stack deployment completed successfully
- Review the CloudFormation stack outputs
"@
        throw $errorMessage
    }

    $TenantConfig = @{
        env = $Environment
        region = $Region 
        systemKey = $SystemKey
        tenantKey = $TenantKey
        ss = $SystemSuffix
        ts = $Tenant.TenantSuffix ?? "{ss}"
        behaviors = @()
    }

    Write-Host "debug Get-TenantKVSEntry"
    $BehaviorsHash = @{} + $SystemBehaviorsHash # clone
    $TenantBehaviorsHash = (Get-BehaviorsHashTable "{ts}" $Environment $Region $Tenant.Behaviors $ServiceStackOutputDict 1)
    
    if ($null -eq $TenantBehaviorsHash) {
        $errorMessage = @"
Error: Failed to process tenant behaviors for tenant '$TenantKey'
Function: Get-TenantKVSEntry
Hints:
- Check tenant behavior configuration
- Verify behavior format is correct
- Ensure all required behavior properties are present
- Review the tenant behavior structure
"@
        throw $errorMessage
    }

    # append method compatible with all powershell versions
    $TenantBehaviorsHash.Keys | ForEach-Object {
        $BehaviorsHash[$_] = $TenantBehaviorsHash[$_]
    }
    $TenantConfig.behaviors = $BehaviorsHash.Values

    Write-LzAwsVerbose "Successfully processed behaviors for tenant '$TenantKey'"
    return $TenantConfig

}