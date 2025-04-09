<#
.SYNOPSIS
    Deploys multiple tenant configurations to AWS
.DESCRIPTION
    Batch deploys all tenant configurations defined in SystemConfig.yaml to AWS environment,
    handling all necessary resources and settings for each tenant.
.EXAMPLE
    Deploy-TenantsAws
    Deploys all tenant configurations from SystemConfig.yaml
.NOTES
    Requires valid AWS credentials and appropriate permissions
.OUTPUTS
    None
#>
function Deploy-TenantsAws {
    [CmdletBinding()]
    param()
    
    try {
        $null = Get-SystemConfig
        $Config = $script:Config

        Write-LzAwsVerbose "Starting tenant deployments"
        $TenantsHashTable = $Config.Tenants 
        
        if ($TenantsHashTable.Count -eq 0) {
            $errorMessage = @"
Error: No tenants found in system configuration
Function: Deploy-TenantsAws
Hints:
  - Check if tenants are defined in systemconfig.yaml
  - Verify the configuration file is properly formatted
  - Ensure you're using the correct configuration file
"@
            throw $errorMessage
        }
        foreach($Item in $TenantsHashTable.GetEnumerator()) {
            $TenantName = $Item.Key
            Write-LzAwsVerbose "Processing tenant: $TenantName"
            Deploy-TenantAws $TenantName
        }
        Write-LzAwsVerbose "Finished tenant deployments"
        Write-Host "All tenants deployed successfully" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}

