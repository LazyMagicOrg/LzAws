function Write-OutputDictionary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Dictionary,
        
        [Parameter(Mandatory=$false)]
        [string]$Title = "Stack Outputs"
    )
    
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "------------------------" -ForegroundColor Cyan
    
    $Dictionary.GetEnumerator() | Sort-Object Key | ForEach-Object {
        $Key = $_.Key
        $Value = $_.Value
        Write-Host "${Key}:" -ForegroundColor Green -NoNewline    
        Write-Host " $Value"
    }
    
    Write-Host "------------------------`n" -ForegroundColor Cyan
}