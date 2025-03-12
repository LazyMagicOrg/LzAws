<#
.SYNOPSIS
    Deploys authentication configurations to AWS
.DESCRIPTION
    Deploys or updates authentication and authorization configurations
    in AWS, including Cognito User Pools, Identity Pools, and related resources.
.EXAMPLE
    Deploy-AuthsAws
    Deploys the authentication configurations defined in the system config
.NOTES
    Requires valid AWS credentials and appropriate permissions
.OUTPUTS
    System.Object
#>
function Deploy-AuthsAws {
    [CmdletBinding()]
    param()	
	Write-LzAwsVerbose "Deploying Authentication stack(s)"  
	$SystemConfig = Get-SystemConfig 
    $AdminAuth = $SystemConfig.AdminAuth
    $AdminEmail = $AdminAuth.Email

	$Config = $SystemConfig.Config
	$ProfileName = $Config.Profile
	$SystemKey = $Config.SystemKey

    $Region = $SystemConfig.Region
    $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

    # Verify required folders and files exist
    if(-not (Test-Path -Path "./Generated" -PathType Container)) {
        throw "Generated folder does not exist."
    }

    if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
        throw "deploymentconfig.yaml does not exist."
    }

    # Get system stack outputs
    $TargetStack = $SystemKey + "---system"
    $SystemStackOutputDict = Get-StackOutputs $TargetStack
    $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]

    # Load deployment config
    $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml

    # Initialize KVS entry dictionary
    $KvsEntry = @{}

    # Process each authenticator
    $Authenticators = $DeploymentConfig.Authentications
    foreach($Authenticator in $Authenticators) {
        $StackName = $Config.SystemKey + "---" + $Authenticator.Name

        # Build parameters for SAM deployment
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "UserPoolNameParameter" = $Authenticator.Name
            "CallBackURLParameter" = $Authenticator.CallBackURL
            "LogoutURLParameter" = $Authenticator.LogoutURL
            "DeleteAfterDaysParameter" = $Authenticator.DeleteAfterDays
            "StartWindowMinutesParameter" = $Authenticator.StartWindowMinutes    
            "ScheduleExpressionParameter" = $Authenticator.ScheduleExpression
            "SecurityLevelParameter" = $Authenticator.SecurityLevel
        }
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict

        # Deploy the authenticator stack
        Write-Host "Deploy the stack $StackName using profile $ProfileName"
        sam deploy `
            --template-file $Authenticator.Template `
            --s3-bucket $ArtifactsBucket `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
            --profile $ProfileName

        # Get stack outputs and build KVS entry
        $StackOutputs = Get-StackOutputs $StackName
        $Key = $Authenticator.Name
        $Value = @{
            awsRegion = $Region
            userPoolName = $Authenticator.Name 
            userPoolId = $StackOutputs["UserPoolId"]
            userPoolClientId = $StackOutputs["UserPoolClientId"]
            userPoolSecurityLevel = $StackOutputs["SecurityLevel"]
            identityPoolId = ""
        }
        $KvsEntry.$Key = $Value
    }


    # Update KVS with all authenticator configurations
    $KvsEntryJson = ConvertTo-JSON $KvsEntry -Depth 10 -Compress
    $KvsEntryKey = "AuthConfigs"
    Update-KVSEntry $KeyValueStoreArn $KvsEntryKey $KvsEntryJson  
}