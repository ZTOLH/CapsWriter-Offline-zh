# Stop CapsWriter-Offline: supervisor first, then server/client processes.
$Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'supervisor.log'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$killed = @()
try {
    $sup = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*supervisor.ps1*' -and $_.Name -like 'powershell*'
    }
    foreach ($p in $sup) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed += ('supervisor:' + $p.ProcessId) } catch { }
    }
} catch { }
Start-Sleep -Milliseconds 800

foreach ($name in @('start_server', 'start_client')) {
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += ($name + ':' + $p.Id) } catch { }
    }
}

$msg = ('{0} stopped: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($killed -join ', '))
if ($killed.Count -eq 0) { $msg = ('{0} stopped: nothing was running' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) }
Add-Content -LiteralPath $LogFile -Value $msg -Encoding UTF8
Write-Output ('CapsWriter stopped. ' + ($killed -join ', '))
