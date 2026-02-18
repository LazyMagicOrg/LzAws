function Find-FileUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        
        [Parameter(Mandatory = $false)]
        [string]$StartPath
    )

    if ($StartPath) {
        $CurrentPath = (Resolve-Path $StartPath -ErrorAction SilentlyContinue).Path
        if (-not $CurrentPath) {
            return $null
        }
    } else {
        $CurrentPath = (Get-Location).Path
    }

    while ($CurrentPath -ne '') {
        # Check if the file exists in the current directory
        $FilePath = Join-Path $CurrentPath $FileName -ErrorAction SilentlyContinue
        if ($FilePath -and (Test-Path $FilePath)) {
            return $FilePath
        }

        # Get the parent directory
        $ParentPath = Split-Path $CurrentPath -Parent -ErrorAction SilentlyContinue
        # Move up to the parent directory
        $CurrentPath = $ParentPath
    }
    return $null
}

# Example usage:
# Find-FileUp "package.json"
# Find-FileUp "web.config" -StartPath "C:\Projects\MyWebApp\src"