function Get-StackOutputs {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$SourceStackName
	)

	$ProfileName = $script:ProfileName
	$Region = $script:Region
	$Account = $script:Account

	if ($null -eq $ProfileName -or $null -eq $Region -or $null -eq $Account) {
		$errorMessage = @"
Error: Required AWS configuration is missing
Function: Get-StackOutputs
Hints:
  - Check if AWS region is set
  - Verify AWS account is configured
  - Ensure AWS profile name is set
  - Review AWS configuration settings
"@
		throw $errorMessage
	}

	Write-LzAwsVerbose "Getting stack outputs for '$SourceStackName'"
	
	try {
		$Stack = Get-CFNStack -StackName $SourceStackName -ProfileName $ProfileName -Region $Region
	}
	catch {
		if ($_.Exception.Message -like "*does not exist*") {
			$errorMessage = @"
Error: CloudFormation stack '$SourceStackName' does not exist
Function: Get-StackOutputs
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
Error: Failed to retrieve CloudFormation stack '$SourceStackName'
Function: Get-StackOutputs
Hints:
  - Check AWS credentials and permissions
  - Verify the stack exists and is accessible
  - Ensure you have cloudformation:DescribeStacks permission
  - Review AWS IAM permissions
"@
		throw $errorMessage
	}

	if ($null -eq $Stack.Outputs) {
		$errorMessage = @"
Error: CloudFormation stack '$SourceStackName' has no outputs
Function: Get-StackOutputs
Hints:
  - Check if the stack template defines outputs
  - Verify the stack deployment completed successfully
  - Ensure the stack is not in a failed state
  - Review CloudFormation template outputs section
"@
		throw $errorMessage
	}

	$OutputDictionary = @{}
	foreach($Output in $Stack.Outputs) {
		$OutputDictionary[$Output.OutputKey] = $Output.OutputValue
	}

	Write-LzAwsVerbose "Retrieved $($OutputDictionary.Count) stack outputs"
	return $OutputDictionary
}