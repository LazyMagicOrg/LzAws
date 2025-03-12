<#
.SYNOPSIS
    Deploys system and tenant assets to AWS S3 buckets
.DESCRIPTION
    Deploys assets from the Tenancies solution to AWS S3 buckets for both system-level and tenant-specific assets.
    Processes tenant configurations to determine appropriate bucket names and asset deployments based on domain structure.
    Supports both single-level tenant domains (tenant.example.com) and two-level tenant domains (subtenant.tenant.example.com).
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Deploy-AssetsAws
    Deploys all system and tenant assets based on configuration
.NOTES
    - Must be run from the Tenancy Solution root folder
    - Tenant projects must follow naming convention: [tenant][-subtenant]
    - Do not prefix project names with system key
    - Primarily intended as a development tool
.OUTPUTS
    None
#>

function Deploy-AssetsAws {
    [CmdletBinding()]

    $SystemConfig = Get-SystemConfig
    $ProfileName = $SystemConfig.Config.Profile

    # Update system assets
    $BucketName = $SystemConfig.Config.SystemKey + "---assets-" + $SystemConfig.Config.SystemSuffix
    Write-Host "Deploying system assets to bucket: $BucketName using profile: $ProfileName"
    Update-TenantAsset "system" $BucketName $ProfileName    

    # Update tenant assets
    Write-Host "Processing tenant configurations..."
    $Tenants = $SystemConfig.Config.Tenants
    foreach($TenantKey in $Tenants.Keys) {
        Write-Host "`nProcessing tenant: $TenantKey"
        $TenantConfigJson = Get-TenantConfig $TenantKey
        $KvsEntries = $TenantConfigJson | ConvertFrom-Json -Depth 10

        # Process the tenant and subtenants for the tenant
        foreach($Prop in $KvsEntries.PSObject.Properties) {
            $Domain = $Prop.Name
            $KvsEntry = $Prop.Value
            $Tenant = $KvsEntry.tenantKey
            $Subtenant = $KvsEntry.subtenantKey
            $DomainParts = $Domain.Split('.') 
            $DomainPartsCount = $DomainParts.Count

            # Determine tenancy project name and level based on domain structure
            $TenancyProject = ""
            $TenantLevel = 0
            
            if($DomainPartsCount -eq 2) {
                # Domain format: tenant.example.com
                $TenancyProject = $Tenant
                $TenantLevel = 1
            } 
            elseif($DomainPartsCount -eq 3) {
                # Domain format: subtenant.tenant.example.com
                $TenancyProject = $Tenant + "-" + $Subtenant
                $TenantLevel = 2
            } 
            else {
                throw "Invalid domain format. Cannot determine tenancy project from domain: $Domain"
            }

            Write-Host "`nProcessing domain configuration:"
            Write-Host "Domain: $Domain"
            Write-Host "Tenant: $Tenant"
            Write-Host "Subtenant: $Subtenant"
            Write-Host "Tenant Level: $TenantLevel"

            # Update Tenant Asset Bucket for matching behaviors
            $Behaviors = $KvsEntry.Behaviors
            foreach($Behavior in $Behaviors) {
                $AssetType = $Behavior[1]
                if($AssetType -ne "assets") {
                    continue
                }
                
                $BehaviorLevel = $Behavior[4]
                if($BehaviorLevel -ne $TenantLevel) {
                    continue
                }

                $BucketName = Get-AssetName $KvsEntry $Behavior $false
                Write-Host "Deploying tenant assets for project: $TenancyProject to bucket: $BucketName using profile: $ProfileName"
                Update-TenantAsset $TenancyProject $BucketName $ProfileName
            }
        }
    }
}