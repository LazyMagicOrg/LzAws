<#
.SYNOPSIS
    Generates tenant configuration JSON file
.DESCRIPTION
    Gets the configuration details for a specified tenant and generates a JSON file
    in the Generated folder with the tenant's configuration.
.PARAMETER TenantKey
    The unique identifier for the tenant
.EXAMPLE
    Get-TenantConfigAws -TenantKey "tenant123"
    Generates a configuration JSON file for tenant123 in the Generated folder
.NOTES
    Requires valid AWS credentials and appropriate permissions
.OUTPUTS
    None. Creates a JSON file in the Generated folder.
#>
function Get-TenantConfigAws {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true)]
        [string]$TenantKey
    )
    
    Write-LzAwsVerbose "Generating kvs entries for tenant $TenantKey"  
    Get-SystemConfig # sets script scopevariables
    $Region = $script:Region
    $Account = $script:Account    
    $ProfileName = $script:ProfileName
    $Config = $script:Config

    $TenantConfig = Get-TenantConfig $TenantKey

    # Write the [tenant].json file
    Set-Content -Path ("./Generated/" + $TenantKey + ".g.json") -Value $TenantConfig

    Write-Host "Generated config json for tenant $TenantKey"

}
