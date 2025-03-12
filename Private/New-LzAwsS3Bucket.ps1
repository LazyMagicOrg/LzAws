function New-LzAwsS3Bucket {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BucketName,
        [Parameter(Mandatory=$true)]
        [string]$Region,
        [Parameter(Mandatory=$true)]
        [string]$Account,
        [Parameter(Mandatory=$true)]
        [ValidateSet("ASSETS", "CDNLOG")] # WebApp buckets are ASSETS buckets
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
                aws s3api create-bucket `
                    --bucket $CleanBucketName `
                    --region $Region `
                    --create-bucket-configuration LocationConstraint=$Region `
                    --object-ownership BucketOwnerPreferred `
                    --profile $ProfileName
            } else {
                # For other bucket types, use PowerShell cmdlet
                New-S3Bucket -BucketName $CleanBucketName -Region $Region -ErrorAction Stop
            }
        
            # Verify bucket was created
            $VerifyExists = Test-S3BucketExists -BucketName $CleanBucketName
            if (-not $VerifyExists) {
                Write-Error "Bucket creation failed - bucket does not exist after creation attempt"
                throw
            }
        }
        catch {
            Write-Error "Failed to create bucket: $_"
            return
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
            Write-Error "Failed to apply bucket policy: $_"
            throw
        }
        Write-LzAwsVerbose "Successfully created/updated bucket $CleanBucketName"
    }
    catch {
        throw "An error occurred: $($_.Exception.Message)"
    }
}