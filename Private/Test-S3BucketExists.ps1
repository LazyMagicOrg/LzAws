function Test-S3BucketExists {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BucketName
    )

    $ProfileName = $script:ProfileName
    $Region = $script:Region

    if ($null -eq $BucketName) {
        $errorMessage = @"
Error: Bucket name is required
Function: Test-S3BucketExists
Hints:
- Provide a valid bucket name
- Check if the bucket name parameter is set
"@
        throw $errorMessage
    }

    # Clean bucket name - remove any S3 URL components
    $CleanBucketName = $BucketName.Split('.')[0] 
    try {
        $bucket = Get-S3Bucket -BucketName $CleanBucketName -Region $Region -ProfileName $ProfileName
        return $null -ne $bucket
    }
    catch {
        if ($_.Exception.Message -like "*NoSuchBucket*") {
            return $false
        }
        $errorMessage = @"
Error: Failed to check bucket existence for '$CleanBucketName'
Function: Test-S3BucketExists
Hints:
- Check if you have sufficient AWS permissions
- Verify AWS credentials are valid
- Ensure AWS region is correctly set
- Review AWS IAM permissions
AWS Error: $($_.Exception.Message)
"@
        throw $errorMessage
    }
}