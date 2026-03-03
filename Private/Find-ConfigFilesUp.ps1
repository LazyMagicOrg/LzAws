<#
.SYNOPSIS
    Searches up the directory tree for files matching a wildcard pattern
.DESCRIPTION
    Like Find-FileUp but accepts wildcard patterns (e.g., "config.*.dev.yaml")
    and returns ALL matching files at the first directory that has any matches.
    Stops walking up once a match is found.
.PARAMETER Pattern
    Wildcard pattern to match (passed to Get-ChildItem -Filter)
.OUTPUTS
    String[] - Full paths of matching files, or empty array if none found
#>
function Find-ConfigFilesUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $CurrentPath = (Get-Location).Path

    while ($CurrentPath -ne '') {
        $matches = @(Get-ChildItem -Path $CurrentPath -Filter $Pattern -File -ErrorAction SilentlyContinue)
        if ($matches.Count -gt 0) {
            return @($matches | ForEach-Object { $_.FullName })
        }

        # Move up to the parent directory
        $ParentPath = Split-Path $CurrentPath -Parent -ErrorAction SilentlyContinue
        $CurrentPath = $ParentPath
    }

    return @()
}
