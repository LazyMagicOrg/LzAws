# This script updates the contents of a tenant s3 bucket 
# from a project in a Tenancy solution. Note that this 
# technique is useful in development but you may implement 
# different tenant asset s3 bucket management strategies 
# that don't rely on having a Tenancy solution.

function New-ImageThumbnail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [int]$MaxWidth = 200,
        [Parameter(Mandatory = $false)]
        [int]$MaxHeight = 200
    )

    try {
        # Load System.Drawing.Common assembly
        Add-Type -AssemblyName System.Drawing.Common

        # Load the source image
        $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
        
        # Calculate new dimensions maintaining aspect ratio
        $ratioX = $MaxWidth / $sourceImage.Width
        $ratioY = $MaxHeight / $sourceImage.Height
        $ratio = [Math]::Min($ratioX, $ratioY)
        
        $newWidth = [int]($sourceImage.Width * $ratio)
        $newHeight = [int]($sourceImage.Height * $ratio)

        # Create new bitmap for thumbnail
        $thumbnail = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
        
        # Create graphics object and set high quality settings
        $graphics = [System.Drawing.Graphics]::FromImage($thumbnail)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        # Draw the thumbnail
        $graphics.DrawImage($sourceImage, 0, 0, $newWidth, $newHeight)

        # Save the thumbnail with high quality
        $thumbnail.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)

        # Clean up resources
        $graphics.Dispose()
        $thumbnail.Dispose()
        $sourceImage.Dispose()

        Write-LzAwsVerbose "Successfully generated thumbnail: $DestinationPath"
        return $true
    }
    catch {
        $errorMessage = @"
Error: Failed to generate thumbnail for '$SourcePath'
Function: New-ImageThumbnail
Hints:
  - Check if the source image file exists and is accessible
  - Verify the image file is not corrupted
  - Ensure you have sufficient permissions to write to the destination
Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }
}

function Update-TenantAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,
        [Parameter(Mandatory = $true)] 
        [string] $BucketName,
        [Parameter(Mandatory = $true)]
        [string] $ProfileName
    )

    $ProjectFolder = "$ProjectName"

    $PathKey = "system"
    if($ProjectName -ne "system" ) {
        if($ProjectName.Split('-').Count -gt 1) {
            $PathKey = "subtenancy"
        }
        else {
            $PathKey = "tenant"
        }
    }

    if(-not (Test-Path $ProjectFolder -PathType Container)) {
        $errorMessage = @"
Error: Project folder '$ProjectFolder' not found
Function: Update-TenantAsset
Hints:
  - Check if the project folder exists
  - Verify you're running from the correct directory
  - Ensure the project name matches the folder name
"@
        throw $errorMessage
    }

    # First verify the bucket exists
    if (-not (Test-S3BucketExists -BucketName $BucketName)) {
        $errorMessage = @"
Error: S3 bucket '$BucketName' does not exist
Function: Update-TenantAsset
Hints:
  - Check if the bucket was created successfully
  - Verify AWS permissions for S3 operations
  - Ensure the bucket name is correct
"@
        throw $errorMessage
    }

    # Process each language folder. base, en-US, es-MX etc.
    # Note that base is not actually a language, but a special folder that contains assets shared across all languages.
    $AssetLanguages = Get-ChildItem -Directory -Path $ProjectFolder | Where-Object { 
        $_.Name -ne "bin" -and
        $_.Name -ne "obj"
    }

    foreach($AssetLanguage in $AssetLanguages) {
        $AssetLanguageName = $AssetLanguage.Name
        Write-LzAwsVerbose "Processing language: $AssetLanguageName"
        $AssetLanguageLength = $AssetLanguage.FullName.Length

        $AssetGroups = Get-ChildItem -Directory -Path $AssetLanguage.FullName
        foreach($AssetGroup in $AssetGroups) {
            $AssetGroupName = $AssetGroup.Name
            Write-LzAwsVerbose "Processing asset group: $AssetGroupName"

            $Manifest = @() # start building a new manifest
            $Assets = Get-ChildItem -Path $AssetGroup.FullName -Recurse | Where-Object {
                -not $_.PSIsContainer -and
                $_.Name -ne "assets-manifest.json" -and
                $_.Name -ne "version.json"
            }

            foreach ($Asset in $Assets) {
                try {
                    $Hash = Get-FileHash -Path $Asset.FullName -Algorithm SHA256
                    $RelativePath = $Asset.FullName.Substring($AssetLanguageLength + 1).Replace("\", "/")
                    $RelativePath = $PathKey + "/" + $AssetLanguageName + "/" + $RelativePath
                    
                    # Check if this is an image file that needs a thumbnail
                    if ($Asset.Extension -match '\.(jpg|jpeg|png)$' -and -not $Asset.Name.EndsWith('.TN.jpg')) {
                        $thumbnailPath = [System.IO.Path]::ChangeExtension($Asset.FullName, '.TN.jpg')
                        $shouldGenerateThumbnail = $false
                        
                        if (-not (Test-Path $thumbnailPath)) {
                            $shouldGenerateThumbnail = $true
                        }
                        else {
                            # Check if source image is newer than thumbnail
                            $sourceLastWrite = (Get-Item $Asset.FullName).LastWriteTime
                            $thumbLastWrite = (Get-Item $thumbnailPath).LastWriteTime
                            $shouldGenerateThumbnail = $sourceLastWrite -gt $thumbLastWrite
                        }

                        if ($shouldGenerateThumbnail) {
                            Write-LzAwsVerbose "Generating thumbnail for: $($Asset.Name)"
                            if (New-ImageThumbnail -SourcePath $Asset.FullName -DestinationPath $thumbnailPath) {
                                # Add thumbnail to manifest
                                $ThumbHash = Get-FileHash -Path $thumbnailPath -Algorithm SHA256
                                $ThumbRelativePath = [System.IO.Path]::ChangeExtension($RelativePath, '.TN.jpg')
                                $Manifest += @{
                                    hash = "sha256-$($ThumbHash.Hash)"
                                    url = "$ThumbRelativePath"
                                }
                            }
                        }
                    }

                    $Manifest += @{
                        hash = "sha256-$($Hash.Hash)"
                        url = "$RelativePath"
                    }
                }
                catch {
                    $errorMessage = @"
Error: Failed to process asset '$($Asset.Name)'
Function: Update-TenantAsset
Hints:
  - Check if the file exists and is accessible
  - Verify file permissions
  - Ensure the file is not locked or in use
File: $($Asset.FullName)
Error Details: $($_.Exception.Message)
"@
                    throw $errorMessage
                }
            }

            if ($Manifest.count -eq 0)  {
                $ManifestJson = "[]"
            } else {
                $ManifestJson = $Manifest | ConvertTo-Json -Depth 10 -AsArray
            }
            
            try {
                # Write manifest file
                $ManifestFilePath = Join-Path -Path $AssetGroup.FullName -ChildPath "assets-manifest.json"
                Set-Content -Path $ManifestFilePath -Value "$ManifestJson"

                # Get version of current contents using the hash of the generated assets-manifest.json 
                $Hash = Get-FileHash -Path $ManifestFilePath -Algorithm SHA256
                $VersionContent = '{ "version":"' + $Hash.Hash.SubString(0,8) + '" }'
                $VersionFilePath = Join-Path -Path $AssetGroup.FullName -ChildPath "version.json"
                Set-Content -Path $VersionFilePath -Value $VersionContent
            }
            catch {
                $errorMessage = @"
Error: Failed to write manifest/version files for asset group '$AssetGroupName'
Function: Update-TenantAsset
Hints:
  - Check if the directory is writable
  - Verify file permissions
  - Ensure the files are not locked
Directory: $($AssetGroup.FullName)
Error Details: $($_.Exception.Message)
"@
                throw $errorMessage
            }
        }

        try {
            # Use AWS CLI to sync files to S3
            $syncCommand = "aws s3 sync '$($AssetLanguage.FullName)' 's3://$BucketName/$AssetLanguageName' --profile $ProfileName"
            $result = Invoke-Expression $syncCommand 2>&1
            $exitCode = $LASTEXITCODE  # Use LASTEXITCODE instead of $?
            
            if ($exitCode -ne 0) {
                $errorMessage = @"
Error: Failed to sync files to S3 for language '$AssetLanguageName'
Function: Update-TenantAsset
Hints:
  - Check AWS permissions for S3 operations
  - Verify the bucket exists and is accessible
  - Ensure network connectivity to AWS
Command: $syncCommand
AWS Error: $($result | Out-String)
"@
                throw $errorMessage
            }
            
            Write-LzAwsVerbose "Successfully synced $AssetLanguageName to S3"
            Write-LzAwsVerbose ($result | Out-String)  # Ensure string conversion
        }
        catch {
            $errorMessage = @"
Error: Failed to sync files to S3 for language '$AssetLanguageName'
Function: Update-TenantAsset
Hints:
  - Check AWS service status
  - Verify AWS credentials are valid
  - Ensure the AWS CLI is installed and configured
Error Details: $($_.Exception.Message)
"@
            throw $errorMessage
        }
    }

    Write-LzAwsVerbose "Successfully updated assets for project: $ProjectName"
}