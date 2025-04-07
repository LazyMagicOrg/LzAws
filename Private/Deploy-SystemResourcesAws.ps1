# This script creates AWS resources for the system.
# This these system resources:
# - S3 buckets for system assets
# - DynamoDB table for system
function Deploy-SystemResourcesAws {
    [CmdletBinding()]
    param()
    Write-LzAwsVerbose "Starting system resources deployment"  
    try {
        $SystemConfig = Get-SystemConfig 
        # Get-SystemConfig already handles Write-Error -ErrorAction Stop on failure

        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            Write-Host "Error: System configuration is missing Config section"
            Write-Host "Hints:"
            Write-Host "  - Check if Config section exists in systemconfig.yaml"
            Write-Host "  - Verify the configuration file structure"
            Write-Host "  - Ensure all required configuration sections are present"
            Write-Error "System configuration is missing Config section" -ErrorAction Stop
        }

        $ProfileName = $Config.Profile
        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---system"
        $ArtifactsBucket = $SystemKey + "---artifacts-" + $SystemSuffix

        # Deploy the system stack
        try {
            Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
            sam deploy `
                --template-file Templates/sam.system.yaml `
                --s3-bucket $ArtifactsBucket `
                --stack-name $StackName `
                --parameter-overrides SystemKey=$SystemKey EnvironmentParameter=$Environment SystemSuffixParameter=$SystemSuffix `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --profile $ProfileName

            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error: Failed to deploy system stack"
                Write-Host "Hints:"
                Write-Host "  - Check AWS CloudFormation console for detailed errors"
                Write-Host "  - Verify you have required IAM permissions"
                Write-Host "  - Ensure the template syntax is correct"
                Write-Host "  - Validate the parameter values"
                Write-Error "SAM deployment failed with exit code $LASTEXITCODE" -ErrorAction Stop
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
            Write-Error $_.Exception.Message -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Error: An unexpected error occurred during system deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error $_.Exception.Message -ErrorAction Stop
    }
}