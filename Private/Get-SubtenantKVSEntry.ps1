function Get-SubtenantKVSEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$ProcessedTenant,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Subtenant,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubTenantKey,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$ServiceStackOutputDict
    )

    Write-LzAwsVerbose "Generating KVS entry for subtenant '$SubTenantKey'"

    if ($null -eq $ProcessedTenant) {
        $errorMessage = @"
Error: Processed tenant configuration is required for subtenant '$SubTenantKey'
Function: Get-SubtenantKVSEntry 
Hints:
  - Check if tenant configuration exists
  - Verify the tenant object is not null
  - Ensure tenant is properly processed
  - Review the tenant configuration structure
"@
        throw $errorMessage
    }

    if ($null -eq $Subtenant) {
        $errorMessage = @"
Error: Subtenant configuration is required for subtenant '$SubTenantKey'
Function: Get-SubtenantKVSEntry 
Hints:
- Check if subtenant configuration exists
- Verify the subtenant object is not null
- Ensure subtenant is properly defined in systemconfig.yaml
- Review the subtenant configuration structure
"@
      throw $errorMessage
    }

    if ($null -eq $ServiceStackOutputDict) {
        $errorMessage = @"
Error: Service stack outputs are required for subtenant '$SubTenantKey'
Function: Get-SubtenantKVSEntry 
Hints:
- Check if service stack exists
- Verify stack outputs are available
- Ensure stack deployment completed successfully
- Review the CloudFormation stack outputs
"@
        throw $errorMessage
    }

    $TenantConfig = @{
        env = $ProcessedTenant.env
        region = $ProcessedTenant.region
        systemKey = $ProcessedTenant.systemKey
        tenantKey = $ProcessedTenant.tenantKey
        subtenantKey = $SubTenantKey
        ss = $ProcessedTenant.ss
        ts = $ProcessedTenant.ts
        sts = $Subtenant.SubTenantSuffix ?? "{ts}"
        behaviors = @()
    }

    $BehaviorsHash = Get-HashTableFromProcessedBehaviorArray $ProcessedTenant.behaviors
    if ($null -eq $BehaviorsHash) {
        $errorMessage = @"
Error: Failed to process tenant behaviors for subtenant '$SubTenantKey'
Function: Get-SubtenantKVSEntry 
Hints:
- Check tenant behavior configuration
- Verify behavior format is correct
- Ensure all required behavior properties are present
- Review the tenant behavior structure
"@
        throw $errorMessage
    }
    
    Write-Host "debug Get-SubtenantKVSEntry"
    $SubtenantBehaviorsHash = (Get-BehaviorsHashTable "{sts}" $ProcessedTenant.env $ProcessedTenant.region $Subtenant.Behaviors $ServiceStackOutputDict 2)
    if ($null -eq $SubtenantBehaviorsHash) {
        $errorMessage = @"
Error: Failed to process subtenant behaviors for subtenant '$SubTenantKey'
Function: Get-SubtenantKVSEntry 
Hints:
- Check subtenant behavior configuration
- Verify behavior format is correct
- Ensure all required behavior properties are present
- Review the subtenant behavior structure
"@
        throw $errorMessage
    }

    $SubtenantBehaviorsHash.Keys | ForEach-Object {
        $BehaviorsHash[$_] = $SubtenantBehaviorsHash[$_]
    }

    $TenantConfig.behaviors = $BehaviorsHash.Values
    Write-LzAwsVerbose "Successfully processed behaviors for subtenant '$SubTenantKey'"
    return $TenantConfig
 }