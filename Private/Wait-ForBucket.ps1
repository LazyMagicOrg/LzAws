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
    
    try {
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

        Write-Host "Error: Bucket '$BucketName' did not become accessible within $MaxAttempts attempts"
        Write-Host "Hints:"
        Write-Host "  - Check if the bucket was created successfully"
        Write-Host "  - Verify AWS permissions for bucket access"
        Write-Host "  - Ensure the bucket name is correct"
        Write-Host "  - Check AWS service status"
        Write-Error "Bucket did not become available after $MaxAttempts attempts" -ErrorAction Stop
    }
    catch {
        Write-Host "Error: Failed while waiting for bucket '$BucketName'"
        Write-Host "Hints:"
        Write-Host "  - Check AWS credentials and permissions"
        Write-Host "  - Verify network connectivity to AWS"
        Write-Host "  - Ensure the AWS profile is correctly configured"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error $_.Exception.Message -ErrorAction Stop
    }
}