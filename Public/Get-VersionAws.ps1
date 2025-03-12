function Get-VersionAws {
    <#
    .SYNOPSIS
        Gets the current version of the AWS module
    .DESCRIPTION
        Returns the semantic version number of the this module
    .EXAMPLE
        Get-VersionAws
        Returns: 1.0.0
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $moduleInfo = Get-Module -Name (Get-Item $PSScriptRoot).Parent.Name
        if ($moduleInfo) {
            return $moduleInfo.Version.ToString()
        }
        return "1.0.0" # Fallback version
    }
    catch {
        Write-Warning "Could not determine module version. Returning default version."
        return "1.0.0"
    }
}