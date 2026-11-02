#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Inspect')]
param(
    [string] $Distribution = 'Ubuntu-24.04',
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')][string] $ArchivePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string] $SHA256,
    [int] $MemoryLimitGB = 0,
    [Parameter(ParameterSetName = 'Install')][switch] $EnableStartup
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WSLSetup.psm1') -Force
Assert-GrafttyWSLDistribution -Name $Distribution
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this entry point in PowerShell on Windows 11.' }
$registration = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
    Get-ItemProperty | Where-Object { $_.DistributionName -ceq $Distribution })
if ($registration.Count -ne 1 -or $registration[0].Version -ne 2) {
    throw "Install a WSL2 distribution first: wsl --install -d $Distribution. Finish its non-root user setup before retrying."
}
$action = if ($PSCmdlet.ParameterSetName -eq 'Install') { 'install' } else { 'inspect' }
$request = @{ action = $action }
if ($action -eq 'install') {
    $archive = Get-Item -LiteralPath $ArchivePath
    if ($archive.PSIsContainer -or (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash -ine $SHA256) {
        throw 'Archive SHA-256 mismatch. Obtain the expected digest from a trusted release source.'
    }
    $request.archivePath = $archive.FullName
    $request.sha256 = $SHA256
    $request.enableStartup = [bool]$EnableStartup
}
$physicalGB = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
$configuration = @{ Changed = $false; RestartRequired = $false; BackupPath = $null }
# Validate the request and guest before changing global WSL settings.
$inspection = Invoke-GrafttyWSL -Executable (Join-Path $env:SystemRoot 'System32\wsl.exe') -Distribution $Distribution -ProgramPath (Join-Path $PSScriptRoot 'wsl-install.py') -Request @{ action = 'inspect' }
if ($MemoryLimitGB -ne 0) {
    $configuration = Update-GrafttyWSLMemory -Path (Join-Path $env:USERPROFILE '.wslconfig') -MemoryGB $MemoryLimitGB -PhysicalMemoryGB $physicalGB
}
$result = if ($action -eq 'inspect') { $inspection } else {
    Invoke-GrafttyWSL -Executable (Join-Path $env:SystemRoot 'System32\wsl.exe') -Distribution $Distribution -ProgramPath (Join-Path $PSScriptRoot 'wsl-install.py') -Request $request
}
$result | Add-Member -NotePropertyName windowsPhysicalMemoryGB -NotePropertyValue $physicalGB
$result | Add-Member -NotePropertyName windowsLogicalCPUs -NotePropertyValue (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$result | Add-Member -NotePropertyName recommendedMemoryLimitGB -NotePropertyValue ([Math]::Max(1, [Math]::Floor($physicalGB - 8)))
$result | Add-Member -NotePropertyName configuration -NotePropertyValue $configuration
$startup = if ($EnableStartup) { Enable-GrafttyWSLStartup -Distribution $Distribution } else { @{ Enabled = $false } }
$result | Add-Member -NotePropertyName startup -NotePropertyValue $startup
$result | ConvertTo-Json -Depth 6
if ($configuration.RestartRequired) {
    Write-Warning 'WSL memory settings changed. They take effect after WSL restarts. No running distribution was stopped.'
}
