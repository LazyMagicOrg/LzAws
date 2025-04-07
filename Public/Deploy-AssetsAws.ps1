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
    param()

    try {
        $SystemConfig = Get-SystemConfig
        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account    
        $ProfileName = $SystemConfig.Config.Profile
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

    # Update system assets
    try {
        $BucketName = $SystemConfig.Config.SystemKey + "---assets-" + $SystemConfig.Config.SystemSuffix
        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName
        Write-Host "Deploying system assets to bucket: $BucketName using profile: $ProfileName"
        Update-TenantAsset "system" $BucketName $ProfileName    
    }
    catch {
        Write-Host "Error: Failed to deploy system assets"
        Write-Host "Hints:"
        Write-Host "  - Check if the system assets bucket exists and is accessible"
        Write-Host "  - Verify AWS permissions for S3 operations"
        Write-Host "  - Ensure system asset files are properly structured"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }

    # Update tenant assets
    Write-Host "Processing tenant configurations..."
    $Tenants = $SystemConfig.Config.Tenants
    foreach($TenantKey in $Tenants.Keys) {
        Write-Host "Processing tenant: $TenantKey"
        try {
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
                    Write-Host "Error: Invalid domain format for tenant '$TenantKey'"
                    Write-Host "Hints:"
                    Write-Host "  - Domain must be in format: tenant.example.com or subtenant.tenant.example.com"
                    Write-Host "  - Check tenant configuration in systemconfig.yaml"
                    Write-Host "  - Verify domain structure matches expected format"
                    Write-Host "Domain: $Domain"
                    exit 1
                }

                Write-Host "Processing domain configuration:"
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

                    try {
                        $BucketName = Get-AssetName $KvsEntry $Behavior $false
                        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName
                        Write-Host "Deploying tenant assets for project: $TenancyProject to bucket: $BucketName using profile: $ProfileName"
                        Update-TenantAsset $TenancyProject $BucketName $ProfileName
                    }
                    catch {
                        Write-Host "Error: Failed to update tenant assets for project '$TenancyProject'"
                        Write-Host "Hints:"
                        Write-Host "  - Check if the asset bucket exists and is accessible"
                        Write-Host "  - Verify AWS permissions for S3 operations"
                        Write-Host "  - Ensure asset files are properly structured"
                        Write-Host "Error Details: $($_.Exception.Message)"
                        exit 1
                    }
                }
            }
        }
        catch {
            Write-Host "Error: Failed to process tenant '$TenantKey'"
            Write-Host "Hints:"
            Write-Host "  - Check tenant configuration in systemconfig.yaml"
            Write-Host "  - Verify tenant assets are properly structured"
            Write-Host "  - Ensure AWS resources are properly configured"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }

    Write-LzAwsVerbose "Finished deploying all assets"
}