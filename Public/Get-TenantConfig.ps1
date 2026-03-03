<#
.SYNOPSIS
    Loads tenant configuration from a config file
.DESCRIPTION
    Discovers and loads a tenant configuration YAML file, sets AWS credentials,
    and populates module-level variables for use by Deploy-Tenant*Aws scripts.

    The filename is the source of truth for SystemKey, TenantKey, and Environment.
    These values are extracted from the filename and injected into the config dict,
    overwriting any YAML properties.

    Config file discovery order:

    When -TenantKey is provided (targeted):
      1. tenantconfig.*.{tenantkey}.{env}.yaml   (new: glob for systemkey)
      2. tenantconfig.*.{tenantkey}.yaml         (new: env-agnostic)
      3. tenantconfig.{tenantkey}.{env}.yaml     (legacy: no systemkey)
      4. tenantconfig.{tenantkey}.yaml           (legacy: env-agnostic)
      5. config.{tenantkey}.{env}.yaml           (legacy: old prefix)
      6. config.{tenantkey}.yaml                 (legacy: old prefix)
      7. tenantconfig.{env}.yaml                 (legacy: single-tenant)
      8. tenantconfig.yaml                       (legacy: single-tenant)
      9. systemconfig.{env}.yaml                 (legacy)
     10. systemconfig.yaml                       (legacy)

    When -TenantKey is omitted (auto-detect):
      1. Glob for tenantconfig.*.*.{env}.yaml — 5-segment files
         (systemkey + tenantkey), require exactly one match.
      2. Glob for tenantconfig.*.*.yaml — 4-segment env-agnostic.
      3. Legacy fallbacks (tenantconfig.*.{env}.yaml, config.*.{env}.yaml, etc.)

    The environment is resolved independently via Get-Environment
    (reads env.yaml or infers from folder names like _Dev, _Test, _Prod).
.PARAMETER TenantKey
    Optional. The tenant identifier used for config file discovery.
    If omitted and exactly one tenantconfig.*.*.{env}.yaml exists, it is
    auto-detected.
.EXAMPLE
    Get-TenantConfig
    Auto-detects the tenant config (works when only one config exists)
.EXAMPLE
    Get-TenantConfig -TenantKey "ezra"
    Loads tenantconfig.ezra.ezra.dev.yaml (or falls back to legacy naming)
.OUTPUTS
    Hashtable with keys: TenantConfig, Config, Account, Region, ProfileName
#>
function Get-TenantConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TenantKey
    )

    Write-LzAwsVerbose "Loading tenant configuration"

    # Resolve environment independently (from env.yaml or folder names)
    $EnvName = Get-Environment
    if ($null -ne $EnvName) {
        Write-LzAwsVerbose "Environment resolved to '$EnvName'"
    }

    $FilePath = $null
    $ConfigFileName = $null
    $InferredTenantKey = $null
    $InferredSystemKey = $null

    if (-not [string]::IsNullOrWhiteSpace($TenantKey)) {
        # =============================================================
        # TARGETED: TenantKey provided — search for specific config
        # =============================================================
        Write-LzAwsVerbose "Looking for config for tenant '$TenantKey'"

        # 1. tenantconfig.*.{tenantkey}.{env}.yaml (new convention, glob for systemkey)
        if ($null -ne $EnvName) {
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.$TenantKey.$EnvName.yaml")
            if ($ConfigFiles.Count -eq 1) {
                $FilePath = $ConfigFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                # Extract SystemKey: tenantconfig.{systemkey}.{tenantkey}.{env}.yaml
                $parts = $ConfigFileName -split '\.'
                $InferredSystemKey = $parts[1]
                Write-LzAwsVerbose "Found $ConfigFileName (SystemKey: $InferredSystemKey)"
            }
            elseif ($ConfigFiles.Count -gt 1) {
                $fileList = ($ConfigFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple tenant configs found for tenant '$TenantKey' in environment '$EnvName':
$fileList
Function: Get-TenantConfig
Hints:
  - Multiple systems have a tenant named '$TenantKey'
  - This is ambiguous — ensure only one system's config exists, or use explicit naming
"@
                throw $errorMessage
            }
        }

        # 2. tenantconfig.*.{tenantkey}.yaml (new convention, env-agnostic)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.$TenantKey.yaml")
            # Filter to 4-segment files: tenantconfig.{sk}.{tk}.yaml
            $EnvAgnosticFiles = @($ConfigFiles | Where-Object {
                $name = Split-Path $_ -Leaf
                ($name -split '\.').Count -eq 4
            })
            if ($EnvAgnosticFiles.Count -eq 1) {
                $FilePath = $EnvAgnosticFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $parts = $ConfigFileName -split '\.'
                $InferredSystemKey = $parts[1]
                Write-LzAwsVerbose "Found $ConfigFileName (SystemKey: $InferredSystemKey)"
            }
            elseif ($EnvAgnosticFiles.Count -gt 1) {
                $fileList = ($EnvAgnosticFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple tenant configs found for tenant '$TenantKey':
$fileList
Function: Get-TenantConfig
Hints:
  - Multiple systems have a tenant named '$TenantKey'
  - Use environment-specific naming: tenantconfig.{systemkey}.{tenantkey}.{env}.yaml
"@
                throw $errorMessage
            }
        }

        # 3. Legacy: tenantconfig.{tenantkey}.{env}.yaml (no systemkey)
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "tenantconfig.$TenantKey.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 4. Legacy: tenantconfig.{tenantkey}.yaml (no systemkey)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "tenantconfig.$TenantKey.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 5. Legacy: config.{tenantkey}.{env}.yaml (old prefix)
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "config.$TenantKey.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 6. Legacy: config.{tenantkey}.yaml (old prefix)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "config.$TenantKey.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 7. Legacy: tenantconfig.{env}.yaml (single-tenant)
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "tenantconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 8. Legacy: tenantconfig.yaml (single-tenant)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "tenantconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 9. Legacy: systemconfig.{env}.yaml
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "systemconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 10. Legacy: systemconfig.yaml
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "systemconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        $InferredTenantKey = $TenantKey

    } else {
        # =============================================================
        # AUTO-DETECT: no TenantKey — find config automatically
        # =============================================================
        Write-LzAwsVerbose "No TenantKey specified, auto-detecting config file"

        # 1. Glob for tenantconfig.*.*.{env}.yaml (5-segment: systemkey + tenantkey)
        if ($null -ne $EnvName) {
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.*.$EnvName.yaml")
            # Filter to exactly 5 dot-segments: tenantconfig.{sk}.{tk}.{env}.yaml
            $FiveSegFiles = @($ConfigFiles | Where-Object {
                $name = Split-Path $_ -Leaf
                ($name -split '\.').Count -eq 5
            })

            if ($FiveSegFiles.Count -eq 1) {
                $FilePath = $FiveSegFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $parts = $ConfigFileName -split '\.'
                $InferredSystemKey = $parts[1]
                $InferredTenantKey = $parts[2]
                Write-LzAwsVerbose "Auto-detected tenant config: $ConfigFileName (SystemKey: $InferredSystemKey, TenantKey: $InferredTenantKey)"
            }
            elseif ($FiveSegFiles.Count -gt 1) {
                $fileList = ($FiveSegFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple tenant configs found for environment '$EnvName':
$fileList
Function: Get-TenantConfig
Hints:
  - Specify the tenant explicitly: Deploy-TenantDataAws -TenantKey "ezra"
  - Or remove extra config files so auto-detection can pick the single one
"@
                throw $errorMessage
            }
        }

        # 2. Glob for tenantconfig.*.*.yaml (4-segment env-agnostic)
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.*.yaml")
            # Filter to exactly 4 dot-segments: tenantconfig.{sk}.{tk}.yaml
            $FourSegFiles = @($ConfigFiles | Where-Object {
                $name = Split-Path $_ -Leaf
                ($name -split '\.').Count -eq 4
            })

            if ($FourSegFiles.Count -eq 1) {
                $FilePath = $FourSegFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $parts = $ConfigFileName -split '\.'
                $InferredSystemKey = $parts[1]
                $InferredTenantKey = $parts[2]
                Write-LzAwsVerbose "Auto-detected env-agnostic tenant config: $ConfigFileName (SystemKey: $InferredSystemKey, TenantKey: $InferredTenantKey)"
            }
            elseif ($FourSegFiles.Count -gt 1) {
                $fileList = ($FourSegFiles | ForEach-Object { "  " + (Split-Path $_ -Leaf) }) -join "`n"
                $errorMessage = @"
Error: Multiple tenant configs found:
$fileList
Function: Get-TenantConfig
Hints:
  - Specify the tenant explicitly: Deploy-TenantDataAws -TenantKey "ezra"
  - Or use environment-specific naming: tenantconfig.{systemkey}.{tenantkey}.{env}.yaml
"@
                throw $errorMessage
            }
        }

        # 3. Legacy: Glob for tenantconfig.*.{env}.yaml (3-segment, no systemkey)
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFiles = @(Find-ConfigFilesUp "tenantconfig.*.$EnvName.yaml")
            # Filter to exactly 4 dot-segments: tenantconfig.{tk}.{env}.yaml
            $LegacyFiles = @($ConfigFiles | Where-Object {
                $name = Split-Path $_ -Leaf
                ($name -split '\.').Count -eq 4
            })

            if ($LegacyFiles.Count -eq 1) {
                $FilePath = $LegacyFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $InferredTenantKey = ($ConfigFileName -replace "^tenantconfig\.", "" -replace "\.$EnvName\.yaml$", "")
                Write-LzAwsVerbose "Auto-detected legacy tenant config: $ConfigFileName (TenantKey: $InferredTenantKey)"
            }
        }

        # 4. Legacy: Glob for config.*.{env}.yaml (old prefix)
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFiles = @(Find-ConfigFilesUp "config.*.$EnvName.yaml")

            if ($ConfigFiles.Count -eq 1) {
                $FilePath = $ConfigFiles[0]
                $ConfigFileName = Split-Path $FilePath -Leaf
                $InferredTenantKey = ($ConfigFileName -replace "^config\.", "" -replace "\.$EnvName\.yaml$", "")
                Write-LzAwsVerbose "Auto-detected legacy config: $ConfigFileName (TenantKey: $InferredTenantKey)"
            }
        }

        # 5. Legacy fallback: tenantconfig.{env}.yaml
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "tenantconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 6. Legacy fallback: tenantconfig.yaml
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "tenantconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 7. Legacy fallback: systemconfig.{env}.yaml
        if (($null -eq $FilePath -or -not (Test-Path $FilePath)) -and $null -ne $EnvName) {
            $ConfigFileName = "systemconfig.$EnvName.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }

        # 8. Legacy fallback: systemconfig.yaml
        if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
            $ConfigFileName = "systemconfig.yaml"
            Write-LzAwsVerbose "Trying $ConfigFileName (legacy)"
            $FilePath = Find-FileUp $ConfigFileName -ErrorAction SilentlyContinue
        }
    }

    # --- Validate we found a file ---
    if ($null -eq $FilePath -or -not (Test-Path $FilePath)) {
        $tenantHint = if (-not [string]::IsNullOrWhiteSpace($TenantKey)) {
            "  - No config file found for tenant '$TenantKey'"
        } else {
            "  - No config file found (auto-detection found nothing)"
        }
        $errorMessage = @"
Error: Can't find tenant configuration file.
Function: Get-TenantConfig
Hints:
$tenantHint
  - Expected: tenantconfig.{systemkey}.{tenantkey}.$EnvName.yaml (e.g., tenantconfig.ezra.ezra.dev.yaml)
  - Legacy:   tenantconfig.{tenantkey}.$EnvName.yaml or config.{tenantkey}.$EnvName.yaml
  - Are you running from the correct directory?
  - Check if the environment is correct: '$EnvName'
"@
        throw $errorMessage
    }

    Write-LzAwsVerbose "Using tenant configuration file: $FilePath"
    $ConfigFileName = Split-Path $FilePath -Leaf

    # --- Parse YAML ---
    try {
        $TenantConfig = Get-Content -Path $FilePath | ConvertFrom-Yaml
    } catch {
        $errorMessage = @"
Error: Failed to parse $ConfigFileName as YAML
Function: Get-TenantConfig
Hints:
  - Check if the file is valid YAML
  - Ensure the file is not corrupted
  - Verify the file format
"@
        throw $errorMessage
    }

    # --- Inject keys from filename (source of truth) ---
    # The filename determines SystemKey, TenantKey, and Environment.
    # YAML properties are overwritten by filename values.
    if (-not [string]::IsNullOrWhiteSpace($InferredSystemKey)) {
        $TenantConfig.SystemKey = $InferredSystemKey
        Write-LzAwsVerbose "Injected SystemKey '$InferredSystemKey' from filename"
    }
    if (-not [string]::IsNullOrWhiteSpace($InferredTenantKey)) {
        $TenantConfig.TenantKey = $InferredTenantKey
        Write-LzAwsVerbose "Injected TenantKey '$InferredTenantKey' from filename"
    }
    if ($null -ne $EnvName) {
        $TenantConfig.Environment = $EnvName
        Write-LzAwsVerbose "Injected Environment '$EnvName' from environment resolution"
    }

    # --- Backward compatibility for legacy configs ---
    # Legacy configs may have SystemKey but no TenantKey (old monolithic pattern).
    # Only map SystemKey → TenantKey when TenantKey is still absent after injection.
    if ($null -eq $TenantConfig.TenantKey -and $null -ne $TenantConfig.SystemKey) {
        Write-LzAwsVerbose "Mapping SystemKey → TenantKey (legacy backward compatibility)"
        $TenantConfig.TenantKey = $TenantConfig.SystemKey
    }
    if ($null -eq $TenantConfig.TenantSuffix -and $null -ne $TenantConfig.SystemSuffix) {
        Write-LzAwsVerbose "Mapping SystemSuffix → TenantSuffix (backward compatibility)"
        $TenantConfig.TenantSuffix = $TenantConfig.SystemSuffix
    }

    # --- Set AWS credentials ---
    $ProfileName = $TenantConfig.Profile
    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        $errorMessage = @"
Error: Profile not specified in $ConfigFileName
Function: Get-TenantConfig
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
Function: Get-TenantConfig
Hints:
  - Have you logged in? aws sso login --profile $ProfileName
  - Check if the profile exists: aws configure list-profiles
  - Verify the profile has valid credentials
"@
        throw $errorMessage
    }

    $CurrentProfile = Get-AWSCredential

    # --- Validate region ---
    $Region = $TenantConfig.Region
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $errorMessage = @"
Error: Region not specified in $ConfigFileName
Function: Get-TenantConfig
Hints:
  - Add a 'Region' property to your config file
  - Example: Region: us-west-2
"@
        throw $errorMessage
    }

    # --- Set module-level variables ---
    $script:TenantConfig = $TenantConfig
    $script:Config = $TenantConfig          # Backward compat: existing code reads $script:Config
    $script:Account = $CurrentProfile.AccountId
    $script:Region = $Region
    $script:ProfileName = $ProfileName

    $Value = @{
        TenantConfig = $TenantConfig
        Config       = $TenantConfig
        Account      = $CurrentProfile.AccountId
        Region       = $Region
        ProfileName  = $ProfileName
    }

    Write-LzAwsVerbose "Loaded config for tenant '$($TenantConfig.TenantKey)' (system: $($TenantConfig.SystemKey), env: $($TenantConfig.Environment), region: $Region)"
    return $Value
}
