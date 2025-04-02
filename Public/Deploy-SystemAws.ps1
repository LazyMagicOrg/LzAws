<#
.SYNOPSIS
    Deploys system-wide AWS infrastructure
.DESCRIPTION
    Deploys or updates core system infrastructure components in AWS using SAM templates.
    First deploys system resources, then deploys the main system stack which includes
    key-value store and other foundational services.
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
        Get-SystemConfig # sets script scopevariables
        $Region = $script:Region
        $Account = $script:Account    
        $ProfileName = $script:ProfileName
        $Config = $script:Config

        Deploy-SystemResourcesAws

        Write-LzAwsVerbose "Deploying system stack"  

        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix

        $StackName = $SystemKey + "---system"

        # note that sam requires the --Profile be explicitly set
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
        Write-Host "Deploying the stack $StackName using profile $ProfileName" 
        sam deploy `
        --template-file Templates/sam.system.yaml `
        --stack-name $StackName `
        --parameter-overrides SystemKeyParameter=$SystemKey SystemSuffixParameter=$SystemSuffix `
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
        --profile $ProfileName
    }
    catch {
        throw
    }
}
