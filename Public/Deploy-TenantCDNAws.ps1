<#
.SYNOPSIS
    Deploys a tenant CDN configuration to AWS
.DESCRIPTION
    Deploys or updates a tenant's CloudFront distribution and related resources.

    Supports two deployment architectures, detected automatically:

    ECS architecture (Config.ECS exists):
      - Deploys ACM wildcard certificate to us-east-1 (CloudFront requirement)
      - Creates S3 bucket for WASM/static assets (private, accessed via OAC)
      - Creates CloudFront distribution with S3 + ALB origins
      - Creates Origin Access Control for S3
      - Creates Route53 records pointing root domain and wildcard to CloudFront
      - No TenantKey parameter required (uses DefaultTenant from config)
      - Requires system stack (Deploy-SystemAws)

    Lambda architecture (Config.Tenants exists):
      - Deploys per-tenant CloudFront distribution with Lambda origins
      - Requires TenantKey parameter matching a tenant in tenantconfig
      - Requires policies stack (Deploy-TenantPoliciesAws)
.PARAMETER TenantKey
    The unique identifier for the CDN tenant. Required for Lambda architecture.
    Ignored for ECS architecture (uses DefaultTenant from config).
.EXAMPLE
    Deploy-TenantCDNAws
    Deploys the ECS tenant CDN stack (CloudFront + S3 + ALB proxy)
.EXAMPLE
    Deploy-TenantCDNAws -TenantKey "tenant123"
    Deploys the specified tenant CDN configuration (Lambda architecture)
.NOTES
    Requires valid AWS credentials and appropriate permissions.
    Architecture is auto-detected from tenantconfig.
    The CDN certificate is deployed automatically to us-east-1 as a sub-step.
.OUTPUTS
    System.Boolean - $true on success, $false on failure
#>
function Deploy-TenantCDNAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )

    try {
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $Environment = $Config.Environment
        # Use ConfigTenantKey to avoid collision with $TenantKey parameter (Lambda architecture)
        $ConfigTenantKey = $Config.TenantKey

        # Get system key (needed for stack naming in both architectures)
        $SystemKey = $Config.SystemKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            throw "SystemKey not found in tenantconfig. Add 'SystemKey: `"ezra`"' to your tenantconfig file."
        }

        # Detect architecture: ECS (CloudFront + S3 + ALB) vs Lambda
        $IsEcs = ($null -ne $Config.ECS)

        if ($IsEcs) {
            # ---------------------------------------------------------------
            # ECS Architecture: CloudFront + S3 bucket + ALB proxy
            # ---------------------------------------------------------------
            Write-LzAwsVerbose "Deploying tenant CDN stack (ECS architecture)"

            $DomainName = $Config.DefaultTenant
            if ([string]::IsNullOrWhiteSpace($DomainName)) {
                $errorMessage = @"
Error: DefaultTenant is missing or empty in tenantconfig
Function: Deploy-TenantCDNAws
Hints:
  - Add a 'DefaultTenant' property to your tenantconfig file
  - Example: DefaultTenant: "ezradev.click"
"@
                throw $errorMessage
            }

            $StackName = "$SystemKey-$ConfigTenantKey--cdn"

            # Verify template exists
            if (-not (Test-Path -Path "Templates/sam.tenant.yaml" -PathType Leaf)) {
                $errorMessage = @"
Error: Template file not found: Templates/sam.tenant.yaml
Function: Deploy-TenantCDNAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
                throw $errorMessage
            }

            # --- Get infrastructure stack outputs ---
            $InfraStackName = "$SystemKey---system"
            Write-LzAwsVerbose "Reading system stack outputs from $InfraStackName"
            $InfraStackOutputDict = Get-StackOutputs $InfraStackName

            $AlbDnsName = $InfraStackOutputDict["AlbDnsName"]
            if ([string]::IsNullOrWhiteSpace($AlbDnsName)) {
                $errorMessage = @"
Error: AlbDnsName not found in stack outputs for '$InfraStackName'
Function: Deploy-TenantCDNAws
Hints:
  - Verify the infrastructure stack was deployed successfully
  - Run Deploy-SystemAws first
"@
                throw $errorMessage
            }

            $PublicHostedZoneId = $InfraStackOutputDict["PublicHostedZoneId"]
            if ([string]::IsNullOrWhiteSpace($PublicHostedZoneId)) {
                $errorMessage = @"
Error: PublicHostedZoneId not found in stack outputs for '$InfraStackName'
Function: Deploy-TenantCDNAws
Hints:
  - Verify the infrastructure stack was deployed successfully
  - Run Deploy-SystemAws first
"@
                throw $errorMessage
            }

            # --- Deploy CDN certificate to us-east-1 (CloudFront requirement) ---
            $CertStackName = "$SystemKey-$ConfigTenantKey--cdn-cert"

            # Verify cert template exists
            if (-not (Test-Path -Path "Templates/sam.cdn-cert.yaml" -PathType Leaf)) {
                $errorMessage = @"
Error: Template file not found: Templates/sam.cdn-cert.yaml
Function: Deploy-TenantCDNAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
                throw $errorMessage
            }

            $CertParametersDict = @{
                "SystemKeyParameter"   = $SystemKey
                "TenantKeyParameter"   = $ConfigTenantKey
                "DomainNameParameter"  = $DomainName
                "HostedZoneIdParameter" = $PublicHostedZoneId
            }

            $CertTemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.cdn-cert.yaml"
            $FilteredCertParametersDict = @{}
            foreach ($Key in $CertParametersDict.Keys) {
                if ($CertTemplateParameters -contains $Key) {
                    $FilteredCertParametersDict[$Key] = $CertParametersDict[$Key]
                }
            }
            $CertParameters = ConvertTo-ParameterOverrides -parametersDict $FilteredCertParametersDict

            Write-Host "Deploying CDN certificate stack $CertStackName to us-east-1"
            $certResult = sam deploy `
                --template-file Templates/sam.cdn-cert.yaml `
                --stack-name $CertStackName `
                --parameter-overrides $CertParameters `
                --capabilities CAPABILITY_IAM `
                --region us-east-1 `
                --profile $ProfileName 2>&1

            $certExitCode = $LASTEXITCODE
            if ($certExitCode -ne 0) {
                $certResults = $certResult | Out-String
                if ($certResults -match "No changes to deploy") {
                    Write-LzAwsVerbose "CDN certificate stack is up to date."
                } else {
                    $errorMessage = @"
Error: SAM deployment failed for CDN certificate
Function: Deploy-TenantCDNAws
Hints:
  - Check AWS CloudFormation console in us-east-1 for detailed errors
  - If the certificate is pending validation, check ACM console and
    create DNS validation records in Route 53 if needed
  - Verify you have required IAM permissions
Error Details: SAM deployment failed with exit code $certExitCode
Command Output: $certResults
"@
                    throw $errorMessage
                }
            } else {
                Write-Host "CDN certificate deployed to us-east-1" -ForegroundColor Green
            }

            # --- Read CDN certificate ARN from us-east-1 ---
            Write-LzAwsVerbose "Reading CDN certificate ARN from $CertStackName in us-east-1"
            $certStackJson = aws cloudformation describe-stacks `
                --stack-name $CertStackName `
                --region us-east-1 `
                --profile $ProfileName `
                --output json 2>&1

            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to read CDN certificate stack '$CertStackName' in us-east-1
Function: Deploy-TenantCDNAws
Hints:
  - Check if the certificate has been issued (not pending validation)
  - Check ACM console in us-east-1 and create DNS validation records if needed
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
Function: Deploy-TenantCDNAws
Hints:
  - Verify the CDN certificate stack deployed successfully in us-east-1
  - Check if the ACM certificate has been issued (pending validation?)
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "CDN Certificate ARN: $CdnCertificateArn"

            # --- Get policies stack outputs ---
            $PolicyStackName = "$SystemKey-$ConfigTenantKey--policies"
            $PolicyStackOutputDict = Get-StackOutputs $PolicyStackName
            $ResponseHeadersPolicyId = $PolicyStackOutputDict["ResponseHeadersPolicyId"]
            if ([string]::IsNullOrWhiteSpace($ResponseHeadersPolicyId)) {
                $errorMessage = @"
Error: ResponseHeadersPolicyId not found in policies stack outputs
Function: Deploy-TenantCDNAws
Hints:
  - Verify the policies stack was deployed successfully
  - Run Deploy-TenantPoliciesAws first
"@
                throw $errorMessage
            }
            Write-LzAwsVerbose "Response Headers Policy ID: $ResponseHeadersPolicyId"

            # --- Read CDN config from tenantconfig ---
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
            $TenantSuffix = $Config.TenantSuffix
            $ParametersDict = @{
                "SystemKeyParameter"        = $SystemKey
                "TenantKeyParameter"          = $ConfigTenantKey
                "TenantSuffixParameter"       = $TenantSuffix
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
            Write-Host "Deploying tenant CDN stack $StackName"
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
                    Write-LzAwsVerbose "No changes to deploy. Tenant CDN stack is up to date."
                } else {
                    $errorMessage = @"
Error: SAM deployment failed for tenant CDN stack
Function: Deploy-TenantCDNAws
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

                Write-Host "Successfully deployed tenant CDN stack" -ForegroundColor Green
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
Function: Deploy-TenantCDNAws
Hints:
  - Provide a TenantKey: Deploy-TenantCDNAws -TenantKey "mytenant"
  - The TenantKey must match a tenant defined in tenantconfig
  - For ECS architecture, add an ECS section to tenantconfig
"@
                throw $errorMessage
            }

            Deploy-TenantResourcesAws $TenantKey

            Write-LzAwsVerbose "Deploying tenant CDN stack (Lambda architecture)"

            $TenantSuffix = $Config.TenantSuffix

            $StackName = $ConfigTenantKey + "-" + $TenantKey + "--tenant"
            $ArtifactsBucket = $SystemKey + "-" + $ConfigTenantKey + "--artifacts-" + $Config.TenantSuffix
            $Tenant = $Config.Tenants[$TenantKey]
            # Validate required tenant properties
            $RequiredProps = @('RootDomain', 'HostedZoneId', 'AcmCertificateArn')
            foreach ($Prop in $RequiredProps) {
                if (-not $Tenant.ContainsKey($Prop) -or [string]::IsNullOrWhiteSpace($Tenant[$Prop])) {
                    $errorMessage = @"
Error: Missing required property '$Prop' for tenant '$TenantKey'
Function: Deploy-TenantCDNAws
Hints:
  - Check tenant configuration in tenantconfig.yaml
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
Function: Deploy-TenantCDNAws
Hints:
  - Check tenant configuration in tenantconfig.yaml
  - Verify the RootDomain property is defined
  - Ensure the RootDomain value is not empty
"@
                throw $errorMessage
            }

            $HostedZoneId = $Tenant.HostedZoneId
            $AcmCertificateArn = $Tenant.AcmCertificateArn
            $CdnTenantSuffix = $TenantSuffix # default
            if($Tenant.ContainsKey('TenantSuffix') -and ![string]::IsNullOrWhiteSpace($Tenant.TenantSuffix)) {
                $CdnTenantSuffix = $Tenant.TenantSuffix
            }

            # Get stack outputs
            $PolicyStackOutputDict = Get-StackOutputs ($SystemKey + "-" + $ConfigTenantKey + "--policies")

            # Create the parameters dictionary
            $ParametersDict = @{
                # TenantConfig values
                "SystemKeyParameter" = $SystemKey
                "EnvironmentParameter" = $Environment
                "TenantKeyParameter" = $TenantKey
                "GuidParameter" = $CdnTenantSuffix
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
Function: Deploy-TenantCDNAws
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
                Write-LzAwsVerbose "Tenant CDN deployment completed successfully for $TenantKey"
            }
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
