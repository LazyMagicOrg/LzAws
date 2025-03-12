function ConvertTo-ParameterOverrides {
    param ([hashtable]$ParametersDict)
    $Overrides = @()
    foreach($Key in $ParametersDict.Keys) {
        $Value = $ParametersDict[$Key]
		$Overrides += "$Key='$Value'"
	}
    return $Overrides -join " "
}