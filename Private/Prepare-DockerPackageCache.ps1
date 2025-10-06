<#
.SYNOPSIS
    Prepares a local package cache for Docker builds by copying from NuGet cache
.DESCRIPTION
    This script runs dotnet restore, identifies all required packages, and copies them
    from the NuGet global cache to a local folder for Docker to use.
    This eliminates the need for external package sources during Docker build.
.PARAMETER ProjectPath
    Full or relative path to the .csproj file to analyze
.PARAMETER OutputPath
    Path where packages should be copied (default: "./DockerPackages")
.PARAMETER NugetConfigPath
    Optional path to a parent Nuget.Config file to discover local package sources
.PARAMETER Clean
    If specified, removes the output folder before starting
.EXAMPLE
    Prepare-DockerPackageCache -ProjectPath "Containers/ChatAppRunner/ChatAppRunner.csproj"
.EXAMPLE
    Prepare-DockerPackageCache -ProjectPath "MyProject.csproj" -OutputPath "./LocalPackages" -NugetConfigPath "../../Nuget.Config"
.NOTES
    This is a private helper function for the LzAws module.
#>
function Prepare-DockerPackageCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectPath,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = "DockerPackages",

        [Parameter(Mandatory=$false)]
        [string]$NugetConfigPath = $null,

        [Parameter(Mandatory=$false)]
        [switch]$Clean
    )

    $ErrorActionPreference = "Stop"

    Write-LzAwsVerbose "Starting Docker package cache preparation"
    Write-Host "======================================"
    Write-Host "Docker Package Preparation"
    Write-Host "======================================"
    Write-Host "Project: $ProjectPath"
    Write-Host "Output: $OutputPath"
    Write-Host ""

    # Resolve paths to absolute
    if (-not [System.IO.Path]::IsPathRooted($ProjectPath)) {
        $ProjectPath = Resolve-Path $ProjectPath -ErrorAction Stop
    }

    # Clean existing output folder if requested
    if ($Clean -and (Test-Path $OutputPath)) {
        Write-Host "Cleaning existing output folder..."
        Remove-Item $OutputPath -Recurse -Force
    }

    # Create output folder
    if (-not (Test-Path $OutputPath)) {
        Write-Host "Creating output folder..."
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Step 1: Run dotnet restore to ensure all packages are cached
    Write-Host "Running dotnet restore to populate NuGet cache..."
    Write-LzAwsVerbose "Restoring packages for $ProjectPath"

    dotnet restore $ProjectPath --verbosity quiet
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet restore failed for $ProjectPath"
    }

    # Step 2: Parse project.assets.json to get ALL package dependencies (including transitive)
    Write-Host "Analyzing package dependencies from project.assets.json..."

    $projectDir = Split-Path $ProjectPath -Parent
    $assetsJsonPath = Join-Path $projectDir "obj/project.assets.json"

    if (-not (Test-Path $assetsJsonPath)) {
        throw "project.assets.json not found at $assetsJsonPath. Did dotnet restore succeed?"
    }

    $assetsJson = Get-Content $assetsJsonPath -Raw | ConvertFrom-Json

    # Step 3: Get NuGet global packages location
    $nugetGlobalPackages = dotnet nuget locals global-packages --list |
        Select-String "global-packages:" |
        ForEach-Object { $_.ToString().Replace("global-packages:", "").Trim() }

    Write-Host "NuGet global cache: $nugetGlobalPackages"
    Write-LzAwsVerbose "Using NuGet cache: $nugetGlobalPackages"

    # Step 3.5: Get local package sources from optional Nuget.Config
    $localPackageSources = @()

    if ($NugetConfigPath -and (Test-Path $NugetConfigPath)) {
        Write-Host "Found Nuget.Config, checking for local package sources..."
        Write-LzAwsVerbose "Reading NuGet config from: $NugetConfigPath"

        try {
            [xml]$nugetConfig = Get-Content $NugetConfigPath
            $configDir = Split-Path $NugetConfigPath -Parent

            foreach ($source in $nugetConfig.configuration.packageSources.add) {
                if ($source.value -like "./*" -or $source.value -like "../*") {
                    # Resolve relative path from config directory
                    $resolvedPath = Resolve-Path (Join-Path $configDir $source.value) -ErrorAction SilentlyContinue
                    if ($resolvedPath -and (Test-Path $resolvedPath)) {
                        $localPackageSources += $resolvedPath.Path
                        Write-Host "  Found local source: $($source.key) -> $($resolvedPath.Path)"
                        Write-LzAwsVerbose "Added local package source: $($resolvedPath.Path)"
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to parse Nuget.Config: $_"
        }
    }
    Write-Host ""

    # Step 4: Collect all unique packages from libraries section
    # project.assets.json has a "libraries" section with all packages (NuGet and project references)
    $packageDict = @{}

    foreach ($library in $assetsJson.libraries.PSObject.Properties) {
        $libName = $library.Name
        $libValue = $library.Value

        # Library names are in format "PackageName/Version" or "ProjectName/Version"
        # Only process NuGet packages (not project references)
        if ($libValue.type -eq "package") {
            if ($libName -match "^(.+)/(.+)$") {
                $pkgName = $matches[1]
                $pkgVersion = $matches[2]

                $key = "$pkgName|$pkgVersion"
                if (-not $packageDict.ContainsKey($key)) {
                    $packageDict[$key] = @{
                        Name = $pkgName
                        Version = $pkgVersion
                    }
                }
            }
        }
    }

    Write-Host "Found $($packageDict.Count) unique packages"
    Write-LzAwsVerbose "Discovered $($packageDict.Count) packages to copy"
    Write-Host ""

    # Step 5: Copy packages from cache to output folder
    Write-Host "Copying packages from NuGet cache and local sources..."
    $copiedCount = 0
    $skippedCount = 0
    $notFoundCount = 0

    foreach ($pkg in $packageDict.Values) {
        $pkgName = $pkg.Name.ToLower()
        $pkgVersion = $pkg.Version.ToLower()
        $found = $false

        # Try NuGet global cache first
        # NuGet cache structure: {cache}/{packageName}/{version}/{packageName}.{version}.nupkg
        $cachePath = Join-Path $nugetGlobalPackages "$pkgName/$pkgVersion"
        $nupkgFile = Join-Path $cachePath "$pkgName.$pkgVersion.nupkg"

        if (Test-Path $nupkgFile) {
            $destFile = Join-Path $OutputPath "$pkgName.$pkgVersion.nupkg"

            if (-not (Test-Path $destFile)) {
                Copy-Item $nupkgFile $destFile -Force
                $copiedCount++
                Write-Host "  [+] $pkgName $pkgVersion (from cache)"
                $found = $true
            } else {
                $skippedCount++
                $found = $true
            }
        }

        # If not found in cache, try local package sources
        if (-not $found) {
            foreach ($localSource in $localPackageSources) {
                # Local sources have flat structure: {source}/{packageName}.{version}.nupkg
                $localNupkg = Join-Path $localSource "$pkgName.$pkgVersion.nupkg"
                if (Test-Path $localNupkg) {
                    $destFile = Join-Path $OutputPath "$pkgName.$pkgVersion.nupkg"

                    if (-not (Test-Path $destFile)) {
                        Copy-Item $localNupkg $destFile -Force
                        $copiedCount++
                        Write-Host "  [+] $pkgName $pkgVersion (from local)"
                        $found = $true
                    } else {
                        $skippedCount++
                        $found = $true
                    }
                    break
                }
            }
        }

        if (-not $found) {
            Write-Host "  [!] Not found: $pkgName $pkgVersion" -ForegroundColor Yellow
            $notFoundCount++
        }
    }

    Write-Host ""
    Write-Host "======================================"
    Write-Host "Package preparation complete!"
    Write-Host "Copied: $copiedCount packages"
    Write-Host "Skipped: $skippedCount packages (already present)"
    if ($notFoundCount -gt 0) {
        Write-Host "Not Found: $notFoundCount packages" -ForegroundColor Yellow
        Write-Host "  (These may be available from nuget.org during Docker build)"
    }
    Write-Host "Location: $OutputPath"
    Write-Host "======================================"
    Write-Host ""

    Write-LzAwsVerbose "Package cache preparation completed successfully"
}
