<#
.SYNOPSIS
    Deploys a tenant configuration to AWS
.DESCRIPTION
    Deploys or updates a tenant's configuration and resources in AWS environment,
    including necessary IAM roles, policies, and related resources.
.PARAMETER TenantKey
    The unique identifier for the tenant that matches a tenant defined in SystemConfig.yaml
.EXAMPLE
    Deploy-TenantAws -TenantKey "tenant123"
    Deploys the specified tenant configuration to AWS
.NOTES
    Requires valid AWS credentials and appropriate permissions
    The tenantKey must match a tenant defined in the SystemConfig.yaml file
.OUTPUTS
    None
#>
function Deploy-TenantAws {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory=$true)]
        [string]$TenantKey
    )

    try {
        try {
            Deploy-TenantResourcesAws $TenantKey
        }
        catch {
            Write-Host "Error: Failed to deploy tenant resources for '$TenantKey'"
            Write-Host "Hints:"
            Write-Host "  - Check if the tenant exists in systemconfig.yaml"
            Write-Host "  - Verify AWS resources are properly configured"
            Write-Host "  - Review AWS CloudTrail logs for deployment failures"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        Write-LzAwsVerbose "Deploying tenant stack"  
        try {
            $SystemConfig = Get-SystemConfig 
            $Config = $SystemConfig.Config
            $Environment = $Config.Environment
            $ProfileName = $Config.Profile
            $SystemKey = $Config.SystemKey
            $SystemSuffix = $Config.SystemSuffix
        }
        catch {
            Write-Host "Error: Failed to load system configuration for tenant '$TenantKey'"
            Write-Host "Hints:"
            Write-Host "  - Check if systemconfig.yaml exists and is valid"
            Write-Host "  - Verify AWS credentials are properly configured"
            Write-Host "  - Ensure you have sufficient permissions"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        $StackName = $Config.SystemKey + "-" + $TenantKey + "--tenant" 
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

        try {
            $CdnLogBucketName = Get-CDNLogBucketName -SystemConfig $SystemConfig -TenantKey $TenantKey
        }
        catch {
            Write-Host "Error: Failed to get CDN log bucket name for tenant '$TenantKey'"
            Write-Host "Hints:"
            Write-Host "  - Check if the CDN log bucket exists"
            Write-Host "  - Verify the system stack is deployed"
            Write-Host "  - Ensure the tenant configuration is valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        $Tenant = $Config.Tenants[$TenantKey]

        # Validate required tenant properties
        $RequiredProps = @('RootDomain', 'HostedZoneId', 'AcmCertificateArn')
        foreach ($Prop in $RequiredProps) {
            if (-not $Tenant.ContainsKey($Prop) -or [string]::IsNullOrWhiteSpace($Tenant[$Prop])) {
                Write-Host "Error: Missing required property '$Prop' for tenant '$TenantKey'"
                Write-Host "Hints:"
                Write-Host "  - Check tenant configuration in systemconfig.yaml"
                Write-Host "  - Verify all required properties are defined"
                Write-Host "  - Ensure property values are not empty"
                exit 1
            }
        }

        $RootDomain = $Tenant.RootDomain
        if([string]::IsNullOrWhiteSpace($RootDomain)) {
            Write-Host "RootDomain is missing or empty."
            return $false
        }

        $HostedZoneId = $Tenant.HostedZoneId
        $AcmCertificateArn = $Tenant.AcmCertificateArn
        $TenantSuffix = $SystemSuffix # default
        if($Tenant.ContainsKey('TenantSuffix') -and ![string]::IsNullOrWhiteSpace($Tenant.TenantSuffix)) {
            $TenantSuffix = $Tenant.TenantSuffix    
        }

        # Get stack outputs
        $PolicyStackOutputDict = Get-StackOutputs ($Config.SystemKey + "---policies")

        # Create the parameters dictionary
        $ParametersDict = @{
            # SystemConfigFile values
            "SystemKeyParameter" = $SystemKey
            "EnvironmentParameter" = $Environment
            "TenantKeyParameter" = $TenantKey
            "GuidParameter" = $TenantSuffix
            "RootDomainParameter" = $RootDomain
            "HostedZoneIdParameter" = $HostedZoneId
            "AcmCertificateArnParameter" = $AcmCertificateArn

            # CFPolicyStack values
            "OriginRequestPolicyIdParameter" = $PolicyStackOutputDict["OriginRequestPolicyId"]
            "CachePolicyIdParameter" = $PolicyStackOutputDict["CachePolicyId"]
            "CacheByHeaderPolicyIdParameter" = $PolicyStackOutputDict["CacheByHeaderPolicyId"]
            "ApiCachePolicyIdParameter" = $PolicyStackOutputDict["ApiCachePolicyId"]
            "AuthConfigFunctionArnParameter" = $PolicyStackOutputDict["AuthConfigFunctionArn"]
            "RequestFunctionArnParameter" = $PolicyStackOutputDict["RequestFunctionArn"]
            "ApiRequestFunctionArnParameter" = $PolicyStackOutputDict["ApiRequestFunctionArn"]
        }

        # Deploy the stack using SAM CLI
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict
        Write-Host "Deploying the stack $StackName" 
        sam deploy `
        --template-file Templates/sam.tenant.yaml `
        --s3-bucket $ArtifactsBucket `
        --stack-name $StackName `
        --parameter-overrides $Parameters `
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
        --profile $ProfileName

        Write-LzAwsVerbose "Tenant deployment completed successfully for $TenantKey"
    }
    catch {
        Write-Host "Error: An unexpected error occurred while deploying tenant '$TenantKey'"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service status"
        Write-Host "  - Verify tenant configuration is valid"
        Write-Host "  - Review AWS CloudTrail logs for details"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}

