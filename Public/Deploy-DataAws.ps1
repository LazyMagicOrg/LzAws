<#
.SYNOPSIS
    Deploys the persistent data stack (RDS, EFS, secrets)
.DESCRIPTION
    Deploys or updates the data stack which contains long-lived, stateful resources:
    RDS PostgreSQL database, EFS filesystem, Secrets Manager secrets, SES email
    identity, and the DB initialization task. This stack is deployed after the
    system stack and should be torn down last (or never) to preserve data across
    system/service stack rebuilds.

    Auto-detects existing retained resources (RDS instances, EFS filesystems,
    secrets) from previous deployments and reuses them.
.PARAMETER DbSnapshotIdentifier
    Optional. RDS snapshot identifier to restore from. When provided, the database
    is created from this snapshot instead of as an empty instance. Use the snapshot
    identifier (not the ARN) for manual snapshots, or the ARN for automated/shared
    snapshots. Ignored if an existing retained RDS instance is detected.
.EXAMPLE
    Deploy-DataAws
    Deploys the data stack based on configuration in systemconfig.yaml
.EXAMPLE
    Deploy-DataAws -DbSnapshotIdentifier "my-snapshot-id"
    Deploys the data stack, restoring the RDS database from the specified snapshot
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires the system stack to be deployed first (needs VPC, subnets, ECS cluster)
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-DataAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$DbSnapshotIdentifier = ''
    )

    Write-LzAwsVerbose "Deploy-DataAws"

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        Write-LzAwsVerbose "Deploying data stack"
        $StackName = $SystemKey + "---data"
        $ArtifactsBucket = $SystemKey + "---artifacts-" + $SystemSuffix

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.data.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.data.yaml
Function: Deploy-DataAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        }

        # Get system stack outputs (VPC, subnets, ECS cluster, security groups)
        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName

        if ($null -eq $SystemStackOutputDict -or $SystemStackOutputDict.Count -eq 0) {
            $errorMessage = @"
Error: System stack '$SystemStackName' not found or has no outputs
Function: Deploy-DataAws
Hints:
  - Deploy the system stack first: Deploy-SystemAws
  - Verify the system stack name is correct
  - Check if the system stack deployed successfully
"@
            throw $errorMessage
        }

        # Build parameters dict
        $ParametersDict = @{
            "SystemKeyParameter"    = $SystemKey
            "EnvironmentParameter"  = $Config.Environment
            "DomainNameParameter"   = $Config.DefaultTenant
        }

        # Add system stack outputs as parameters
        foreach ($OutputKey in $SystemStackOutputDict.Keys) {
            $ParameterName = $OutputKey + "Parameter"
            if (-not $ParametersDict.ContainsKey($ParameterName)) {
                $ParametersDict[$ParameterName] = $SystemStackOutputDict[$OutputKey]
                Write-LzAwsVerbose "Added system stack output: $ParameterName"
            }
        }

        # Add ECS-specific parameters from config
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            if ($EcsConfig.LogRetentionDays) {
                $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
            }
            if ($EcsConfig.DbInstanceClass) {
                $ParametersDict["DbInstanceClassParameter"] = $EcsConfig.DbInstanceClass
            }
            if ($EcsConfig.DbAllocatedStorage) {
                $ParametersDict["DbAllocatedStorageParameter"] = [string]$EcsConfig.DbAllocatedStorage
            }
            if ($EcsConfig.DbMultiAZ -ne $null) {
                $ParametersDict["DbMultiAZParameter"] = "$($EcsConfig.DbMultiAZ)".ToLower()
            }
        }

        # =====================================================================
        # Detect existing retained resources
        # =====================================================================

        # Check for an existing retained RDS instance (DeletionPolicy: Retain)
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
                if ([string]::IsNullOrWhiteSpace($ExistingSecretArn)) {
                    Write-Host "Warning: Existing RDS instance has no managed secret. Run 'aws rds modify-db-instance --db-instance-identifier $DbInstanceId --manage-master-user-password' then re-run Deploy-DataAws." -ForegroundColor Yellow
                }
            } else {
                Write-LzAwsVerbose "RDS instance found but missing endpoint — will create new instance"
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

        # Handle snapshot restore
        if (-not [string]::IsNullOrWhiteSpace($DbSnapshotIdentifier)) {
            if (-not [string]::IsNullOrWhiteSpace($ParametersDict["ExistingDbEndpointParameter"])) {
                Write-Host "Warning: Existing RDS instance '$DbInstanceId' found — ignoring -DbSnapshotIdentifier. Delete the existing instance first to restore from snapshot." -ForegroundColor Yellow
            } else {
                # Verify the snapshot exists
                Write-LzAwsVerbose "Verifying snapshot: $DbSnapshotIdentifier"
                $snapshotJson = aws rds describe-db-snapshots `
                    --db-snapshot-identifier $DbSnapshotIdentifier `
                    --profile $ProfileName `
                    --region $Region `
                    --output json 2>&1

                if ($LASTEXITCODE -ne 0) {
                    # Try as a shared/automated snapshot (by ARN)
                    $snapshotJson = aws rds describe-db-snapshots `
                        --db-snapshot-identifier $DbSnapshotIdentifier `
                        --include-shared `
                        --profile $ProfileName `
                        --region $Region `
                        --output json 2>&1
                }

                if ($LASTEXITCODE -ne 0) {
                    $errorMessage = @"
Error: DB snapshot '$DbSnapshotIdentifier' not found
Function: Deploy-DataAws
Hints:
  - Verify the snapshot identifier or ARN is correct
  - Ensure the snapshot is in the same region ($Region)
  - For shared snapshots, verify the snapshot has been shared with this account
  - Use 'aws rds describe-db-snapshots --profile $ProfileName --region $Region' to list available snapshots
"@
                    throw $errorMessage
                }

                Write-Host "Will restore RDS from snapshot: $DbSnapshotIdentifier" -ForegroundColor Cyan
                $ParametersDict["DbSnapshotIdentifierParameter"] = $DbSnapshotIdentifier
            }
        }

        # Detect retained security groups (DeletionPolicy: Retain)
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
            Write-LzAwsVerbose "No existing RDS security group found — will create new"
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
            Write-LzAwsVerbose "No existing EFS security group found — will create new"
            $ParametersDict["ExistingEfsSecurityGroupIdParameter"] = ''
        }

        # Detect retained DB subnet group (DeletionPolicy: Retain)
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
            Write-LzAwsVerbose "No existing DB subnet group found — will create new"
            $ParametersDict["ExistingDbSubnetGroupNameParameter"] = ''
        }

        # Detect retained EFS filesystem (DeletionPolicy: Retain)
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
                    Write-Host "Found existing EFS filesystem: $ExistingEfsId (reusing retained filesystem)" -ForegroundColor Cyan
                } else {
                    Write-LzAwsVerbose "No existing EFS filesystem found — will create new"
                    $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
                }
            } else {
                Write-LzAwsVerbose "Warning: Failed to query EFS filesystems: $efsJson"
                $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
            }
        } catch {
            Write-LzAwsVerbose "Warning: Failed to check for existing EFS: $($_.Exception.Message)"
            $ParametersDict["ExistingEfsFileSystemIdParameter"] = ''
        }

        # Check for existing retained secrets
        $KeycloakSecretName = "$SystemKey/keycloak-admin"
        Write-LzAwsVerbose "Checking for existing secret: $KeycloakSecretName"
        $kcSecretJson = aws secretsmanager describe-secret `
            --secret-id $KeycloakSecretName `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $kcSecretArn = ($kcSecretJson | ConvertFrom-Json).ARN
            if (-not [string]::IsNullOrWhiteSpace($kcSecretArn)) {
                Write-Host "Found existing secret: $KeycloakSecretName" -ForegroundColor Cyan
                $ParametersDict["ExistingKeycloakAdminSecretArnParameter"] = $kcSecretArn
            }
        } else {
            Write-LzAwsVerbose "No existing Keycloak admin secret found — will create new secret"
            $ParametersDict["ExistingKeycloakAdminSecretArnParameter"] = ''
        }

        $SmartStoreSecretName = "$SystemKey/smartstore-db"
        Write-LzAwsVerbose "Checking for existing secret: $SmartStoreSecretName"
        $ssSecretJson = aws secretsmanager describe-secret `
            --secret-id $SmartStoreSecretName `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ssSecretArn = ($ssSecretJson | ConvertFrom-Json).ARN
            if (-not [string]::IsNullOrWhiteSpace($ssSecretArn)) {
                Write-Host "Found existing secret: $SmartStoreSecretName" -ForegroundColor Cyan
                $ParametersDict["ExistingSmartStoreDbSecretArnParameter"] = $ssSecretArn
            }
        } else {
            Write-LzAwsVerbose "No existing SmartStore DB secret found — will create new secret"
            $ParametersDict["ExistingSmartStoreDbSecretArnParameter"] = ''
        }

        $SesSmtpSecretName = "$SystemKey/ses-smtp"
        Write-LzAwsVerbose "Checking for existing secret: $SesSmtpSecretName"
        $sesSecretJson = aws secretsmanager describe-secret `
            --secret-id $SesSmtpSecretName `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $sesSecretArn = ($sesSecretJson | ConvertFrom-Json).ARN
            if (-not [string]::IsNullOrWhiteSpace($sesSecretArn)) {
                # Validate that the credentials in the secret are still active.
                $sesSecretValid = $false
                try {
                    $sesSecretValue = aws secretsmanager get-secret-value `
                        --secret-id $SesSmtpSecretName `
                        --profile $ProfileName `
                        --region $Region `
                        --query 'SecretString' `
                        --output text 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $sesSecretObj = $sesSecretValue | ConvertFrom-Json
                        $sesUsername = $sesSecretObj.username
                        if (-not [string]::IsNullOrWhiteSpace($sesUsername)) {
                            # The username is an IAM access key ID — check if it still exists
                            $iamUsers = aws iam list-users `
                                --profile $ProfileName `
                                --region $Region `
                                --query 'Users[*].UserName' `
                                --output json 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $userNames = ($iamUsers | ConvertFrom-Json)
                                foreach ($userName in $userNames) {
                                    $keyJson = aws iam list-access-keys `
                                        --user-name $userName `
                                        --profile $ProfileName `
                                        --region $Region `
                                        --output json 2>&1
                                    if ($LASTEXITCODE -eq 0) {
                                        $keys = ($keyJson | ConvertFrom-Json).AccessKeyMetadata
                                        foreach ($key in $keys) {
                                            if ($key.AccessKeyId -eq $sesUsername -and $key.Status -eq 'Active') {
                                                $sesSecretValid = $true
                                                break
                                            }
                                        }
                                    }
                                    if ($sesSecretValid) { break }
                                }
                            }
                        }
                    }
                } catch {
                    Write-LzAwsVerbose "Error validating SES SMTP secret: $_"
                }

                if ($sesSecretValid) {
                    Write-Host "Found existing secret: $SesSmtpSecretName (credentials valid)" -ForegroundColor Cyan
                    $ParametersDict["ExistingSesSMTPSecretArnParameter"] = $sesSecretArn
                } else {
                    Write-Host "Found existing secret: $SesSmtpSecretName but credentials are stale — deleting secret so it will be recreated" -ForegroundColor Yellow
                    aws secretsmanager delete-secret `
                        --secret-id $SesSmtpSecretName `
                        --force-delete-without-recovery `
                        --profile $ProfileName `
                        --region $Region 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Stale SES SMTP secret deleted — will create new credentials" -ForegroundColor Cyan
                        $ParametersDict["ExistingSesSMTPSecretArnParameter"] = ''
                    } else {
                        Write-Host "Warning: Failed to delete stale SES SMTP secret. You may need to delete it manually." -ForegroundColor Yellow
                        $ParametersDict["ExistingSesSMTPSecretArnParameter"] = $sesSecretArn
                    }
                }
            }
        } else {
            Write-LzAwsVerbose "No existing SES SMTP secret found — will create new secret"
            $ParametersDict["ExistingSesSMTPSecretArnParameter"] = ''
        }

        # =====================================================================
        # Filter parameters and deploy
        # =====================================================================

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.data.yaml"
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

        # Deploy the data stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $result = sam deploy `
            --template-file Templates/sam.data.yaml `
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
Function: Deploy-DataAws
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

        Write-Host "Deploy-DataAws stack deployed successfully" -ForegroundColor Green

        # Determine if this was a snapshot restore (snapshot was provided AND no existing DB was found)
        $restoredFromSnapshot = (-not [string]::IsNullOrWhiteSpace($DbSnapshotIdentifier)) -and
            [string]::IsNullOrWhiteSpace($ParametersDict["ExistingDbEndpointParameter"])

        # Run DB initialization task (only on fresh database creation)
        $existingDbDetected = -not [string]::IsNullOrWhiteSpace($ParametersDict["ExistingDbEndpointParameter"])
        if ($restoredFromSnapshot) {
            Write-Host "Skipping DB init task — database was restored from snapshot" -ForegroundColor Cyan
        } elseif ($existingDbDetected) {
            Write-LzAwsVerbose "Skipping DB init task — using existing database"
        } elseif ($null -ne $EcsConfig) {
            Write-LzAwsVerbose "Running ECS DB initialization task"
            $DataStackOutputs = Get-StackOutputs $StackName

            $clusterArn = $SystemStackOutputDict["EcsClusterArn"]
            $subnet1 = $SystemStackOutputDict["PrivateSubnet1Id"]
            $subnet2 = $SystemStackOutputDict["PrivateSubnet2Id"]
            $securityGroup = $SystemStackOutputDict["EcsPrivateSecurityGroupId"]

            if (-not [string]::IsNullOrEmpty($clusterArn) -and
                -not [string]::IsNullOrEmpty($subnet1) -and
                -not [string]::IsNullOrEmpty($securityGroup)) {

                $initResult = Invoke-EcsInitTask `
                    -TaskFamily "$SystemKey-db-init" `
                    -ClusterArn $clusterArn `
                    -Subnets "$subnet1,$subnet2" `
                    -SecurityGroup $securityGroup `
                    -Description "database initialization"

                if (-not $initResult) {
                    Write-Host "Warning: DB initialization task failed. You may need to run it manually." -ForegroundColor Yellow
                }
            } else {
                Write-LzAwsVerbose "Skipping DB init: required stack outputs not found (cluster, subnets, or security group)"
            }
        }

        # Post-deploy guidance for snapshot restore
        if ($restoredFromSnapshot) {
            Write-Host ""
            Write-Host "=== Snapshot Restore Post-Steps ===" -ForegroundColor Yellow
            Write-Host "The database was restored from snapshot. To enable Secrets Manager credential management:" -ForegroundColor Yellow
            Write-Host "  aws rds modify-db-instance --db-instance-identifier $DbInstanceId --manage-master-user-password --profile $ProfileName --region $Region" -ForegroundColor White
            Write-Host "Then re-run Deploy-DataAws (without -DbSnapshotIdentifier) to pick up the new secret ARN." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-DataAws completed"
    return $true
}
