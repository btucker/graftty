$ErrorActionPreference = 'Stop'
$testDirectory = 'C:\graftty-tests'
& (Join-Path $testDirectory 'test-wsl-setup.ps1')
& (Join-Path $testDirectory 'test-wsl-setup.ps1') -StartupOnly
Import-Module (Join-Path $testDirectory 'WSLSetup.psm1') -Force

# Exercise real Windows Task Scheduler registration through the production
# helper. The random distribution does not exist, so this cannot start Linux
# workloads. Remove only this test's task, even if an assertion fails.
$distribution = 'Graftty-Smoke-' + [guid]::NewGuid().ToString('N')
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$definition = Get-GrafttyWSLStartupDefinition -Distribution $distribution -SystemDirectory ([Environment]::GetFolderPath('System')) -UserSID $sid
try {
    $registration = Enable-GrafttyWSLStartup -Distribution $distribution
    $task = Get-ScheduledTask -TaskName $registration.TaskName
    if ($task.Principal.RunLevel -ne 'Limited' -or $task.Principal.LogonType -ne 'Interactive') {
        throw 'Startup task requested the wrong security context'
    }
    $user = $task.Principal.UserId
    $actualSID = if ($user.StartsWith('S-1-')) { $user } else {
        ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if ($actualSID -ne $sid) { throw 'Startup task is not bound to this Windows user' }
    if ($task.Actions.Arguments -cne $definition.Arguments) { throw 'Startup task changed its command' }
} finally {
    $task = Get-ScheduledTask -TaskName $definition.TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $definition.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $definition.TaskName -Confirm:$false
    }
}

# Prove that the real Windows entry point rejects a WSL1 registration before
# trying to execute Linux or install an archive. This key is test-owned.
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\' + [guid]::NewGuid().ToString('B')
try {
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DistributionName -Value $distribution -PropertyType String | Out-Null
    New-ItemProperty -Path $key -Name Version -Value 1 -PropertyType DWord | Out-Null
    $rejected = $false
    try { & (Join-Path $testDirectory 'Install-GrafttyWSL.ps1') -Distribution $distribution | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch 'WSL2 distribution') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'The installer accepted a WSL1 registration' }
} finally { Remove-Item -Path $key -Force -ErrorAction SilentlyContinue }

$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$result = [ordered]@{
    windowsVersion = [Environment]::OSVersion.Version.ToString()
    architecture = $env:PROCESSOR_ARCHITECTURE
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    virtualizationFirmwareEnabled = $processor.VirtualizationFirmwareEnabled
    resourceConfiguration = 'passed'
    startupDefinition = 'passed'
    taskRegistration = 'passed'
    wsl1Rejected = 'passed'
    wsl2Runtime = 'not-run: requires nested virtualization or a native Windows host'
}
$json = $result | ConvertTo-Json
$json | Set-Content -LiteralPath (Join-Path $testDirectory 'results.json') -Encoding UTF8
Write-Output 'GRAFTTY_WINDOWS_TEST_RESULTS'
Write-Output $json
