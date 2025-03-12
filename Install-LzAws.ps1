[CmdletBinding(DefaultParameterSetName='Scope')]
param(
    [Parameter(ParameterSetName='Scope')]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [Parameter(ParameterSetName='Path')]
    [string]$Path,

    [switch]$Force
)

$moduleName = "LzAws"

function Get-DefaultModulePath {
    param (
        [string]$Scope
    )

    # Get the proper module path based on scope
    switch ($Scope) {
        'CurrentUser' {
            if ($IsWindows -or (!$IsLinux -and !$IsMacOS)) {
                # PowerShell 7+ on Windows
                Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
            }
            else {
                # Linux/MacOS
                Join-Path $HOME '.local/share/powershell/Modules'
            }
        }
        'AllUsers' {
            if ($IsWindows -or (!$IsLinux -and !$IsMacOS)) {
                # Windows
                'C:\Program Files\PowerShell\Modules'
            }
            elseif ($IsMacOS) {
                '/usr/local/share/powershell/Modules'
            }
            else {
                # Linux
                '/usr/local/share/powershell/Modules'
            }
        }
    }
}

try {
    # Determine installation path
    $modulePath = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Path
    }
    else {
        $defaultPath = Get-DefaultModulePath -Scope $Scope
        Join-Path $defaultPath $moduleName
    }

    # Check if AllUsers installation requires elevation
    if ($Scope -eq 'AllUsers' -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Installing to AllUsers scope requires elevated privileges. Please run PowerShell as Administrator."
    }

    Write-Host "Installing $moduleName module to: $modulePath"

    # Remove existing module if loaded
    if (Get-Module $moduleName) {
        Remove-Module $moduleName -Force
    }

    # Check if module directory exists
    if (Test-Path $modulePath) {
        if ($Force) {
            Remove-Item -Path $modulePath -Recurse -Force -ErrorAction Stop
            Write-Verbose "Removed existing module directory"
        }
        else {
            throw "Module directory already exists. Use -Force to overwrite."
        }
    }

    # Create module directory
    New-Item -ItemType Directory -Path $modulePath -Force -ErrorAction Stop | Out-Null
    Write-Verbose "Created module directory: $modulePath"

    # Copy module files and folders
    $sourcePath = Get-Location
    
    # Copy root files
    Get-ChildItem -Path $sourcePath -File | ForEach-Object {
        if ($_.Name -ne 'Install-LzAws.ps1') {
            Copy-Item -Path $_.FullName -Destination $modulePath -Force -ErrorAction Stop
            Write-Verbose "Copied file: $($_.Name)"
        }
    }
    
    # Copy Public and Private folders
    @('Public', 'Private') | ForEach-Object {
        $folderPath = Join-Path $sourcePath $_
        if (Test-Path $folderPath) {
            $destinationPath = Join-Path $modulePath $_
            Copy-Item -Path $folderPath -Destination $modulePath -Recurse -Force -ErrorAction Stop
            Write-Verbose "Copied folder: $_"
            
            # List files copied in this folder
            Get-ChildItem -Path $folderPath -File | ForEach-Object {
                Write-Verbose "  - $($_.Name)"
            }
        }
    }

    Write-Host "`nModule installation completed successfully" -ForegroundColor Green
    Write-Host "To use the module, restart your PowerShell session and run:"
    Write-Host "Import-Module $moduleName" -ForegroundColor Cyan

}
catch {
    Write-Error "Installation failed: $_"
    return
}