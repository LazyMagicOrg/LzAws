# This script creates AWS resources for the system.
# This these system resources:
# - S3 buckets for system assets
# - DynamoDB table for system
function Deploy-SystemResourcesAws {
    [CmdletBinding()]
    param()
        Write-LzAwsVerbose "Starting system resources deployment"  

    $Config = $script:Config
    if ($null -eq $Config) {
        $errorMessage = @"
Error: System configuration is required
Function: Deploy-SystemResourcesAws
Hints:
- Check if systemconfig.yaml is loaded
- Verify the configuration is not null
- Ensure the configuration file exists
- Review the configuration loading process
"@
        throw $errorMessage
    }

    $Region = $script:Region
    $Account = $script:Account
    $ProfileName = $script:ProfileName

    if ($null -eq $Region -or $null -eq $Account -or $null -eq $ProfileName) {
        $errorMessage = @"
Error: Required AWS configuration is missing
Function: Deploy-SystemResourcesAws
Hints:
- Check if AWS region is set
- Verify AWS account is configured
- Ensure AWS profile name is set
- Review AWS configuration settings
"@
        throw $errorMessage
    }
    # Create the s3 buckets 
    Write-LzAwsVerbose "Creating S3 bucket"
    $BucketName = $Config.SystemKey + "---assets-" + $Config.SystemSuffix
    New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName
    
    # Create the DynamoDB table
    $TableName = $Config.SystemKey 
    if($ReportOnly) {
        Write-Host "Creating DynamoDB table $TableName"
    } else {
        $null = Create-DynamoDbTable -TableName $TableName
    }

    Write-LzAwsVerbose "Finished deploying system resources"
}