<#
.SYNOPSIS
    Loads system configuration from a config file
.DESCRIPTION
    Discovers and loads a system configuration YAML file, sets AWS credentials,
    and populates module-level variables for use by Deploy-SystemAws and other
    system-level scripts.

    The filename is the source of truth for SystemKey and Environment.
    These values are extracted from the filename and injected into the config dict,
    overwriting any YAML properties.

    Config file discovery order:

    When -SystemKey is provided (targeted):
      1. systemconfig.{systemkey}.{env}.yaml    (new convention)
      2. systemconfig.{systemkey}.yaml          (env-agnostic)
      3. systemconfig.{env}.yaml                (legacy)
      4. systemconfig.yaml                      (legacy)

    When -SystemKey is omitted (auto-detect):
      1. Glob for systemconfig.*.{env}.yaml — if exactly one match, use it
         and infer SystemKey from the filename.
      2. Glob for systemconfig.*.yaml — if exactly one match (env-agnostic).
      3. systemconfig.{env}.yaml                (legacy)
      4. systemconfig.yaml                      (legacy)

    The environment is resolved independently via Get-Environment
    (reads env.yaml or infers from folder names like _Dev, _Test, _Prod).
.PARAMETER SystemKey
    Optional. The system identifier used for config file discovery.
    If omitted and exactly one systemconfig.*.{env}.yaml exists, it is
    auto-detected.
.EXAMPLE
    Get-SystemConfig
    Auto-detects the system config (works when only one system config exists)
.EXAMPLE
    Get-SystemConfig -SystemKey "ezra"
    Loads systemconfig.ezra.dev.yaml (or falls back to legacy naming)
.OUTPUTS
    Hashtable with keys: SystemConfig, Account, Region, ProfileName
#>
function Get-SystemConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$SystemKey
    )

    Write-LzAwsVerbose "Loading system configuration"

    # Resolve environment independently (from env.yaml or folder names)
    $EnvName = Get-Environment
    if ($null -ne $EnvName) {
        Write-LzAwsVerbose "Environment resolved to '$EnvName'"
    }

    $FilePath = $null
    $ConfigFileName = $null
    $InferredSystemKey = $null

    if (-not [string]::IsNullOrWhiteSpace($SystemKey)) {
        # =============================================================
        # TARGETED: SystemKey provided — search for specific config
        # =============================================================
        Write-LzAwsVerbose "Looking for config for system '$SystemKey'"

        # 1. systemconfig.{systemkey}.{env}.yaml (new convention, env-specific)
        if ($null -ne $EnvName) {
            $ConfigFileName = "systemconfig.$SystemKey.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 2. systemconfig.{systemkey}.yaml (new convention, env-agnostic)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "systemconfig.$SystemKey.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 3. Legacy: systemconfig.{env}.yaml
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "systemconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 4. Legacy: systemconfig.yaml
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "systemconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        $InferredSystemKey = $SystemKey

    } else {
        # =============================================================
        # AUTO-DETECT: no SystemKey — find config automatically
        # =============================================================
        Write-LzAwsVerbose "No SystemKey specified, auto-detecting config file"

        # 1. Glob for systemconfig.*.{env}.yaml
        if ($null -ne $EnvName) {
            $ConfigFiles = @(Find-ConfigFilesUp "systemconfig.*.$EnvName.yaml")

            if ($ConfigFiles.Count -eq 1) {
                $FilePath = $ConfigFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                # Extract SystemKey from filename: systemconfig.{systemkey}.{env}.yaml
                $InferredSystemKey = ($ConfigFileName -replace "^systemconfig\.", "" -replace "\.$EnvName\.yaml$", "")
                Write-LzAwsVerbose "Auto-detected system config: $ConfigFileName (SystemKey: $InferredSystemKey)"
            }
            elseif ($ConfigFiles.Count -gt 1) {
                $fileList = ($ConfigFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple system configs found for environment '$EnvName':
$fileList
Function: Get-SystemConfig
Hints:
  - Specify the system explicitly: Deploy-SystemAws -SystemKey "ezra"
  - Or remove extra config files so auto-detection can pick the single one
"@
                throw $errorMessage
            }
        }

        # 2. Glob for systemconfig.*.yaml (env-agnostic)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFiles = @(Find-ConfigFilesUp "systemconfig.*.yaml")
            # Filter to true env-agnostic files: systemconfig.{key}.yaml (exactly 3 dot-segments)
            $EnvAgnosticFiles = @($ConfigFiles | Where-Object {
                $name = Split-Path $_ -Leaf
                ($name -split '\.').Count -eq 3  # systemconfig.{key}.yaml = 3 parts
            })

            if ($EnvAgnosticFiles.Count -eq 1) {
                $FilePath = $EnvAgnosticFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $InferredSystemKey = ($ConfigFileName -replace "^systemconfig\.", "" -replace "\.yaml$", "")
                Write-LzAwsVerbose "Auto-detected env-agnostic system config: $ConfigFileName (SystemKey: $InferredSystemKey)"
            }
            elseif ($EnvAgnosticFiles.Count -gt 1) {
                $fileList = ($EnvAgnosticFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple system configs found:
$fileList
Function: Get-SystemConfig
Hints:
  - Specify the system explicitly: Deploy-SystemAws -SystemKey "ezra"
  - Or use environment-specific naming: systemconfig.{systemkey}.{env}.yaml
"@
                throw $errorMessage
            }
        }

        # 3. Legacy fallback: systemconfig.{env}.yaml
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "systemconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 4. Legacy fallback: systemconfig.yaml
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "systemconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }
    }

    # --- Validate we found a file ---
    if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
        $systemHint = if (-not [string]::IsNullOrWhiteSpace($SystemKey)) {
            "  - No config file found for system '$SystemKey'"
        } else {
            "  - No config file found (auto-detection found nothing)"
        }
        $errorMessage = @"
Error: Can't find system configuration file.
Function: Get-SystemConfig
Hints:
$systemHint
  - Expected: systemconfig.{systemkey}.$EnvName.yaml (e.g., systemconfig.ezra.dev.yaml)
  - Legacy:   systemconfig.$EnvName.yaml or systemconfig.yaml
  - Are you running from the correct directory?
  - Check if the environment is correct: '$EnvName'
"@
        throw $errorMessage
    }

    Write-LzAwsVerbose "Using system configuration file: $FilePath"
    $ConfigFileName = Split-Path $FilePath -Leaf

    # --- Parse YAML ---
    try {
        $SystemConfig = Get-Content -Path $FilePath | ConvertFrom-Yaml
    } catch {
        $errorMessage = @"
Error: Failed to parse $ConfigFileName as YAML
Function: Get-SystemConfig
Hints:
  - Check if the file is valid YAML
  - Ensure the file is not corrupted
  - Verify the file format
"@
        throw $errorMessage
    }

    # --- Inject SystemKey and Environment from filename ---
    # The filename is the source of truth. YAML properties are overwritten.
    if (-not [string]::IsNullOrWhiteSpace($InferredSystemKey)) {
        $SystemConfig.SystemKey = $InferredSystemKey
        Write-LzAwsVerbose "Injected SystemKey '$InferredSystemKey' from filename"
    }
    if ($null -ne $EnvName) {
        $SystemConfig.Environment = $EnvName
        Write-LzAwsVerbose "Injected Environment '$EnvName' from environment resolution"
    }

    # --- Set AWS credentials ---
    $ProfileName = $SystemConfig.Profile
    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        $errorMessage = @"
Error: Profile not specified in $ConfigFileName
Function: Get-SystemConfig
Hints:
  - Add a 'Profile' property to your config file
  - Example: Profile: "monro-dev"
"@
        throw $errorMessage
    }

    try {
        Set-AWSCredential -ProfileName $ProfileName -Scope Global
    } catch {
        $errorMessage = @"
Error: Failed to set AWS profile to '$ProfileName'
Function: Get-SystemConfig
Hints:
  - Have you logged in? aws sso login --profile $ProfileName
  - Check if the profile exists: aws configure list-profiles
  - Verify the profile has valid credentials
"@
        throw $errorMessage
    }

    $CurrentProfile = Get-AWSCredential

    # --- Validate region ---
    $Region = $SystemConfig.Region
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $errorMessage = @"
Error: Region not specified in $ConfigFileName
Function: Get-SystemConfig
Hints:
  - Add a 'Region' property to your config file
  - Example: Region: us-west-2
"@
        throw $errorMessage
    }

    # --- Set module-level variables ---
    # Note: Uses $script:SystemConfig (not $script:Config) to avoid collision with Get-TenantConfig
    $script:SystemConfig = $SystemConfig
    $script:Account = $CurrentProfile.AccountId
    $script:Region = $Region
    $script:ProfileName = $ProfileName

    $Value = @{
        SystemConfig = $SystemConfig
        Account      = $CurrentProfile.AccountId
        Region       = $Region
        ProfileName  = $ProfileName
    }

    Write-LzAwsVerbose "Loaded config for system '$($SystemConfig.SystemKey)' (env: $($SystemConfig.Environment), region: $Region)"
    return $Value
}
