<#
.SYNOPSIS
    Deploys the sam.perms.yaml stack
.DESCRIPTION
    The perms stack allows the creation of service permissions, like 
    giving a lambda execution role access to a cognito user pool.
.PARAMETER None
    This cmdlet does not accept parameters directly, but reads from system configuration
.EXAMPLE
    Deploy-PermsAws
    Deploys the system infrastructure based on the sam.perms.yaml template
.NOTES
    - Must be run from the Tenancy Solution root folder
    - Requires valid AWS credentials and appropriate permissions
    - Uses AWS SAM CLI for deployments
.OUTPUTS
    None
#>
function Deploy-PermsAws {
    [CmdletBinding()]
    param()    
    try {
        Write-LzAwsVerbose "Starting permissions stack deployment"

        # Deploy system resources first
        try {
            Deploy-SystemResourcesAws
        }
        catch {
            Write-Host "Error: Failed to deploy system resources"
            Write-Host "Hints:"
            Write-Host "  - Check if system resources deployment completed successfully"
            Write-Host "  - Verify AWS credentials and permissions"
            Write-Host "  - Review system stack deployment logs"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        Write-LzAwsVerbose "Deploying perms stack"  
        $SystemConfig = Get-SystemConfig 
        # Get-SystemConfig already handles exit 1 on failure

        $Config = $SystemConfig.Config
        if ($null -eq $Config) {
            Write-Host "Error: System configuration is missing Config section"
            Write-Host "Hints:"
            Write-Host "  - Check if Config section exists in systemconfig.yaml"
            Write-Host "  - Verify the configuration file structure"
            Write-Host "  - Ensure all required configuration sections are present"
            exit 1
        }

        $ProfileName = $Config.Profile
        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---perms"
        $SystemStackName = $SystemKey + "---system"

        # Get system stack outputs
        try {
            $SystemStackOutputs = Get-StackOutputs $SystemStackName
            if ($null -eq $SystemStackOutputs["KeyValueStoreArn"]) {
                Write-Host "Error: KeyValueStoreArn not found in system stack outputs"
                Write-Host "Hints:"
                Write-Host "  - Verify the system stack was deployed successfully"
                Write-Host "  - Check if the KVS resource was created"
                Write-Host "  - Ensure the system stack outputs are correct"
                exit 1
            }
        }
        catch {
            Write-Host "Error: Failed to get system stack outputs"
            Write-Host "Hints:"
            Write-Host "  - Verify the system stack exists"
            Write-Host "  - Check if you have permission to read stack outputs"
            Write-Host "  - Ensure the stack name is correct: $SystemStackName"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Build parameters for stack deployment
        try {
            $ParametersDict = @{
                "SystemKeyParameter" = $SystemKey
                "EnvironmentParameter" = $Environment
                "SystemSuffixParameter" = $SystemSuffix	
                "KeyValueStoreArnParameter" = $SystemStackOutputs["KeyValueStoreArn"]	
            }

            $ServiceStackName = $SystemKey + "---service"
            $ServiceStackOutputs = Get-StackOutputs $ServiceStackName
            $ServiceStackOutputs.GetEnumerator() | Sort-Object Key | ForEach-Object{
                $Key = $_.Key + "Parameter"
                $Value = $_.Value
                $ParametersDict.Add($Key, $Value)
            }
        }
        catch {
            Write-Host "Error: Failed to prepare stack parameters"
            Write-Host "Hints:"
            Write-Host "  - Check if service stack exists and is deployed"
            Write-Host "  - Verify service stack outputs are available"
            Write-Host "  - Ensure parameter names match template requirements"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Verify deployment config exists
        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            Write-Host "Error: deploymentconfig.g.yaml does not exist"
            Write-Host "Hints:"
            Write-Host "  - Run the generation step before deployment"
            Write-Host "  - Check if the generation process completed successfully"
            Write-Host "  - Verify the deployment configuration was generated"
            exit 1
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
                exit 1
            }
        }
        catch {
            Write-Host "Error: Failed to load deployment configuration"
            Write-Host "Hints:"
            Write-Host "  - Check if deploymentconfig.g.yaml is valid YAML"
            Write-Host "  - Verify the file is not corrupted"
            Write-Host "  - Ensure the configuration format is correct"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }

        # Process authentication stacks
        $Authentications = $DeploymentConfig.Authentications
        foreach($Authentication in $Authentications) {
            $Name = $Authentication.Name
            $AuthStackName = $Config.SystemKey + "---" + $Name
            Write-LzAwsVerbose "Processing auth stack: $AuthStackName"

            try {
                $AuthStackOutputs = Get-StackOutputs $AuthStackName
                if ($null -eq $AuthStackOutputs["UserPoolId"] -or 
                    $null -eq $AuthStackOutputs["UserPoolClientId"] -or 
                    $null -eq $AuthStackOutputs["IdentityPoolId"] -or 
                    $null -eq $AuthStackOutputs["SecurityLevel"] -or 
                    $null -eq $AuthStackOutputs["UserPoolArn"]) {
                    Write-Host "Error: Missing required outputs from auth stack '$AuthStackName'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if the auth stack was deployed successfully"
                    Write-Host "  - Verify the auth stack template includes all required outputs"
                    Write-Host "  - Ensure the auth resources were created properly"
                    exit 1
                }

                $ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputs["UserPoolId"])
                $ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputs["UserPoolClientId"])
                $ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputs["IdentityPoolId"])
                $ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputs["SecurityLevel"])
                $ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputs["UserPoolArn"])
            }
            catch {
                Write-Host "Error: Failed to process auth stack '$AuthStackName'"
                Write-Host "Hints:"
                Write-Host "  - Verify the auth stack exists and is deployed"
                Write-Host "  - Check if you have permission to read stack outputs"
                Write-Host "  - Ensure all required outputs are defined in the template"
                Write-Host "Error Details: $($_.Exception.Message)"
                exit 1
            }
        }

        # Deploy the permissions stack
        try {
            $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict
            Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
            
            sam deploy `
                --template-file Templates/sam.perms.yaml `
                --stack-name $StackName `
                --parameter-overrides $Parameters `
                --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
                --profile $ProfileName

            if ($LASTEXITCODE -ne 0) {
                throw "SAM deployment failed with exit code $LASTEXITCODE"
            }

            Write-Host "Successfully deployed permissions stack" -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to deploy permissions stack"
            Write-Host "Hints:"
            Write-Host "  - Check AWS CloudFormation console for detailed errors"
            Write-Host "  - Verify you have required IAM permissions"
            Write-Host "  - Ensure the template file exists: Templates/sam.perms.yaml"
            Write-Host "  - Validate the template syntax and parameters"
            Write-Host "Error Details: $($_.Exception.Message)"
            exit 1
        }
    } 
    catch {
        Write-Host "Error: An unexpected error occurred during permissions deployment"
        Write-Host "Hints:"
        Write-Host "  - Check the AWS CloudFormation console for stack status"
        Write-Host "  - Verify all required AWS services are available"
        Write-Host "  - Review AWS CloudTrail logs for detailed error information"
        Write-Host "Error Details: $($_.Exception.Message)"
        exit 1
    }
}
