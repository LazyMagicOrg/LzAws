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

    try {
        Write-LzAwsVerbose "Generating KVS entry for subtenant '$SubTenantKey'"

        if ($null -eq $ProcessedTenant) {
            Write-Host "Error: Processed tenant configuration is required"
            Write-Host "Hints:"
            Write-Host "  - Check if tenant configuration exists"
            Write-Host "  - Verify the tenant object is not null"
            Write-Host "  - Ensure tenant is properly processed"
            Write-Host "Subtenant: $SubTenantKey"
            Write-Error "Processed tenant configuration is required for subtenant '$SubTenantKey'" -ErrorAction Stop
        }

        if ($null -eq $Subtenant) {
            Write-Host "Error: Subtenant configuration is required"
            Write-Host "Hints:"
            Write-Host "  - Check if subtenant configuration exists"
            Write-Host "  - Verify the subtenant object is not null"
            Write-Host "  - Ensure subtenant is properly defined in systemconfig.yaml"
            Write-Host "Subtenant: $SubTenantKey"
            Write-Error "Subtenant configuration is required for subtenant '$SubTenantKey'" -ErrorAction Stop
        }

        if ($null -eq $ServiceStackOutputDict) {
            Write-Host "Error: Service stack outputs are required"
            Write-Host "Hints:"
            Write-Host "  - Check if service stack exists"
            Write-Host "  - Verify stack outputs are available"
            Write-Host "  - Ensure stack deployment completed successfully"
            Write-Host "Subtenant: $SubTenantKey"
            Write-Error "Service stack outputs are required for subtenant '$SubTenantKey'" -ErrorAction Stop
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

        try {
            $BehaviorsHash = Get-HashTableFromProcessedBehaviorArray $ProcessedTenant.behaviors
            if ($null -eq $BehaviorsHash) {
                Write-Host "Error: Failed to process tenant behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check tenant behavior configuration"
                Write-Host "  - Verify behavior format is correct"
                Write-Host "  - Ensure all required behavior properties are present"
                Write-Host "Subtenant: $SubTenantKey"
                Write-Error "Failed to process tenant behaviors for subtenant '$SubTenantKey'" -ErrorAction Stop
            }
            Write-Host "debug Get-SubtenantKVSEntry"
            $SubtenantBehaviorsHash = (Get-BehaviorsHashTable "{sts}" $ProcessedTenant.env $ProcessedTenant.region $Subtenant.Behaviors $ServiceStackOutputDict 2)
            if ($null -eq $SubtenantBehaviorsHash) {
                Write-Host "Error: Failed to process subtenant behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check subtenant behavior configuration"
                Write-Host "  - Verify behavior format is correct"
                Write-Host "  - Ensure all required behavior properties are present"
                Write-Host "Subtenant: $SubTenantKey"
                Write-Error "Failed to process subtenant behaviors for subtenant '$SubTenantKey'" -ErrorAction Stop
            }

            $SubtenantBehaviorsHash.Keys | ForEach-Object {
                $BehaviorsHash[$_] = $SubtenantBehaviorsHash[$_]
            }

            $TenantConfig.behaviors = $BehaviorsHash.Values
            Write-LzAwsVerbose "Successfully processed behaviors for subtenant '$SubTenantKey'"
            return $TenantConfig
        }
        catch {
            Write-Host "Error: Failed to process subtenant behaviors"
            Write-Host "Hints:"
            Write-Host "  - Check subtenant behavior configuration"
            Write-Host "  - Verify behavior format is correct"
            Write-Host "  - Ensure all required behavior properties are present"
            Write-Host "Subtenant: $SubTenantKey"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to process subtenant behaviors for subtenant '$SubTenantKey': $($_.Exception.Message)" -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Error: Failed to generate subtenant KVS entry"
        Write-Host "Hints:"
        Write-Host "  - Check subtenant configuration in systemconfig.yaml"
        Write-Host "  - Verify all required subtenant properties are present"
        Write-Host "  - Ensure the subtenant domain is properly configured"
        Write-Host "Subtenant: $SubTenantKey"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to generate subtenant KVS entry for subtenant '$SubTenantKey': $($_.Exception.Message)" -ErrorAction Stop
    }
}