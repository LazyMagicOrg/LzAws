function Get-CDNLogBucketName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SystemConfig,
        [Parameter(Mandatory=$true)]
        [string]$TenantKey
    )

    $Config = $script:Config
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