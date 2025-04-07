function Find-FileUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        
        [Parameter(Mandatory = $false)]
        [string]$StartPath = (Get-Location).Path
    )

    # Convert the start path to absolute path
    $CurrentPath = Resolve-Path $StartPath

    while ($true) {
        # Check if the file exists in the current directory
        $FilePath = Join-Path $CurrentPath $FileName -ErrorAction SilentlyContinue
        if ($FilePath -and (Test-Path $FilePath)) {
            return $FilePath
        }

        # Get the parent directory
        $ParentPath = Split-Path $CurrentPath -Parent -ErrorAction SilentlyContinue

        # If we're at the root directory and haven't found the file, return null
        if ($null -eq $ParentPath -or $CurrentPath -eq $ParentPath) {
            return $null
        }

        # Move up to the parent directory
        $CurrentPath = $ParentPath
    }
}

# Example usage:
# Find-FileUp "package.json"
# Find-FileUp "web.config" -StartPath "C:\Projects\MyWebApp\src"