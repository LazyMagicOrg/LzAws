<#
.SYNOPSIS
    Deploys the CDN ACM certificate to us-east-1
.DESCRIPTION
    Deploys an ACM wildcard certificate for CloudFront to the us-east-1 region.
    CloudFront requires certificates in us-east-1 regardless of where other
    resources are deployed. Uses DNS validation against the Route 53 hosted zone.

    This is a one-time deployment. The certificate ARN is used by Deploy-TenantAws
    when deploying the CloudFront distribution.
.EXAMPLE
    Deploy-CdnCertAws
    Deploys the CDN certificate stack to us-east-1
.NOTES
    Requires valid AWS credentials and a Route 53 public hosted zone for the domain.
    The stack is deployed to us-east-1, NOT the region in tenantconfig.
.OUTPUTS
    System.Boolean - $true on success, $false on failure
#>
function Deploy-CdnCertAws {
    [CmdletBinding()]
    param()

    Write-LzAwsVerbose "Starting CDN certificate deployment to us-east-1"
    try {
        $null = Get-TenantConfig
        $ProfileName = $script:ProfileName
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $TenantKey = $Config.TenantKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            throw "SystemKey not found in tenantconfig. Add 'SystemKey: `"ezra`"' to your tenantconfig file."
        }
        if ([string]::IsNullOrWhiteSpace($TenantKey)) {
            throw "TenantKey not found in tenantconfig. Add 'TenantKey' to your tenantconfig file."
        }
        $DomainName = $Config.DefaultTenant

        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            $errorMessage = @"
Error: DefaultTenant is missing or empty in tenantconfig
Function: Deploy-CdnCertAws
Hints:
  - Add a 'DefaultTenant' property to your tenantconfig file
  - Example: DefaultTenant: "ezradev.click"
"@
            throw $errorMessage
        }

        $StackName = "$SystemKey-$TenantKey--cdn-cert"

        # Resolve the public hosted zone ID for DNS validation
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig -and -not [string]::IsNullOrWhiteSpace($EcsConfig.PublicHostedZoneId)) {
            $PublicHostedZoneId = $EcsConfig.PublicHostedZoneId
            Write-LzAwsVerbose "Using PublicHostedZoneId from config: $PublicHostedZoneId"
        } else {
            $PublicHostedZoneId = Resolve-PublicHostedZoneId -DomainName $DomainName
        }

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.cdn-cert.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.cdn-cert.yaml
Function: Deploy-CdnCertAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        $ParametersDict = @{
            "SystemKeyParameter"   = $SystemKey
            "TenantKeyParameter"     = $TenantKey
            "DomainNameParameter"    = $DomainName
            "HostedZoneIdParameter"  = $PublicHostedZoneId
        }

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.cdn-cert.yaml"
        $FilteredParametersDict = @{}
        foreach ($Key in $ParametersDict.Keys) {
            if ($TemplateParameters -contains $Key) {
                $FilteredParametersDict[$Key] = $ParametersDict[$Key]
            }
        }
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

        # Deploy to us-east-1 (CloudFront certificate requirement)
        Write-Host "Deploying CDN certificate stack $StackName to us-east-1"
        $result = sam deploy `
            --template-file Templates/sam.cdn-cert.yaml `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM `
            --region us-east-1 `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $results = $result | Out-String
            if ($results -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. CDN certificate stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed for CDN certificate
Function: Deploy-CdnCertAws
Hints:
  - Check AWS CloudFormation console in us-east-1 for detailed errors
  - If the certificate is pending validation, check ACM console and
    create DNS validation records in Route 53 if needed
  - Verify you have required IAM permissions
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $($result | Out-String)
"@
                throw $errorMessage
            }
        }
        else {
            Write-Host "Successfully deployed CDN certificate to us-east-1" -ForegroundColor Green
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
