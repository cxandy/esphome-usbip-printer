# ============================================================
#  USB/IP Print Client GUI  (WPF, PowerShell 5.1, zero deps)
#  Bundled client: usbip-win 0.3.6-dev (usbip.exe in this folder)
#
#  Launch with "USBIP-Client.vbs" (no console window).
#  "USBIP-Client.bat" still works but shows a console briefly.
#  Settings persist in usbip-gui.ini next to this file.
# ============================================================

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:usbip = Join-Path $script:dir 'usbip.exe'
$script:ini   = Join-Path $script:dir 'usbip-gui.ini'
$script:vbs   = Join-Path $script:dir 'USBIP-Client.vbs'

# ---------- config load ----------
$cfg = @{ ip = ''; busid = ''; interval = 15 }
if (Test-Path $ini) {
    Get-Content $ini | ForEach-Object {
        if     ($_ -match '^\s*ip\s*=\s*(.+?)\s*$')        { $cfg.ip       = $Matches[1] }
        elseif ($_ -match '^\s*busid\s*=\s*(.*?)\s*$')     { $cfg.busid    = $Matches[1] }
        elseif ($_ -match '^\s*interval\s*=\s*(\d+)\s*$')  { $cfg.interval = [int]$Matches[1] }
    }
}
# sanity check: discard a saved value that is not a valid IPv4 address
if ($cfg.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $cfg.ip = '' }
if ($cfg.interval -lt 5 -or $cfg.interval -gt 300) { $cfg.interval = 15 }

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
    $txtLog.ScrollToEnd()
}

function Brush([string]$hex) {
    New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function Set-Status([string]$text, [string]$bg, [string]$fg, [string]$dotHex) {
    $txtStatus.Text       = $text
    $txtStatus.Foreground = Brush $fg
    $bdPill.Background    = Brush $bg
    $dotStatus.Fill       = Brush $dotHex
}

function Busy([bool]$on) {
    $window.Cursor = if ($on) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }
    $btnConnect.IsEnabled = -not $on
    $btnScan.IsEnabled    = -not $on
}

function Get-Busid([string]$ip) {
    $r = Run-Usbip "list -r $ip"
    # dump the raw output: some usbip builds return non-zero exit codes
    # even on success, and empty output is a diagnosis on its own
    Log "---- usbip list $ip ----"
    ($r.Out + "`n" + $r.Err) -split "`n" | ForEach-Object {
        if ($_.Trim()) { Log $_.TrimEnd() }
    }
    $all = ($r.Out -split "`n") + ($r.Err -split "`n")
    $line = $all | Where-Object { $_ -match '^\s*\d+-\d+:' } | Select-Object -First 1
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
    if ($found) { return ,@($found | Select-Object -Unique) }

    # 2) Fallback: scan the local /24 for open TCP 3240 (USB/IP port)
    try {
        $local = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress    -notlike '127.*'     -and
                $_.IPAddress    -notlike '169.254.*' -and
                $_.PrefixOrigin -ne 'WellKnown'
            } | Sort-Object InterfaceMetric | Select-Object -First 1
        if (-not $local) { return ,@() }
        $base = ($local.IPAddress -split '\.')[0..2] -join '.'
        Log "正在扫描网段 $base.0/24 的 3240 端口..."
        $pending = @()
        foreach ($i in 1..254) {
            $ip = "$base.$i"
            $c  = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $c.BeginConnect($ip, 3240, $null, $null)
                $pending += @{ IP = $ip; Client = $c; AR = $ar; Done = $false }
            } catch { $c.Close() }
        }
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
    return ,@($found | Select-Object -Unique)
}

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

# ---------- XAML UI ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="USB/IP 打印客户端" Height="640" Width="680"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#EEF1F6"
        FontFamily="Microsoft YaHei UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect BlurRadius="16" ShadowDepth="1" Direction="270" Opacity="0.10"/>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#2563EB"/>
    </Style>
    <Style x:Key="BtnNeutral" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#475569"/>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#0891B2"/>
      <Setter Property="Padding" Value="10,7"/>
    </Style>
    <Style x:Key="TbInput" TargetType="TextBox">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="#FBFCFE" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="10,7" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Grid Grid.Row="0" Margin="2,0,2,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="USB/IP 打印客户端" FontSize="19" FontWeight="Bold" Foreground="#0F172A"/>
        <TextBlock Text="ESP32-S3 打印服务器 · 佳能 LBP2900 · Brother MFC-7420" FontSize="11.5" Foreground="#64748B" Margin="0,3,0,0"/>
      </StackPanel>
      <Border x:Name="bdPill" Grid.Column="1" CornerRadius="14" Padding="12,6" VerticalAlignment="Center" Background="#FEE2E2">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="dotStatus" Width="9" Height="9" Fill="#DC2626" VerticalAlignment="Center" Margin="0,0,7,0"/>
          <TextBlock x:Name="txtStatus" Text="未连接" Foreground="#B91C1C" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- connection card -->
    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,14">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="服务器 IP" Foreground="#475569" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBox x:Name="txtIp" Grid.Column="1" Style="{StaticResource TbInput}" Margin="0,0,10,0"/>
          <Button x:Name="btnScan" Grid.Column="2" Style="{StaticResource BtnAccent}" Content="⟳ 自动扫描" Margin="0,0,14,0"/>
          <TextBlock Grid.Column="3" Text="busid" Foreground="#475569" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBox x:Name="txtBusid" Grid.Column="4" Style="{StaticResource TbInput}" MinWidth="70"/>
        </Grid>
        <TextBlock Text="busid 留空 = 自动探测；IP 留空或点“自动扫描”将在局域网内查找打印服务器"
                   FontSize="11.5" Foreground="#94A3B8" Margin="1,8,0,12"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="btnConnect" Grid.Column="0" Style="{StaticResource BtnPrimary}" Content="连接并保持在线" Margin="0,0,10,0"/>
          <Button x:Name="btnDetach" Grid.Column="1" Style="{StaticResource BtnNeutral}" Content="断开" Margin="0,0,10,0"/>
          <CheckBox x:Name="chkAuto" Grid.Column="3" Content="开机自动连接" VerticalAlignment="Center" Foreground="#334155"/>
        </Grid>
      </StackPanel>
    </Border>

    <!-- log card -->
    <Border Grid.Row="2" Style="{StaticResource Card}" Background="#1B2030" Padding="0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#252B3E" CornerRadius="12,12,0,0" Padding="14,8">
          <TextBlock Text="运行日志" FontSize="11.5" Foreground="#8FA3C8" FontWeight="SemiBold"/>
        </Border>
        <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                 Foreground="#C7D7F5" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 Padding="12,8" Text=" "/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'txtIp','btnScan','txtBusid','btnConnect','btnDetach','chkAuto','txtLog','bdPill','dotStatus','txtStatus') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# ---------- actions ----------
$script:watching     = $false
$script:lastAttachOk = $false
$script:failCount    = 0

$btnScan.Add_Click({
    Busy $true
    try {
        $cfg.ip = $txtIp.Text.Trim()
        Log "开始扫描 USB/IP 打印服务器..."
        $found = @(Find-Servers)
        if ($found.Count -eq 0) {
            Log '[失败] 未发现设备。请确认打印机已通电、ESP32 已接入同一网段。'
            return
        }
        foreach ($f in $found) { Log "  发现设备: $f" }
        if ($found.Count -gt 1) { Log '发现多台设备，已选用第一台（可在 IP 框中手动改用其他地址）。' }
        $cfg.ip = $found[0]
        $txtIp.Text = $cfg.ip
        Save-Cfg
        Log "[OK] 已选用 $($cfg.ip)"
    } finally { Busy $false }
})

$btnConnect.Add_Click({
    Busy $true
    try {
        $cfg.ip    = $txtIp.Text.Trim()
        $cfg.busid = $txtBusid.Text.Trim()

        # IP empty or stale -> discover automatically
        if (-not $cfg.ip) {
            Log '未填写 IP，开始自动扫描...'
            $found = @(Find-Servers)
            if ($found.Count -eq 0) {
                Log '[错误] 自动扫描未发现设备。请确认打印机已通电、ESP32 已联网。'
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
            $b = Get-Busid $cfg.ip
            if (-not $b) {
                Log '[错误] 未发现 USB 设备。请确认打印机已通电并插在 ESP32 上。'
                Set-Status '服务器在线，但打印机未连接' '#FEF3C7' '#B45309' '#D97706'
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
            $script:failCount = 0
            Set-Status '已连接' '#DCFCE7' '#15803D' '#16A34A'
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
    } finally { Busy $false }
})

$btnDetach.Add_Click({
    $watching = $false
    $timer.Stop()
    [void](Run-Usbip 'detach -p *')
    $script:lastAttachOk = $false
    Set-Status '未连接' '#FEE2E2' '#B91C1C' '#DC2626'
    Log '[OK] 已断开所有 USB/IP 设备。'
})

# autostart checkbox (scheduled task, no UAC at logon)
$chkAuto.Add_Click({
    $task = 'USBIP-PrintClient'
    if ($chkAuto.IsChecked) {
        $arg = "/create /f /tn $task /tr \"wscript.exe \`"$vbs\`"\" /sc onlogon /rl highest"
        if (Run-ExternalSchTasks $arg) {
            Log '[OK] 已注册开机自动连接（登录时自动运行，无需 UAC）。'
        } else {
            Log '[警告] 注册开机任务失败。'
            $chkAuto.IsChecked = $false
        }
    } else {
        [void](Run-ExternalSchTasks "/delete /f /tn $task")
        Log '[OK] 已取消开机自动连接。'
    }
})

# watchdog timer (DispatcherTimer runs on the UI thread)
$timer          = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($cfg.interval)
$timer.Add_Tick({
    if (-not $watching) { return }
    $r = Run-Usbip "attach -r $($cfg.ip) -b $($cfg.busid)"
    if ($r.Exit -eq 0) {
        $script:failCount = 0
        if (-not $script:lastAttachOk) {
            Log '[OK] 设备已重新连接。'
            Set-Status '已连接' '#DCFCE7' '#15803D' '#16A34A'
        }
        $script:lastAttachOk = $true
    } else {
        $script:failCount++
        # several failures in a row usually mean the IP changed (DHCP) -> re-scan
        if ($script:failCount -eq 4 -and -not $script:lastAttachOk) {
            Log '[提示] 连续失败，IP 可能已变化，重新扫描...'
            $found = @(Find-Servers)
            if ($found.Count -gt 0) {
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
            Set-Status '重连中...' '#FEF3C7' '#B45309' '#D97706'
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
if ($taskQuery.ExitCode -eq 0) { $chkAuto.IsChecked = $true }

$txtIp.Text    = $cfg.ip
$txtBusid.Text = $cfg.busid

Log "USB/IP 打印客户端已启动。"
Log "提示: 服务器 IP 和 busid 均可留空，点“连接并保持在线”会自动查找并连接。"
Log "首次使用: 连接成功后安装佳能 LBP2900 驱动，之后即可直接打印。"

[void]$window.ShowDialog()
