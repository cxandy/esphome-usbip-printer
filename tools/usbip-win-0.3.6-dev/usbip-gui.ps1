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
# sanity check: discard a saved value that is not a valid IPv4 address
if ($cfg.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $cfg.ip = '' }
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

# ---------- device discovery ----------
function Find-Servers {
    $found = @()

    # 1) Fast path: resolve known mDNS host names (Win10+ resolves .local natively)
    foreach ($h in 'usbip-server.local', 'usbip-mfc7420.local') {
        try {
            $a = [System.Net.Dns]::GetHostAddresses($h) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                Select-Object -First 1
            if ($a) { $found += $a.IPAddressToString; break }
        } catch { }
    }
    if ($found) { return $found | Select-Object -Unique }

    # 2) Fallback: scan the local /24 for open TCP 3240 (USB/IP port)
    try {
        $local = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress      -notlike '127.*'     -and
                $_.IPAddress      -notlike '169.254.*' -and
                $_.PrefixOrigin   -ne 'WellKnown'
            } | Sort-Object InterfaceMetric | Select-Object -First 1
        if (-not $local) { return @() }
        $base = ($local.IPAddress -split '\.')[0..2] -join '.'
        Log "正在扫描网段 $base.0/24 的 3240 端口..."
        $pending = @()
        foreach ($i in 1..254) {
            $ip = "$base.$i"
            $c  = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $c.BeginConnect($ip, 3240, $null, $null)
                $pending += @{ IP = $ip; Client = $c; AR = $ar }
            } catch { $c.Close() }
        }
        # give the connects ~1.5 s in two passes, collect the ones that completed
        foreach ($wait in 400, 1100) {
            Start-Sleep -Milliseconds $wait
            foreach ($t in $pending) {
                if ($t.Done) { continue }
                try {
                    if ($t.AR.IsCompleted) {
                        $t.Client.EndConnect($t.AR)
                        $t.Done = $true
                        $found += $t.IP
                    }
                } catch { $t.Done = $true }
            }
        }
        foreach ($t in $pending) { try { $t.Client.Close() } catch { } }
    } catch { }
    # leading comma preserves the array even for a single result
    return ,@($found | Select-Object -Unique)
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
$txtIp.Size          = New-Object System.Drawing.Size(150, 24)
$form.Controls.Add($txtIp)

$btnScan             = New-Object System.Windows.Forms.Button
$btnScan.Text        = '自动扫描'
$btnScan.Location    = New-Object System.Drawing.Point(246, 12)
$btnScan.Size        = New-Object System.Drawing.Size(76, 26)
$form.Controls.Add($btnScan)

$lblBusid            = New-Object System.Windows.Forms.Label
$lblBusid.Text       = '设备 busid:'
$lblBusid.Location   = New-Object System.Drawing.Point(332, 18)
$lblBusid.AutoSize   = $true
$form.Controls.Add($lblBusid)

$txtBusid            = New-Object System.Windows.Forms.TextBox
$txtBusid.Text       = $cfg.busid
$txtBusid.Location   = New-Object System.Drawing.Point(408, 14)
$txtBusid.Size       = New-Object System.Drawing.Size(66, 24)
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
$chkAuto.Location         = New-Object System.Drawing.Point(400, 50)
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

    # IP empty or stale -> discover automatically
    if (-not $cfg.ip) {
        Log '未填写 IP，开始自动扫描...'
        $found = @(Find-Servers)
        if (-not $found) {
            Log '[错误] 自动扫描未发现设备。请确认打印机已插好、ESP32 已联网。'
            return
        }
        foreach ($f in $found) { Log "  发现设备: $f" }
        $cfg.ip = $found[0]
        $txtIp.Text = $cfg.ip
    }
    Save-Cfg

    $r = Run-Usbip 'install'
    $installMsg = ($r.Out + ' ' + $r.Err).Trim()
    if ($r.Exit -eq 0 -or $installMsg -match 'already exist') { Log 'vhci 驱动已就绪' }
    else { Log "驱动安装输出: $installMsg" }

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

$btnScan.Add_Click({
    $cfg.ip = $txtIp.Text.Trim()
    Log "开始扫描 USB/IP 打印服务器..."
    $found = @(Find-Servers)
    if ($found.Count -eq 0) {
        Log '[失败] 未发现设备。请确认打印机已插好、ESP32 已接入同一网段。'
        return
    }
    foreach ($f in $found) { Log "  发现设备: $f" }
    if ($found.Count -gt 1) { Log '发现多台设备，已选用第一台（可在 IP 框中手动改用其他地址）。' }
    $cfg.ip = $found[0]
    $txtIp.Text = $cfg.ip
    Save-Cfg
    Log "[OK] 已选用 $($cfg.ip)"
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
$script:failCount    = 0
$timer.Add_Tick({
    if (-not $watching) { return }
    $r = Run-Usbip "attach -r $($cfg.ip) -b $($cfg.busid)"
    if ($r.Exit -eq 0) {
        $script:failCount = 0
        if (-not $script:lastAttachOk) {
            Log '[OK] 设备已重新连接。'
            Set-Status '● 已连接' ([System.Drawing.Color]::ForestGreen)
        }
        $script:lastAttachOk = $true
    } else {
        $script:failCount++
        # several failures in a row usually mean the IP changed (DHCP) -> re-scan
        if ($script:failCount -eq 4 -and -not $script:lastAttachOk) {
            Log '[提示] 连续失败，IP 可能已变化，重新扫描...'
            $found = @(Find-Servers)
            if ($found) {
                foreach ($f in $found) { Log "  发现设备: $f" }
                $cfg.ip = $found[0]
                $txtIp.Text = $cfg.ip
                Save-Cfg
            } else {
                Log '[提示] 扫描未发现设备，继续重试原地址...'
            }
        }
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
