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
        Write-LzAwsVerbose "Error generating thumbnail: $_"
        return $false
    }
}

function Update-TenantAsset {
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
        throw "Folder $ProjectFolder not found"
    }

    # First verify the bucket exists
    if (-not (Test-S3BucketExists -BucketName $BucketName)) {
        throw "Bucket $BucketName does not exist"
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
                    throw "Error processing asset $($Asset.FullName): $_"
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
                throw "Error writing manifest/version files: $_"
            }
        }

        try {
            # Use AWS CLI to sync files to S3
            $syncCommand = "aws s3 sync '$($AssetLanguage.FullName)' 's3://$BucketName/$AssetLanguageName' --profile $ProfileName"
            $result = Invoke-Expression $syncCommand 2>&1
            $exitCode = $LASTEXITCODE  # Use LASTEXITCODE instead of $?
            
            if ($exitCode -ne 0) {
                throw "AWS CLI command failed with exit code $exitCode. Output: $($result | Out-String)"
            }
            
            Write-LzAwsVerbose "Successfully synced $AssetLanguageName to S3"
            Write-LzAwsVerbose ($result | Out-String)  # Ensure string conversion
        }
        catch {
            throw "Error syncing to S3: $($_.Exception.Message)"
        }
    }
}