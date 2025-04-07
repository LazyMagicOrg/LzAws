function Get-SystemConfig {
	# Load the systemconfig.yaml file
	$FilePath = Find-FileUp "systemconfig.yaml" -ErrorAction SilentlyContinue

	if($null -eq $FilePath -or -not (Test-Path $FilePath)) {
		Write-Host "Error: Can't find systemconfig.yaml."
		Write-Host "Hints:"
		Write-Host "  - Are you running this from the root of a solution?"
		Write-Host "  - Do you have a systemconfig.yaml file in a folder above the solution folder?"
		Write-Error "Cannot find systemconfig.yaml file" -ErrorAction Stop
	}

	try {
		$Config = Get-Content -Path $FilePath | ConvertFrom-Yaml
		$ProfileName = $Config.Profile

		# Load configuration from YAML file
		Write-LzAwsVerbose ("Getting system config for: " + $Config.SystemKey)
		Write-LzAwsVerbose "Loaded system configuration from $FilePath"
		Write-LzAwsVerbose "Setting profile to $ProfileName"

		Set-AWSCredential -ProfileName $ProfileName -Scope Global

		# Load System level configuration properties we process
		$CurrentProfile = Get-AWSCredential
		$Value = @{
			Config = $Config
			Account = $CurrentProfile.accountId
			Region = $CurrentProfile.region
			ProfileName = $ProfileName
		}
		return $Value
	}
	catch {
		if ($_.Exception.Message -like "*Set-AWSCredential*") {
			Write-Host "Error: Failed to set AWS profile to '$ProfileName'"
			Write-Host "Hints:"
			Write-Host "  - Have you logged in? aws sso login --profile $ProfileName"
			Write-Host "  - Check if the profile exists in your AWS credentials file"
			Write-Host "  - Verify the profile has valid credentials"
			Write-Host "  - Try running 'aws configure list-profiles' to see available profiles"
			Write-Error "Failed to set AWS profile to '$ProfileName'" -ErrorAction Stop
		}
		Write-Error "Failed to load system configuration: $($_.Exception.Message)" -ErrorAction Stop
	}
}