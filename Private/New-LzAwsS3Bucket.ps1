function New-LzAwsS3Bucket {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        [Parameter(Mandatory=$true)]
        [string]$Region,
        [Parameter(Mandatory=$true)]
        [string]$Account,
        [Parameter(Mandatory=$true)]
        [ValidateSet("ASSETS", "CDNLOG", "WEBAPP")] # WebApp buckets are ASSETS buckets
        [string]$BucketType,
        [Parameter(Mandatory=$true)]
        [string]$ProfileName
    )


    if ($null -eq $BucketName -or $null -eq $Region -or $null -eq $Account -or $null -eq $ProfileName) {
        $errorMessage = @"
Error: Required parameters are missing
Function: New-LzAwsS3Bucket
Hints:
- Check if bucket name is provided
- Verify AWS region is set
- Ensure AWS account is configured
- Review AWS profile name settings
"@
        throw $errorMessage
    }

    # Clean bucket name - remove any S3 URL components
    $CleanBucketName = $BucketName.Split('.')[0]

    # Check if bucket already exists
    $BucketExists = Test-S3BucketExists -BucketName $CleanBucketName

    if($BucketExists) {
        return
    }

    Write-LzAwsVerbose "Attempting to create bucket: $CleanBucketName in region $Region"
    if($BucketType -eq "CDNLOG") {
        # For CDNLOG buckets, use AWS CLI to create with ownership controls
            $result = aws s3api create-bucket `
                --bucket $CleanBucketName `
                --region $Region `
                --create-bucket-configuration LocationConstraint=$Region `
                --object-ownership BucketOwnerPreferred `
                --profile $ProfileName 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                $errorMessage = @"
Error: Failed to create CDN log bucket '$CleanBucketName'
Function: New-LzAwsS3Bucket
Hints:
- Check if you have sufficient AWS permissions
- Verify the bucket name is unique in your AWS account
- Ensure the region is valid and accessible
- Review AWS IAM permissions
AWS Error: $result
"@
                throw $errorMessage
            }
    } else {
        # For other bucket types, use PowerShell cmdlet
        try {
            New-S3Bucket -BucketName $CleanBucketName -Region $Region -ErrorAction Stop
        }
        catch {
            $errorMessage = @"
Error: Failed to create bucket '$CleanBucketName'
Function: New-LzAwsS3Bucket
Hints:
- Check if you have sufficient AWS permissions
- Verify the bucket name is unique in your AWS account
- Ensure the region is valid and accessible
- Review AWS IAM permissions
AWS Error: $($_.Exception.Message)
"@
            throw $errorMessage
        }
    }

    # Verify bucket was created
    $VerifyExists = Test-S3BucketExists -BucketName $CleanBucketName
    if (-not $VerifyExists) {
        $errorMessage = @"
Error: Bucket creation failed - bucket '$CleanBucketName' does not exist after creation attempt
Function: New-LzAwsS3Bucket
Hints:
- Check AWS CloudTrail logs for creation failure details
- Verify the bucket name meets AWS naming requirements
- Ensure there are no AWS service issues
- Review AWS S3 service status
"@
        throw $errorMessage
    }

    $BucketPolicy = "";
    # Create bucket policy
    if($BucketType -eq "ASSETS" -or $BucketType -eq "WEBAPP") {
        $BucketPolicy = @{
            Version = "2012-10-17"
            Statement = @(
                @{
                    Sid = "AllowCloudFrontRead"
                    Effect = "Allow"
                    Principal = @{
                        Service = "cloudfront.amazonaws.com"
                    }
                    Action = "s3:GetObject"
                    Resource = "arn:aws:s3:::" + $CleanBucketName + "/*"
                    Condition = @{
                        StringEquals = @{
                            "AWS:SourceAccount" = $Account
                        }
                    }
                }
            )
        }
    } elseif ($BucketType -eq "CDNLOG") {
        $BucketPolicy = @{
            Version = "2012-10-17"
            Statement = @(
                @{
                    Effect = "Allow"
                    Principal = @{
                        Service = "delivery.logs.amazonaws.com"
                    }
                    Action = "s3:PutObject"
                    Resource = "arn:aws:s3:::${CleanBucketName}/*"
                    Condition = @{
                        StringEquals = @{
                            "s3:x-amz-acl" = "bucket-owner-full-control"
                        }
                    }
                },
                @{
                    Effect = "Allow"
                    Principal = @{
                        Service = "delivery.logs.amazonaws.com"
                    }
                    Action = "s3:GetBucketAcl"
                    Resource = "arn:aws:s3:::${CleanBucketName}"
                },
                @{
                    Effect = "Allow"
                    Principal = @{
                        Service = "logging.s3.amazonaws.com"
                    }
                    Action = @(
                        "s3:PutObject"
                    )
                    Resource = "arn:aws:s3:::${CleanBucketName}/*"
                }
            )
        }
    }

    # Convert policy to JSON
    $PolicyJson = $BucketPolicy | ConvertTo-Json -Depth 10

    # Apply bucket policy
    Write-LzAwsVerbose "Applying bucket policy..."
    try {
        $null = Write-S3BucketPolicy -BucketName $CleanBucketName -Policy $PolicyJson
    }
    catch {
        $errorMessage = @"
Error: Failed to apply bucket policy to '$CleanBucketName'
Function: New-LzAwsS3Bucket
Hints:
- Check if you have sufficient AWS permissions
- Verify the bucket policy JSON is valid
- Ensure the bucket exists and is accessible
- Review AWS IAM permissions
AWS Error: $($_.Exception.Message)
"@
        throw $errorMessage
    }

    Write-LzAwsVerbose "Successfully created/updated bucket $CleanBucketName"
}