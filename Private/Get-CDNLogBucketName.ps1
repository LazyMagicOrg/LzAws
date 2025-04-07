function Get-CDNLogBucketName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SystemConfig,
        
        [Parameter(Mandatory=$true)]
        [string]$TenantKey
    )

    try {
        if ($null -eq $SystemConfig) {
            Write-Host "Error: System configuration is required"
            Write-Host "Hints:"
            Write-Host "  - Ensure Get-SystemConfig was called successfully"
            Write-Host "  - Check if systemconfig.yaml exists and is valid"
            Write-Host "  - Verify AWS credentials are properly configured"
            Write-Error "System configuration is required" -ErrorAction Stop
        }

        if ($null -eq $SystemConfig.Config) {
            Write-Host "Error: System configuration is missing Config property"
            Write-Host "Hints:"
            Write-Host "  - Check if systemconfig.yaml has the correct structure"
            Write-Host "  - Verify the Config property is properly set"
            Write-Host "  - Ensure Get-SystemConfig is returning the expected format"
            Write-Error "System configuration is missing Config property" -ErrorAction Stop
        }

        if ([string]::IsNullOrEmpty($SystemConfig.Config.SystemKey)) {
            Write-Host "Error: SystemKey is missing from configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if SystemKey is defined in systemconfig.yaml"
            Write-Host "  - Verify the value is not empty"
            Write-Host "  - Ensure the configuration is properly loaded"
            Write-Error "SystemKey is missing from configuration" -ErrorAction Stop
        }

        if ([string]::IsNullOrEmpty($SystemConfig.Config.SystemSuffix)) {
            Write-Host "Error: SystemSuffix is missing from configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if SystemSuffix is defined in systemconfig.yaml"
            Write-Host "  - Verify the value is not empty"
            Write-Host "  - Ensure the configuration is properly loaded"
            Write-Error "SystemSuffix is missing from configuration" -ErrorAction Stop
        }

        if ([string]::IsNullOrEmpty($TenantKey)) {
            Write-Host "Error: TenantKey is required"
            Write-Host "Hints:"
            Write-Host "  - Provide a valid tenant key"
            Write-Host "  - Check if the tenant key is properly formatted"
            Write-Host "  - Ensure the tenant exists in the system"
            Write-Error "TenantKey is required" -ErrorAction Stop
        }

        if ($null -eq $SystemConfig.Config.Tenants) {
            Write-Host "Error: Tenants configuration is missing"
            Write-Host "Hints:"
            Write-Host "  - Check if Tenants section exists in systemconfig.yaml"
            Write-Host "  - Verify the Tenants property is properly configured"
            Write-Host "  - Ensure the configuration includes tenant definitions"
            Write-Error "Tenants configuration is missing" -ErrorAction Stop
        }

        if (-not $SystemConfig.Config.Tenants.ContainsKey($TenantKey)) {
            Write-Host "Error: Tenant '$TenantKey' not found in configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if the tenant is defined in systemconfig.yaml"
            Write-Host "  - Verify the tenant key is spelled correctly"
            Write-Host "  - Ensure the tenant is properly configured"
            Write-Error "Tenant '$TenantKey' not found in configuration" -ErrorAction Stop
        }

        $Config = $SystemConfig.Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix
        $Tenant = $Config.Tenants[$TenantKey]
        $TenantSuffix = $SystemSuffix
        if($Tenant.PSObject.Properties.Name -contains "Suffix") {
            $TenantSuffix = $Tenant.Suffix
        }

        $CDNLogBucket = $SystemKey + "-" + $TenantKey + "--cdnlog-" + $TenantSuffix
        Write-LzAwsVerbose "Generated CDN log bucket name: $CDNLogBucket"
        return $CDNLogBucket
    }
    catch {
        Write-Host "Error: Failed to generate CDN log bucket name"
        Write-Host "Hints:"
        Write-Host "  - Check if all required configuration values are present"
        Write-Host "  - Verify the tenant key format is valid"
        Write-Host "  - Ensure the system configuration is properly loaded"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to generate CDN log bucket name: $($_.Exception.Message)" -ErrorAction Stop
    }
}