function Get-StacksOutputs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$StackNames
    )

    $ProfileName = $script:ProfileName
    $Region = $script:Region
    $Account = $script:Account

    if ($null -eq $ProfileName -or $null -eq $Region -or $null -eq $Account) {
        $errorMessage = @"
Error: Required AWS configuration is missing
Function: Get-StacksOutputs
Hints:
  - Check if AWS region is set
  - Verify AWS account is configured
  - Ensure AWS profile name is set
  - Review AWS configuration settings
"@
        throw $errorMessage
    }

    Write-LzAwsVerbose "Getting outputs from $($StackNames.Count) stack(s)"

    $OutputDictionary = @{}

    foreach ($StackName in $StackNames) {
        Write-LzAwsVerbose "Getting stack outputs for '$StackName'"
        
        try {
            $Stack = Get-CFNStack -StackName $StackName -ProfileName $ProfileName -Region $Region
        }
        catch {
            if ($_.Exception.Message -like "*does not exist*") {
                $errorMessage = @"
Error: CloudFormation stack '$StackName' does not exist
Function: Get-StacksOutputs
Hints:
  - Check if the stack was deployed successfully
  - Verify the stack name is correct
  - Ensure you're using the correct AWS region
  - Review CloudFormation console for stack status
"@
                throw $errorMessage
            }
            throw
        }

        if ($null -eq $Stack) {
            $errorMessage = @"
Error: Failed to retrieve CloudFormation stack '$StackName'
Function: Get-StacksOutputs
Hints:
  - Check AWS credentials and permissions
  - Verify the stack exists and is accessible
  - Ensure you have cloudformation:DescribeStacks permission
  - Review AWS IAM permissions
"@
            throw $errorMessage
        }

        if ($null -eq $Stack.Outputs) {
            Write-LzAwsVerbose "Stack '$StackName' has no outputs, skipping"
            continue
        }

        foreach ($Output in $Stack.Outputs) {
            if (-not $OutputDictionary.ContainsKey($Output.OutputKey)) {
                $OutputDictionary[$Output.OutputKey] = $Output.OutputValue
                Write-LzAwsVerbose "Added output: $($Output.OutputKey)"
            } else {
                Write-LzAwsVerbose "Skipping duplicate output key: $($Output.OutputKey)"
            }
        }
    }

    Write-LzAwsVerbose "Retrieved $($OutputDictionary.Count) total stack outputs"
    return $OutputDictionary
}
