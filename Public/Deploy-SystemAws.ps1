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
        $null = Get-SystemConfig 
        $ProfileName = $script:ProfileName
        $Region = $script:Region
        $Config = $script:Config
        $SystemKey = $Config.SystemKey
        $SystemSuffix = $Config.SystemSuffix
        
        # Deploy system resources first
        Write-LzAwsVerbose "Deploying system resources"
        Deploy-SystemResourcesAws

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
  - Ensure you are running from the correct directory
"@
            throw $errorMessage
        } 

        # Deploy the system stack
        Write-LzAwsVerbose "Deploying the stack $StackName using profile $ProfileName" 
        $result = sam deploy `
            --template-file Templates/sam.system.yaml `
            --stack-name $StackName `
            --parameter-overrides SystemKeyParameter=$SystemKey SystemSuffixParameter=$SystemSuffix `
            --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND `
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
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    Write-Host "Deploy-SystemAws completed"
    return $true
}
