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
    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $AdminEmail = $Config.AdminEmail
        if ($null -eq $AdminEmail -or [string]::IsNullOrEmpty($AdminEmail)) {
            $errorMessage = @"
Error: AdminEmail is missing or invalid
Function: Deploy-AuthsAws
Hints:
  - Check if AdminEmail exists in systemconfig.yaml
  - Verify AdminEmail is properly configured
  - Ensure the email address is valid
"@
            throw $errorMessage
        }

        $SystemKey = $Config.SystemKey
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix
        Write-LzAwsVerbose "ArtifactsBucket: $ArtifactsBucket"
        $bucketExists = Test-S3BucketExists -BucketName $ArtifactsBucket
        Write-LzAwsVerbose "bucketExists: $bucketExists"
        if (-not $bucketExists) {
            $errorMessage = @"
Error: S3 bucket '$ArtifactsBucket' does not exist
Function: Deploy-AuthsAws
Hints:
    - Have you run Deploy-SystemAws? It creates this bucket
    - Verify AWS permissions for S3 operations
"@
            throw $errorMessage
        }

        # Verify required folders and files exist
        if(-not (Test-Path -Path "./Generated" -PathType Container)) {
            $errorMessage = @"
Error: Generated folder does not exist
Function: Deploy-AuthsAws
Hints:
  - Run the generation step before deployment
  - Check if you are in the correct directory
  - Verify the generation process completed successfully
"@
            throw $errorMessage
        }

        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: deploymentconfig.g.yaml does not exist
Function: Deploy-AuthsAws
Hints:
  - Run the generation step before deployment
  - Check if the generation process completed successfully
  - Verify the deployment configuration was generated
"@
            throw $errorMessage
        }

        # Get system stack outputs
        $TargetStack = $SystemKey + "---system"
        $SystemStackOutputDict = Get-StackOutputs $TargetStack
        $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]
        
        if ([string]::IsNullOrEmpty($KeyValueStoreArn)) {
            $errorMessage = @"
Error: KeyValueStoreArn not found in system stack outputs
Function: Deploy-AuthsAws
Hints:
  - Verify the system stack was deployed successfully
  - Check if the KVS resource was created
  - Ensure the system stack outputs are correct
"@
            throw $errorMessage
        }

        # Load deployment config
        try {
            $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
        }
        catch {
            $errorMessage = @"
Error: Failed to load deployment configuration
Function: Deploy-AuthsAws
Hints:
  - Check if deploymentconfig.g.yaml is valid YAML
  - Verify the file is not corrupted
  - Ensure the configuration format is correct
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        if ($null -eq $DeploymentConfig.Authentications) {
            $errorMessage = @"
Error: No authentication configurations found in deployment config
Function: Deploy-AuthsAws
Hints:
  - Check if authentications are defined in the source config
  - Verify the generation process included authentications
  - Ensure the deployment config format is correct
"@
                throw $errorMessage
            }

        # Initialize KVS entry dictionary
        $KvsEntry = @{}

        # Process each authenticator
        $Authenticators = $DeploymentConfig.Authentications
        foreach($Authenticator in $Authenticators) {
            $StackName = $Config.SystemKey + "---" + $Authenticator.Name
            Write-LzAwsVerbose "Processing authenticator: $($Authenticator.Name)"

            if ([string]::IsNullOrEmpty($Authenticator.Template) -or -not (Test-Path $Authenticator.Template)) {
                $errorMessage = @"
Error: Invalid or missing template for authenticator '$($Authenticator.Name)'
Function: Deploy-AuthsAws
Hints:
  - Check if the template file exists: $($Authenticator.Template)
  - Verify the template path is correct
  - Ensure the template is properly referenced
"@
                throw $errorMessage
            }

            # Build parameters for SAM deployment
            try {
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
            }
            catch {
                $errorMessage = @"
Error: Failed to prepare parameters for authenticator '$($Authenticator.Name)'
Function: Deploy-AuthsAws
Hints:
  - Check if all required parameters are present
  - Verify parameter values are valid
  - Ensure parameter types match template requirements
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }

            # Deploy the authenticator stack
            Write-Host "Deploying stack $StackName using profile $ProfileName"
            $result = sam deploy `
                --template-file $Authenticator.Template `
                --s3-bucket $ArtifactsBucket `
                --stack-name $StackName `
                --parameter-overrides $Parameters `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --region $Region `
                --profile $ProfileName 2>&1

            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                # Convert the result array to a single string for easier searching
                $resultString = $result | Out-String

                if ($resultString -match "No changes to deploy") {
                    Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
                } else {

                $errorMessage = @"
Error: Failed to deploy authenticator stack '$StackName'
Function: Deploy-AuthsAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the S3 bucket '$ArtifactsBucket' exists and is accessible
  - Validate the template syntax and parameters
Error Details: $result
"@
                    throw $errorMessage
                }
            }

            # Get stack outputs and build KVS entry
            $StackOutputs = Get-StackOutputs $StackName

            if ($null -eq $StackOutputs["UserPoolId"] -or $null -eq $StackOutputs["UserPoolClientId"] -or $null -eq $StackOutputs["SecurityLevel"]) {
                $errorMessage = @"
Error: Missing required outputs from stack '$StackName'
Function: Deploy-AuthsAws
Hints:
  - Check if the stack deployment completed successfully
  - Verify the template includes all required outputs
  - Ensure the resources were created properly
"@
                throw $errorMessage
            }

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
        try {
            $KvsEntryJson = ConvertTo-JSON $KvsEntry -Depth 10 -Compress
        } catch {
            $errorMessage = @"
Error: Failed to convert JSON KvsEntry
Function: Deploy-AuthsAws
Hints:
  - Ensure the JSON data is valid
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        $KvsEntryKey = "AuthConfigs"
        Update-KVSEntry $KeyValueStoreArn $KvsEntryKey $KvsEntryJson
        Write-LzAwsVerbose "Successfully updated KVS with authenticator configurations"
        Write-Host "Successfully deployed all authentication stacks" -ForegroundColor Green
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}