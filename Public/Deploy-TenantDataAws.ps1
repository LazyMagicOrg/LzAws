<#
.SYNOPSIS
    Deploys the per-tenant data stack (EFS access points, secrets, SES, DB init)
.DESCRIPTION
    Deploys or updates the tenant data stack which creates per-tenant resources
    on top of the shared system infrastructure:
    - SmartStore EFS access points on the system's shared EFS
    - Consolidated tenant secret ({SystemKey}/{TenantKey}) with DB + SES credentials
    - SES domain identity with DKIM
    - SES SMTP credentials (merged into tenant secret)
    - DB initialization task (creates smartstore database on system's shared RDS)

    Reads system stack outputs for VPC, subnets, ECS cluster, RDS, EFS references.
    Auto-detects existing retained tenant secret.
.EXAMPLE
    Deploy-TenantDataAws
    Deploys the tenant data stack based on tenantconfig.yaml
.NOTES
    - Must be run from the AWSTemplates directory
    - Requires the system stack deployed first (Deploy-SystemAws)
    - Requires valid AWS credentials and appropriate permissions
.OUTPUTS
    Boolean - $true on success, $false on failure
#>
function Deploy-TenantDataAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )

    Write-LzAwsVerbose "Deploy-TenantDataAws"

    try {
        $null = Get-TenantConfig -TenantKey $TenantKey
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $TenantKey = $Config.TenantKey
        $TenantSuffix = $Config.TenantSuffix

        Write-LzAwsVerbose "Deploying tenant data stack"

        # Verify template exists
        if (-not (Test-Path -Path "Templates/sam.tenant-data.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: Template file not found: Templates/sam.tenant-data.yaml
Function: Deploy-TenantDataAws
Hints:
  - Check if the template file exists in the Templates directory
  - Verify the template file name is correct
  - Ensure you are running from the AWSTemplates directory
"@
            throw $errorMessage
        }

        # Get system stack outputs
        $SystemKey = $Config.SystemKey
        if ([string]::IsNullOrWhiteSpace($SystemKey)) {
            $errorMessage = @"
Error: SystemKey not found in tenantconfig
Function: Deploy-TenantDataAws
Hints:
  - Add 'SystemKey: "ezra"' to your tenantconfig file
  - SystemKey identifies which system stack to read outputs from
"@
            throw $errorMessage
        }

        $StackName = $SystemKey + "-" + $TenantKey + "--data"
        $ArtifactsBucket = $SystemKey + "-" + $TenantKey + "--artifacts-" + $TenantSuffix
        $Account = $script:Account

        # Create S3 artifacts bucket if it doesn't exist
        Write-LzAwsVerbose "Ensuring S3 artifacts bucket exists: $ArtifactsBucket"
        New-LzAwsS3Bucket -BucketName $ArtifactsBucket -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName

        $SystemStackName = $SystemKey + "---system"
        Write-LzAwsVerbose "Getting system stack outputs from '$SystemStackName'"
        $SystemStackOutputDict = Get-StackOutputs $SystemStackName

        if ($null -eq $SystemStackOutputDict -or $SystemStackOutputDict.Count -eq 0) {
            $errorMessage = @"
Error: System stack '$SystemStackName' not found or has no outputs
Function: Deploy-TenantDataAws
Hints:
  - Deploy the system stack first: Deploy-SystemAws
  - Verify the system stack name is correct
  - Check if the system stack deployed successfully
"@
            throw $errorMessage
        }

        # Build parameters dict
        $ParametersDict = @{
            "TenantKeyParameter"    = $TenantKey
            "SystemKeyParameter"  = $SystemKey
            "EnvironmentParameter"  = $Config.Environment
            "DomainNameParameter"   = $Config.DefaultTenant
        }

        # Map system stack outputs to template parameters
        # The system outputs use names like "VpcId", "PrivateSubnet1Id", etc.
        # The template expects "VpcIdParameter", "PrivateSubnet1IdParameter", etc.
        foreach ($OutputKey in $SystemStackOutputDict.Keys) {
            $ParameterName = $OutputKey + "Parameter"
            if (-not $ParametersDict.ContainsKey($ParameterName)) {
                $ParametersDict[$ParameterName] = $SystemStackOutputDict[$OutputKey]
                Write-LzAwsVerbose "Added system stack output: $ParameterName"
            }
        }

        # Map specific system outputs that have different names in the template
        # System output "DbEndpoint" → template param "DbEndpointParameter"
        # System output "DbMasterSecretArn" → template param "DbMasterSecretArnParameter"
        # System output "FileSystemId" → template param "FileSystemIdParameter"
        # System output "RdsSecurityGroupId" → template param "RdsSecurityGroupIdParameter"
        # (These should already be mapped by the foreach loop above)

        # Add ECS-specific parameters from config
        $EcsConfig = $Config.ECS
        if ($null -ne $EcsConfig) {
            if ($EcsConfig.LogRetentionDays) {
                $ParametersDict["LogRetentionDaysParameter"] = [string]$EcsConfig.LogRetentionDays
            }
            # Per-tenant resource isolation: EFS paths and database name
            # Config values override auto-generated defaults below.
            if ($EcsConfig.EfsSmartStoreDataPath) {
                $ParametersDict["EfsSmartStoreDataPathParameter"] = $EcsConfig.EfsSmartStoreDataPath
            }
            if ($EcsConfig.EfsSmartStoreConfigPath) {
                $ParametersDict["EfsSmartStoreConfigPathParameter"] = $EcsConfig.EfsSmartStoreConfigPath
            }
            if ($EcsConfig.EfsAppHostConfigPath) {
                $ParametersDict["EfsAppHostConfigPathParameter"] = $EcsConfig.EfsAppHostConfigPath
            }
            if ($EcsConfig.DatabaseName) {
                $ParametersDict["DatabaseNameParameter"] = $EcsConfig.DatabaseName
            }
        }

        # Tenant-qualified defaults: if config didn't specify EFS paths or DB name,
        # use /{TenantKey}/... paths and {TenantKey}_smartstore DB name so each
        # tenant is isolated on the shared EFS and RDS by default.
        if (-not $ParametersDict.ContainsKey("EfsSmartStoreDataPathParameter")) {
            $ParametersDict["EfsSmartStoreDataPathParameter"] = "/$TenantKey/smartstore-data"
            Write-LzAwsVerbose "Using default EFS path: /$TenantKey/smartstore-data"
        }
        if (-not $ParametersDict.ContainsKey("EfsSmartStoreConfigPathParameter")) {
            $ParametersDict["EfsSmartStoreConfigPathParameter"] = "/$TenantKey/smartstore-config"
            Write-LzAwsVerbose "Using default EFS path: /$TenantKey/smartstore-config"
        }
        if (-not $ParametersDict.ContainsKey("EfsAppHostConfigPathParameter")) {
            $ParametersDict["EfsAppHostConfigPathParameter"] = "/$TenantKey/apphost-config"
            Write-LzAwsVerbose "Using default EFS path: /$TenantKey/apphost-config"
        }
        if (-not $ParametersDict.ContainsKey("DatabaseNameParameter")) {
            $ParametersDict["DatabaseNameParameter"] = "${TenantKey}_smartstore"
            Write-LzAwsVerbose "Using default database name: ${TenantKey}_smartstore"
        }

        # =====================================================================
        # Detect existing retained tenant secret
        # =====================================================================
        # The consolidated tenant secret lives at {SystemKey}/{TenantKey}.
        # Legacy names ({SK}/{TK}/tenant, {SK}/{TK}/smartstore-db) are checked
        # as fallbacks but won't be reused — a new secret will be created.

        $TenantSecretName = "$SystemKey/$TenantKey"
        Write-LzAwsVerbose "Checking for existing tenant secret: $TenantSecretName"
        $ssSecretJson = aws secretsmanager describe-secret `
            --secret-id $TenantSecretName `
            --profile $ProfileName `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ssSecretArn = ($ssSecretJson | ConvertFrom-Json).ARN
            if (-not [string]::IsNullOrWhiteSpace($ssSecretArn)) {
                Write-Host "Found existing tenant secret: $TenantSecretName" -ForegroundColor Cyan
                $ParametersDict["ExistingTenantSecretArnParameter"] = $ssSecretArn
            }
        } else {
            # Fall back: check for legacy secret name ({SK}/{TK}/tenant)
            $LegacySecretName = "$SystemKey/$TenantKey/tenant"
            Write-LzAwsVerbose "Checking for legacy secret: $LegacySecretName"
            $legacyJson = aws secretsmanager describe-secret `
                --secret-id $LegacySecretName `
                --profile $ProfileName `
                --region $Region `
                --output json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Found legacy secret: $LegacySecretName (will create new tenant secret at $TenantSecretName)" -ForegroundColor Yellow
            }
            Write-LzAwsVerbose "No existing tenant secret found — will create new secret"
            $ParametersDict["ExistingTenantSecretArnParameter"] = ''
        }

        # =====================================================================
        # Filter parameters and deploy
        # =====================================================================

        $TemplateParameters = Get-TemplateParameters -TemplatePath "Templates/sam.tenant-data.yaml"
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

        # Deploy the tenant data stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName"
        $result = sam deploy `
            --template-file Templates/sam.tenant-data.yaml `
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
Function: Deploy-TenantDataAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template syntax is correct
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $resultString
"@
                throw $errorMessage
            }
        }

        Write-Host "Deploy-TenantDataAws stack deployed successfully" -ForegroundColor Green

        # Run DB initialization task (creates smartstore database on system RDS)
        $existingTenantSecret = -not [string]::IsNullOrWhiteSpace($ParametersDict["ExistingTenantSecretArnParameter"])
        if (-not $existingTenantSecret) {
            Write-LzAwsVerbose "Running tenant DB initialization task"
            $DataStackOutputs = Get-StackOutputs $StackName

            $clusterArn = $SystemStackOutputDict["EcsClusterArn"]
            $subnet1 = $SystemStackOutputDict["PrivateSubnet1Id"]
            $subnet2 = $SystemStackOutputDict["PrivateSubnet2Id"]
            $securityGroup = $SystemStackOutputDict["EcsPrivateSecurityGroupId"]

            if (-not [string]::IsNullOrEmpty($clusterArn) -and
                -not [string]::IsNullOrEmpty($subnet1) -and
                -not [string]::IsNullOrEmpty($securityGroup)) {

                $initResult = Invoke-EcsInitTask `
                    -TaskFamily "$SystemKey-$TenantKey-db-init" `
                    -ClusterArn $clusterArn `
                    -Subnets "$subnet1,$subnet2" `
                    -SecurityGroup $securityGroup `
                    -Description "tenant database initialization"

                if (-not $initResult) {
                    Write-Host "Warning: DB initialization task failed. You may need to run it manually." -ForegroundColor Yellow
                }
            } else {
                Write-LzAwsVerbose "Skipping DB init: required system outputs not found"
            }
        } else {
            Write-LzAwsVerbose "Skipping DB init — tenant secret already exists (database likely initialized)"
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-TenantDataAws completed"
    return $true
}
