# This script deploys a stack that creates the policies and functions used in CloudFront
function Deploy-TenantPoliciesAws {
    <#
    .SYNOPSIS
        Deploys CloudFront policies for a tenant to AWS

    .DESCRIPTION
        Deploys or updates CloudFront policies and functions for a tenant,
        managing caching, request handling, and response headers.

    .PARAMETER TenantKey
        Optional. The tenant identifier for config file discovery.
        If omitted, auto-detects when only one config exists.

    .EXAMPLE
        Deploy-TenantPoliciesAws
        Deploys the tenant's CloudFront policies to AWS

    .EXAMPLE
        Deploy-TenantPoliciesAws -TenantKey "ezra"
        Deploys policies for a specific tenant

    .OUTPUTS
        System.Boolean - $true on success, $false on failure

    .NOTES
        Requires valid AWS credentials and appropriate permissions

    .LINK
        New-LzAwsCFPoliciesStack

    .COMPONENT
        LzAws
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )
    Write-LzAwsVerbose "Starting CloudFront Policies and Functions stack deployment"
    try {
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config

        if ($null -eq $Config) {
            $errorMessage = @"
Error: Tenant configuration is missing Config section
Function: Deploy-TenantPoliciesAws
Hints:
  - Check if Config section exists in tenantconfig.yaml
  - Verify the configuration file structure
  - Ensure all required configuration sections are present
"@
            throw $errorMessage
        }

        $TenantKey = $Config.TenantKey
        $TenantSuffix = $Config.TenantSuffix
        $Environment = $Config.Environment

        # Get infrastructure stack outputs (system-aware)
        $SystemKey = $Config.SystemKey
        if (-not [string]::IsNullOrWhiteSpace($SystemKey)) {
            $InfraStackName = "$SystemKey---system"
            Write-LzAwsVerbose "Reading system stack outputs from $InfraStackName"
        } else {
            throw "SystemKey not found in tenantconfig. Add 'SystemKey' to your tenantconfig file."
        }
        $StackName = $SystemKey + "-" + $TenantKey + "--policies"
        $InfraStackOutputDict = Get-StackOutputs $InfraStackName

        if ($null -eq $InfraStackOutputDict["KeyValueStoreArn"]) {
            $errorMessage = @"
Error: KeyValueStoreArn not found in infrastructure stack outputs
Function: Deploy-TenantPoliciesAws
Hints:
  - Verify the infrastructure stack was deployed successfully
  - Check if the KVS resource was created
  - Ensure the infrastructure stack outputs are correct
"@
            throw $errorMessage
        }
        $KeyValueStoreArn = $InfraStackOutputDict["KeyValueStoreArn"]

        $RootDomain = $Config.DefaultTenant
        if ([string]::IsNullOrWhiteSpace($RootDomain)) {
            $errorMessage = @"
Error: DefaultTenant is missing or empty in tenantconfig
Function: Deploy-TenantPoliciesAws
Hints:
  - Add a 'DefaultTenant' property to your tenantconfig file
  - Example: DefaultTenant: "ezradev.click"
"@
            throw $errorMessage
        }

        Write-LzAwsVerbose "Deploying the stack $StackName"

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.policies.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.policies.yaml
Function: Deploy-TenantPoliciesAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        }

        # Deploy the policies stack
        $ParametersDict = @{
            "SystemKeyParameter"     = $SystemKey
            "TenantKeyParameter"       = $TenantKey
            "TenantSuffixParameter"    = $TenantSuffix
            "EnvironmentParameter"     = $Environment
            "KeyValueStoreArnParameter" = $KeyValueStoreArn
            "RootDomainParameter"      = $RootDomain
        }

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.policies.yaml"
        $FilteredParametersDict = @{}
        foreach ($Key in $ParametersDict.Keys) {
            if ($TemplateParameters -contains $Key) {
                $FilteredParametersDict[$Key] = $ParametersDict[$Key]
                Write-LzAwsVerbose "Including parameter: $Key"
            } else {
                Write-LzAwsVerbose "Skipping parameter not in template: $Key"
            }
        }

        $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

        $result = sam deploy `
            --template-file Templates/sam.policies.yaml `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
            --region $Region `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-TenantPoliciesAws
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
        Write-Host "Successfully deployed policies stack" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
