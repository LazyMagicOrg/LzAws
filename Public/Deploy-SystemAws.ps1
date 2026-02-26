<#
.SYNOPSIS
    Deploys system-wide AWS infrastructure
.DESCRIPTION
    Deploys or updates core system infrastructure components in AWS using SAM templates.
    Deploys the main system stack which includes VPC, networking, ALBs, ECS cluster,
    Route 53, ACM certificate, and WebFinger Lambda.
    Note: Database, EFS, secrets, and SES resources are in the data stack (Deploy-DataAws).
    Downstream stacks (auth, service) read data stack outputs directly.
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Deploy-SystemAws
    Deploys the system infrastructure based on configuration in systemconfig.yaml
.NOTES
    - Must be run from the Tenancy Solution root folder
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
    - Data stack must be deployed after this stack (Deploy-DataAws)
.OUTPUTS
    None
#>
function Deploy-SystemAws {
    [CmdletBinding()]
    param()

    Write-LzAwsVerbose "Deploy-SystemAws"

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        # Deploy system resources first (S3 assets bucket, DynamoDB table)
        Write-LzAwsVerbose "Deploying system resources"
        Deploy-SystemResourcesAws

        Write-LzAwsVerbose "Deploying system stack"
        $StackName = $SystemKey + "---system"
        $ArtifactsBucket = $SystemKey + "---artifacts-" + $SystemSuffix

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.system.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.system.yaml
Function: Deploy-SystemAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        }

        # Build parameters dict
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "SystemSuffixParameter" = $SystemSuffix
        }

        # Add ECS-specific parameters when Config.ECS is present
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            Write-LzAwsVerbose "ECS configuration detected, adding ECS parameters"

            $ParametersDict["EnvironmentParameter"] = $Config.Environment
            $ParametersDict["DomainNameParameter"] = $Config.DefaultTenant

            if ($EcsConfig.LogRetentionDays) {
                $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
            }

            # Resolve the public hosted zone ID for the domain
            if (-not [string]::IsNullOrWhiteSpace($EcsConfig.PublicHostedZoneId)) {
                # Explicit override in config
                $PublicHostedZoneId = $EcsConfig.PublicHostedZoneId
                Write-LzAwsVerbose "Using PublicHostedZoneId from config: $PublicHostedZoneId"
            } else {
                # Auto-resolve from DefaultTenant domain name
                $PublicHostedZoneId = Resolve-PublicHostedZoneId -DomainName $Config.DefaultTenant
            }
            $ParametersDict["PublicHostedZoneIdParameter"] = $PublicHostedZoneId
        }

        # Use Get-TemplateParameters to filter to only valid parameters
        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.system.yaml"
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

        # Deploy the system stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $result = sam deploy `
            --template-file Templates/sam.system.yaml `
            --s3-bucket $ArtifactsBucket `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
            --profile $ProfileName `
            --region $Region 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            # Convert the result array to a single string for easier searching
            $resultString = $result | Out-String

            # Check if the result contains "No changes to deploy" (case-insensitive)
            if ($resultString -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-SystemAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
  - Validate the parameter values
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $resultString
"@
                throw $errorMessage
            }
        }

        Write-Host "Deploy-SystemAws stack deployed successfully" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-SystemAws completed"
    return $true
}
