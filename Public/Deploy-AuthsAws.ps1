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
        $SystemConfig = Get-SystemConfig
        # Get-SystemConfig already handles exit 1 on failure

        $AdminEmail = $SystemConfig.Config.AdminEmail
        if ($null -eq $AdminEmail -or [string]::IsNullOrEmpty($AdminEmail)) {
            Write-Host "Error: AdminEmail is missing or invalid"
            Write-Host "Hints:"
            Write-Host "  - Check if AdminEmail exists in systemconfig.yaml"
            Write-Host "  - Verify AdminEmail is properly configured"
            Write-Host "  - Ensure the email address is valid"
            exit 1
        }

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
        $Region = $SystemConfig.Region
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

        # Verify required folders and files exist
        if(-not (Test-Path -Path "./Generated" -PathType Container)) {
            Write-Host "Error: Generated folder does not exist"
            Write-Host "Hints:"
            Write-Host "  - Run the generation step before deployment"
            Write-Host "  - Check if you are in the correct directory"
            Write-Host "  - Verify the generation process completed successfully"
            Write-Error "Generated folder does not exist" -ErrorAction Stop
        }

        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            Write-Host "Error: deploymentconfig.g.yaml does not exist"
            Write-Host "Hints:"
            Write-Host "  - Run the generation step before deployment"
            Write-Host "  - Check if the generation process completed successfully"
            Write-Host "  - Verify the deployment configuration was generated"
            Write-Error "deploymentconfig.g.yaml does not exist" -ErrorAction Stop
        }

        # Get system stack outputs
        $TargetStack = $SystemKey + "---system"
        try {
            $SystemStackOutputDict = Get-StackOutputs $TargetStack
            $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]
            
            if ([string]::IsNullOrEmpty($KeyValueStoreArn)) {
                Write-Host "Error: KeyValueStoreArn not found in system stack outputs"
                Write-Host "Hints:"
                Write-Host "  - Verify the system stack was deployed successfully"
                Write-Host "  - Check if the KVS resource was created"
                Write-Host "  - Ensure the system stack outputs are correct"
                Write-Error "KeyValueStoreArn not found in system stack outputs" -ErrorAction Stop
            }
        }
        catch {
            Write-Host "Error: Failed to get system stack outputs"
            Write-Host "Hints:"
            Write-Host "  - Verify the system stack exists"
            Write-Host "  - Check if you have permission to read stack outputs"
            Write-Host "  - Ensure the stack name is correct: $TargetStack"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error $_.Exception.Message -ErrorAction Stop
        }

        # Load deployment config
        try {
            $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
            
            if ($null -eq $DeploymentConfig.Authentications) {
                Write-Host "Error: No authentication configurations found in deployment config"
                Write-Host "Hints:"
                Write-Host "  - Check if authentications are defined in the source config"
                Write-Host "  - Verify the generation process included authentications"
                Write-Host "  - Ensure the deployment config format is correct"
                Write-Error "No authentication configurations found in deployment config" -ErrorAction Stop
            }
        }
        catch {
            Write-Host "Error: Failed to load deployment configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if deploymentconfig.g.yaml is valid YAML"
            Write-Host "  - Verify the file is not corrupted"
            Write-Host "  - Ensure the configuration format is correct"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error $_.Exception.Message -ErrorAction Stop
        }

        # Initialize KVS entry dictionary
        $KvsEntry = @{}

        # Process each authenticator
        $Authenticators = $DeploymentConfig.Authentications
        foreach($Authenticator in $Authenticators) {
            $StackName = $Config.SystemKey + "---" + $Authenticator.Name
            Write-LzAwsVerbose "Processing authenticator: $($Authenticator.Name)"

            if ([string]::IsNullOrEmpty($Authenticator.Template) -or -not (Test-Path $Authenticator.Template)) {
                Write-Host "Error: Invalid or missing template for authenticator '$($Authenticator.Name)'"
                Write-Host "Hints:"
                Write-Host "  - Check if the template file exists: $($Authenticator.Template)"
                Write-Host "  - Verify the template path is correct"
                Write-Host "  - Ensure the template is properly referenced"
                Write-Error "Invalid or missing template for authenticator '$($Authenticator.Name)'" -ErrorAction Stop
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
                Write-Host "Error: Failed to prepare parameters for authenticator '$($Authenticator.Name)'"
                Write-Host "Hints:"
                Write-Host "  - Check if all required parameters are present"
                Write-Host "  - Verify parameter values are valid"
                Write-Host "  - Ensure parameter types match template requirements"
                Write-Host "Error Details: $($_.Exception.Message)"
                Write-Error $_.Exception.Message -ErrorAction Stop
            }

            # Deploy the authenticator stack
            Write-Host "Deploying stack $StackName using profile $ProfileName"
            try {
                sam deploy `
                    --template-file $Authenticator.Template `
                    --s3-bucket $ArtifactsBucket `
                    --stack-name $StackName `
                    --parameter-overrides $Parameters `
                    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                    --profile $ProfileName

                if ($LASTEXITCODE -ne 0) {
                    Write-Host "Error: Failed to deploy authenticator stack '$StackName'"
                    Write-Host "Hints:"
                    Write-Host "  - Check AWS CloudFormation console for detailed errors"
                    Write-Host "  - Verify you have required IAM permissions"
                    Write-Host "  - Ensure the S3 bucket '$ArtifactsBucket' exists and is accessible"
                    Write-Host "  - Validate the template syntax and parameters"
                    Write-Error "SAM deployment failed with exit code $LASTEXITCODE" -ErrorAction Stop
                }
            }
            catch {
                Write-Host "Error: Failed to deploy authenticator stack '$StackName'"
                Write-Host "Hints:"
                Write-Host "  - Check AWS CloudFormation console for detailed errors"
                Write-Host "  - Verify you have required IAM permissions"
                Write-Host "  - Ensure the S3 bucket '$ArtifactsBucket' exists and is accessible"
                Write-Host "  - Validate the template syntax and parameters"
                Write-Host "Error Details: $($_.Exception.Message)"
                Write-Error $_.Exception.Message -ErrorAction Stop
            }

            # Get stack outputs and build KVS entry
            try {
                $StackOutputs = Get-StackOutputs $StackName
                if ($null -eq $StackOutputs["UserPoolId"] -or $null -eq $StackOutputs["UserPoolClientId"] -or $null -eq $StackOutputs["SecurityLevel"]) {
                    Write-Host "Error: Missing required outputs from stack '$StackName'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if the stack deployment completed successfully"
                    Write-Host "  - Verify the template includes all required outputs"
                    Write-Host "  - Ensure the resources were created properly"
                    Write-Error "Missing required outputs from stack '$StackName'" -ErrorAction Stop
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
            catch {
                Write-Host "Error: Failed to process stack outputs for '$StackName'"
                Write-Host "Hints:"
                Write-Host "  - Verify the stack exists and deployment completed"
                Write-Host "  - Check if you have permission to read stack outputs"
                Write-Host "  - Ensure all required outputs are defined in the template"
                Write-Host "Error Details: $($_.Exception.Message)"
                Write-Error $_.Exception.Message -ErrorAction Stop
            }
        }

        # Update KVS with all authenticator configurations
        try {
            $KvsEntryJson = ConvertTo-JSON $KvsEntry -Depth 10 -Compress
            $KvsEntryKey = "AuthConfigs"
            Update-KVSEntry $KeyValueStoreArn $KvsEntryKey $KvsEntryJson
            Write-LzAwsVerbose "Successfully updated KVS with authenticator configurations"
        }
        catch {
            Write-Host "Error: Failed to update KVS entry with authenticator configurations"
            Write-Host "Hints:"
            Write-Host "  - Check if the KVS table exists and is accessible"
            Write-Host "  - Verify you have permission to update KVS entries"
            Write-Host "  - Ensure the JSON data is valid"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error $_.Exception.Message -ErrorAction Stop
        }

        Write-Host "Successfully deployed all authentication stacks" -ForegroundColor Green
    }
    catch {
        Write-Host "Error: An unexpected error occurred during authentication deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error $_.Exception.Message -ErrorAction Stop
    }
}