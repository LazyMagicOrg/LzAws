<#
.SYNOPSIS
    Lists all available AWS commands in this module
.DESCRIPTION
    Provides a list of all public cmdlets available in this module along with their synopsis.
    This includes:
    - Deploy-AuthsAws: Deploys authentication configurations to AWS
    - Deploy-PoliciesAws: Deploys IAM policies to AWS
    - Deploy-ServiceAws: Deploys service infrastructure and resources to AWS
    - Deploy-SystemAws: Deploys system-wide AWS infrastructure
    - Deploy-TenantAws: Deploys a tenant configuration to AWS
    - Deploy-TenantsAws: Deploys multiple tenant configurations to AWS
    - Deploy-WebappAws: Deploys a web application to AWS infrastructure
    - Get-CDNLogAws: Retrieves and processes CloudFront CDN logs from AWS S3
    - Get-TenantConfigAws: Generates tenant configuration JSON file
    - Get-VersionAws: Gets the current version of the AWS module
.EXAMPLE
    Get-AwsCommands
    Lists all available commands with their descriptions
.NOTES
    This command helps discover available functionality in the module
.OUTPUTS
    System.Object[]
    Returns a list of command objects with Name and Synopsis properties
#>
function Get-AwsCommands {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param()

    try {

        # Get all public functions from the module
        # $ModulePath = (Get-Item $PSScriptRoot).Parent.FullName
        $Commands = Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" | ForEach-Object {
        $Content = Get-Content $_.FullName -Raw
        if ($Content -match '\.SYNOPSIS\s*\r?\n\s*([^\r\n]+)') {
            @{
                Name = $_.BaseName
                    Synopsis = $Matches[1].Trim()
            }
            }
        }

        return $Commands | Sort-Object Name
    }
    catch {
        throw
    }
} 