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
    # Setup
    
    Write-LzAwsVerbose "Deploying CloudFront Policies and Functions stack"  
    try {
        $SystemConfig = Get-SystemConfig # find and load the systemconfig.yaml file
        $Config = $SystemConfig.Config
        $ProfileName = $Config.Profile
        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment

        $StackName = $SystemKey + "---policies" 

        # Get system stack outputs
        $SystemStack = $Config.SystemKey + "---system"
        $SystemStackOutputDict = Get-StackOutputs $SystemStack
        $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]

        Write-LzAwsVerbose "Deploying the stack $StackName" 

        # Note that sam requires we explicitly set the --profile	
        sam deploy `
        --template-file Templates/sam.policies.yaml `
        --stack-name $StackName `
        --parameter-overrides SystemKey=$SystemKey  EnvironmentParameter=$Environment KeyValueStoreArnParameter=$KeyValueStoreArn `
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
        --profile $ProfileName 
    }
    catch {
        throw
    }
}
