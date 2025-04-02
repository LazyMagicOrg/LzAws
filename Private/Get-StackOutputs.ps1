function Get-StackOutputs {
	param (
	    [string]$SourceStackName
        )
    $ProfileName = $script:ProfileName
    $Region = $script:Region
    $Account = $script:Account
    Write-LzAwsVerbose "Getting stack outputs for $SourceStackName"
    $Stack = Get-CFNStack -StackName $SourceStackName -ProfileName $ProfileName -Region $Region
    $OutputDictionary = @{}
    foreach($Output in $Stack.Outputs) {
        $OutputDictionary[$Output.OutputKey] = $Output.OutputValue
    }
    return $OutputDictionary
}