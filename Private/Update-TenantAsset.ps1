# This script updates the contents of a tenant s3 bucket 
# from a project in a Tenancy solution. Note that this 
# technique is useful in development but you may implement 
# different tenant asset s3 bucket management strategies 
# that don't rely on having a Tenancy solution.
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
                    #$RelativePath = $TenancyName + "/" + $AssetLanguageName + "/" + $RelativePath
                    $RelativePath = $PathKey + "/" + $AssetLanguageName + "/" + $RelativePath
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