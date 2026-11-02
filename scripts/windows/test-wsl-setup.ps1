param([switch] $StartupOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WSLSetup.psm1') -Force

function Assert-True($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Expected rejection'
}

if ($StartupOnly) {
    $task = Get-GrafttyWSLStartupDefinition -Distribution Ubuntu-24.04 -SystemDirectory ([IO.Path]::GetTempPath()) -UserSID 'S-1-5-21-123-1001'
    Assert-True ($task.LogonType -eq 'Interactive') 'Startup must use the signed-in user'
    Assert-True ($task.RunLevel -eq 'Limited') 'Startup must not request elevation'
    Assert-True ($task.UserSID -eq 'S-1-5-21-123-1001') 'Task must bind the current user'
    $encoded = ($task.Arguments -split ' ')[-1]
    $program = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    Assert-True ($program.Contains('--distribution Ubuntu-24.04 --exec /usr/bin/sleep infinity')) 'Startup must retain a foreground WSL process'
    Assert-True ($program.Contains('-NoNewWindow')) 'Startup must not require a visible terminal'
    $other = Get-GrafttyWSLStartupDefinition -Distribution Ubuntu-24.04 -SystemDirectory ([IO.Path]::GetTempPath()) -UserSID 'S-1-5-21-123-1002'
    Assert-True ($task.TaskName -ne $other.TaskName) 'Users must not share a startup task'
    'WSL sign-in startup checks passed'
    exit 0
}

$original = "# keep me`r`n[wsl2]`r`nprocessors=12`r`nmemory=8GB # old`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
$updated = Set-GrafttyWSLMemory -Content $original -MemoryGB 56 -PhysicalMemoryGB 64
Assert-True ($updated.Contains("memory=56GB # old`r`n")) 'Memory must change'
Assert-True ($updated.Contains("processors=12`r`n")) 'CPU override must survive'
Assert-True ($updated.Contains("autoMemoryReclaim=gradual`r`n")) 'Other sections must survive'
Assert-True ($updated.StartsWith('# keep me')) 'Comments must survive'
Assert-True ((Set-GrafttyWSLMemory -Content $updated -MemoryGB 56 -PhysicalMemoryGB 64) -ceq $updated) 'Edits must be idempotent'
Assert-True ((Set-GrafttyWSLMemory -Content '' -MemoryGB 56 -PhysicalMemoryGB 64) -match '(?m)^memory=56GB') 'Empty file must work'
Assert-True ((Set-GrafttyWSLMemory -Content "[experimental]`nautoMemoryReclaim=gradual`n" -MemoryGB 56 -PhysicalMemoryGB 64).Contains('[wsl2]')) 'Missing section must work'
foreach ($text in @("[wsl2]`nmemory=8GB`nmemory=16GB", "[wsl2]`n[wsl2]", "[wsl2]`nmemory=8GB`n[WSL2]")) {
    Assert-Throws { Set-GrafttyWSLMemory -Content $text -MemoryGB 56 -PhysicalMemoryGB 64 }
}
Assert-Throws { Set-GrafttyWSLMemory -Content '' -MemoryGB 64 -PhysicalMemoryGB 64 }
Assert-Throws { Set-GrafttyWSLMemory -Content '' -MemoryGB 0 -PhysicalMemoryGB 64 }
Assert-Throws { Assert-GrafttyWSLDistribution -Name 'Ubuntu; touch injected' }
Assert-GrafttyWSLDistribution -Name 'Ubuntu-24.04'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('graftty-wsl-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $path = Join-Path $temporary '.wslconfig'
    [IO.File]::WriteAllText($path, $original)
    $result = Update-GrafttyWSLMemory -Path $path -MemoryGB 56 -PhysicalMemoryGB 64
    Assert-True ([IO.File]::ReadAllText($path) -ceq $updated) 'Publish must preserve content'
    Assert-True ([IO.File]::ReadAllText($result.BackupPath) -ceq $original) 'Backup must preserve original'
    Assert-True $result.RestartRequired 'Config changes require restart'
    $again = Update-GrafttyWSLMemory -Path $path -MemoryGB 56 -PhysicalMemoryGB 64
    Assert-True (-not $again.Changed) 'Repeated setup must not rewrite settings'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $wsl = Join-Path $temporary 'wsl fixture'
        $python = Join-Path $temporary 'request.py'
        [IO.File]::WriteAllText($wsl, "#!/bin/sh`n[ `"`$1`" = --distribution ] && [ `"`$3`" = --exec ] || exit 9`nshift 3`nexec `"`$@`"`n")
        & /bin/chmod +x $wsl
        [IO.File]::WriteAllText($python, 'import base64,json,sys; print(json.dumps(json.loads(base64.b64decode(sys.argv[1]))))')
        $request = @{ archivePath = "C:\工具\a 'quoted' `$literal`nline.tar.gz"; action = 'inspect' }
        $received = Invoke-GrafttyWSL -Executable $wsl -Distribution Ubuntu-24.04 -ProgramPath $python -Request $request
        Assert-True ($received.archivePath -ceq $request.archivePath) 'Paths must pass through stdin without shell interpretation'
        [IO.File]::WriteAllText($python, 'raise SystemExit(7)')
        Assert-Throws { Invoke-GrafttyWSL -Executable $wsl -Distribution Ubuntu-24.04 -ProgramPath $python -Request $request }
    }
} finally { [IO.Directory]::Delete($temporary, $true) }
'WSL resource configuration checks passed'
