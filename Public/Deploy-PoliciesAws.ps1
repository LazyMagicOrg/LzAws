# This script deploys as stack that creates the policies and functions used in CloudFront
function Deploy-PoliciesAws {
    <#
    .SYNOPSIS
        Deploys IAM policies to AWS

    .DESCRIPTION
        Deploys or updates IAM policies in AWS, managing permissions
        and access controls across the infrastructure.

    .EXAMPLE
        Deploy-PoliciesAws 
        Deploys the specified IAM policies to AWS

    .OUTPUTS
        System.Object

    .NOTES
        Requires valid AWS credentials and appropriate permissions

    .LINK
        New-LzAwsCFPoliciesStack

    .COMPONENT
        LzAws
    #>    
    Write-LzAwsVerbose "Starting CloudFront Policies and Functions stack deployment"  
    try {
        $null = Get-SystemConfig # find and load the systemconfig.yaml file
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config

        if ($null -eq $Config) {
            $errorMessage = @"
Error: System configuration is missing Config section
Function: Deploy-PoliciesAws
Hints:
  - Check if Config section exists in systemconfig.yaml
  - Verify the configuration file structure
  - Ensure all required configuration sections are present
"@
            throw $errorMessage
        }

        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment
        $StackName = $SystemKey + "---policies" 

        # Get system stack outputs
        $SystemStack = $Config.SystemKey + "---system"
        $SystemStackOutputDict = Get-StackOutputs $SystemStack

        if ($null -eq $SystemStackOutputDict["KeyValueStoreArn"]) {
            $errorMessage = @"
Error: KeyValueStoreArn not found in system stack outputs
Function: Deploy-PoliciesAws
Hints:
  - Verify the system stack was deployed successfully
  - Check if the KVS resource was created
  - Ensure the system stack outputs are correct
"@
            throw $errorMessage
        }
        $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]

        Write-LzAwsVerbose "Deploying the stack $StackName" 

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.policies.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.policies.yaml
Function: Deploy-PoliciesAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        }

        # Deploy the policies stack
        $result = sam deploy `
            --template-file Templates/sam.policies.yaml `
            --stack-name $StackName `
            --parameter-overrides SystemKey=$SystemKey EnvironmentParameter=$Environment KeyValueStoreArnParameter=$KeyValueStoreArn `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
            --region $Region `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-PoliciesAws
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
