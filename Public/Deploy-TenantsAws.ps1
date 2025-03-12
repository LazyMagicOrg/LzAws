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
    
    # Add diagnostic output
    $currentVerbosity = Get-LzAwsVerbosity
    Write-Host "Current verbosity setting: $currentVerbosity"
    
    $SystemConfig = Get-SystemConfig
    $Config = $SystemConfig.Config

    Write-LzAwsVerbose "Starting tenant deployments"
    $TenantsHashTable = $Config.Tenants 
    foreach($Item in $TenantsHashTable.GetEnumerator()) {
        $TenantName = $Item.Key
        Write-LzAwsVerbose "Processing tenant: $TenantName"
        # Add more diagnostic output
        Write-Host "Debug: Verbosity is $(Get-LzAwsVerbosity) before deploying $TenantName"
        Write-Host "Calling Deploy-TenantAws $TenantName"
        Deploy-TenantAws $TenantName
    }
    Write-LzAwsVerbose "Finished tenant deployments"
    
    # Final diagnostic check
    Write-Host "Final verbosity setting: $(Get-LzAwsVerbosity)"
}

