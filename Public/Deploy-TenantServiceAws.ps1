<#
.SYNOPSIS
    Deploys the per-tenant service stack (SmartStore, AppHost ECS services)
.DESCRIPTION
    Deploys or updates the tenant service stack which contains ECS services
    (SmartStore, AppHost), ALB rules, config init task, and EFS mount instance.

    Reads system stack outputs (VPC, ALBs, ECS, DNS) and tenant data stack
    outputs (EFS access points, tenant secret). Discovers ECR images automatically.
.EXAMPLE
    Deploy-TenantServiceAws
    Deploys the tenant service stack based on tenantconfig.yaml
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires system stack and tenant data stack deployed first
    - Requires Docker images pushed to ECR
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-TenantServiceAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )
    Write-LzAwsVerbose "Starting tenant service deployment"
    try {
        $SystemConfig = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            throw "System configuration is missing Config section"
        }

        $Environment = $Config.Environment
        $TenantKey = $Config.TenantKey
        $TenantSuffix = $Config.TenantSuffix

        # Get system key (needed for stack naming)
        $SystemKey = $Config.SystemKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            throw "SystemKey not found in tenantconfig. Add 'SystemKey: `"ezra`"' to your tenantconfig file."
        }

        $StackName = $SystemKey + "-" + $TenantKey + "--service"
        $ArtifactsBucket = $SystemKey + "-" + $TenantKey + "--artifacts-" + $TenantSuffix

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.tenant-service.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.tenant-service.yaml
Function: Deploy-TenantServiceAws
Hints:
  - Check if the template file exists in the Templates directory
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        # Get system stack outputs

        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName

        # Build parameters dict
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "TenantKeyParameter" = $TenantKey
            "TenantSuffixParameter" = $TenantSuffix
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

        # Get tenant data stack outputs
        $DataStackName = "$SystemKey-$TenantKey--data"
        Write-LzAwsVerbose "Getting data stack outputs from '$DataStackName'"
        try {
            $DataStackOutputDict = Get-StackOutputs $DataStackName
            if ($null -ne $DataStackOutputDict -and $DataStackOutputDict.Count -gt 0) {
                Write-Host "Found data stack '$DataStackName' with $($DataStackOutputDict.Count) outputs" -ForegroundColor Cyan
                foreach ($OutputKey in $DataStackOutputDict.Keys) {
                    $ParameterName = $OutputKey + "Parameter"
                    if (-not $ParametersDict.ContainsKey($ParameterName)) {
                        $ParametersDict[$ParameterName] = $DataStackOutputDict[$OutputKey]
                        Write-LzAwsVerbose "Added data stack output: $ParameterName"
                    }
                }
            } else {
                Write-Host "Warning: Data stack not found. Deploy it first with Deploy-TenantDataAws" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Warning: Data stack '$DataStackName' not yet deployed" -ForegroundColor Yellow
        }

        # Map system secret ARN for EFS mount instance Tailscale access
        if ($SystemStackOutputDict.ContainsKey("SystemSecretArn")) {
            $ParametersDict["SystemSecretArnParameter"] = $SystemStackOutputDict["SystemSecretArn"]
        }

        # Map DB master secret ARN for task execution role IAM permissions
        # System output is "DbMasterSecretArn" but template parameter is "DbSecretArnParameter"
        if ($SystemStackOutputDict.ContainsKey("DbMasterSecretArn")) {
            $ParametersDict["DbSecretArnParameter"] = $SystemStackOutputDict["DbMasterSecretArn"]
        }

        # Set Tailscale auth key secret name (system secret name, for UserData)
        $ParametersDict["TailscaleAuthKeySecretParameter"] = "$SystemKey/system"

        # Map TenantSecretArn from data stack
        if ($DataStackOutputDict -and $DataStackOutputDict.ContainsKey("TenantSecretArn")) {
            $ParametersDict["TenantSecretArnParameter"] = $DataStackOutputDict["TenantSecretArn"]
        }

        # Add ECS-specific config values
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            if ($EcsConfig.SmartStoreImage) {
                $ParametersDict["SmartStoreImageParameter"] = $EcsConfig.SmartStoreImage
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
            if ($EcsConfig.EnableEfsMountInstance -ne $null) {
                $ParametersDict["EnableEfsMountInstanceParameter"] = ([string]$EcsConfig.EnableEfsMountInstance).ToLower()
            }
            # Per-tenant resource isolation: listener priorities and service discovery names
            $ListenerPriorities = $EcsConfig.ListenerPriorities
            if ($null -ne $ListenerPriorities) {
                if ($ListenerPriorities.SmartStore) {
                    $ParametersDict["SmartStoreListenerPriorityParameter"] = [string]$ListenerPriorities.SmartStore
                }
                if ($ListenerPriorities.AppHost) {
                    $ParametersDict["AppHostListenerPriorityParameter"] = [string]$ListenerPriorities.AppHost
                }
            }
            if ($EcsConfig.SmartStoreServiceDiscoveryName) {
                $ParametersDict["SmartStoreServiceDiscoveryNameParameter"] = $EcsConfig.SmartStoreServiceDiscoveryName
            }
            if ($EcsConfig.AppHostServiceDiscoveryName) {
                $ParametersDict["AppHostServiceDiscoveryNameParameter"] = $EcsConfig.AppHostServiceDiscoveryName
            }
        }

        # Add SecretPrefix - constructed from SystemKey/TenantKey
        $SecretsConfig = $Config.SecretsManager
        if ($null -ne $SecretsConfig -and $SecretsConfig.SecretPrefix) {
            Write-LzAwsVerbose "Overriding config SecretPrefix '$($SecretsConfig.SecretPrefix)' with constructed value"
        }
        $ParametersDict["SecretPrefixParameter"] = "$SystemKey/$TenantKey"

        # Discover ECR images (system-scoped — images are shared across tenants)
        # ECR repos use SystemSuffix from the system config, not TenantSuffix
        $SystemSuffix = $Config.SystemSuffix
        if ([string]::IsNullOrWhiteSpace($SystemSuffix)) {
            # Tenant config doesn't have SystemSuffix — read it from system config
            Write-LzAwsVerbose "SystemSuffix not in tenant config, reading from system config"
            $sysConfig = Get-SystemConfig
            $SystemSuffix = $sysConfig.SystemConfig.SystemSuffix
        }
        if ([string]::IsNullOrWhiteSpace($SystemSuffix)) {
            throw "SystemSuffix not found in tenant or system config. ECR repo names require it (e.g., {SystemKey}-{SystemSuffix}-{env}-smartstore)."
        }
        $EcrRepoPrefix = "$SystemKey-$SystemSuffix-$Environment"
        $AccountId = aws sts get-caller-identity --query Account --output text --profile $ProfileName --region $Region

        # SmartStore ECR image (unless overridden)
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
                    throw "SmartStore image not found in ECR: $SmartStoreRepo"
                }
            } catch {
                if ($_.Exception.Message -match "not found in ECR") { throw }
                throw "Failed to check ECR for SmartStore image '$SmartStoreRepo': $($_.Exception.Message)"
            }
        }

        # AppHost ECR image
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
                throw "AppHost image not found in ECR: $AppHostRepo"
            }
        } catch {
            if ($_.Exception.Message -match "not found in ECR") { throw }
            throw "Failed to check ECR for AppHost image '$AppHostRepo': $($_.Exception.Message)"
        }

        # Upload tenant config to S3 for config init task
        try {
            # Discovery order matches Get-TenantConfig:
            # 1. tenantconfig.{systemkey}.{tenantkey}.{env}.yaml (new convention, glob for systemkey)
            # 2. tenantconfig.{tenantkey}.{env}.yaml (legacy, no systemkey)
            # 3. config.{tenantkey}.{env}.yaml (legacy prefix)
            # 4. tenantconfig.{env}.yaml (legacy single-tenant)
            # 5. systemconfig.{env}.yaml (legacy)
            # 6. systemconfig.yaml (legacy)
            $ConfigFile = $null
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.$TenantKey.$Environment.yaml")
            if ($ConfigFiles.Count -eq 1) {
                $ConfigFile = $ConfigFiles[0]
            }
            if ($null -eq $ConfigFile) {
                $ConfigFile = Find-FileUp "tenantconfig.$TenantKey.$Environment.yaml"
            }
            if ($null -eq $ConfigFile) {
                $ConfigFile = Find-FileUp "config.$TenantKey.$Environment.yaml"
            }
            if ($null -eq $ConfigFile) {
                $ConfigFile = Find-FileUp "tenantconfig.$Environment.yaml"
            }
            if ($null -eq $ConfigFile) {
                $ConfigFile = Find-FileUp "systemconfig.$Environment.yaml"
            }
            if ($null -eq $ConfigFile) {
                $ConfigFile = Find-FileUp "systemconfig.yaml"
            }

            if ($null -ne $ConfigFile) {
                $configFileName = Split-Path $ConfigFile -Leaf
                Write-LzAwsVerbose "Found config file: $configFileName"
                # Keep S3 key as system/systemconfig.yaml for backward compat with ECS tasks
                $S3ConfigKey = "system/systemconfig.yaml"
                Write-LzAwsVerbose "Uploading $ConfigFile to s3://$ArtifactsBucket/$S3ConfigKey"
                aws s3 cp $ConfigFile "s3://$ArtifactsBucket/$S3ConfigKey" --region $Region --profile $ProfileName
                if ($LASTEXITCODE -eq 0) {
                    $PreSignedUrl = aws s3 presign "s3://$ArtifactsBucket/$S3ConfigKey" --expires-in 3600 --region $Region --profile $ProfileName
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($PreSignedUrl)) {
                        $ParametersDict["TenantConfigUrlParameter"] = $PreSignedUrl
                        Write-LzAwsVerbose "Generated pre-signed URL for config file"
                    }
                }
            } else {
                Write-LzAwsVerbose "Warning: No config file found for S3 upload"
            }
        } catch {
            Write-LzAwsVerbose "Warning: Failed to upload config file: $($_.Exception.Message)"
        }

        # Filter to only parameters the template expects
        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.tenant-service.yaml"
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

        # Deploy
        Write-Host "Deploying stack $StackName using profile $ProfileName" -ForegroundColor Cyan
        $result = sam deploy `
            --template-file Templates/sam.tenant-service.yaml `
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
Function: Deploy-TenantServiceAws
Error Details: $resultString
"@
                throw $errorMessage
            }
        }

        Write-Host "Successfully deployed tenant service stack" -ForegroundColor Green

        # Run config init task
        if ($null -ne $EcsConfig) {
            Write-LzAwsVerbose "Running ECS config initialization task"
            $ServiceStackOutputs = Get-StackOutputs $StackName

            $clusterArn = $SystemStackOutputDict["EcsClusterArn"]
            $subnet1 = $SystemStackOutputDict["PrivateSubnet1Id"]
            $subnet2 = $SystemStackOutputDict["PrivateSubnet2Id"]
            $securityGroup = $SystemStackOutputDict["EcsPrivateSecurityGroupId"]

            if (-not [string]::IsNullOrEmpty($clusterArn) -and
                -not [string]::IsNullOrEmpty($subnet1) -and
                -not [string]::IsNullOrEmpty($securityGroup)) {

                $taskFamily = "$SystemKey-$TenantKey-init"

                $initResult = Invoke-EcsInitTask `
                    -TaskFamily $taskFamily `
                    -ClusterArn $clusterArn `
                    -Subnets "$subnet1,$subnet2" `
                    -SecurityGroup $securityGroup `
                    -Description "config initialization"

                if (-not $initResult) {
                    Write-Host "Warning: Config initialization task failed." -ForegroundColor Yellow
                }
            } else {
                Write-LzAwsVerbose "Skipping config init: required stack outputs not found"
            }
        }

        return $true
    }

    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
