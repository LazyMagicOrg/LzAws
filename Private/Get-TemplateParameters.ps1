<#
.SYNOPSIS
    Gets the list of parameter names defined in a CloudFormation/SAM template
.DESCRIPTION
    Parses a CloudFormation or SAM YAML template and extracts all parameter names
    from the Parameters section. This is useful for filtering parameter overrides
    to only include parameters that the template actually expects.
.PARAMETER TemplatePath
    Path to the CloudFormation/SAM YAML template file
.EXAMPLE
    $templateParams = Get-TemplateParameters -TemplatePath "sam.Service.packaged.yaml"
    Returns an array of parameter names defined in the template
.EXAMPLE
    $filteredParams = Get-TemplateParameters -TemplatePath "template.yaml" | 
        Where-Object { $myParams.ContainsKey($_) }
    Gets template parameters and filters to only those you have values for
.OUTPUTS
    System.String[]
    Array of parameter names defined in the template
.NOTES
    - Requires the powershell-yaml module for YAML parsing
    - Returns an empty array if no parameters are defined
    - Throws an error if the template file doesn't exist or can't be parsed
#>
function Get-TemplateParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath
    )

    Write-LzAwsVerbose "Getting template parameters from: $TemplatePath"

    if (-not (Test-Path $TemplatePath)) {
        throw "Template file not found: $TemplatePath"
    }

    try {
        # Read and parse the YAML template
        $templateContent = Get-Content -Path $TemplatePath -Raw
        $template = $templateContent | ConvertFrom-Yaml

        # Extract parameter names
        $parameterNames = @()
        if ($null -ne $template.Parameters) {
            $parameterNames = $template.Parameters.Keys | ForEach-Object { $_.ToString() }
            Write-LzAwsVerbose "Found $($parameterNames.Count) parameters in template"
        } else {
            Write-LzAwsVerbose "No Parameters section found in template"
        }

        return $parameterNames
    }
    catch {
        $errorMessage = @"
Error: Failed to parse template parameters
Function: Get-TemplateParameters
Template: $TemplatePath
Hints:
  - Verify the template file is valid YAML
  - Ensure the powershell-yaml module is installed
  - Check the template has a valid Parameters section
Error Details: $($_.Exception.Message)
"@
        throw $errorMessage
    }
}
