<#
.SYNOPSIS
    Deploys service infrastructure and resources to AWS
.DESCRIPTION
    Deploys or updates service infrastructure in AWS using CloudFormation/SAM templates.
    This includes configuring authentication resources,
    and setting up other required AWS services.
.PARAMETER None
    This cmdlet does not accept any parameters. It uses system configuration files
    to determine deployment settings.
.EXAMPLE
    Deploy-ServiceAws
    Deploys the service infrastructure using settings from configuration files
.NOTES
    - Requires valid AWS credentials and appropriate permissions
    - Must be run from the AWSTemplates directory
    - Requires system configuration files and SAM templates
    - Will configure the use of authentication resources created with Deploy-AuthsAws
.OUTPUTS
    None
#>
function Deploy-ServiceAws {
    [CmdletBinding()]
    param()	
    Write-LzAwsVerbose "Starting service infrastructure deployment"  
    try {
        $SystemConfig = Get-SystemConfig 
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            $errorMessage = @"
Error: System configuration is missing Config section
Function: Deploy-ServiceAws
Hints:
  - Check if Config section exists in systemconfig.yaml
  - Verify the configuration file structure
  - Ensure all required configuration sections are present
"@
            throw $errorMessage
        }

        $Environment = $Config.Environment
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $Config.SystemKey + "---service"
        $ArtifactsBucket = $Config.SystemKey + "---artifacts-" + $Config.SystemSuffix

        # Clean up existing artifacts
        try {
            Write-LzAwsVerbose "Removing existing S3 artifacts"
            aws s3 rm s3://$ArtifactsBucket/system/ --recursive --profile $ProfileName --region $Region
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove existing S3 artifacts"
            }
        }
        catch {
            $errorMessage = @"
Error: Failed to clean up existing S3 artifacts
Function: Deploy-ServiceAws
Hints:
  - Check if you have permission to delete S3 objects
  - Verify the S3 bucket exists and is accessible
  - Ensure AWS credentials are valid
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Package SAM template
        if(Test-Path "sam.Service.packages.yaml") {
            Remove-Item "sam.Service.packages.yaml"
        }

        Write-LzAwsVerbose "Packaging SAM template"
        sam package --template-file Generated/sam.Service.g.yaml `
            --output-template-file sam.Service.packaged.yaml `
            --s3-bucket $ArtifactsBucket `
            --s3-prefix system `
            --region $Region `
            --profile $ProfileName

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: Failed to package SAM template
Function: Deploy-ServiceAws
Hints:
    - Check if the source template exists: Generated/sam.Service.g.yaml
    - Verify S3 bucket permissions
    - Ensure AWS credentials are valid
"@
            throw $errorMessage            
        }

        # Upload templates to S3
        try {
            Write-LzAwsVerbose "Uploading templates to S3"
            Set-Location Generated
            $Files = Get-ChildItem -Path . -Filter sam.*.yaml
            foreach ($File in $Files) {
                $FileName = $File.Name
                aws s3 cp $File.FullName s3://$ArtifactsBucket/system/$FileName --region $Region --profile $ProfileName
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to upload template: $FileName"
                }
            }
            Set-Location ..
        }
        catch {
            $errorMessage = @"
Error: Failed to upload templates to S3
Function: Deploy-ServiceAws
Hints:
  - Check if the Generated directory contains template files
  - Verify S3 bucket permissions
  - Ensure AWS credentials are valid
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Build parameters for stack deployment
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "EnvironmentParameter" = $Environment
            "ArtifactsBucketParameter" = $ArtifactsBucket
            "SystemSuffixParameter" = $SystemSuffix					
        }

        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: deploymentconfig.g.yaml does not exist
Function: Deploy-ServiceAws
Hints:
  - Run the generation step before deployment
  - Check if the generation process completed successfully
  - Verify the deployment configuration was generated
"@
            throw $errorMessage
        }

        try {
            $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
        }
        catch {
            $errorMessage = @"
Error: No deployment config file found
Function: Deploy-ServiceAws
Hints:
    - Run LazyMagic Generation to ensure deploymentconfig.g.yaml is generated
    - Verify the generation process included authentications
    - Ensure the deployment config format is correct
"@
            throw $errorMessage
        }

        if ($null -eq $DeploymentConfig.Authentications) {
            $errorMessage = @"
Error: No authentication configurations found in deployment config
Function: Deploy-ServiceAws
Hints:
  - Check if authentications are defined in the source config
  - Verify the generation process included authentications
  - Ensure the deployment config format is correct
"@
            throw $errorMessage
        }

        $Authentications = $DeploymentConfig.Authentications
        foreach($Authentication in $Authentications) {
            $Name = $Authentication.Name
            $AuthStackName = $Config.SystemKey + "---" + $Name
            Write-LzAwsVerbose "Processing auth stack: $AuthStackName"

            # Get auth stack outputs
            Write-LzAwsVerbose "Getting stack outputs for '$AuthStackName'"
            $AuthStackOutputDict = Get-StackOutputs $AuthStackName
            Write-LzAwsVerbose "Retrieved $($AuthStackOutputDict.Count) stack outputs"
            if ($null -eq $AuthStackOutputDict["UserPoolId"] -or $null -eq $AuthStackOutputDict["UserPoolClientId"] -or $null -eq $AuthStackOutputDict["SecurityLevel"]) {
                    $errorMessage = @"
Error: Missing required outputs from auth stack '$AuthStackName'
Function: Deploy-ServiceAws
Hints:
  - Check if the auth stack was deployed successfully
  - Verify the auth stack template includes all required outputs
  - Ensure the auth resources were created properly
"@
                throw $errorMessage
            }

            $ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputDict["UserPoolId"])
            $ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputDict["UserPoolClientId"])
            $ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputDict["IdentityPoolId"])
            $ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputDict["SecurityLevel"])
            $ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputDict["UserPoolArn"])
        }
        # Deploy the service stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict

        $result = sam deploy `
            --template-file sam.Service.packaged.yaml `
            --s3-bucket $ArtifactsBucket `
            --stack-name $StackName `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
            --parameter-overrides $Parameters `
            --region $Region `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            if ($result -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            }   else {
                $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-ServiceAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
  - Validate the parameter values
Error Details: $result
"@
                throw $errorMessage
            }
        }

        Write-Host "Successfully deployed service stack" -ForegroundColor Green

        # Update KVS with Events APIs configuration
        Write-LzAwsVerbose "Retrieving service stack outputs for Events APIs"
        try {
            $ServiceStackOutputDict = Get-StackOutputs $StackName

            # Build EventsApis KVS entry by discovering all *EventsApi outputs
            $EventsApisEntry = @{}

            # Find all stack outputs ending with "EventsApiApiKey"
            foreach ($outputKey in $ServiceStackOutputDict.Keys) {
                Write-LzAwsVerbose "stack output key: $outputKey"
                if ($outputKey -match '^(.+)EventsApiApiKey$') {
                    # Extract base name (e.g., "ConsumerEventsApiApiKey" -> "ConsumerEventsApi")
                    $apiName = $matches[1] + "EventsApi"
                    $authOutputKey = "${apiName}Auth"
                    $httpDomainKey = "${apiName}Domain"

                    # Check if corresponding *EventsApiAuth output exists
                    if ($null -ne $ServiceStackOutputDict[$authOutputKey]) {
                        $authConfig = $ServiceStackOutputDict[$authOutputKey]
                        $httpDomain = $ServiceStackOutputDict[$httpDomainKey]

                        # Prepend websocket protocol if missing
                        if (-not [string]::IsNullOrEmpty($httpDomain)) {
                            if (-not ($httpDomain -match '^wss?://')) {
                                $wsUrl = "wss://$httpDomain"
                            } else {
                                $wsUrl = $httpDomain
                            }
                        } else {
                            $wsUrl = $null
                        }

                        # Convert API name to camelCase for resource key (e.g., ConsumerEventsApi -> consumerEvents)
                        $resourceKey = $apiName -replace 'EventsApi$', 'Events'
                        $resourceKey = $resourceKey.Substring(0,1).ToLower() + $resourceKey.Substring(1)

                        $EventsApisEntry[$resourceKey] = @{
                            authConfig = $authConfig
                            wsUrl = $wsUrl
                        }
                        Write-LzAwsVerbose "Found $apiName with auth config '$authConfig': $wsUrl"
                    }
                }
            }

            # Update KVS with Events APIs if any were found
            if ($EventsApisEntry.Count -gt 0) {
                # Get KVS ARN from system stack
                $SystemStackName = $SystemKey + "---system"
                $SystemStackOutputDict = Get-StackOutputs $SystemStackName
                $KeyValueStoreArn = $SystemStackOutputDict["KeyValueStoreArn"]

                if ([string]::IsNullOrEmpty($KeyValueStoreArn)) {
                    Write-LzAwsVerbose "Warning: KeyValueStoreArn not found, skipping Events APIs KVS update"
                } else {
                    $EventsApisJson = ConvertTo-JSON $EventsApisEntry -Depth 10 -Compress
                    $KvsEntryKey = "EventsApis"

                    Write-LzAwsVerbose "Updating KVS with Events APIs configuration"
                    Update-KVSEntry $KeyValueStoreArn $KvsEntryKey $EventsApisJson
                    Write-Host "Successfully updated KVS with Events APIs configuration" -ForegroundColor Green
                }
            } else {
                Write-LzAwsVerbose "No Events APIs found in service stack outputs"
            }
        } catch {
            Write-LzAwsVerbose "Warning: Failed to update EventsApis KVS entry: $($_.Exception.Message)"
            # Don't fail deployment if KVS update fails
        }

        # Update log group retention policies for this stack using AWS CLI
        Write-LzAwsVerbose "Checking CloudWatch log groups for stack '$StackName'"
        try {
            # Query log groups that contain the stack name
            $logGroupsJson = aws logs describe-log-groups `
                --query "logGroups[?contains(logGroupName, ``$StackName``)].{name:logGroupName,retention:retentionInDays}" `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-LzAwsVerbose "Warning: Failed to query log groups: $logGroupsJson"
            } else {
                $logGroups = $logGroupsJson | ConvertFrom-Json

                if ($logGroups.Count -eq 0) {
                    Write-LzAwsVerbose "No log groups found for stack '$StackName'"
                } else {
                    Write-LzAwsVerbose "Found $($logGroups.Count) log group(s) for stack '$StackName'"
                    $UpdatedCount = 0
                    $SkippedCount = 0

                    foreach ($logGroup in $logGroups) {
                        if ($null -eq $logGroup.retention) {
                            Write-LzAwsVerbose "Setting 1-day retention for: $($logGroup.name)"
                            $result = aws logs put-retention-policy `
                                --log-group-name $logGroup.name `
                                --retention-in-days 1 `
                                --profile $ProfileName `
                                --region $Region 2>&1

                            if ($LASTEXITCODE -eq 0) {
                                $UpdatedCount++
                                Write-LzAwsVerbose "Successfully set retention policy for: $($logGroup.name)"
                            } else {
                                Write-LzAwsVerbose "Warning: Failed to set retention for $($logGroup.name): $result"
                            }
                        } else {
                            $SkippedCount++
                            Write-LzAwsVerbose "Log group already has retention: $($logGroup.name) ($($logGroup.retention) days)"
                        }
                    }

                    if ($UpdatedCount -gt 0) {
                        Write-Host "Updated retention policy for $UpdatedCount log group(s) to 1 day" -ForegroundColor Green
                    }
                    if ($SkippedCount -gt 0) {
                        Write-LzAwsVerbose "Skipped $SkippedCount log group(s) with existing retention policies"
                    }
                }
            }
        } catch {
            Write-LzAwsVerbose "Warning: Failed to update log retention policies: $($_.Exception.Message)"
            # Don't fail the deployment if log updates fail
        }
    }

    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}

