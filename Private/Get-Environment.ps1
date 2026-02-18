function Get-Environment {
    [CmdletBinding()]
    param()

    # Method 1: Look for env.yaml in the folder hierarchy
    $EnvFilePath = Find-FileUp "env.yaml" -ErrorAction SilentlyContinue
    if ($EnvFilePath -and (Test-Path $EnvFilePath)) {
        try {
            $EnvConfig = Get-Content -Path $EnvFilePath | ConvertFrom-Yaml
            if ($EnvConfig -and $EnvConfig.env) {
                Write-LzAwsVerbose "Environment resolved from env.yaml: $($EnvConfig.env)"
                return $EnvConfig.env
            }
        } catch {
            Write-LzAwsVerbose "Warning: Found env.yaml but failed to parse it"
        }
    }

    # Method 2: Examine folder hierarchy for _Dev*, _Test*, or _Prod* folder names
    $CurrentPath = (Get-Location).Path
    while ($CurrentPath -ne '') {
        $FolderName = Split-Path $CurrentPath -Leaf
        if ($FolderName -like '_Dev*') {
            Write-LzAwsVerbose "Environment resolved from folder name '$FolderName': dev"
            return "dev"
        }
        if ($FolderName -like '_Test*') {
            Write-LzAwsVerbose "Environment resolved from folder name '$FolderName': test"
            return "test"
        }
        if ($FolderName -like '_Prod*') {
            Write-LzAwsVerbose "Environment resolved from folder name '$FolderName': prod"
            return "prod"
        }
        $CurrentPath = Split-Path $CurrentPath -Parent -ErrorAction SilentlyContinue
    }

    return $null
}
