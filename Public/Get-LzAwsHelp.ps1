<#
.SYNOPSIS
    Lists all available LzAws commands in this module
.DESCRIPTION
    Provides a list of all public cmdlets available in this module along with their synopsis.
    This includes:
    - Deploy-SystemAws: Deploys system-wide AWS infrastructure
    - Deploy-AuthsAws: Deploys authentication configurations to AWS
    - Deploy-PoliciesAws: Deploys IAM policies to AWS
    - Deploy-ServiceAws: Deploys service infrastructure and resources to AWS
    - Deploy-TenantsAws: Deploys multiple tenant configurations to AWS
    - Deploy-WebappAws: Deploys a web application to AWS infrastructure
    - Get-TenantConfigAws: Generates tenant configuration JSON file
    - Get-VersionAws: Gets the current version of the AWS module
.EXAMPLE
    Get-LzAwsHelp
    Lists all available commands with their descriptions
.NOTES
    This command helps discover available functionality in the module

.OUTPUTS
    System.String[]
    Returns a list of strings in the format "cmdletname - synopsis"
#>
function Get-LzAwsHelp {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param()

    # Get all public functions from the module
    $Commands = Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" | ForEach-Object {
        $Content = Get-Content $_.FullName -Raw
        if ($Content -match '\.SYNOPSIS\s*\r?\n\s*([^\r\n]+)') {
            "$($_.BaseName) - $($Matches[1].Trim())"
        }
    }

    return $Commands | Sort-Object
}