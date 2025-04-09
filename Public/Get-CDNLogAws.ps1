<#
.SYNOPSIS
    Retrieves and processes CloudFront CDN logs from AWS S3
.DESCRIPTION
    Gets the latest CloudFront CDN log file from an S3 bucket for a specific tenant,
    decompresses it, and converts it to a simplified CSV format. The script handles
    downloading, decompression, parsing and conversion of the log data.
.PARAMETER TenantKey
    The tenant identifier used to locate the correct S3 bucket
.PARAMETER Guid
    Optional GUID parameter for future use
.EXAMPLE
    Get-CDNLogAws -TenantKey "tenant1"
    Downloads and processes the latest CDN log for tenant1
.NOTES
    Requires:
    - Valid AWS credentials and appropriate S3 permissions
    - AWS Tools for PowerShell module

    For more information, see:
    https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/AccessLogs.html
.OUTPUTS
    Creates a CSV file named 'cloudfront_log_simplified.csv' containing the processed log data.
    The CSV includes parsed CloudFront log entries with standardized field names.
#>
function Get-CDNLogAws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TenantKey,
        
        [Parameter(Mandatory=$False)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$Guid
    )

    try {
        $null = Get-SystemConfig
        $Config = $script:Config
        $ProfileName = $script:ProfileName

        # Get the CDN log bucket name
        $BucketName = Get-CDNLogBucketName -SystemConfig $SystemConfig -TenantKey $TenantKey

        # Verify bucket exists
        if (-not (Test-S3BucketExists -BucketName $BucketName)) {
            $errorMessage = @"
Error: CDN log bucket '$BucketName' does not exist
Function: Get-CDNLogAws
Hints:
  - Check if the bucket was created successfully
  - Verify AWS permissions for S3 operations
  - Ensure the bucket name is correct
"@
            throw $errorMessage
        }

        function Convert-CloudFrontLogToCSV {
            param (
                [string]$LogFilePath
            )

            # Read the file line by line
            $Lines = Get-Content -Path $LogFilePath
            $VersionLine = $Lines | Where-Object { $_ -match '^#Version:' }
            $FieldsLine = $Lines | Where-Object { $_ -match '^#Fields:' }
            $DataLines = $Lines | Where-Object { $_ -notmatch '^#' -and $_ -ne '' }

            if (-not $FieldsLine) {
                throw "Fields line not found in the log file."
            }

            $Fields = ($FieldsLine -split ':')[1].Trim() -split '\s+'
            $Header = $Fields

            $CsvData = foreach ($Line in $DataLines) {
                $Values = $Line -split "`t"
                $LineObj = [ordered]@{}
                for ($i = 0; $i -lt $Header.Count; $i++) {
                    $LineObj[$Header[$i]] = $Values[$i]
                }
                [PSCustomObject]$LineObj
            }

            return @{
                Version = if ($VersionLine) { ($VersionLine -split ' ')[1] } else { "Unknown" }
                Fields = $Fields
                Data = $CsvData
            }
        }

        function Expand-GZipFile {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory=$True)]
                [ValidateNotNullOrEmpty()]
                [ValidateScript({Test-Path $_ -PathType Leaf})]
                [string]$Infile,
                
                [Parameter(Mandatory=$False)]
                [string]$Outfile = ($Infile -replace '\.gz$','')
            )
        
            try {
                $InputFile = New-Object System.IO.FileStream $Infile, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
                $Output = New-Object System.IO.FileStream $Outfile, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
                $GzipStream = New-Object System.IO.Compression.GzipStream $InputFile, ([IO.Compression.CompressionMode]::Decompress)
        
                $Buffer = New-Object byte[](1024)
                while($True) {
                    $Read = $GzipStream.Read($Buffer, 0, 1024)
                    if ($Read -le 0) {break}
                    $Output.Write($Buffer, 0, $Read)
                }
            }
            catch {
                $errorMessage = @"
Error: Failed to decompress file '$Infile'
Function: Expand-GZipFile
Hints:
  - Check if the file exists and is accessible
  - Verify the file is not corrupted
  - Ensure you have sufficient permissions
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
            finally {
                if ($GzipStream) { $GzipStream.Dispose() }
                if ($Output) { $Output.Dispose() }
                if ($InputFile) { $InputFile.Dispose() }
            }
        
            Write-LzAwsVerbose "Successfully decompressed '$Infile' to '$Outfile'"
        }

        # Get the latest file from the S3 bucket
        Write-LzAwsVerbose "Retrieving latest log file from S3..."
        try {
            $LatestFile = Get-S3Object -BucketName $BucketName -ProfileName $ProfileName | 
                Sort-Object LastModified -Descending | 
                Select-Object -First 1

            if (-not $LatestFile) {
                $errorMessage = @"
Error: No log files found in bucket '$BucketName'
Function: Get-CDNLogAws
Hints:
  - Check if CloudFront is configured to write logs
  - Verify the bucket has the correct permissions
  - Ensure there is traffic generating logs
"@
                throw $errorMessage
            }
        }
        catch {
            $errorMessage = @"
Error: Failed to retrieve log files from bucket '$BucketName'
Function: Get-CDNLogAws
Hints:
  - Check AWS permissions for S3 operations
  - Verify the bucket exists and is accessible
  - Ensure network connectivity to AWS
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        # Download the compressed file
        $TempCompressedFile = [System.IO.Path]::GetTempFileName()
        Write-LzAwsVerbose "Downloading log file to: $TempCompressedFile"
        try {
            Read-S3Object -BucketName $BucketName -Key $LatestFile.Key -File $TempCompressedFile -ProfileName $ProfileName
        }
        catch {
            $errorMessage = @"
Error: Failed to download log file from S3
Function: Get-CDNLogAws
Hints:
  - Check AWS permissions for S3 operations
  - Verify the file exists in the bucket
  - Ensure sufficient disk space
File: $($LatestFile.Key)
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }

        try {
            # Decompress the file
            $TempDecompressedFile = [System.IO.Path]::GetTempFileName()
            Write-LzAwsVerbose "Decompressing to: $TempDecompressedFile"
            Expand-GZipFile -infile $TempCompressedFile -outfile $TempDecompressedFile

            # Convert to CSV
            Write-LzAwsVerbose "Converting log file to CSV format..."
            $Result = Convert-CloudFrontLogToCSV -LogFilePath $TempDecompressedFile

            # Export to CSV file
            $OutputPath = "cloudfront_log_simplified.csv"
            Write-LzAwsVerbose "Exporting to: $OutputPath"
            $Result.Data | Export-Csv -Path $OutputPath -NoTypeInformation

            Write-Host "Bucket: $($BucketName)"
            Write-Host "Log file processed: $($LatestFile.Key)"
            Write-Host "Processing complete. Simplified CSV file saved to: $OutputPath"
            Write-Host "Log file version: $($Result.Version)"
            Write-Host "Fields found: $($Result.Fields -join ', ')"
        }
        catch {
            $errorMessage = @"
Error: Failed to process log file
Function: Get-CDNLogAws
Hints:
  - Check if the log file is valid
  - Verify sufficient disk space
  - Ensure write permissions in current directory
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }
        finally {
            # Clean up temporary files
            if (Test-Path $TempDecompressedFile) {
                Remove-Item -Path $TempDecompressedFile -Force
            }
            if (Test-Path $TempCompressedFile) {
                Remove-Item -Path $TempCompressedFile -Force
            }
        }
    }
    catch {
        Write-Host ($_.Exception.Message)
        return $false
    }
    return $true
}