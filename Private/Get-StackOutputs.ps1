function Get-StackOutputs {
	param (
	    [string]$SourceStackName
        )
    Write-LzAwsVerbose "Getting stack outputs for $SourceStackName"
    $Stack = Get-CFNStack -StackName $SourceStackName 
    $OutputDictionary = @{}
    foreach($Output in $Stack.Outputs) {
        $OutputDictionary[$Output.OutputKey] = $Output.OutputValue
    }
    return $OutputDictionary
}