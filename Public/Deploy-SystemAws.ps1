<#
.SYNOPSIS
    Deploys system-wide AWS infrastructure
.DESCRIPTION
    Deploys or updates core system infrastructure components in AWS using SAM templates.
    First deploys system resources, then deploys the main system stack which includes
    key-value store and other foundational services.
    For ECS deployments (when Config.ECS is present), passes additional parameters
    for VPC, networking, database, and runs DB initialization after deployment.
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Deploy-SystemAws
    Deploys the system infrastructure based on configuration in systemconfig.yaml
.NOTES
    - Must be run from the Tenancy Solution root folder
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
.OUTPUTS
    None
#>
function Deploy-SystemAws {
    [CmdletBinding()]
    param()

    Write-LzAwsVerbose "Deploy-SystemAws"

    try {
        $null = Get-SystemConfig
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        # Deploy system resources first (S3 assets bucket, DynamoDB table)
        Write-LzAwsVerbose "Deploying system resources"
        Deploy-SystemResourcesAws

        Write-LzAwsVerbose "Deploying system stack"
        $StackName = $SystemKey + "---system"
        $ArtifactsBucket = $SystemKey + "---artifacts-" + $SystemSuffix

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.system.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.system.yaml
Function: Deploy-SystemAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        }

        # Build parameters dict
        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "SystemSuffixParameter" = $SystemSuffix
        }

        # Add ECS-specific parameters when Config.ECS is present
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            Write-LzAwsVerbose "ECS configuration detected, adding ECS parameters"

            $ParametersDict["EnvironmentParameter"] = $Config.Environment
            $ParametersDict["DomainNameParameter"] = $Config.DefaultTenant

            if ($EcsConfig.LogRetentionDays) {
                $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
            }

            # Resolve the public hosted zone ID for the domain
            if (-not [string]::IsNullOrWhiteSpace($EcsConfig.PublicHostedZoneId)) {
                # Explicit override in config
                $PublicHostedZoneId = $EcsConfig.PublicHostedZoneId
                Write-LzAwsVerbose "Using PublicHostedZoneId from config: $PublicHostedZoneId"
            } else {
                # Auto-resolve from DefaultTenant domain name
                $PublicHostedZoneId = Resolve-PublicHostedZoneId -DomainName $Config.DefaultTenant
            }
            $ParametersDict["PublicHostedZoneIdParameter"] = $PublicHostedZoneId

            if ($EcsConfig.DbInstanceClass) {
                $ParametersDict["DbInstanceClassParameter"] = $EcsConfig.DbInstanceClass
            }
            if ($EcsConfig.DbAllocatedStorage) {
                $ParametersDict["DbAllocatedStorageParameter"] = [string]$EcsConfig.DbAllocatedStorage
            }
            if ($EcsConfig.DbMultiAZ -ne $null) {
                $ParametersDict["DbMultiAZParameter"] = "$($EcsConfig.DbMultiAZ)".ToLower()
            }

            # Check for an existing retained RDS instance (from a previous stack deployment).
            # The DB uses DeletionPolicy: Retain so it survives stack deletes.
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

                if (-not [string]::IsNullOrWhiteSpace($ExistingEndpoint) -and
                    -not [string]::IsNullOrWhiteSpace($ExistingSecretArn)) {
                    Write-Host "Found existing RDS instance: $DbInstanceId ($ExistingEndpoint)" -ForegroundColor Cyan
                    $ParametersDict["ExistingDbEndpointParameter"] = $ExistingEndpoint
                    $ParametersDict["ExistingDbSecretArnParameter"] = $ExistingSecretArn
                    $ParametersDict["ExistingDbInstanceIdParameter"] = $ExistingInstanceId
                } else {
                    Write-LzAwsVerbose "RDS instance found but missing endpoint or secret — will create new instance"
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

            # Check for existing retained secrets (from a previous stack deployment).
            # Secrets use DeletionPolicy: Retain so they survive stack deletes.
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
                    # The secret can become stale if the IAM user/access key was deleted
                    # (e.g., stack delete) while the secret survived (DeletionPolicy: Retain).
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
                # Explicitly pass empty string to override any previous stack parameter value.
                # CloudFormation reuses previous parameter values when not specified in --parameter-overrides.
                $ParametersDict["ExistingSesSMTPSecretArnParameter"] = ''
            }
        }

        # Use Get-TemplateParameters to filter to only valid parameters
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
            # Convert the result array to a single string for easier searching
            $resultString = $result | Out-String

            # Check if the result contains "No changes to deploy" (case-insensitive)
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

        # Run DB initialization task for ECS deployments
        if ($null -ne $EcsConfig) {
            Write-LzAwsVerbose "Running ECS DB initialization task"
            $SystemStackOutputs = Get-StackOutputs $StackName

            $clusterArn = $SystemStackOutputs["EcsClusterArn"]
            $subnet1 = $SystemStackOutputs["PrivateSubnet1Id"]
            $subnet2 = $SystemStackOutputs["PrivateSubnet2Id"]
            $securityGroup = $SystemStackOutputs["EcsPrivateSecurityGroupId"]

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
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-SystemAws completed"
    return $true
}
