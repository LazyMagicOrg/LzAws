<#
.SYNOPSIS
    Synchronizes NuGet packages to a local cache for Docker builds
.DESCRIPTION
    This function runs dotnet restore, identifies all required packages, and synchronizes them
    from the NuGet global cache and local package sources to a local DockerPackages folder.
    This eliminates the need for external package sources during Docker build.
.PARAMETER ProjectPath
    Path to the .csproj file to analyze (relative to Service directory)
.PARAMETER Clean
    If specified, removes the DockerPackages folder before starting
.EXAMPLE
    Sync-DockerPackages -ProjectPath "Containers/ChatAppRunner/ChatAppRunner.csproj"
.EXAMPLE
    Sync-DockerPackages -ProjectPath "Containers/ChatAppRunner/ChatAppRunner.csproj" -Clean
.NOTES
    - This function must be run from the Service directory
    - Automatically handles both NuGet global cache and local package sources
    - Synchronizes packages to ensure Docker builds can work offline
.OUTPUTS
    Boolean - Returns $true on success, $false on failure
#>
function Sync-DockerPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory=$false)]
        [switch]$Clean
    )

    Write-LzAwsVerbose "Starting Docker package preparation for '$ProjectPath'"

    try {

        Write-Host "======================================"
        Write-Host "Docker Package Preparation"
        Write-Host "======================================"
        Write-Host "Project: $ProjectPath"
        Write-Host ""

        # Clean existing DockerPackages folder if requested
        $dockerPackagesPath = "DockerPackages"
        if ($Clean -and (Test-Path $dockerPackagesPath)) {
            Write-Host "Cleaning existing DockerPackages folder..."
            Remove-Item $dockerPackagesPath -Recurse -Force
            Write-LzAwsVerbose "Cleaned DockerPackages folder"
        }

        # Create DockerPackages folder
        if (-not (Test-Path $dockerPackagesPath)) {
            Write-Host "Creating DockerPackages folder..."
            New-Item -ItemType Directory -Path $dockerPackagesPath -Force | Out-Null
            Write-LzAwsVerbose "Created DockerPackages folder"
        }

        # Step 1: Run dotnet restore to ensure all packages are cached
        Write-Host "Running dotnet restore to populate NuGet cache..."
        Write-LzAwsVerbose "Running: dotnet restore $ProjectPath --verbosity quiet"
        dotnet restore $ProjectPath --verbosity quiet
        if ($LASTEXITCODE -ne 0) {
            $errorMessage = @"
Error: dotnet restore failed
Function: Sync-DockerPackages
Hints:
  - Ensure the .csproj file exists at: $ProjectPath
  - Check that dotnet SDK is installed: dotnet --version
  - Verify all package sources are accessible
"@
            throw $errorMessage
        }
        Write-LzAwsVerbose "dotnet restore completed successfully"

        # Step 2: Parse project.assets.json to get ALL package dependencies (including transitive)
        Write-Host "Analyzing package dependencies from project.assets.json..."
        Write-LzAwsVerbose "Parsing project.assets.json for package dependencies"

        $projectDir = Split-Path $ProjectPath -Parent
        $assetsJsonPath = Join-Path $projectDir "obj/project.assets.json"

        if (-not (Test-Path $assetsJsonPath)) {
            $errorMessage = @"
Error: project.assets.json not found
Function: Sync-DockerPackages
Hints:
  - Expected location: $assetsJsonPath
  - Ensure dotnet restore completed successfully
  - Check that the project file path is correct
"@
            throw $errorMessage
        }

        $assetsJson = Get-Content $assetsJsonPath -Raw | ConvertFrom-Json
        Write-LzAwsVerbose "Successfully parsed project.assets.json"

        # Step 3: Get NuGet global packages location
        Write-LzAwsVerbose "Getting NuGet global packages location"
        $nugetGlobalPackages = dotnet nuget locals global-packages --list | Select-String "global-packages:" | ForEach-Object { $_.ToString().Replace("global-packages:", "").Trim() }
        Write-Host "NuGet global cache: $nugetGlobalPackages"
        Write-LzAwsVerbose "NuGet cache location: $nugetGlobalPackages"

        # Step 3.5: Get local package sources from _Dev/Nuget.Config
        Write-LzAwsVerbose "Checking for local package sources in Nuget.Config"
        $localPackageSources = @()
        $devNugetConfig = "../../Nuget.Config"
        if (Test-Path $devNugetConfig) {
            Write-Host "Found _Dev/Nuget.Config, checking for local package sources..."
            Write-LzAwsVerbose "Found Nuget.Config at $devNugetConfig"
            [xml]$nugetConfig = Get-Content $devNugetConfig
            foreach ($source in $nugetConfig.configuration.packageSources.add) {
                if ($source.value -like "./*" -or $source.value -like "../*") {
                    # Resolve relative path from _Dev directory
                    $resolvedPath = Resolve-Path (Join-Path "../../" $source.value) -ErrorAction SilentlyContinue
                    if ($resolvedPath -and (Test-Path $resolvedPath)) {
                        $localPackageSources += $resolvedPath.Path
                        Write-Host "  Found local source: $($source.key) -> $($resolvedPath.Path)"
                        Write-LzAwsVerbose "Added local package source: $($resolvedPath.Path)"
                    }
                }
            }
        }
        Write-Host ""

        # Step 4: Collect all unique packages from libraries section
        # project.assets.json has a "libraries" section with all packages (NuGet and project references)
        Write-LzAwsVerbose "Collecting unique packages from project.assets.json"
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
        Write-LzAwsVerbose "Collected $($packageDict.Count) unique NuGet packages"
        Write-Host ""

        # Step 5: Copy packages from cache to DockerPackages
        Write-Host "Copying packages from NuGet cache and local sources..."
        Write-LzAwsVerbose "Starting package copy operation"
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
                $destFile = Join-Path $dockerPackagesPath "$pkgName.$pkgVersion.nupkg"

                if (-not (Test-Path $destFile)) {
                    Copy-Item $nupkgFile $destFile -Force
                    $copiedCount++
                    Write-Host "  [+] $pkgName $pkgVersion (from cache)"
                    Write-LzAwsVerbose "Copied from cache: $pkgName $pkgVersion"
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
                        $destFile = Join-Path $dockerPackagesPath "$pkgName.$pkgVersion.nupkg"

                        if (-not (Test-Path $destFile)) {
                            Copy-Item $localNupkg $destFile -Force
                            $copiedCount++
                            Write-Host "  [+] $pkgName $pkgVersion (from local)"
                            Write-LzAwsVerbose "Copied from local source: $pkgName $pkgVersion"
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
                Write-LzAwsVerbose "Package not found in any source: $pkgName $pkgVersion"
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
        Write-Host "Location: $dockerPackagesPath"
        Write-Host "======================================"
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Update nuget.config to point to DockerPackages"
        Write-Host "  2. Run docker build"
        Write-Host ""

        Write-LzAwsVerbose "Package preparation completed successfully"
        return $true
    }
    catch {
        Write-Host ($_.Exception.Message) -ForegroundColor Red
        return $false
    }
}
