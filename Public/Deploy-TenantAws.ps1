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
        Deploy-TenantResourcesAws $TenantKey

        Write-LzAwsVerbose "Deploying tenant stack"  

        $null = Get-SystemConfig 
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $Environment = $Config.Environment
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $Config.SystemKey + "-" + $TenantKey + "--tenant" 
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix
        $Tenant = $Config.Tenants[$TenantKey]
        # Validate required tenant properties
        $RequiredProps = @('RootDomain', 'HostedZoneId', 'AcmCertificateArn')
        foreach ($Prop in $RequiredProps) {
            if (-not $Tenant.ContainsKey($Prop) -or [string]::IsNullOrWhiteSpace($Tenant[$Prop])) {
                $errorMessage = @"
Error: Missing required property '$Prop' for tenant '$TenantKey'
Function: Deploy-TenantAws
Hints:
  - Check tenant configuration in systemconfig.yaml
  - Verify all required properties are defined
  - Ensure property values are not empty
"@
                throw $errorMessage
            }
        }

        $RootDomain = $Tenant.RootDomain
        if([string]::IsNullOrWhiteSpace($RootDomain)) {
            $errorMessage = @"
Error: RootDomain is missing or empty for tenant '$TenantKey'
Function: Deploy-TenantAws
Hints:
  - Check tenant configuration in systemconfig.yaml
  - Verify the RootDomain property is defined
  - Ensure the RootDomain value is not empty
"@
            throw $errorMessage
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
        $result = sam deploy `
        --template-file Templates/sam.tenant.yaml `
        --s3-bucket $ArtifactsBucket `
        --stack-name $StackName `
        --parameter-overrides $Parameters `
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
        --region $Region `
        --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $results = $result | Out-String
            if($results -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed for tenant '$TenantKey'
Function: Deploy-TenantAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
  - Validate the parameter values
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $($result | Out-String)
"@
                throw $errorMessage
            }
        }

        Write-LzAwsVerbose "Tenant deployment completed successfully for $TenantKey"
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}

