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
        Get-SystemConfig # sets script scopevariables
        $Region = $script:Region
        $Account = $script:Account    
        $ProfileName = $script:ProfileName
        $Config = $script:Config

        Deploy-SystemResourcesAws

        Write-LzAwsVerbose "Deploying perms stack"  
        $SystemKey = $Config.SystemKey
        $Environment = $Config.Environment
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---perms"

        $SystemStackName = $SystemKey + "---system"

        $SystemStackOutputs = Get-StackOutputs $SystemStackName

        # Build parameters for stack deployment
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

        if(-not (Test-Path -Path "./Generated/deploymentconfig.g.yaml" -PathType Leaf)) {
            throw "deploymentconfig.yaml does not exist."
        }

        $DeploymentConfig = Get-Content -Path "./Generated/deploymentconfig.g.yaml" | ConvertFrom-Yaml
        $Authentications = $DeploymentConfig.Authentications

        # Generate the authenticator parameters
        foreach($Authentication in $Authentications) {
            $Name = $Authentication.Name
            $AuthStackName = $Config.SystemKey + "---" + $Name
            $AuthStackOutputs = Get-StackOutputs $AuthStackName
            Write-Host "Processing auth stack: $AuthStackName"
            $ParametersDict.Add($Name + "UserPoolIdParameter", $AuthStackOutputs["UserPoolId"])
            $ParametersDict.Add($Name + "UserPoolClientIdParameter", $AuthStackOutputs["UserPoolClientId"])
            $ParametersDict.Add($Name + "IdentityPoolIdParameter", $AuthStackOutputs["IdentityPoolId"])
            $ParametersDict.Add($Name + "SecurityLevelParameter", $AuthStackOutputs["SecurityLevel"])
            $ParametersDict.Add($Name + "UserPoolArnParameter", $AuthStackOutputs["UserPoolArn"])
        }  

        # Write-OutputDictionary $ParametersDict

        $Parameters = ConvertTo-ParameterOverrides -parametersDict $ParametersDict
        # note that sam requires the --Profile be explicitly set
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
        sam deploy `
        --template-file Templates/sam.perms.yaml `
        --stack-name $StackName `
        --parameter-overrides $Parameters `
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
        --profile $ProfileName
    } 
    catch {
        throw
    }
}
