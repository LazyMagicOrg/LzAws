function Get-SystemConfig {
	# Load the systemconfig.yaml file
	$FilePath = Find-FileUp "systemconfig.yaml"

	if($null -eq $FilePath) {
		throw "Could not find a systemconfig.yaml file"
	}

	if(-not (Test-Path $FilePath)) {
		Write-Host "Please create a systemconfig.yaml file above the solution folder."
		Write-Host "Copy the systemconfig.yaml.template file and update the values in the new file."
		throw "Missing systemconfig.yaml"
	}

	$Config = Get-Content -Path $FilePath | ConvertFrom-Yaml
	$ProfileName = $Config.Profile

	# Load configuration from YAML file
	Write-LzAwsVerbose ("Getting system config for: " + $Config.SystemKey)
	Write-LzAwsVerbose "Loaded system configuration from $FilePath"
	Write-LzAwsVerbose "Setting profile to $ProfileName"

	try {
		Set-AWSCredential -ProfileName $ProfileName -Scope Global
	} catch {
		throw "Failed to set profile to $ProfileName"
	}

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