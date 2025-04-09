function Deploy-TestError {
    [CmdletBinding()]
    param()  
    try {
        Get-SystemConfig
        $Config = $script:Config
        $ProfileName = $script:ProfileName
        $Region = $script:Region

        Write-Host "ProfileName: $ProfileName"
        Write-Host "Region: $Region"
    } 
    catch {
        Write-Host $_.Exception.Message
    }
}