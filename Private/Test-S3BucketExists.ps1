function Test-S3BucketExists {
    param (
        [string]$BucketName
    )
    
    try {
        $ProfileName = $script:ProfileName
        $Region = $script:Region


        # Try to get just this specific bucket
        $null = Get-S3BucketLocation -BucketName $BucketName -ErrorAction SilentlyContinue -ProfileName $ProfileName -Region $Region
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*The specified bucket does not exist*") {
            return $false
        }
        Write-LzAwsVerbose "Error checking bucket existence: $_" 
        return $false
    }
}