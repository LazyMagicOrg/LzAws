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

    try {
        Write-LzAwsVerbose "Generating KVS entry for tenant '$TenantKey'"

        if ($null -eq $SystemBehaviorsHash) {
            Write-Host "Error: System behaviors hash is required"
            Write-Host "Hints:"
            Write-Host "  - Check if system behaviors are properly configured"
            Write-Host "  - Verify the behaviors hash is not null"
            Write-Host "  - Ensure system configuration is loaded correctly"
            Write-Error "System behaviors hash is required" -ErrorAction Stop
        }

        if ($null -eq $Tenant) {
            Write-Host "Error: Tenant configuration is required"
            Write-Host "Hints:"
            Write-Host "  - Check if tenant configuration exists"
            Write-Host "  - Verify the tenant object is not null"
            Write-Host "  - Ensure tenant is properly defined in systemconfig.yaml"
            Write-Host "Tenant: $TenantKey"
            Write-Error "Tenant configuration is required for tenant '$TenantKey'" -ErrorAction Stop
        }

        if ($null -eq $ServiceStackOutputDict) {
            Write-Host "Error: Service stack outputs are required"
            Write-Host "Hints:"
            Write-Host "  - Check if service stack exists"
            Write-Host "  - Verify stack outputs are available"
            Write-Host "  - Ensure stack deployment completed successfully"
            Write-Host "System: $SystemKey"
            Write-Error "Service stack outputs are required for system '$SystemKey'" -ErrorAction Stop
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

        try {
            Write-Host "debug Get-TenantKVSEntry"
            $BehaviorsHash = @{} + $SystemBehaviorsHash # clone
            $TenantBehaviorsHash = (Get-BehaviorsHashTable "{ts}" $Environment $Region $Tenant.Behaviors $ServiceStackOutputDict 1)
            
            if ($null -eq $TenantBehaviorsHash) {
                Write-Host "Error: Failed to process tenant behaviors"
                Write-Host "Hints:"
                Write-Host "  - Check tenant behavior configuration"
                Write-Host "  - Verify behavior format is correct"
                Write-Host "  - Ensure all required behavior properties are present"
                Write-Host "Tenant: $TenantKey"
                Write-Error "Failed to process tenant behaviors for tenant '$TenantKey'" -ErrorAction Stop
            }

            # append method compatible with all powershell versions
            $TenantBehaviorsHash.Keys | ForEach-Object {
                $BehaviorsHash[$_] = $TenantBehaviorsHash[$_]
            }
            $TenantConfig.behaviors = $BehaviorsHash.Values

            Write-LzAwsVerbose "Successfully processed behaviors for tenant '$TenantKey'"
            return $TenantConfig
        }
        catch {
            Write-Host "Error: Failed to process tenant behaviors"
            Write-Host "Hints:"
            Write-Host "  - Check tenant behavior configuration"
            Write-Host "  - Verify behavior format is correct"
            Write-Host "  - Ensure all required behavior properties are present"
            Write-Host "Tenant: $TenantKey"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Failed to process tenant behaviors for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Error: Failed to generate tenant KVS entry"
        Write-Host "Hints:"
        Write-Host "  - Check tenant configuration in systemconfig.yaml"
        Write-Host "  - Verify all required tenant properties are present"
        Write-Host "  - Ensure the tenant domain is properly configured"
        Write-Host "Tenant: $TenantKey"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to generate tenant KVS entry for tenant '$TenantKey': $($_.Exception.Message)" -ErrorAction Stop
    }
}