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

        Get-SystemConfig 
        $ProfileName = $script:Profile
        $Region = $script:Region
        # Deploy system resources first
        Deploy-SystemResourcesAws

        Write-LzAwsVerbose "Deploying perms stack"  
        $Config = $script:Config

        if ($null -eq $Config) {
            $errorMessage = @"
Error: System configuration is missing Config section
Function: Deploy-PermsAws
Hints:
  - Check if Config section exists in systemconfig.yaml
  - Verify the configuration file structure
  - Ensure all required configuration sections are present
"@
            throw $errorMessage
        }

       
        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---perms"
        $SystemStackName = $SystemKey + "---system"

        # Get system stack outputs
        $SystemStackOutputs = Get-StackOutputs $SystemStackName

        if ($null -eq $SystemStackOutputs["KeyValueStoreArn"]) {
            $errorMessage = @"
Error: KeyValueStoreArn not found in system stack outputs
Function: Deploy-PermsAws
Hints:
  - Verify the system stack was deployed successfully
  - Check if the KVS resource was created
  - Ensure the system stack outputs are correct
"@
                throw $errorMessage
        }

        $ParametersDict = @{
            "SystemKeyParameter" = $SystemKey
            "EnvironmentParameter" = $Environment
            "SystemSuffixParameter" = $SystemSuffix	
            "KeyValueStoreArnParameter" = $SystemStackOutputs["KeyValueStoreArn"]	
        }
        $ServiceStackName = $SystemKey + "---service"

        # Build parameters for stack deployment
        $ServiceStackOutputs = Get-StackOutputs $ServiceStackName

        $ServiceStackOutputs.GetEnumerator() | Sort-Object Key | ForEach-Object{
            $Key = $_.Key + "Parameter"
            $Value = $_.Value
            $ParametersDict.Add($Key, $Value)
        }

        # Verify deployment config exists
        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            $errorMessage = @"
Error: deploymentconfig.g.yaml does not exist
Function: Deploy-PermsAws
Hints:
  - Run the generation step before deployment
  - Check if the generation process completed successfully
  - Verify the deployment configuration was generated
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
Function: Deploy-PermsAws
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
Function: Deploy-PermsAws
Hints:
  - Check if authentications are defined in the source config
  - Verify the generation process included authentications
  - Ensure the deployment config format is correct
"@
            throw $errorMessage
        }

        # Process authentication stacks
        $Authentications = $DeploymentConfig.Authentications
        foreach($Authentication in $Authentications) {
            $Name = $Authentication.Name
            $AuthStackName = $Config.SystemKey + "---" + $Name
            Write-LzAwsVerbose "Processing auth stack: $AuthStackName"

            $AuthStackOutputs = Get-StackOutputs $AuthStackName

            if ($null -eq $AuthStackOutputs["UserPoolId"] -or 
                $null -eq $AuthStackOutputs["UserPoolClientId"] -or 
                $null -eq $AuthStackOutputs["IdentityPoolId"] -or 
                $null -eq $AuthStackOutputs["SecurityLevel"] -or 
                $null -eq $AuthStackOutputs["UserPoolArn"]) {
                $errorMessage = @"
Error: Missing required outputs from auth stack '$AuthStackName'
Function: Deploy-PermsAws
Hints:
  - Check if the auth stack was deployed successfully
  - Verify the auth stack template includes all required outputs
  - Ensure the auth resources were created properly
"@
                throw $errorMessage
            }

            $ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputs["UserPoolId"])
            $ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputs["UserPoolClientId"])
            $ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputs["IdentityPoolId"])
            $ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputs["SecurityLevel"])
            $ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputs["UserPoolArn"])
        }

        # Deploy the permissions stack
        $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
        
        $result = sam deploy `
            --template-file Templates/sam.perms.yaml `
            --stack-name $StackName `
            --parameter-overrides $Parameters `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
            --region $Region `
            --profile $ProfileName 2>&1

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            $errorMessage = @"
Error: SAM deployment failed
Function: Deploy-PermsAws
Hints:
  - Check AWS CloudFormation console for detailed errors
  - Verify you have required IAM permissions
  - Ensure the template file exists: Templates/sam.perms.yaml
  - Validate the template syntax and parameters
Error Details: SAM deployment failed with exit code $exitCode
Command Output: $($result | Out-String)
"@
            throw $errorMessage
        }

        Write-Host "Successfully deployed permissions stack" -ForegroundColor Green
    } 
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}
