# ============================================================
#  USB/IP Print Client GUI  (Windows PowerShell 5.1 + WinForms)
#  Bundled client: usbip-win 0.3.6-dev (usbip.exe in this folder)
#
#  Launch with the elevated launcher "USBIP-Client.bat".
#  Settings persist in usbip-gui.ini next to this file.
# ============================================================

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:usbip = Join-Path $script:dir 'usbip.exe'
$script:ini   = Join-Path $script:dir 'usbip-gui.ini'
$script:bat   = Join-Path $script:dir 'USBIP-Client.bat'

# ---------- config load ----------
$cfg = @{ ip = '192.168.137.194'; busid = ''; interval = 15 }
if (Test-Path $ini) {
    Get-Content $ini | ForEach-Object {
        if     ($_ -match '^\s*ip\s*=\s*(.+?)\s*$')        { $cfg.ip       = $Matches[1] }
        elseif ($_ -match '^\s*busid\s*=\s*(.*?)\s*$')     { $cfg.busid    = $Matches[1] }
        elseif ($_ -match '^\s*interval\s*=\s*(\d+)\s*$')  { $cfg.interval = [int]$Matches[1] }
    }
}
function Save-Cfg {
    Set-Content -Path $ini -Encoding ASCII -Value @(
        "ip=$($cfg.ip)",
        "busid=$($cfg.busid)",
        "interval=$($cfg.interval)"
    )
}

# ---------- helpers ----------
function Run-Usbip([string]$argline) {
    if (-not (Test-Path $usbip)) {
        return [pscustomobject]@{ Exit = 1; Out = ''; Err = "usbip.exe not found in $dir" }
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName               = $usbip
    $p.StartInfo.Arguments              = $argline
    $p.StartInfo.UseShellExecute        = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.StartInfo.CreateNoWindow         = $true
    [void]$p.Start()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

function Log([string]$msg) {
    $txtLog.AppendText("[" + (Get-Date -Format 'HH:mm:ss') + "]  " + $msg + "`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
}

function Set-Status([string]$text, [System.Drawing.Color]$color) {
    $lblStatus.Text = $text
    $lblStatus.ForeColor = $color
}

function Get-Busid([string]$ip) {
    $r = Run-Usbip "list -r $ip"
    if ($r.Exit -ne 0) { return $null }
    $line = ($r.Out -split "`n" | Where-Object { $_ -match '^\s*\d+-\d+:' } | Select-Object -First 1)
    if ($line -match '^\s*(\d+-\d+):') { return $Matches[1] }
    return $null
}

# ---------- form ----------
$form                = New-Object System.Windows.Forms.Form
$form.Text           = 'USB/IP 打印客户端 (LBP2900 / ESP32)'
$form.Size           = New-Object System.Drawing.Size(560, 520)
$form.FormBorderStyle= 'FixedSingle'
$form.StartPosition  = 'CenterScreen'
$form.TopMost        = $false
$form.Font           = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# server ip row
$lblIp               = New-Object System.Windows.Forms.Label
$lblIp.Text          = '服务器 IP:'
$lblIp.Location      = New-Object System.Drawing.Point(15, 18)
$lblIp.AutoSize      = $true
$form.Controls.Add($lblIp)

$txtIp               = New-Object System.Windows.Forms.TextBox
$txtIp.Text          = $cfg.ip
$txtIp.Location      = New-Object System.Drawing.Point(90, 14)
$txtIp.Size          = New-Object System.Drawing.Size(160, 24)
$form.Controls.Add($txtIp)

$lblBusid            = New-Object System.Windows.Forms.Label
$lblBusid.Text       = '设备 busid:'
$lblBusid.Location   = New-Object System.Drawing.Point(270, 18)
$lblBusid.AutoSize   = $true
$form.Controls.Add($lblBusid)

$txtBusid            = New-Object System.Windows.Forms.TextBox
$txtBusid.Text       = $cfg.busid
$txtBusid.Location   = New-Object System.Drawing.Point(355, 14)
$txtBusid.Size       = New-Object System.Drawing.Size(80, 24)
$form.Controls.Add($txtBusid)

$lblHint             = New-Object System.Windows.Forms.Label
$lblHint.Text        = '(留空 = 自动探测)'
$lblHint.Location    = New-Object System.Drawing.Point(443, 18)
$lblHint.AutoSize    = $true
$lblHint.ForeColor   = [System.Drawing.Color]::Gray
$form.Controls.Add($lblHint)

# status strip
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = '● 未连接'
$lblStatus.Location  = New-Object System.Drawing.Point(15, 50)
$lblStatus.AutoSize  = $true
$lblStatus.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
$form.Controls.Add($lblStatus)

# buttons
$btnConnect               = New-Object System.Windows.Forms.Button
$btnConnect.Text          = '连接并保持在线'
$btnConnect.Location      = New-Object System.Drawing.Point(15, 80)
$btnConnect.Size          = New-Object System.Drawing.Size(160, 32)
$form.Controls.Add($btnConnect)

$btnDetach                = New-Object System.Windows.Forms.Button
$btnDetach.Text           = '断开'
$btnDetach.Location       = New-Object System.Drawing.Point(185, 80)
$btnDetach.Size           = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnDetach)

$btnRefresh               = New-Object System.Windows.Forms.Button
$btnRefresh.Text          = '查看端口状态'
$btnRefresh.Location      = New-Object System.Drawing.Point(285, 80)
$btnRefresh.Size          = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnRefresh)

$chkAuto                  = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text             = '开机自动连接'
$chkAuto.Location         = New-Object System.Drawing.Point(420, 84)
$chkAuto.AutoSize         = $true
$form.Controls.Add($chkAuto)

# log
$txtLog                   = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline         = $true
$txtLog.ReadOnly          = $true
$txtLog.ScrollBars        = 'Vertical'
$txtLog.Location          = New-Object System.Drawing.Point(15, 125)
$txtLog.Size              = New-Object System.Drawing.Size(515, 340)
$txtLog.Font              = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

# ---------- actions ----------
$script:watching = $false
$script:lastAttachOk = $false

$btnConnect.Add_Click({
    $cfg.ip       = $txtIp.Text.Trim()
    $cfg.busid    = $txtBusid.Text.Trim()
    Save-Cfg

    $r = Run-Usbip 'install'
    if ($r.Exit -eq 0) { Log 'vhci 驱动已就绪' }
    else {
        $msg = $r.Err.Trim(); if (-not $msg) { $msg = $r.Out.Trim() }
        Log "驱动安装输出: $msg"
    }

    if (-not $cfg.busid) {
        Log "正在探测 $($cfg.ip) 上的设备..."
        $b = Get-Busid $cfg.ip
        if (-not $b) {
            Log "[错误] 未发现设备。请确认打印机已插好、ESP32 已联网。"
            return
        }
        $cfg.busid = $b
        $txtBusid.Text = $b
        Save-Cfg
    }
    Log "目标: $($cfg.ip) / busid $($cfg.busid)"

    $r = Run-Usbip "attach -r $($cfg.ip) -b $($cfg.busid)"
    if ($r.Exit -eq 0) {
        $script:lastAttachOk = $true
        Set-Status '● 已连接' ([System.Drawing.Color]::ForestGreen)
        Log '[OK] 连接成功。首次使用请在设备管理器中确认出现 "USB 打印支持"。'
    } else {
        $msg = $r.Err.Trim(); if (-not $msg) { $msg = $r.Out.Trim() }
        Log "[连接失败] $msg"
        Log '看门狗将持续重试...'
    }

    if (-not $watching) {
        $watching = $true
        $timer.Start()
        Log "看门狗已启动（每 $($cfg.interval) 秒检查一次，掉线自动重连）。"
    }
})

$btnDetach.Add_Click({
    $watching = $false
    $timer.Stop()
    $r = Run-Usbip 'detach -p *'
    $script:lastAttachOk = $false
    Set-Status '● 未连接' ([System.Drawing.Color]::Firebrick)
    Log '[OK] 已断开所有 USB/IP 设备。'
})

$btnRefresh.Add_Click({
    $r = Run-Usbip 'port'
    Log "---- usbip.exe port ----"
    if ($r.Out.Trim()) { $r.Out.Trim() -split "`n" | ForEach-Object { Log $_.TrimEnd() } }
    if ($r.Err.Trim()) { $r.Err.Trim() -split "`n" | ForEach-Object { Log $_.TrimEnd() } }
})

# autostart checkbox (scheduled task, no UAC at logon)
$chkAuto.Add_Click({
    $task = 'USBIP-PrintClient'
    if ($chkAuto.Checked) {
        $arg = "/create /f /tn $task /tr `"$bat`" /sc onlogon /rl highest"
        $r = Run-ExternalSchTasks $arg
        if ($r) { Log '[OK] 已注册开机自动连接（登录时自动运行，无需 UAC）。' }
        else    { Log '[警告] 注册开机任务失败。' ; $chkAuto.Checked = $false }
    } else {
        $r = Run-ExternalSchTasks "/delete /f /tn $task"
        Log '[OK] 已取消开机自动连接。'
    }
})

function Run-ExternalSchTasks([string]$argline) {
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = 'schtasks.exe'
    $p.StartInfo.Arguments = $argline
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    [void]$p.Start()
    $p.WaitForExit()
    return ($p.ExitCode -eq 0)
}

# watchdog timer
$timer               = New-Object System.Windows.Forms.Timer
$timer.Interval      = $cfg.interval * 1000
$timer.Add_Tick({
    if (-not $watching) { return }
    $r = Run-Usbip "attach -r $($cfg.ip) -b $($cfg.busid)"
    if ($r.Exit -eq 0) {
        if (-not $script:lastAttachOk) {
            Log '[OK] 设备已重新连接。'
            Set-Status '● 已连接' ([System.Drawing.Color]::ForestGreen)
        }
        $script:lastAttachOk = $true
    } else {
        if ($script:lastAttachOk) {
            Log '[掉线] 设备丢失，持续重试中...'
            Set-Status '● 重连中...' ([System.Drawing.Color]::DarkOrange)
        }
        $script:lastAttachOk = $false
    }
})

# init state of autostart checkbox
$taskQuery = New-Object System.Diagnostics.Process
$taskQuery.StartInfo.FileName = 'schtasks.exe'
$taskQuery.StartInfo.Arguments = '/query /tn USBIP-PrintClient'
$taskQuery.StartInfo.UseShellExecute = $false
$taskQuery.StartInfo.CreateNoWindow = $true
[void]$taskQuery.Start()
$taskQuery.WaitForExit()
if ($taskQuery.ExitCode -eq 0) { $chkAuto.Checked = $true }

Log '提示: 右上角"查看端口状态"可查看当前 attach 情况。'
Log '首次使用: 连接成功后安装佳能 LBP2900 驱动，之后即可直接打印。'

[void]$form.ShowDialog()
