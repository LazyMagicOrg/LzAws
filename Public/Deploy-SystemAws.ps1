<#
.SYNOPSIS
    Deploys the shared system infrastructure stack
.DESCRIPTION
    Deploys or updates the system stack which contains shared infrastructure:
    VPC, ALBs, ECS cluster, shared RDS PostgreSQL, EFS, Keycloak, Tailscale VPN,
    Route 53, ACM certificate, and WebFinger Lambda.

    Auto-detects existing retained resources (RDS, EFS, security groups, secrets,
    DB subnet group) from previous deployments and reuses them.
.PARAMETER SystemKey
    Optional. The system identifier used for config file discovery.
    If omitted, auto-detected from the single systemconfig.*.{env}.yaml file.
.EXAMPLE
    Deploy-SystemAws
    Deploys the system infrastructure (auto-detects systemconfig.ezra.dev.yaml)
.EXAMPLE
    Deploy-SystemAws -SystemKey "ezra"
    Deploys using systemconfig.ezra.dev.yaml explicitly
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
    - This stack must be deployed before any system stacks
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-SystemAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$SystemKey
    )

    Write-LzAwsVerbose "Deploy-SystemAws"

    try {
        $null = Get-SystemConfig -SystemKey $SystemKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Account = $script:Account
        $SystemConfig = $script:SystemConfig
        $SystemKey = $SystemConfig.SystemKey
        $SystemSuffix = $SystemConfig.SystemSuffix

        # Create S3 artifacts bucket
        Write-LzAwsVerbose "Ensuring S3 artifacts bucket exists"
        $ArtifactsBucket = $SystemKey + "---artifacts-" + $SystemSuffix
        New-LzAwsS3Bucket -BucketName $ArtifactsBucket -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName

        Write-LzAwsVerbose "Deploying system stack"
        $StackName = $SystemKey + "---system"

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.system.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.system.yaml
Function: Deploy-SystemAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        # Resolve SystemDomain (fall back to DefaultTenant for backward compat)
        $SystemDomain = $SystemConfig.SystemDomain
        if ([string]::IsNullOrWhiteSpace($SystemDomain)) {
            $SystemDomain = $SystemConfig.DefaultTenant
            if (-not [string]::IsNullOrWhiteSpace($SystemDomain)) {
                Write-LzAwsVerbose "Using DefaultTenant as SystemDomain (add SystemDomain to config)"
            }
        }
        if ([string]::IsNullOrWhiteSpace($SystemDomain)) {
            throw "SystemDomain (or DefaultTenant) not specified in config file"
        }

        # Build parameters dict from systemconfig
        $ParametersDict = @{
            "SystemKeyParameter"    = $SystemKey
            "SystemSuffixParameter" = $SystemSuffix
            "EnvironmentParameter"    = $SystemConfig.Environment
            "SystemDomainParameter" = $SystemDomain
        }

        # Resolve the public hosted zone ID
        if (-not [string]::IsNullOrWhiteSpace($SystemConfig.PublicHostedZoneId)) {
            $PublicHostedZoneId = $SystemConfig.PublicHostedZoneId
            Write-LzAwsVerbose "Using PublicHostedZoneId from config: $PublicHostedZoneId"
        } else {
            $PublicHostedZoneId = Resolve-PublicHostedZoneId -DomainName $SystemDomain
        }
        $ParametersDict["PublicHostedZoneIdParameter"] = $PublicHostedZoneId

        # Database parameters
        $DbConfig = $SystemConfig.Database
        if ($null -ne $DbConfig) {
            if ($DbConfig.InstanceClass) {
                $ParametersDict["DbInstanceClassParameter"] = $DbConfig.InstanceClass
            }
            if ($DbConfig.AllocatedStorage) {
                $ParametersDict["DbAllocatedStorageParameter"] = [string]$DbConfig.AllocatedStorage
            }
            if ($DbConfig.MultiAZ -ne $null) {
                $ParametersDict["DbMultiAZParameter"] = "$($DbConfig.MultiAZ)".ToLower()
            }
            if ($DbConfig.MasterUsername) {
                $ParametersDict["DbMasterUsername"] = $DbConfig.MasterUsername
            }
        }

        # Keycloak parameters
        $KcConfig = $SystemConfig.Keycloak
        if ($null -ne $KcConfig) {
            if ($KcConfig.ImageTag) {
                $ParametersDict["KeycloakImageTagParameter"] = $KcConfig.ImageTag
            }
            if ($KcConfig.Cpu) {
                $ParametersDict["KeycloakCpuParameter"] = [string]$KcConfig.Cpu
            }
            if ($KcConfig.Memory) {
                $ParametersDict["KeycloakMemoryParameter"] = [string]$KcConfig.Memory
            }
        }

        # Tailscale parameters
        $TsConfig = $SystemConfig.Tailscale
        if ($null -ne $TsConfig) {
            if ($TsConfig.InstanceType) {
                $ParametersDict["TailscaleInstanceTypeParameter"] = $TsConfig.InstanceType
            }
            if ($TsConfig.DesiredCapacity -ne $null) {
                $ParametersDict["TailscaleDesiredCapacityParameter"] = [string]$TsConfig.DesiredCapacity
            }
        }

        # Log retention
        if ($SystemConfig.LogRetentionDays) {
            $ParametersDict["LogRetentionDaysParameter"] = [string]$SystemConfig.LogRetentionDays
        }

        # =====================================================================
        # Detect existing retained resources
        # =====================================================================

        # Check for existing retained RDS instance
        $DbInstanceId = "$SystemKey-db"
        Write-LzAwsVerbose "Checking for existing RDS instance: $DbInstanceId"
        $dbJson = aws rds describe-db-instances `
            --db-instance-identifier $DbInstanceId `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $dbInfo = ($dbJson | ConvertFrom-Json).DBInstances[0]
            $ExistingEndpoint = $dbInfo.Endpoint.Address
            $ExistingSecretArn = $dbInfo.MasterUserSecret.SecretArn
            $ExistingInstanceId = $dbInfo.DBInstanceIdentifier

            if (-not [string]::IsNullOrWhiteSpace($ExistingEndpoint)) {
                Write-Host "Found existing RDS instance: $DbInstanceId ($ExistingEndpoint)" -ForegroundColor Cyan
                $ParametersDict["ExistingDbEndpointParameter"] = $ExistingEndpoint
                $ParametersDict["ExistingDbSecretArnParameter"] = if ([string]::IsNullOrWhiteSpace($ExistingSecretArn)) { '' } else { $ExistingSecretArn }
                $ParametersDict["ExistingDbInstanceIdParameter"] = $ExistingInstanceId
            } else {
                $ParametersDict["ExistingDbEndpointParameter"] = ''
                $ParametersDict["ExistingDbSecretArnParameter"] = ''
                $ParametersDict["ExistingDbInstanceIdParameter"] = ''
            }
        } else {
            Write-LzAwsVerbose "No existing RDS instance found — will create new instance"
            $ParametersDict["ExistingDbEndpointParameter"] = ''
            $ParametersDict["ExistingDbSecretArnParameter"] = ''
            $ParametersDict["ExistingDbInstanceIdParameter"] = ''
        }

        # Detect retained security groups
        $RdsSgName = "$SystemKey-rds-sg"
        Write-LzAwsVerbose "Checking for existing security group: $RdsSgName"
        $rdsSgResult = aws ec2 describe-security-groups `
            --filters "Name=group-name,Values=$RdsSgName" `
            --query "SecurityGroups[0].GroupId" `
            --profile $ProfileName `
            --region $Region `
            --output text 2>&1
        if ($LASTEXITCODE -eq 0 -and $rdsSgResult -ne 'None') {
            Write-Host "Found existing security group: $RdsSgName ($rdsSgResult)" -ForegroundColor Cyan
            $ParametersDict["ExistingRdsSecurityGroupIdParameter"] = $rdsSgResult
        } else {
            $ParametersDict["ExistingRdsSecurityGroupIdParameter"] = ''
        }

        $EfsSgName = "$SystemKey-efs-sg"
        Write-LzAwsVerbose "Checking for existing security group: $EfsSgName"
        $efsSgResult = aws ec2 describe-security-groups `
            --filters "Name=group-name,Values=$EfsSgName" `
            --query "SecurityGroups[0].GroupId" `
            --profile $ProfileName `
            --region $Region `
            --output text 2>&1
        if ($LASTEXITCODE -eq 0 -and $efsSgResult -ne 'None') {
            Write-Host "Found existing security group: $EfsSgName ($efsSgResult)" -ForegroundColor Cyan
            $ParametersDict["ExistingEfsSecurityGroupIdParameter"] = $efsSgResult
        } else {
            $ParametersDict["ExistingEfsSecurityGroupIdParameter"] = ''
        }

        # Detect retained DB subnet group
        $SubnetGroupName = "$SystemKey-db-subnet-group"
        Write-LzAwsVerbose "Checking for existing DB subnet group: $SubnetGroupName"
        $subnetGroupResult = aws rds describe-db-subnet-groups `
            --db-subnet-group-name $SubnetGroupName `
            --profile $ProfileName `
            --region $Region `
            --output text 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Found existing DB subnet group: $SubnetGroupName" -ForegroundColor Cyan
            $ParametersDict["ExistingDbSubnetGroupNameParameter"] = $SubnetGroupName
        } else {
            $ParametersDict["ExistingDbSubnetGroupNameParameter"] = ''
        }

        # Detect retained EFS filesystem
        $EfsTagName = "$SystemKey-efs"
        Write-LzAwsVerbose "Checking for existing EFS filesystem with Name tag: $EfsTagName"
        try {
            $efsJson = aws efs describe-file-systems `
                --query "FileSystems[?Tags[?Key=='Name' && Value=='$EfsTagName'] && LifeCycleState=='available'].FileSystemId" `
                --output json `
                --profile $ProfileName `
                --region $Region 2>&1

            if ($LASTEXITCODE -eq 0) {
                $efsIds = @($efsJson | ConvertFrom-Json)
                if ($efsIds.Count -gt 0) {
                    $ExistingEfsId = $efsIds[0]
                    $ParametersDict["ExistingEfsFileSystemIdParameter"] = $ExistingEfsId
                    Write-Host "Found existing EFS filesystem: $ExistingEfsId" -ForegroundColor Cyan
                } else {
                    $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
                }
            } else {
                $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
            }
        } catch {
            $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
        }

        # Detect retained system secret
        $SystemSecretName = "$SystemKey/system"
        Write-LzAwsVerbose "Checking for existing secret: $SystemSecretName"
        $secretJson = aws secretsmanager describe-secret `
            --secret-id $SystemSecretName `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $secretArn = ($secretJson | ConvertFrom-Json).ARN
            if (-not [string]::IsNullOrWhiteSpace($secretArn)) {
                Write-Host "Found existing secret: $SystemSecretName" -ForegroundColor Cyan
                $ParametersDict["ExistingSystemSecretArnParameter"] = $secretArn
            }
        } else {
            Write-LzAwsVerbose "No existing system secret found — will create new secret"
            $ParametersDict["ExistingSystemSecretArnParameter"] = ''
        }

        # =====================================================================
        # Filter parameters and deploy
        # =====================================================================

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.system.yaml"
        $FilteredParametersDict = @{}
        foreach ($Key in $ParametersDict.Keys) {
            if ($TemplateParameters -contains $Key) {
                $FilteredParametersDict[$Key] = $ParametersDict[$Key]
                Write-LzAwsVerbose "Including parameter: $Key"
            } else {
                Write-LzAwsVerbose "Skipping parameter not in template: $Key"
            }
        }

        # On fresh database creation, deploy with Keycloak at 0 tasks first.
        # The keycloak database doesn't exist yet, so Keycloak would crash.
        # After deploy, we run the init task to create the DB, then scale up.
        # On subsequent deploys, explicitly set desired count to 1 (or config value)
        # to prevent SAM from reusing the previous parameter value of 0.
        $freshDatabase = [string]::IsNullOrWhiteSpace($ParametersDict["ExistingDbEndpointParameter"])
        if ($freshDatabase) {
            Write-Host "Fresh database — deploying with Keycloak disabled (will enable after DB init)" -ForegroundColor Cyan
            $FilteredParametersDict["KeycloakDesiredCountParameter"] = "0"
        } else {
            $kcDesired = if ($SystemConfig.ECS.KeycloakDesiredCount) { [string]$SystemConfig.ECS.KeycloakDesiredCount } else { "1" }
            $FilteredParametersDict["KeycloakDesiredCountParameter"] = $kcDesired
        }

        # Auto-detect admin blocking: disable on first deploy (Tailscale VPN not yet
        # available), enable on updates. Config override takes precedence.
        $stackExists = $false
        $null = aws cloudformation describe-stacks --stack-name $StackName --profile $ProfileName --region $Region 2>&1
        if ($LASTEXITCODE -eq 0) { $stackExists = $true }

        if ($SystemConfig.ECS.EnableAdminBlocking -ne $null) {
            # Explicit config override
            $FilteredParametersDict["EnableAdminBlockingParameter"] = ([string]$SystemConfig.ECS.EnableAdminBlocking).ToLower()
            Write-LzAwsVerbose "Admin blocking set from config: $($FilteredParametersDict['EnableAdminBlockingParameter'])"
        } elseif (-not $stackExists) {
            # First deploy — no VPN yet, disable blocking for initial Keycloak setup
            $FilteredParametersDict["EnableAdminBlockingParameter"] = "false"
            Write-Host "First deploy — admin blocking disabled (use Set-KeycloakAdminBlocking to enable after VPN setup)" -ForegroundColor Cyan
        }

        $Parameters = ConvertTo-ParameterOverrides -parametersDict $FilteredParametersDict

        # Deploy the system stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $result = sam deploy `
            --template-file Templates/sam.system.yaml `
            --s3-bucket $ArtifactsBucket `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM `
            --profile $ProfileName `
            --region $Region 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $resultString = $result | Out-String

            if ($resultString -match "No changes to deploy") {
                Write-LzAwsVerbose "No changes to deploy. Stack is up to date."
            } else {
                $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-SystemAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
  - Validate the parameter values
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $resultString
"@
                throw $errorMessage
            }
        }

        Write-Host "Deploy-SystemAws stack deployed successfully" -ForegroundColor Green

        # Run system DB init task and scale up Keycloak (only on fresh database creation)
        if ($freshDatabase) {
            Write-LzAwsVerbose "Running system DB initialization task"
            $SystemStackOutputs = Get-StackOutputs $StackName

            $clusterArn = $SystemStackOutputs["EcsClusterArn"]
            $subnet1 = $SystemStackOutputs["PrivateSubnet1Id"]
            $subnet2 = $SystemStackOutputs["PrivateSubnet2Id"]
            $securityGroup = $SystemStackOutputs["EcsPrivateSecurityGroupId"]

            if (-not [string]::IsNullOrEmpty($clusterArn) -and
                -not [string]::IsNullOrEmpty($subnet1) -and
                -not [string]::IsNullOrEmpty($securityGroup)) {

                $initResult = Invoke-EcsInitTask `
                    -TaskFamily "$SystemKey-system-init" `
                    -ClusterArn $clusterArn `
                    -Subnets "$subnet1,$subnet2" `
                    -SecurityGroup $securityGroup `
                    -Description "system database initialization"

                if (-not $initResult) {
                    Write-Host "Warning: System DB initialization task failed. You may need to run it manually." -ForegroundColor Yellow
                    Write-Host "After fixing, scale Keycloak up with: aws ecs update-service --cluster $clusterArn --service $SystemKey-keycloak --desired-count 1 --profile $ProfileName --region $Region" -ForegroundColor Yellow
                } else {
                    # DB init succeeded — now scale Keycloak up
                    Write-Host "DB initialized. Starting Keycloak..." -ForegroundColor Cyan
                    $null = aws ecs update-service `
                        --cluster $clusterArn `
                        --service "$SystemKey-keycloak" `
                        --desired-count 1 `
                        --profile $ProfileName `
                        --region $Region 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Keycloak service scaled to 1" -ForegroundColor Green
                    } else {
                        Write-Host "Warning: Failed to scale Keycloak. Run manually: aws ecs update-service --cluster $clusterArn --service $SystemKey-keycloak --desired-count 1" -ForegroundColor Yellow
                    }
                }
            } else {
                Write-LzAwsVerbose "Skipping system DB init: required stack outputs not found"
            }
        } else {
            Write-LzAwsVerbose "Skipping system DB init — using existing database"
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-SystemAws completed"
    return $true
}
