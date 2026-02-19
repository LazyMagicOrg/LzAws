<#
.SYNOPSIS
    Deploys a tenant configuration to AWS
.DESCRIPTION
    Deploys or updates a tenant's CloudFront distribution and related resources.

    Supports two deployment architectures, detected automatically:

    ECS architecture (Config.ECS exists):
      - Creates S3 bucket for WASM/static assets (private, accessed via OAC)
      - Creates CloudFront distribution with S3 + ALB origins
      - Creates Origin Access Control for S3
      - Creates Route53 records pointing root domain and wildcard to CloudFront
      - No TenantKey parameter required (uses DefaultTenant from config)
      - Requires system stack (Deploy-SystemAws) and CDN certificate (Deploy-CdnCertAws)

    Lambda architecture (Config.Tenants exists):
      - Deploys per-tenant CloudFront distribution with Lambda origins
      - Requires TenantKey parameter matching a tenant in systemconfig
      - Requires policies stack (Deploy-PoliciesAws)
.PARAMETER TenantKey
    The unique identifier for the tenant. Required for Lambda architecture.
    Ignored for ECS architecture (uses DefaultTenant from config).
.EXAMPLE
    Deploy-TenantAws
    Deploys the ECS tenant stack (CloudFront + S3 + ALB proxy)
.EXAMPLE
    Deploy-TenantAws -TenantKey "tenant123"
    Deploys the specified tenant configuration (Lambda architecture)
.NOTES
    Requires valid AWS credentials and appropriate permissions.
    Architecture is auto-detected from systemconfig.
.OUTPUTS
    System.Boolean - $true on success, $false on failure
#>
function Deploy-TenantAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $Environment = $Config.Environment
        $SystemKey = $Config.SystemKey

        # Detect architecture: ECS (CloudFront + S3 + ALB) vs Lambda
        $IsEcs = ($null -ne $Config.ECS)

        if ($IsEcs) {
            # ---------------------------------------------------------------
            # ECS Architecture: CloudFront + S3 bucket + ALB proxy
            # ---------------------------------------------------------------
            Write-LzAwsVerbose "Deploying tenant stack (ECS architecture)"

            $DomainName = $Config.DefaultTenant
            if ([string]::IsNullOrWhiteSpace($DomainName)) {
                $errorMessage = @"
Error: DefaultTenant is missing or empty in systemconfig
Function: Deploy-TenantAws
Hints:
  - Add a 'DefaultTenant' property to your systemconfig file
  - Example: DefaultTenant: "ezradev.click"
"@
                throw $errorMessage
            }

            $StackName = "$SystemKey---tenant"

            # Verify template exists
            if (-not (Test-Path -Path "Templates/sam.tenant.yaml" -PathType Leaf)) {
                $errorMessage = @"
Error: Template file not found: Templates/sam.tenant.yaml
Function: Deploy-TenantAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
                throw $errorMessage
            }

            # --- Get system stack outputs ---
            $SystemStackName = "$SystemKey---system"
            Write-LzAwsVerbose "Reading system stack outputs from $SystemStackName"
            $SystemStackOutputDict = Get-StackOutputs $SystemStackName

            $AlbDnsName = $SystemStackOutputDict["AlbDnsName"]
            if ([string]::IsNullOrWhiteSpace($AlbDnsName)) {
                $errorMessage = @"
Error: AlbDnsName not found in system stack outputs
Function: Deploy-TenantAws
Hints:
  - Verify the system stack was deployed successfully
  - Run Deploy-SystemAws first
"@
                throw $errorMessage
            }

            $PublicHostedZoneId = $SystemStackOutputDict["PublicHostedZoneId"]
            if ([string]::IsNullOrWhiteSpace($PublicHostedZoneId)) {
                $errorMessage = @"
Error: PublicHostedZoneId not found in system stack outputs
Function: Deploy-TenantAws
Hints:
  - Verify the system stack was deployed successfully
  - Run Deploy-SystemAws first
"@
                throw $errorMessage
            }

            # --- Get CDN certificate ARN from us-east-1 ---
            $CertStackName = "$SystemKey---cdn-cert"
            Write-LzAwsVerbose "Reading CDN certificate ARN from $CertStackName in us-east-1"

            # Get-StackOutputs uses $script:Region, but the cert stack is in us-east-1.
            # Call AWS CLI directly to get the cert stack outputs from us-east-1.
            $certStackJson = aws cloudformation describe-stacks `
                --stack-name $CertStackName `
                --region us-east-1 `
                --profile $ProfileName `
                --output json 2>&1

            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to read CDN certificate stack '$CertStackName' in us-east-1
Function: Deploy-TenantAws
Hints:
  - Deploy the CDN certificate first: Deploy-CdnCertAws
  - Verify the certificate stack exists in us-east-1
  - Check that the certificate has been issued (not pending validation)
Error Details: $certStackJson
"@
                throw $errorMessage
            }

            $certStack = $certStackJson | ConvertFrom-Json
            $CdnCertificateArn = $null
            foreach ($output in $certStack.Stacks[0].Outputs) {
                if ($output.OutputKey -eq "CdnCertificateArn") {
                    $CdnCertificateArn = $output.OutputValue
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($CdnCertificateArn)) {
                $errorMessage = @"
Error: CdnCertificateArn not found in CDN certificate stack outputs
Function: Deploy-TenantAws
Hints:
  - Verify the CDN certificate stack deployed successfully in us-east-1
  - Check if the ACM certificate has been issued
  - Run Deploy-CdnCertAws if not already deployed
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "CDN Certificate ARN: $CdnCertificateArn"

            # --- Get policies stack outputs ---
            $PolicyStackName = "$SystemKey---policies"
            $PolicyStackOutputDict = Get-StackOutputs $PolicyStackName
            $ResponseHeadersPolicyId = $PolicyStackOutputDict["ResponseHeadersPolicyId"]
            if ([string]::IsNullOrWhiteSpace($ResponseHeadersPolicyId)) {
                $errorMessage = @"
Error: ResponseHeadersPolicyId not found in policies stack outputs
Function: Deploy-TenantAws
Hints:
  - Verify the policies stack was deployed successfully
  - Run Deploy-PoliciesAws first
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Response Headers Policy ID: $ResponseHeadersPolicyId"

            # --- Read CDN config from systemconfig ---
            $CdnConfig = $Config.CDN
            $PriceClass = "PriceClass_100"
            $DefaultRootObject = "index.html"
            if ($null -ne $CdnConfig) {
                if (-not [string]::IsNullOrWhiteSpace($CdnConfig.PriceClass)) {
                    $PriceClass = $CdnConfig.PriceClass
                }
                if (-not [string]::IsNullOrWhiteSpace($CdnConfig.DefaultRootObject)) {
                    $DefaultRootObject = $CdnConfig.DefaultRootObject
                }
            }

            # --- Build parameters ---
            $SystemSuffix = $Config.SystemSuffix
            $ParametersDict = @{
                "SystemKeyParameter"          = $SystemKey
                "SystemSuffixParameter"       = $SystemSuffix
                "EnvironmentParameter"        = $Environment
                "RootDomainParameter"         = $DomainName
                "HostedZoneIdParameter"       = $PublicHostedZoneId
                "CdnCertificateArnParameter"  = $CdnCertificateArn
                "PriceClassParameter"         = $PriceClass
                "DefaultRootObjectParameter"  = $DefaultRootObject
                "ResponseHeadersPolicyIdParameter" = $ResponseHeadersPolicyId
            }

            $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.tenant.yaml"
            $FilteredParametersDict = @{}
            foreach ($Key in $ParametersDict.Keys) {
                if ($TemplateParameters -contains $Key) {
                    $FilteredParametersDict[$Key] = $ParametersDict[$Key]
                }
            }
            $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

            # --- Deploy ---
            Write-Host "Deploying tenant stack $StackName"
            $result = sam deploy `
                --template-file Templates/sam.tenant.yaml `
                --stack-name $StackName `
                --parameter-overrides $Parameters `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --region $Region `
                --profile $ProfileName 2>&1

            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $results = $result | Out-String
                if ($results -match "No changes to deploy") {
                    Write-LzAwsVerbose "No changes to deploy. Tenant stack is up to date."
                } else {
                    $errorMessage = @"
Error: SAM deployment failed for tenant stack
Function: Deploy-TenantAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the CDN certificate in us-east-1 has been issued
  - Check that origin.{domain} DNS record exists (from system stack)
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $($result | Out-String)
"@
                    throw $errorMessage
                }
            }
            else {
                # Show useful post-deploy info
                $cdnOutputs = Get-StackOutputs $StackName
                $bucketName = $cdnOutputs["AssetsBucketName"]
                $distributionId = $cdnOutputs["CloudFrontDistributionId"]
                $cfDomain = $cdnOutputs["CloudFrontDistributionDomainName"]

                Write-Host "Successfully deployed tenant stack" -ForegroundColor Green
                Write-Host ""
                Write-Host "CloudFront Distribution: $cfDomain" -ForegroundColor Cyan
                Write-Host "Distribution ID: $distributionId" -ForegroundColor Cyan
                Write-Host "Assets Bucket: $bucketName" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "To deploy the WASM app:" -ForegroundColor Yellow
                Write-Host "  aws s3 sync ./publish/wwwroot s3://$bucketName/ --delete --profile $ProfileName --region $Region"
                Write-Host "  aws cloudfront create-invalidation --distribution-id $distributionId --paths '/*' --profile $ProfileName --region $Region"
            }

        } else {
            # ---------------------------------------------------------------
            # Lambda Architecture: per-tenant CloudFront + Lambda origins
            # ---------------------------------------------------------------
            if ([string]::IsNullOrWhiteSpace($TenantKey)) {
                $errorMessage = @"
Error: TenantKey parameter is required for Lambda architecture
Function: Deploy-TenantAws
Hints:
  - Provide a TenantKey: Deploy-TenantAws -TenantKey "mytenant"
  - The TenantKey must match a tenant defined in systemconfig
  - For ECS architecture, add an ECS section to systemconfig
"@
                throw $errorMessage
            }

            Deploy-TenantResourcesAws $TenantKey

            Write-LzAwsVerbose "Deploying tenant stack (Lambda architecture)"

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
            else {
                Write-LzAwsVerbose "Tenant deployment completed successfully for $TenantKey"
            }
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
