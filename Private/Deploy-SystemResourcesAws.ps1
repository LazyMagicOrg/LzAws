# This script creates AWS resources for the system.
# This these system resources:
# - S3 buckets for system assets
# - DynamoDB table for system
function Deploy-SystemResourcesAws {
    [CmdletBinding()]
    param( 
        [switch]$ReportOnly
    )
    try {
        $SystemConfig = Get-SystemConfig
        $Config = $SystemConfig.Config
        $Region = $SystemConfig.Region
        $Account = $SystemConfig.Account
        $ProfileName = $SystemConfig.ProfileName

        Write-LzAwsVerbose "Region: $Region, Account: $Account"

        # Create the s3 buckets 
        Write-LzAwsVerbose "Creating S3 bucket"
        $BucketName = $Config.SystemKey + "---assets-" + $Config.SystemSuffix
        New-LzAwsS3Bucket -BucketName $BucketName -Region $Region -Account $Account -BucketType "ASSETS" -ProfileName $ProfileName

        # Create the DynamoDB table
        $TableName = $Config.SystemKey 
        if($ReportOnly) {
            Write-Host "Creating DynamoDB table $TableName"
        } else {
            Write-LzAwsVerbose "Creating DynamoDB table $TableName"
            Create-DynamoDbTable -TableName $TableName
        }

        Write-LzAwsVerbose "Finished deploying system resources"
    }

    catch {
        Write-Error "Failed to deploy system resources: $($_.Exception.Message)"
        throw
    }
}