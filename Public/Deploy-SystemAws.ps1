<#
.SYNOPSIS
    Deploys system-wide AWS infrastructure
.DESCRIPTION
    Deploys or updates core system infrastructure components in AWS using SAM templates.
    First deploys system resources, then deploys the main system stack which includes
    key-value store and other foundational services.
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Deploy-SystemAws
    Deploys the system infrastructure based on configuration in systemconfig.yaml
.NOTES
    - Must be run from the Tenancy Solution root folder
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
.OUTPUTS
    None
#>
function Deploy-SystemAws {
    [CmdletBinding()]
    param()    

    Write-LzAwsVerbose "Deploy-SystemAws"

    try {
        # Deploy system resources first
        try {
            Write-LzAwsVerbose "Deploying system resources"
            Deploy-SystemResourcesAws
        }
        catch {
            Write-Host "Error: Failed to deploy system resources"
            Write-Host "Hints:"
            Write-Host "  - Check if system resources deployment completed successfully"
            Write-Host "  - Verify AWS credentials and permissions"
            Write-Host "  - Review system stack deployment logs"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        Write-LzAwsVerbose "Deploying system stack"  

        $SystemConfig = Get-SystemConfig 
        # Get-SystemConfig already handles exit 1 on failure

        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            Write-Host "Error: System configuration is missing Config section"
            Write-Host "Hints:"
            Write-Host "  - Check if Config section exists in systemconfig.yaml"
            Write-Host "  - Verify the configuration file structure"
            Write-Host "  - Ensure all required configuration sections are present"
            exit 1
        }

        $ProfileName = $Config.Profile
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---system"

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.system.yaml" -PathType Leaf)) {
            Write-Host "Error: Template file not found: Templates/sam.system.yaml"
            Write-Host "Hints:"
            Write-Host "  - Check if the template file exists in the Templates directory"
            Write-Host "  - Verify the template file name is correct"
            Write-Host "  - Ensure you are running from the correct directory"
            exit 1
        }

        # Deploy the system stack
        try {
            Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
            sam deploy `
                --template-file Templates/sam.system.yaml `
                --stack-name $StackName `
                --parameter-overrides SystemKeyParameter=$SystemKey SystemSuffixParameter=$SystemSuffix `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --profile $ProfileName

            if ($LASTEXITCODE -ne 0) {
                throw "SAM deployment failed with exit code $LASTEXITCODE"
            }

            Write-Host "Successfully deployed system stack" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to deploy system stack"
            Write-Host "Hints:"
            Write-Host "  - Check AWS CloudFormation console for detailed errors"
            Write-Host "  - Verify you have required IAM permissions"
            Write-Host "  - Ensure the template syntax is correct"
            Write-Host "  - Validate the parameter values"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred during system deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}
