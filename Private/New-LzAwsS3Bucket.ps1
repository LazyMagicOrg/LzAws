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

    Write-LzAwsVerbose "Creating S3 bucket $BucketName in region $Region" 

    try {
   
        # Clean bucket name - remove any S3 URL components
        $CleanBucketName = $BucketName.Split('.')[0]

        # Check if bucket already exists
        $BucketExists = Test-S3BucketExists -BucketName $CleanBucketName

        if($BucketExists) {
            return
        }

        Write-LzAwsVerbose "Attempting to create bucket: $CleanBucketName in region $Region"
        try {
            if($BucketType -eq "CDNLOG") {
                # For CDNLOG buckets, use AWS CLI to create with ownership controls
                $result = aws s3api create-bucket `
                    --bucket $CleanBucketName `
                    --region $Region `
                    --create-bucket-configuration LocationConstraint=$Region `
                    --object-ownership BucketOwnerPreferred `
                    --profile $ProfileName 2>&1
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "Error: Failed to create CDN log bucket '$CleanBucketName'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if you have sufficient AWS permissions"
                    Write-Host "  - Verify the bucket name is unique in your AWS account"
                    Write-Host "  - Ensure the region is valid and accessible"
                    Write-Host "AWS Error: $result"
                    Write-Error "Failed to create CDN log bucket '$CleanBucketName': $result" -ErrorAction Stop
                }
            } else {
                # For other bucket types, use PowerShell cmdlet
                try {
                    New-S3Bucket -BucketName $CleanBucketName -Region $Region -ErrorAction Stop
                }
                catch {
                    Write-Host "Error: Failed to create bucket '$CleanBucketName'"
                    Write-Host "Hints:"
                    Write-Host "  - Check if you have sufficient AWS permissions"
                    Write-Host "  - Verify the bucket name is unique in your AWS account"
                    Write-Host "  - Ensure the region is valid and accessible"
                    Write-Host "AWS Error: $($_.Exception.Message)"
                    Write-Error "Failed to create bucket '$CleanBucketName': $($_.Exception.Message)" -ErrorAction Stop
                }
            }
        
            # Verify bucket was created
            $VerifyExists = Test-S3BucketExists -BucketName $CleanBucketName
            if (-not $VerifyExists) {
                Write-Host "Error: Bucket creation failed - bucket '$CleanBucketName' does not exist after creation attempt"
                Write-Host "Hints:"
                Write-Host "  - Check AWS CloudTrail logs for creation failure details"
                Write-Host "  - Verify the bucket name meets AWS naming requirements"
                Write-Host "  - Ensure there are no AWS service issues"
                Write-Error "Bucket creation failed - bucket '$CleanBucketName' does not exist after creation attempt" -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Failed to create bucket: $_" -ErrorAction Stop
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
            Write-S3BucketPolicy -BucketName $CleanBucketName -Policy $PolicyJson
        }
        catch {
            Write-Host "Error: Failed to apply bucket policy to '$CleanBucketName'"
            Write-Host "Hints:"
            Write-Host "  - Check if you have sufficient AWS permissions"
            Write-Host "  - Verify the bucket policy JSON is valid"
            Write-Host "  - Ensure the bucket exists and is accessible"
            Write-Host "AWS Error: $($_.Exception.Message)"
            Write-Error "Failed to apply bucket policy to '$CleanBucketName': $($_.Exception.Message)" -ErrorAction Stop
        }
        Write-LzAwsVerbose "Successfully created/updated bucket $CleanBucketName"
    }
    catch {
        Write-Host "Error: An unexpected error occurred while managing bucket '$CleanBucketName'"
        Write-Host "Hints:"
        Write-Host "  - Check AWS service status"
        Write-Host "  - Verify all required parameters are valid"
        Write-Host "  - Review AWS CloudTrail logs for details"
        Write-Host "Error Details: $($_.Exception.Message)"
        Write-Error "An unexpected error occurred while managing bucket '$CleanBucketName': $($_.Exception.Message)" -ErrorAction Stop
    }
}