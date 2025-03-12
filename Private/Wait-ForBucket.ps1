function Wait-ForBucket {
    param (
        [string]$BucketName,
        [int]$MaxAttempts = 10
    )
    
    for ($I = 1; $I -le $MaxAttempts; $I++) {
        Write-LzAwsVerbose "Attempt $I of $MaxAttempts to verify bucket existence..."
        if (Test-S3BucketExists -BucketName $BucketName) {
            Write-LzAwsVerbose "Bucket verified as accessible"
            return $true
        }
        Write-LzAwsVerbose "Bucket not yet accessible"
        if ($I -lt $MaxAttempts) {
            Start-Sleep -Seconds ($I * 2)
        }
    }
    return $false
}