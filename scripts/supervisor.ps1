# CapsWriter-Offline supervisor
# Keeps start_server.exe (3 processes) and start_client.exe alive,
# restarts the server when its manager pipe breaks, and restarts the
# client when it loses its websocket connection.
$ErrorActionPreference = 'Continue'
$Root       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ServerDir  = Join-Path $Root 'server\CapsWriter-Offline'
$ClientDir  = Join-Path $Root 'client\CapsWriter-Offline-Client'
$LogDir     = Join-Path $Root 'logs'
$LogFile    = Join-Path $LogDir 'supervisor.log'
$ServerLog  = Join-Path $ServerDir 'logs\server_latest.log'
$PauseFlag  = Join-Path $Root 'pause.flag'
$Port       = 6016

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$mutex = New-Object System.Threading.Mutex($false, 'Global\CapsWriterOfflineSupervisor')
if (-not $mutex.WaitOne(0)) { exit 0 }

# --- start child processes with CREATE_NO_WINDOW so no console window shows up ---
$script:HasNoWindow = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshNoWindow {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars;
        public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2;
        public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    public static int Start(string exe, string workdir) {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        uint flags = 0x08000000; // CREATE_NO_WINDOW
        if (!CreateProcess(exe, null, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workdir, ref si, out pi)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return pi.dwProcessId;
    }
}
'@ -ErrorAction Stop
    $script:HasNoWindow = $true
} catch {
    Write-Log ('no-window helper unavailable, falling back: ' + $_.Exception.Message)
}

function Start-NoWindow([string]$exe, [string]$dir) {
    if ($script:HasNoWindow) {
        try { [DshNoWindow]::Start($exe, $dir) | Out-Null; return $true } catch {
            Write-Log ('CreateProcess failed, falling back: ' + $_.Exception.Message)
        }
    }
    try { Start-Process -FilePath $exe -WorkingDirectory $dir -WindowStyle Hidden | Out-Null; return $true } catch {
        Write-Log ('start failed: ' + $_.Exception.Message); return $false
    }
}

function Write-Log([string]$msg) {
    $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1048576)) {
            Move-Item -Force $LogFile ($LogFile + '.1')
        }
    } catch { }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-PidsByName([string]$name) {
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}

function Stop-Pids([int[]]$ids) {
    foreach ($p in $ids) {
        try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Test-Tcp([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $port)
        if (-not $task.Wait(1500)) { return $false }
        return [bool]$client.Connected
    } catch { return $false } finally { try { $client.Dispose() } catch { } }
}

function Test-ClientConnected() {
    try {
        $conns = Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction Stop
        return [bool](@($conns).Count -gt 0)
    } catch {
        $out = & netstat -ano 2>$null | Select-String -Pattern (":$Port\s+.*ESTABLISHED")
        return [bool]($out -ne $null)
    }
}

function Start-Server {
    if (Start-NoWindow (Join-Path $ServerDir 'start_server.exe') $ServerDir) {
        $script:lastServerStart = Get-Date
        Write-Log 'server launched'
    }
}

# Healthy server = one launcher process plus its worker children (>=3 processes,
# exactly one process that is not a child of another start_server.exe).
function Test-ServerTree {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='start_server.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @{ ok = $false; reason = 'no processes' } }
    $ids = @($procs | ForEach-Object { [int]$_.ProcessId })
    $roots = @($procs | Where-Object { $ids -notcontains [int]$_.ParentProcessId })
    $ok = ($procs.Count -ge 3) -and ($roots.Count -eq 1)
    return @{ ok = $ok; reason = ('procs=' + $procs.Count + ' roots=' + $roots.Count) }
}

function Start-Client {
    if (Start-NoWindow (Join-Path $ClientDir 'start_client.exe') $ClientDir) { Write-Log 'client launched' }
}

$script:serverLogPos = 0
if (Test-Path $ServerLog) { $script:serverLogPos = [int64](Get-Item $ServerLog).Length }
$script:portFail = 0
$script:clientDeadChecks = 0
$script:treeFail = 0
$script:lastServerStart = (Get-Date).AddMinutes(-10)
$script:lastServerRestart = (Get-Date).AddMinutes(-10)
$script:lastClientRestart = (Get-Date).AddMinutes(-10)

function Read-NewServerLog {
    if (-not (Test-Path $ServerLog)) { return '' }
    $len = [int64](Get-Item $ServerLog).Length
    if ($len -lt $script:serverLogPos) { $script:serverLogPos = 0 }
    if ($len -eq $script:serverLogPos) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($ServerLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Seek($script:serverLogPos, [System.IO.SeekOrigin]::Begin) | Out-Null
        $count = [int]($len - $script:serverLogPos)
        if ($count -gt 262144) { $count = 262144 }
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $script:serverLogPos = $script:serverLogPos + $read
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch { return '' } finally { if ($fs) { $fs.Dispose() } }
}

Write-Log ('supervisor alive (pid ' + $PID + ')')

while ($true) {
    try {
        if (Test-Path $PauseFlag) { Start-Sleep -Seconds 5; continue }

        # ---- server ----
        $serverPids = Get-PidsByName 'start_server'
        if ($serverPids.Count -eq 0) {
            Start-Server
            Start-Sleep -Seconds 4
            $serverPids = Get-PidsByName 'start_server'
        }

        $tcpOk = Test-Tcp $Port
        if ($tcpOk) { $script:portFail = 0 } else { $script:portFail = $script:portFail + 1 }

        # server process tree can rot while the port stays open (e.g. the launcher is
        # killed and the orphan workers keep listening but never answer tasks)
        $tree = Test-ServerTree
        $startupAge = ((Get-Date) - $script:lastServerStart).TotalSeconds
        if ($tree.ok -or $startupAge -lt 25) {
            $script:treeFail = 0
        } else {
            $script:treeFail = $script:treeFail + 1
        }

        $newText = Read-NewServerLog
        $pipeBroken = $false
        if ($newText -ne '' -and ($newText -match 'BrokenPipeError' -or $newText -match 'WinError 232')) {
            $pipeBroken = $true
        }

        $needRestart = $false
        $why = ''
        if ($pipeBroken) { $needRestart = $true; $why = 'broken pipe in server log' }
        elseif ($serverPids.Count -gt 0 -and (-not $tcpOk) -and $script:portFail -ge 12) {
            $needRestart = $true; $why = 'port 6016 down for ~60s'
        }
        elseif ($serverPids.Count -gt 0 -and $script:treeFail -ge 3) {
            $needRestart = $true; $why = ('broken process tree (' + $tree.reason + ')')
        }

        if ($needRestart) {
            if (((Get-Date) - $script:lastServerRestart).TotalSeconds -lt 25) {
                Write-Log ('restart suppressed (cooldown): ' + $why)
            } else {
                Write-Log ('restarting server: ' + $why)
                Stop-Pids (Get-PidsByName 'start_server')
                Start-Sleep -Seconds 2
                Stop-Pids (Get-PidsByName 'start_server')
                Start-Server
                $script:lastServerRestart = Get-Date
                $script:portFail = 0
                $serverPids = Get-PidsByName 'start_server'
                # the client must reconnect after a server restart
                Stop-Pids (Get-PidsByName 'start_client')
                Start-Sleep -Seconds 3
            }
        }

        # ---- client ----
        $clientPids = Get-PidsByName 'start_client'
        if ($clientPids.Count -eq 0) {
            Start-Client
            Start-Sleep -Seconds 5
        } else {
            $clientTcpOk = Test-Tcp $Port
            $clientConnOk = Test-ClientConnected
            if ($clientTcpOk -and -not $clientConnOk) {
                $script:clientDeadChecks = $script:clientDeadChecks + 1
                if ($script:clientDeadChecks -eq 1) {
                    Write-Log ('client check failing: tcp=' + $clientTcpOk + ' conn=' + $clientConnOk)
                }
            } else {
                $script:clientDeadChecks = 0
            }
            if ($script:clientDeadChecks -ge 10 -and ((Get-Date) - $script:lastClientRestart).TotalSeconds -gt 30) {
                Write-Log 'client running but not connected -> restarting client'
                Stop-Pids (Get-PidsByName 'start_client')
                Start-Sleep -Seconds 2
                Start-Client
                $script:lastClientRestart = Get-Date
                $script:clientDeadChecks = 0
            }
        }
    } catch {
        Write-Log ('loop error: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds 4
}
