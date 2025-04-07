function Test-S3BucketExists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$BucketName
    )
    
    try {
        # Try to get just this specific bucket
        $Null = Get-S3BucketLocation -BucketName $BucketName -ErrorAction SilentlyContinue
        Write-LzAwsVerbose "Bucket '$BucketName' exists"
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*The specified bucket does not exist*") {
            Write-LzAwsVerbose "Bucket '$BucketName' does not exist"
            return $false
        }
        
        if ($_.Exception.Message -like "*Access Denied*") {
            Write-Host "Error: Access denied when checking bucket '$BucketName'"
            Write-Host "Hints:"
            Write-Host "  - Check AWS credentials and permissions"
            Write-Host "  - Verify the IAM role has s3:GetBucketLocation permission"
            Write-Host "  - Ensure the AWS profile is correctly configured"
            Write-Host "Error Details: $($_.Exception.Message)"
            Write-Error "Access denied when checking bucket '$BucketName': $($_.Exception.Message)" -ErrorAction Stop
        }

        Write-Host "Error: Failed to check bucket existence"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service status"
        Write-Host "  - Verify network connectivity to AWS"
        Write-Host "  - Ensure AWS credentials are valid"
        Write-Host "Bucket: $BucketName"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "Failed to check bucket existence for '$BucketName': $($_.Exception.Message)" -ErrorAction Stop
    }
}