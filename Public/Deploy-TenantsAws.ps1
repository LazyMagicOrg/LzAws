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
        # Add diagnostic output
        $currentVerbosity = Get-LzAwsVerbosity
        Write-Host "Current verbosity setting: $currentVerbosity"
        
        try {
            $SystemConfig = Get-SystemConfig
            $Config = $SystemConfig.Config
        }
        catch {
            Write-Host "Error: Failed to load system configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if systemconfig.yaml exists and is valid"
            Write-Host "  - Verify AWS credentials are properly configured"
            Write-Host "  - Ensure you have sufficient permissions"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        Write-LzAwsVerbose "Starting tenant deployments"
        $TenantsHashTable = $Config.Tenants 
        
        if ($TenantsHashTable.Count -eq 0) {
            Write-Host "Error: No tenants found in system configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if tenants are defined in systemconfig.yaml"
            Write-Host "  - Verify the configuration file is properly formatted"
            Write-Host "  - Ensure you're using the correct configuration file"
            exit 1
        }

        foreach($Item in $TenantsHashTable.GetEnumerator()) {
            $TenantName = $Item.Key
            Write-LzAwsVerbose "Processing tenant: $TenantName"
            
            try {
                Write-Host "Deploying tenant: $TenantName"
                Deploy-TenantAws $TenantName
            }
            catch {
                Write-Host "Error: Failed to deploy tenant '$TenantName'"
                Write-Host "Hints:"
                Write-Host "  - Check tenant configuration in systemconfig.yaml"
                Write-Host "  - Verify AWS resources are properly configured"
                Write-Host "  - Review AWS CloudTrail logs for deployment failures"
                Write-Host "Error Details: $($_.Exception.Message)"
                exit 1
            }
        }
        
        Write-LzAwsVerbose "Finished tenant deployments"
        Write-Host "All tenants deployed successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "Error: An unexpected error occurred during tenant deployment"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service status"
        Write-Host "  - Verify system configuration is valid"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}

