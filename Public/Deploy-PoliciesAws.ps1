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
        $SystemConfig = Get-SystemConfig # find and load the systemconfig.yaml file
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
        $Environment = $Config.Environment

        $StackName = $SystemKey + "---policies" 

        # Get system stack outputs
        $SystemStack = $Config.SystemKey + "---system"
        try {
            $SystemStackOutputDict = Get-StackOutputs $SystemStack
            if ($null -eq $SystemStackOutputDict["KeyValueStoreArn"]) {
                Write-Host "Error: KeyValueStoreArn not found in system stack outputs"
                Write-Host "Hints:"
                Write-Host "  - Verify the system stack was deployed successfully"
                Write-Host "  - Check if the KVS resource was created"
                Write-Host "  - Ensure the system stack outputs are correct"
                exit 1
            }
            $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]
        }
        catch {
            Write-Host "Error: Failed to get system stack outputs"
            Write-Host "Hints:"
            Write-Host "  - Verify the system stack exists"
            Write-Host "  - Check if you have permission to read stack outputs"
            Write-Host "  - Ensure the stack name is correct: $SystemStack"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        Write-LzAwsVerbose "Deploying the stack $StackName" 

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.policies.yaml" -PathType Leaf)) {
            Write-Host "Error: Template file not found: Templates/sam.policies.yaml"
            Write-Host "Hints:"
            Write-Host "  - Check if the template file exists in the Templates directory"
            Write-Host "  - Verify the template file name is correct"
            Write-Host "  - Ensure you are running from the correct directory"
            exit 1
        }

        # Deploy the policies stack
        try {
            sam deploy `
                --template-file Templates/sam.policies.yaml `
                --stack-name $StackName `
                --parameter-overrides SystemKey=$SystemKey EnvironmentParameter=$Environment KeyValueStoreArnParameter=$KeyValueStoreArn `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --profile $ProfileName 

            if ($LASTEXITCODE -ne 0) {
                throw "SAM deployment failed with exit code $LASTEXITCODE"
            }

            Write-Host "Successfully deployed policies stack" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to deploy policies stack"
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
        Write-Host "Error: An unexpected error occurred during policies deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}
