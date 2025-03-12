function Get-AssetsAws {
    <#
    .SYNOPSIS
        Retrieves assets from AWS S3 buckets.

    .DESCRIPTION
        Gets assets from specified AWS S3 buckets based on provided filters and parameters.
        Supports retrieving multiple types of assets and filtering by prefix, tags, or other metadata.

    .PARAMETER BucketName
        The name of the S3 bucket to retrieve assets from.

    .PARAMETER Prefix
        Optional prefix to filter S3 objects.

    .PARAMETER Filter
        Optional hashtable of tags or metadata to filter assets.

    .EXAMPLE
        Get-AssetsAws -BucketName "my-assets-bucket"
        Returns all assets from the specified bucket.

    .EXAMPLE
        Get-AssetsAws -BucketName "my-assets-bucket" -Prefix "images/"
        Returns all assets from the images/ prefix in the specified bucket.

    .NOTES
        Requires AWS.Tools.S3 module and appropriate AWS credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BucketName,

        [Parameter(Mandatory = $false)]
        [string]$Prefix,

        [Parameter(Mandatory = $false)]
        [hashtable]$Filter
    )

    begin {
        # Ensure AWS modules are initialized
        if (-not $script:ModulesInitialized) {
            Initialize-LzAwsModules
        }
    }

    process {
        try {
            Write-LzAwsVerbose "Retrieving assets from bucket: $BucketName"

            $params = @{
                BucketName = $BucketName
            }

            if ($Prefix) {
                $params.Prefix = $Prefix
                Write-LzAwsVerbose "Using prefix filter: $Prefix"
            }

            # Get objects from S3 bucket
            $objects = Get-S3Object @params

            # Apply additional filtering if specified
            if ($Filter) {
                Write-LzAwsVerbose "Applying additional filters"
                $objects = $objects | Where-Object {
                    $item = $_
                    $matches = $true
                    foreach ($key in $Filter.Keys) {
                        if ($item.Tags[$key] -ne $Filter[$key]) {
                            $matches = $false
                            break
                        }
                    }
                    $matches
                }
            }

            # Return filtered objects
            return $objects

        }
        catch {
            Write-Error "Failed to retrieve assets from S3: $($_.Exception.Message)"
        }
    }
} 