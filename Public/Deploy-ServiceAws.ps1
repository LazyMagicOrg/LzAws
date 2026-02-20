<#
.SYNOPSIS
    Deploys service infrastructure and resources to AWS
.DESCRIPTION
    Deploys or updates service infrastructure in AWS using CloudFormation/SAM templates.
    Supports two modes:
    1. ECS mode: If Templates/sam.service.yaml exists (and Generated/sam.Service.g.yaml
       does not), deploys the ECS service template directly using system stack outputs.
       Skips packaging, S3 upload, and auth stack iteration.
    2. Generated mode: Falls back to the standard LazyMagic workflow using
       Generated/sam.Service.g.yaml with sam package, S3 upload, and
       deploymentconfig.g.yaml auth stack iteration.
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

        # =================================================================
        # ECS TEMPLATES PATH: Check for Templates/sam.service.yaml FIRST
        # When Templates/sam.service.yaml exists, always use the ECS
        # deployment path (even if Generated/sam.Service.g.yaml also exists).
        # This skips packaging, S3 upload, and auth stack iteration.
        # =================================================================
        $UseEcsTemplate = (Test-Path -Path "Templates/sam.service.yaml" -PathType Leaf)

        if ($UseEcsTemplate) {
            Write-LzAwsVerbose "Using Templates/sam.service.yaml (ECS deployment path)"

            # Get system stack outputs
            $SystemStackName = $SystemKey + "---system"
            Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
            $SystemStackOutputDict = Get-StackOutputs $SystemStackName

            # Build parameters from system stack outputs + config
            $ParametersDict = @{
                "SystemKeyParameter" = $SystemKey
                "SystemSuffixParameter" = $SystemSuffix
                "EnvironmentParameter" = $Environment
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
                # SmartStoreImage is optional - if set, overrides ECR auto-discovery
                if ($EcsConfig.SmartStoreImage) {
                    $ParametersDict["SmartStoreImageParameter"] = $EcsConfig.SmartStoreImage
                    Write-LzAwsVerbose "SmartStore image overridden from config: $($EcsConfig.SmartStoreImage)"
                }
                if ($EcsConfig.SmartStoreCpu) {
                    $ParametersDict["SmartStoreCpuParameter"] = [string]$EcsConfig.SmartStoreCpu
                }
                if ($EcsConfig.SmartStoreMemory) {
                    $ParametersDict["SmartStoreMemoryParameter"] = [string]$EcsConfig.SmartStoreMemory
                }
                if ($EcsConfig.AppHostCpu) {
                    $ParametersDict["AppHostCpuParameter"] = [string]$EcsConfig.AppHostCpu
                }
                if ($EcsConfig.AppHostMemory) {
                    $ParametersDict["AppHostMemoryParameter"] = [string]$EcsConfig.AppHostMemory
                }
                if ($EcsConfig.ServiceDesiredCount -ne $null) {
                    $ParametersDict["ServiceDesiredCountParameter"] = [string]$EcsConfig.ServiceDesiredCount
                }
                if ($EcsConfig.LogRetentionDays) {
                    $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
                }
                if ($EcsConfig.TailscaleAuthKeySecret) {
                    $ParametersDict["TailscaleAuthKeySecretParameter"] = $EcsConfig.TailscaleAuthKeySecret
                }
                if ($EcsConfig.TailscaleInstanceType) {
                    $ParametersDict["TailscaleInstanceTypeParameter"] = $EcsConfig.TailscaleInstanceType
                }
                if ($EcsConfig.TailscaleDesiredCapacity -ne $null) {
                    $ParametersDict["TailscaleDesiredCapacityParameter"] = [string]$EcsConfig.TailscaleDesiredCapacity
                }
                if ($EcsConfig.EnableEfsMountInstance -ne $null) {
                    $ParametersDict["EnableEfsMountInstanceParameter"] = ([string]$EcsConfig.EnableEfsMountInstance).ToLower()
                }
            }

            # Add SecretPrefix from config
            $SecretsConfig = $Config.SecretsManager
            if ($null -ne $SecretsConfig -and $SecretsConfig.SecretPrefix) {
                $ParametersDict["SecretPrefixParameter"] = $SecretsConfig.SecretPrefix
            }

            # Detect retained EFS filesystem (DeletionPolicy: Retain)
            # If the service stack was deleted, the EFS filesystem survives with its
            # Name tag. On re-deploy, we find it by tag and reuse it.
            $EfsTagName = "$SystemKey-efs"
            Write-LzAwsVerbose "Checking for existing EFS filesystem with Name tag: $EfsTagName"
            try {
                $efsJson = aws efs describe-file-systems `
                    --query "FileSystems[?Tags[?Key=='Name' && Value=='$EfsTagName'] && LifeCycleState=='available'].FileSystemId" `
                    --output json `
                    --profile $ProfileName `
                    --region $Region 2>&1

                if ($LASTEXITCODE -eq 0) {
                    $efsIds = ($efsJson | ConvertFrom-Json)
                    if ($efsIds.Count -gt 0) {
                        $ExistingEfsId = $efsIds[0]
                        $ParametersDict["ExistingEfsFileSystemIdParameter"] = $ExistingEfsId
                        Write-Host "Found existing EFS filesystem: $ExistingEfsId (reusing retained filesystem)" -ForegroundColor Cyan
                    } else {
                        Write-LzAwsVerbose "No existing EFS filesystem found — will create new"
                    }
                } else {
                    Write-LzAwsVerbose "Warning: Failed to query EFS filesystems: $efsJson"
                }
            } catch {
                Write-LzAwsVerbose "Warning: Failed to check for existing EFS: $($_.Exception.Message)"
            }

            # Discover ECR images
            # Repo naming convention: {SystemKey}-{SystemSuffix}-{Environment}-{service}
            $EcrRepoPrefix = "$SystemKey-$SystemSuffix-$Environment"
            $AccountId = aws sts get-caller-identity --query Account --output text --profile $ProfileName --region $Region

            # Discover SmartStore ECR image (unless overridden in config)
            if (-not $ParametersDict.ContainsKey("SmartStoreImageParameter")) {
                $SmartStoreRepo = "$EcrRepoPrefix-smartstore"
                Write-LzAwsVerbose "Checking ECR for SmartStore image: $SmartStoreRepo"
                try {
                    $ecrTag = aws ecr describe-images `
                        --repository-name $SmartStoreRepo `
                        --query 'imageDetails | sort_by(@, &imagePushedAt) | [-1].imageTags[0]' `
                        --output text `
                        --region $Region `
                        --profile $ProfileName 2>&1

                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ecrTag) -and $ecrTag -ne "None") {
                        $SmartStoreImage = "$AccountId.dkr.ecr.$Region.amazonaws.com/${SmartStoreRepo}:${ecrTag}"
                        $ParametersDict["SmartStoreImageParameter"] = $SmartStoreImage
                        Write-LzAwsVerbose "Using SmartStore image: $SmartStoreImage"
                    } else {
                        throw "SmartStore image not found in ECR: $SmartStoreRepo. Ensure the image is pushed to ECR."
                    }
                } catch {
                    if ($_.Exception.Message -match "not found in ECR") { throw }
                    throw "Failed to check ECR for SmartStore image '$SmartStoreRepo': $($_.Exception.Message)"
                }
            }

            # Discover AppHost ECR image
            $AppHostRepo = "$EcrRepoPrefix-apphost"
            Write-LzAwsVerbose "Checking ECR for AppHost image: $AppHostRepo"
            try {
                $ecrTag = aws ecr describe-images `
                    --repository-name $AppHostRepo `
                    --query 'imageDetails | sort_by(@, &imagePushedAt) | [-1].imageTags[0]' `
                    --output text `
                    --region $Region `
                    --profile $ProfileName 2>&1

                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ecrTag) -and $ecrTag -ne "None") {
                    $AppHostImage = "$AccountId.dkr.ecr.$Region.amazonaws.com/${AppHostRepo}:${ecrTag}"
                    $ParametersDict["AppHostImageParameter"] = $AppHostImage
                    Write-LzAwsVerbose "Using AppHost image: $AppHostImage"
                } else {
                    throw "AppHost image not found in ECR: $AppHostRepo. Ensure the image is pushed to ECR."
                }
            } catch {
                if ($_.Exception.Message -match "not found in ECR") { throw }
                throw "Failed to check ECR for AppHost image '$AppHostRepo': $($_.Exception.Message)"
            }

            # Upload systemconfig to S3 and generate pre-signed URL for config init task.
            # Uses the resolved Environment to find systemconfig.{env}.yaml first,
            # falling back to systemconfig.yaml. Uploads as systemconfig.yaml (fixed
            # name expected by the init container on EFS).
            try {
                $SystemConfigFile = Find-FileUp "systemconfig.$Environment.yaml"
                if ($null -eq $SystemConfigFile) {
                    $SystemConfigFile = Find-FileUp "systemconfig.yaml"
                }

                if ($null -ne $SystemConfigFile) {
                    $configFileName = Split-Path $SystemConfigFile -Leaf
                    Write-LzAwsVerbose "Found config file: $configFileName"
                    $S3ConfigKey = "system/systemconfig.yaml"
                    Write-LzAwsVerbose "Uploading $SystemConfigFile to s3://$ArtifactsBucket/$S3ConfigKey"
                    aws s3 cp $SystemConfigFile "s3://$ArtifactsBucket/$S3ConfigKey" --region $Region --profile $ProfileName
                    if ($LASTEXITCODE -eq 0) {
                        $PreSignedUrl = aws s3 presign "s3://$ArtifactsBucket/$S3ConfigKey" --expires-in 3600 --region $Region --profile $ProfileName
                        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($PreSignedUrl)) {
                            $ParametersDict["SystemConfigUrlParameter"] = $PreSignedUrl
                            Write-LzAwsVerbose "Generated pre-signed URL for systemconfig.yaml"
                        }
                    }
                } else {
                    Write-LzAwsVerbose "Warning: No systemconfig file found for S3 upload"
                }
            } catch {
                Write-LzAwsVerbose "Warning: Failed to upload systemconfig.yaml: $($_.Exception.Message)"
            }

            # Filter to only parameters the template expects
            $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.service.yaml"
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

            # Deploy directly (no sam package needed for ECS template)
            Write-Host "Deploying stack $StackName using profile $ProfileName" -ForegroundColor Cyan
            $result = sam deploy `
                --template-file Templates/sam.service.yaml `
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
Error: SAM deployment failed
Function: Deploy-ServiceAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
  - Validate the parameter values
Error Details: $resultString
"@
                    throw $errorMessage
                }
            }

            Write-Host "Successfully deployed service stack (ECS)" -ForegroundColor Green

            # Run config init task for ECS deployments
            if ($null -ne $EcsConfig) {
                Write-LzAwsVerbose "Running ECS config initialization task"
                $ServiceStackOutputs = Get-StackOutputs $StackName

                $clusterArn = $SystemStackOutputDict["EcsClusterArn"]
                $subnet1 = $SystemStackOutputDict["PrivateSubnet1Id"]
                $subnet2 = $SystemStackOutputDict["PrivateSubnet2Id"]
                $securityGroup = $SystemStackOutputDict["EcsPrivateSecurityGroupId"]
                $initTaskArn = $ServiceStackOutputs["InitTaskDefinitionArn"]

                if (-not [string]::IsNullOrEmpty($clusterArn) -and
                    -not [string]::IsNullOrEmpty($subnet1) -and
                    -not [string]::IsNullOrEmpty($securityGroup) -and
                    -not [string]::IsNullOrEmpty($initTaskArn)) {

                    # Extract task family from ARN (last segment before :revision)
                    $taskFamily = "$SystemKey-init"

                    $initResult = Invoke-EcsInitTask `
                        -TaskFamily $taskFamily `
                        -ClusterArn $clusterArn `
                        -Subnets "$subnet1,$subnet2" `
                        -SecurityGroup $securityGroup `
                        -Description "config initialization"

                    if (-not $initResult) {
                        Write-Host "Warning: Config initialization task failed. You may need to run it manually." -ForegroundColor Yellow
                    }
                } else {
                    Write-LzAwsVerbose "Skipping config init: required stack outputs not found"
                }
            }

            return $true
        }

        # =================================================================
        # GENERATED TEMPLATE PATH: Original behavior
        # =================================================================
        Write-LzAwsVerbose "Using Generated/sam.Service.g.yaml (standard deployment path)"

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

        # Upload ec2-setup folder as tar.gz if it exists
        if (Test-Path -Path "./ec2-setup" -PathType Container) {
            try {
                Write-LzAwsVerbose "Creating ec2-setup.tar.gz from ec2-setup folder"
                $Ec2SetupTarGz = "./ec2-setup.tar.gz"
                if (Test-Path $Ec2SetupTarGz) {
                    Remove-Item $Ec2SetupTarGz -Force
                }
                tar -czf $Ec2SetupTarGz -C ./ec2-setup .
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create ec2-setup.tar.gz"
                }

                Write-LzAwsVerbose "Uploading ec2-setup.tar.gz to S3"
                aws s3 cp $Ec2SetupTarGz s3://$ArtifactsBucket/ec2-setup.tar.gz --region $Region --profile $ProfileName
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to upload ec2-setup.tar.gz"
                }

                # Clean up local tar.gz file
                Remove-Item $Ec2SetupTarGz -Force
                Write-Host "Successfully uploaded ec2-setup.tar.gz to S3" -ForegroundColor Green
            }
            catch {
                $errorMessage = @"
Error: Failed to upload ec2-setup.tar.gz to S3
Function: Deploy-ServiceAws
Hints:
  - Check if you have permission to upload to S3
  - Verify the S3 bucket exists and is accessible
  - Ensure the ec2-setup folder contains valid files
  - Ensure tar is available on the system
  - Ensure AWS credentials are valid
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
        }

        # Build parameters for stack deployment
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "EnvironmentParameter" = $Environment
            "ArtifactsBucketParameter" = $ArtifactsBucket
            "SystemSuffixParameter" = $SystemSuffix
        }

        if(Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf) {
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
        }

        # Get system stack outputs and add to parameters
        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName
        Write-LzAwsVerbose "Retrieved $($SystemStackOutputDict.Count) outputs from system stack"
        foreach ($OutputKey in $SystemStackOutputDict.Keys) {
            $ParameterName = $OutputKey + "Parameter"
            if (-not $ParametersDict.ContainsKey($ParameterName)) {
                $ParametersDict.Add($ParameterName, $SystemStackOutputDict[$OutputKey])
                Write-LzAwsVerbose "Added system stack output: $ParameterName"
            }
        }

        # Get template parameters and filter to only include valid parameters
        Write-LzAwsVerbose "Reading template parameters from sam.Service.packaged.yaml"
        $TemplateParameters = Get-TemplateParameters -TemplatePath "sam.Service.packaged.yaml"
        Write-LzAwsVerbose "Template expects $($TemplateParameters.Count) parameters"

        # Filter ParametersDict to only include parameters that exist in the template
        $FilteredParametersDict = @{}
        foreach ($Key in $ParametersDict.Keys) {
            if ($TemplateParameters -contains $Key) {
                $FilteredParametersDict[$Key] = $ParametersDict[$Key]
                Write-LzAwsVerbose "Including parameter: $Key"
            } else {
                Write-LzAwsVerbose "Skipping parameter not in template: $Key"
            }
        }

        # Check for missing required parameters (parameters in template without defaults)
        foreach ($TemplateParam in $TemplateParameters) {
            if (-not $FilteredParametersDict.ContainsKey($TemplateParam)) {
                Write-LzAwsVerbose "Warning: Template parameter '$TemplateParam' not provided (may use default)"
            }
        }

        # Deploy the service stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

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
