function Resolve-LzEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$StartPath
    )

    if ($StartPath) {
        $CurrentPath = (Resolve-Path $StartPath -ErrorAction SilentlyContinue).Path
        if (-not $CurrentPath) { $CurrentPath = $StartPath }
    } else {
        $CurrentPath = (Get-Location).Path
    }

    # Pass 1: Look for env.yaml file walking up the directory tree
    $SearchPath = $CurrentPath
    while ($SearchPath -ne '') {
        $envFile = Join-Path $SearchPath "env.yaml" -ErrorAction SilentlyContinue
        if ($envFile -and (Test-Path $envFile)) {
            $content = Get-Content -Path $envFile -Raw
            if ($content -match '(?m)^\s*env\s*:\s*(\S+)') {
                $resolved = $Matches[1].ToLower()
                Write-LzAwsVerbose "Resolved environment '$resolved' from env.yaml at $envFile"
                return $resolved
            }
        }
        $SearchPath = Split-Path $SearchPath -Parent -ErrorAction SilentlyContinue
    }

    # Pass 2: Look for folder name convention (_Dev*, _Test*, _Prod*)
    $SearchPath = $CurrentPath
    while ($SearchPath -ne '') {
        $folderName = Split-Path $SearchPath -Leaf
        if ($folderName -like '_Dev*') {
            Write-LzAwsVerbose "Resolved environment 'dev' from folder name '$folderName'"
            return 'dev'
        }
        if ($folderName -like '_Test*') {
            Write-LzAwsVerbose "Resolved environment 'test' from folder name '$folderName'"
            return 'test'
        }
        if ($folderName -like '_Prod*') {
            Write-LzAwsVerbose "Resolved environment 'prod' from folder name '$folderName'"
            return 'prod'
        }
        $SearchPath = Split-Path $SearchPath -Parent -ErrorAction SilentlyContinue
    }

    return $null
}
