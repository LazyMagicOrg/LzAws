# LzAws.psm1
# This is a PowerShell module that provides AWS infrastructure management functionality.
# It handles module initialization, verbosity settings, and AWS module dependencies.

# Module-scoped variables to track state
$script:LzAwsVerbosePreference = $script:LzAwsVerbosePreference ?? "Continue"
$script:ModulesInitialized = $false                  # Tracks if modules are initialized
$ErrorView = "CategoryView"                          # Suppress call stack display

# Function to set module verbosity level
function Set-LzAwsVerbosity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Continue", "SilentlyContinue", "Stop", "Inquire")]
        [string]$Preference
    )
    
    $script:LzAwsVerbosePreference = $Preference
    # Add immediate verification
    if ($script:LzAwsVerbosePreference -ne $Preference) {
        Write-Warning "Failed to set verbosity preference"
        return
    }
    Write-Host "VERBOSE: LzAws module verbosity set to: $Preference" -ForegroundColor Yellow
}

# Function to get current verbosity setting
function Get-LzAwsVerbosity {
    [CmdletBinding()]
    param()
    
    return $script:LzAwsVerbosePreference
}

# Helper function for consistent verbose output across module
function Write-LzAwsVerbose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message
    )
    
    # Force read from script scope
    $current = $script:LzAwsVerbosePreference
    if ($current -eq 'Continue') {
        Write-Host "VERBOSE: $Message" -ForegroundColor Yellow
    }
}

# Function to remove any existing AWS modules to avoid conflicts
function Remove-ConflictingAWSModules {
    [CmdletBinding()]
    param()

    Write-LzAwsVerbose "Removing any conflicting AWS modules from session..."
    
    # Remove AWS modules from current session
    Get-Module | Where-Object {
        $_.Name -like 'AWS*' -or 
        $_.Name -like 'AWSPowerShell*' -or 
        $_.Name -like 'AWS.Tools.*'
    } | ForEach-Object {
        Write-LzAwsVerbose "Removing module from session: $($_.Name)"
        Remove-Module -Name $_.Name -Force -ErrorAction SilentlyContinue
    }

    # Force garbage collection
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    
    Write-LzAwsVerbose "Finished removing AWS modules from session"
}

# Define required AWS modules and their minimum versions
$script:ModuleRequirements = [ordered]@{
    'powershell-yaml' = '0.4.2'
    'AWS.Tools.Common' = '4.1.748'
    'AWS.Tools.Installer' = '1.0.2.5'   
    'AWS.Tools.SecurityToken' = '4.1.748'
    'AWS.Tools.S3' = '4.1.748'
    'AWS.Tools.CloudFormation' = '4.1.748'
    'AWS.Tools.CloudFrontKeyValueStore' = '4.1.748'
    'AWS.Tools.DynamoDBv2' = '4.1.136'
}

# Function to import a single AWS module
function Import-SingleAWSModule {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$ModuleName,
        [version]$MinimumVersion
    )

    try {
        Write-LzAwsVerbose "Importing module: $ModuleName"
        
        # Check if module needs to be installed/updated
        $installedModule = Get-Module -Name $ModuleName -ListAvailable | 
                          Sort-Object Version -Descending | 
                          Select-Object -First 1

        if (-not $installedModule -or $installedModule.Version -lt $MinimumVersion) {
            Write-LzAwsVerbose "Installing/updating $ModuleName to minimum version $MinimumVersion..."
            Install-Module -Name $ModuleName -MinimumVersion $MinimumVersion -Force -AllowClobber -Scope CurrentUser
        }

        Import-Module -Name $ModuleName -MinimumVersion $MinimumVersion -Force -DisableNameChecking
        Write-LzAwsVerbose "Successfully imported $ModuleName"
        return $true
    }
    catch {
        Write-Error "Failed to import module $ModuleName. Error: $_"
        return $false
    }
}

# Function to initialize all required AWS modules
function Initialize-LzAwsModules {
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    
    if ($script:ModulesInitialized -and -not $Force) { 
        Write-LzAwsVerbose "Modules already initialized"
        return 
    }

    Remove-ConflictingAWSModules

    Write-LzAwsVerbose "Importing required modules..."
    $failedImports = @()
    foreach ($module in $script:ModuleRequirements.Keys) {
        if (-not (Import-SingleAWSModule -ModuleName $module -MinimumVersion $script:ModuleRequirements[$module])) {
            $failedImports += $module
        }
    }

    if ($failedImports.Count -gt 0) {
        $script:ModulesInitialized = $false
        $failedList = $failedImports -join ", "
        throw "Failed to import the following required modules: $failedList"
    }

    $script:ModulesInitialized = $true
    Write-LzAwsVerbose "AWS modules initialized successfully"
}

# Function to reset module state
function Reset-LzAwsModules {
    [CmdletBinding()]
    param()
    
    Write-LzAwsVerbose "Resetting AWS modules..."
    $script:ModulesInitialized = $false
    Remove-ConflictingAWSModules
    Initialize-LzAwsModules -Force
    Write-LzAwsVerbose "AWS modules reset completed"
}

# Initialize modules when the module is imported
try {
    Initialize-LzAwsModules
}
catch {
    Write-Error "Failed to initialize LzAws module: $_"
    throw
}

# Set up module structure and import functions
$FunctionsPath = $PSScriptRoot
$PrivatePath = Join-Path $FunctionsPath "Private"
$PublicPath = Join-Path $FunctionsPath "Public"

# Create Private and Public directories if needed
if (!(Test-Path $PrivatePath)) {
    New-Item -ItemType Directory -Path $PrivatePath -Force | Out-Null
    Write-LzAwsVerbose "Created Private directory at $PrivatePath"
}
if (!(Test-Path $PublicPath)) {
    New-Item -ItemType Directory -Path $PublicPath -Force | Out-Null
    Write-LzAwsVerbose "Created Public directory at $PublicPath"
}

# Import all public and private functions
$Public = @(Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue)

foreach ($import in @($Public + $Private)) {
    try {
        . $import.FullName
    }
    catch {
        Write-Error -Message "Failed to import function $($import.FullName): $_"
    }
}

# Function to initialize help documentation
function Initialize-LzAwsHelp {
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    
    try {
        Write-LzAwsVerbose "Initializing help system..."
        
        $helpPath = Join-Path $PSScriptRoot "en-US"
        
        if (!(Test-Path $helpPath)) {
            New-Item -ItemType Directory -Path $helpPath -Force | Out-Null
        }

        # Create about help file
        $aboutHelpPath = Join-Path $helpPath "about_LzAws.help.txt"
        @"
TOPIC
    about_LzAws

SHORT DESCRIPTION
    AWS infrastructure management tools

LONG DESCRIPTION
    This module provides cmdlets for managing AWS infrastructure deployments.
    
    The following cmdlets are included:
    - Deploy-* cmdlets for deploying various AWS resources
    - Get-* cmdlets for retrieving information
"@ | Set-Content $aboutHelpPath

        Write-LzAwsVerbose "Help system initialized successfully"
    }
    catch {
        Write-Error "Failed to initialize help system: $_"
    }
}

# Initialize help system
try {
    Initialize-LzAwsHelp
}
catch {
    Write-Warning "Failed to initialize help system: $_"
}

# Export public functions and aliases
Export-ModuleMember -Function $Public.BaseName

$AliasesToExport = @()
if ($AliasesToExport) {
    Export-ModuleMember -Alias $AliasesToExport
}

# Clean up when module is removed
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    Write-LzAwsVerbose "Cleaning up AWS modules..."
    Remove-ConflictingAWSModules
}

# At the bottom of the file
Export-ModuleMember -Function @(
    'Set-LzAwsVerbosity',
    'Get-LzAwsVerbosity',
    'Write-LzAwsVerbose'
    # ... other functions ...
)