function Wait-ForBucket {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$BucketName,
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 60)]
        [int]$MaxAttempts = 10
    )
    
    Write-LzAwsVerbose "Waiting for bucket '$BucketName' to become accessible (max attempts: $MaxAttempts)"
    
    for ($I = 1; $I -le $MaxAttempts; $I++) {
        Write-LzAwsVerbose "Attempt $I of $MaxAttempts to verify bucket existence..."
        if (Test-S3BucketExists -BucketName $BucketName) {
            Write-LzAwsVerbose "Bucket '$BucketName' verified as accessible"
            return $true
        }
        Write-LzAwsVerbose "Bucket '$BucketName' not yet accessible"
        if ($I -lt $MaxAttempts) {
            $SleepSeconds = $I * 2
            Write-LzAwsVerbose "Waiting $SleepSeconds seconds before next attempt..."
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    $errorMessage = @"
Error: Bucket '$BucketName' did not become accessible within $MaxAttempts attempts
Function: Wait-ForBucket
Hints:
- Check if the bucket was created successfully
- Verify AWS permissions for bucket access
- Ensure the bucket name is correct
- Check AWS service status
"@
    throw $errorMessage

}