<#
.SYNOPSIS
    Deploys authentication configurations to AWS
.DESCRIPTION
    Deploys or updates authentication and authorization configurations
    in AWS. Supports two modes:
    1. ECS mode: If Templates/sam.auth.yaml exists, deploys Keycloak as a
       single ECS auth stack using system stack outputs.
    2. Cognito mode: Falls back to iterating over deploymentconfig.g.yaml
       authenticators (Cognito User Pools, Identity Pools).
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
        $SystemKey = $Config.SystemKey

        # =====================================================================
        # ECS AUTH PATH: Check for Templates/sam.auth.yaml FIRST
        # This must be before AdminEmail/Generated/deploymentconfig validation
        # because those checks are Cognito-specific and may fail in ECS mode.
        # =====================================================================
        if (Test-Path -Path "Templates/sam.auth.yaml" -PathType Leaf) {
            Write-LzAwsVerbose "Found Templates/sam.auth.yaml - using ECS auth deployment path"

            $StackName = $SystemKey + "---auth"
            $ArtifactsBucket = $SystemKey + "---artifacts-" + $Config.SystemSuffix

            # Get system stack outputs
            $SystemStackName = $SystemKey + "---system"
            Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
            $SystemStackOutputDict = Get-StackOutputs $SystemStackName

            # Build parameters from system stack outputs + ECS config
            $ParametersDict = @{
                "SystemKeyParameter" = $SystemKey
                "SystemSuffixParameter" = $Config.SystemSuffix
                "EnvironmentParameter" = $Config.Environment
                "DomainNameParameter" = $Config.DefaultTenant
            }

            # Add all system stack outputs as parameters
            foreach ($OutputKey in $SystemStackOutputDict.Keys) {
                $ParameterName = $OutputKey + "Parameter"
                if (-not $ParametersDict.ContainsKey($ParameterName)) {
                    $ParametersDict[$ParameterName] = $SystemStackOutputDict[$OutputKey]
                    Write-LzAwsVerbose "Added system stack output: $ParameterName"
                }
            }

            # Add ECS-specific config values
            $EcsConfig = $Config.ECS
            if ($null -ne $EcsConfig) {
                # Auto-detect admin blocking: enable if the service stack exists
                # (meaning Tailscale VPN is deployed), disable otherwise.
                # An explicit config value overrides the auto-detection.
                if ($EcsConfig.EnableAdminBlocking -ne $null) {
                    $ParametersDict["EnableAdminBlockingParameter"] = "$($EcsConfig.EnableAdminBlocking)".ToLower()
                    Write-LzAwsVerbose "EnableAdminBlocking from config: $($ParametersDict['EnableAdminBlockingParameter'])"
                } else {
                    $ServiceStackName = $SystemKey + "---service"
                    $serviceStackStatus = aws cloudformation describe-stacks `
                        --stack-name $ServiceStackName `
                        --query "Stacks[0].StackStatus" `
                        --output text `
                        --profile $ProfileName `
                        --region $Region 2>&1
                    if ($LASTEXITCODE -eq 0 -and $serviceStackStatus -match "COMPLETE") {
                        Write-Host "Service stack found — enabling admin blocking (VPN available)" -ForegroundColor Cyan
                        $ParametersDict["EnableAdminBlockingParameter"] = "true"
                    } else {
                        Write-Host "No service stack — disabling admin blocking (VPN not yet available)" -ForegroundColor Yellow
                        $ParametersDict["EnableAdminBlockingParameter"] = "false"
                    }
                }
                if ($EcsConfig.LogRetentionDays) {
                    $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
                }
                if ($EcsConfig.KeycloakImageTag) {
                    $ParametersDict["KeycloakImageTagParameter"] = $EcsConfig.KeycloakImageTag
                }
                if ($EcsConfig.KeycloakCpu) {
                    $ParametersDict["KeycloakCpuParameter"] = [string]$EcsConfig.KeycloakCpu
                }
                if ($EcsConfig.KeycloakMemory) {
                    $ParametersDict["KeycloakMemoryParameter"] = [string]$EcsConfig.KeycloakMemory
                }
            }

            # Filter to only parameters the template expects
            $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.auth.yaml"
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

            # Deploy the auth stack
            Write-Host "Deploying stack $StackName using profile $ProfileName"
            $result = sam deploy `
                --template-file Templates/sam.auth.yaml `
                --s3-bucket $ArtifactsBucket `
                --stack-name $StackName `
                --parameter-overrides $Parameters `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
                --region $Region `
                --profile $ProfileName 2>&1

            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $resultString = $result | Out-String
                if ($resultString -match "No changes to deploy") {
                    Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
                } else {
                    $errorMessage = @"
Error: Failed to deploy auth stack '$StackName'
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

            # Validate auth stack outputs
            $StackOutputs = Get-StackOutputs $StackName
            if ($null -eq $StackOutputs["UserPoolId"] -or $null -eq $StackOutputs["UserPoolClientId"] -or $null -eq $StackOutputs["SecurityLevel"]) {
                Write-Host "Warning: Auth stack missing expected stub outputs (UserPoolId, UserPoolClientId, SecurityLevel)" -ForegroundColor Yellow
            }

            # Skip KVS update when KeyValueStoreArn is "na" or empty (ECS mode)
            $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]
            if (-not [string]::IsNullOrEmpty($KeyValueStoreArn) -and $KeyValueStoreArn -ne "na") {
                Write-LzAwsVerbose "Updating KVS with auth configuration"
                $KvsEntry = @{
                    "auth" = @{
                        MetadataUrl = $StackOutputs["MetadataUrl"]
                        HostedUIDomain = $StackOutputs["HostedUIDomain"]
                        ClientId = $StackOutputs["ClientId"]
                    }
                }
                $KvsEntryJson = ConvertTo-JSON $KvsEntry -Depth 10 -Compress
                Update-KVSEntry $KeyValueStoreArn "AuthConfigs" $KvsEntryJson
                Write-LzAwsVerbose "Successfully updated KVS with auth configuration"
            } else {
                Write-LzAwsVerbose "Skipping KVS update: KeyValueStoreArn is '$KeyValueStoreArn' (no CloudFront KVS in ECS mode)"
            }

            Write-Host "Successfully deployed authentication stack (ECS/Keycloak)" -ForegroundColor Green
            return $true
        }

        # =====================================================================
        # COGNITO AUTH PATH: Original behavior when sam.auth.yaml doesn't exist
        # =====================================================================
        Write-LzAwsVerbose "No Templates/sam.auth.yaml found - using Cognito deployment path"

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
                    "SystemSuffixParameter" = $Config.SystemSuffix
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
                MetadataUrl = $StackOutputs["MetadataUrl"]
                HostedUIDomain = $StackOutputs["HostedUIDomain"]
                ClientId = $StackOutputs["ClientId"]
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
  - Ensure the JSON data doesn't exceed 1024 bytes
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        $KvsEntryKey = "AuthConfigs"
        Write-LzAwsVerbose "Calling Update-KVSEntry for key AuthConfigs"
        Write-LzAwsVerbose ("KeyValueStoreArn: " + $KeyValueStoreArn)
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
