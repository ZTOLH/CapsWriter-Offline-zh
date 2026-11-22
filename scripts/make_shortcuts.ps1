$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$startup = [Environment]::GetFolderPath('Startup')
$desk = [Environment]::GetFolderPath('Desktop')
$sh = New-Object -ComObject WScript.Shell

# autostart in user Startup folder
$lnk = $sh.CreateShortcut((Join-Path $startup 'CapsWriter 语音输入（自启动）.lnk'))
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + (Join-Path $root 'start_supervisor.vbs') + '"'
$lnk.WorkingDirectory = $root
$lnk.IconLocation = (Join-Path $root 'client\CapsWriter-Offline-Client\start_client.exe') + ',0'
$lnk.Description = '启动 CapsWriter 离线语音输入（服务端+客户端+守护）'
$lnk.WindowStyle = 7
$lnk.Save()

# desktop shortcuts
$lnk = $sh.CreateShortcut((Join-Path $desk 'CapsWriter 语音输入.lnk'))
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + (Join-Path $root 'start_supervisor.vbs') + '"'
$lnk.WorkingDirectory = $root
$lnk.IconLocation = (Join-Path $root 'client\CapsWriter-Offline-Client\start_client.exe') + ',0'
$lnk.Description = '启动 CapsWriter 离线语音输入（服务端+客户端+守护）'
$lnk.WindowStyle = 7
$lnk.Save()

$lnk = $sh.CreateShortcut((Join-Path $desk 'CapsWriter 停止.lnk'))
$lnk.TargetPath = 'C:\Windows\System32\cmd.exe'
$lnk.Arguments = '/c "' + (Join-Path $root 'stop_caps.bat') + '"'
$lnk.WorkingDirectory = $root
$lnk.IconLocation = 'C:\Windows\System32\shell32.dll,27'
$lnk.Description = '停止 CapsWriter 服务端、客户端与守护进程'
$lnk.WindowStyle = 7
$lnk.Save()

foreach ($old in @('CapsWriter 语音输入（客户端）.lnk','CapsWriter 识别服务端.lnk')) {
  $p = Join-Path $desk $old
  if (Test-Path $p) { Remove-Item -Force $p; Write-Output ("removed old: " + $old) }
}
Write-Output '--- startup ---'; Get-ChildItem $startup -Filter *.lnk | Select-Object -ExpandProperty Name
Write-Output '--- desktop ---'; Get-ChildItem $desk -Filter CapsWriter*.lnk | Select-Object -ExpandProperty Name