Set-StrictMode -Version Latest

function Assert-GrafttyWSLDistribution {
    param([string] $Name)
    # Used in a native command line, never in a shell expression.
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$') {
        throw 'Select a distribution name containing letters, digits, dots, underscores, or hyphens.'
    }
}

function Set-GrafttyWSLMemory {
    param([AllowEmptyString()][string] $Content, [int] $MemoryGB, [double] $PhysicalMemoryGB)
    if ($MemoryGB -lt 1 -or $PhysicalMemoryGB - $MemoryGB -lt 2) {
        throw 'The memory ceiling must be positive and leave at least 2 GB for Windows. Reserve more for other workloads.'
    }
    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($Content, '\r?\n')) { $lines.Add($line) }
    $section = -1
    $end = $lines.Count
    $memory = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[wsl2\]\s*(?:[#;].*)?$') {
            if ($section -ne -1) { throw 'Duplicate [wsl2] sections require manual review.' }
            $section = $index
        } elseif ($section -ge 0 -and $end -eq $lines.Count -and $lines[$index] -match '^\s*\[') {
            $end = $index
        }
        if ($section -ge 0 -and $index -lt $end -and $lines[$index] -match '^\s*memory\s*=') {
            if ($memory -ne -1) { throw 'Duplicate memory settings require manual review.' }
            $memory = $index
        }
    }
    if ($section -eq -1) {
        if ($Content.Length -eq 0) { return "[wsl2]${newline}memory=${MemoryGB}GB${newline}" }
        return $Content + $newline + '[wsl2]' + $newline + "memory=${MemoryGB}GB${newline}"
    }
    if ($memory -ge 0) {
        $lines[$memory] = [regex]::Replace($lines[$memory], '(?i)^(\s*memory\s*=\s*)[^#;]*?(\s*(?:[#;].*)?)$', "`${1}${MemoryGB}GB`${2}")
    } else {
        $lines.Insert($end, "memory=${MemoryGB}GB")
    }
    return $lines -join $newline
}

function Update-GrafttyWSLMemory {
    param([string] $Path, [int] $MemoryGB, [double] $PhysicalMemoryGB)
    $exists = [IO.File]::Exists($Path)
    $original = if ($exists) { [IO.File]::ReadAllText($Path) } else { '' }
    $updated = Set-GrafttyWSLMemory -Content $original -MemoryGB $MemoryGB -PhysicalMemoryGB $PhysicalMemoryGB
    if ($updated -ceq $original) { return @{ Changed = $false; RestartRequired = $false; BackupPath = $null } }
    $backup = if ($exists) { $Path + '.graftty-' + [guid]::NewGuid().ToString('N') + '.bak' } else { $null }
    $temporary = $Path + '.graftty-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        if ($exists) {
            # Replace publishes atomically and retains the original bytes as a backup.
            if ([IO.File]::ReadAllText($Path) -cne $original) { throw 'WSL settings changed during setup. Retry after reviewing them.' }
            [IO.File]::Replace($temporary, $Path, $backup)
        } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    return @{ Changed = $true; RestartRequired = $true; BackupPath = $backup }
}

function Invoke-GrafttyWSL {
    param([string] $Executable, [string] $Distribution, [string] $ProgramPath, [hashtable] $Request)
    Assert-GrafttyWSLDistribution -Name $Distribution
    $program = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ProgramPath))
    $body = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Compress)))
    # Only base64 appears in the shell program. Paths and JSON never become shell code.
    $inputText = "exec python3 -c 'exec(__import__(`"base64`").b64decode(`"$program`"))' '$body'`n"
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = "--distribution $Distribution --exec bash -s"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # The stdin program is ASCII, including both base64 values. Do not depend
    # on StandardInputEncoding, which Windows PowerShell's .NET lacks.
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($inputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill()
            throw 'WSL setup timed out. Check the Linux service status before retrying.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "WSL setup failed: $errors$output" }
        return $output | ConvertFrom-Json
    } finally { $process.Dispose() }
}

function Get-GrafttyWSLStartupDefinition {
    param([string] $Distribution, [string] $SystemDirectory, [string] $UserSID)
    Assert-GrafttyWSLDistribution -Name $Distribution
    if ($UserSID -notmatch '^S-1-[0-9-]+$') { throw 'A Windows user SID is required.' }
    $wsl = (Join-Path $SystemDirectory 'wsl.exe').Replace("'", "''")
    # The foreground Linux process keeps WSL active while the independent
    # systemd user service owns the host. No console window needs to stay open.
    $program = "`$p = Start-Process -FilePath '$wsl' -ArgumentList '--distribution $Distribution --exec /usr/bin/sleep infinity' -NoNewWindow -Wait -PassThru; exit `$p.ExitCode"
    return @{
        TaskName = "Graftty-WSL-$Distribution-$UserSID"
        Description = "Graftty WSL startup v1: $UserSID/$Distribution"
        Executable = Join-Path $SystemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
        UserSID = $UserSID
        LogonType = 'Interactive'
        RunLevel = 'Limited'
    }
}

function Enable-GrafttyWSLStartup {
    param([string] $Distribution)
    $definition = Get-GrafttyWSLStartupDefinition -Distribution $Distribution -SystemDirectory ([Environment]::GetFolderPath('System')) -UserSID ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $existing = Get-ScheduledTask -TaskName $definition.TaskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Description -cne $definition.Description) {
        throw 'A different task uses the Graftty startup name. Review it before retrying.'
    }
    $action = New-ScheduledTaskAction -Execute $definition.Executable -Argument $definition.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $definition.UserSID
    $principal = New-ScheduledTaskPrincipal -UserId $definition.UserSID -LogonType $definition.LogonType -RunLevel $definition.RunLevel
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $definition.TaskName -Description $definition.Description -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $definition.TaskName
    return @{ TaskName = $definition.TaskName; Scope = 'Current signed-in Windows user'; RuntimeValidated = $false }
}

Export-ModuleMember -Function Assert-GrafttyWSLDistribution, Set-GrafttyWSLMemory, Update-GrafttyWSLMemory, Invoke-GrafttyWSL, Get-GrafttyWSLStartupDefinition, Enable-GrafttyWSLStartup
