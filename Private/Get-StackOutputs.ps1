function Get-StackOutputs {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$SourceStackName
	)

	try {
		Write-LzAwsVerbose "Getting stack outputs for '$SourceStackName'"
		
		try {
			$Stack = Get-CFNStack -StackName $SourceStackName 
		}
		catch {
			if ($_.Exception.Message -like "*does not exist*") {
				Write-Host "Error: CloudFormation stack '$SourceStackName' does not exist"
				Write-Host "Hints:"
				Write-Host "  - Check if the stack was deployed successfully"
				Write-Host "  - Verify the stack name is correct"
				Write-Host "  - Ensure you're using the correct AWS region"
				Write-Error "CloudFormation stack '$SourceStackName' does not exist" -ErrorAction Stop
			}
			throw
		}

		if ($null -eq $Stack) {
			Write-Host "Error: Failed to retrieve CloudFormation stack '$SourceStackName'"
			Write-Host "Hints:"
			Write-Host "  - Check AWS credentials and permissions"
			Write-Host "  - Verify the stack exists and is accessible"
			Write-Host "  - Ensure you have cloudformation:DescribeStacks permission"
			Write-Error "Failed to retrieve CloudFormation stack '$SourceStackName'" -ErrorAction Stop
		}

		if ($null -eq $Stack.Outputs) {
			Write-Host "Error: CloudFormation stack '$SourceStackName' has no outputs"
			Write-Host "Hints:"
			Write-Host "  - Check if the stack template defines outputs"
			Write-Host "  - Verify the stack deployment completed successfully"
			Write-Host "  - Ensure the stack is not in a failed state"
			Write-Error "CloudFormation stack '$SourceStackName' has no outputs" -ErrorAction Stop
		}

		$OutputDictionary = @{}
		foreach($Output in $Stack.Outputs) {
			$OutputDictionary[$Output.OutputKey] = $Output.OutputValue
		}

		Write-LzAwsVerbose "Retrieved $($OutputDictionary.Count) stack outputs"
		return $OutputDictionary
	}
	catch {
		Write-Host "Error: Failed to get stack outputs for '$SourceStackName'"
		Write-Host "Hints:"
		Write-Host "  - Check AWS service status"
		Write-Host "  - Verify network connectivity to AWS"
		Write-Host "  - Ensure AWS credentials are valid"
		Write-Host "Error Details: $($_.Exception.Message)"
		Write-Error "Failed to get stack outputs for '$SourceStackName': $($_.Exception.Message)" -ErrorAction Stop
	}
}