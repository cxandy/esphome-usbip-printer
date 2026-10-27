// ============================================================
//  USB/IP Print Client GUI for Windows (WinForms, .NET 4.x)
//  Companion client for the ESP32-S3 USB/IP print server.
//
//  Built by GitHub Actions with the framework csc.exe:
//    csc /target:winexe /win32manifest:app.manifest usbip-client.cs
//  The app.manifest requests requireAdministrator, so double-
//  clicking the exe shows UAC once and opens the window directly
//  (no console window).
//
//  Features:
//   - auto-discovery of the server (mDNS names, then /24 scan)
//   - driver install + busid probe + attach
//   - watchdog with automatic re-attach and re-scan
//   - detach, port status, logon autostart (scheduled task)
//   - settings persist in usbip-gui.ini next to the exe
// ============================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace UsbIpPrintClient
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public class MainForm : Form
    {
        readonly string dir = AppDomain.CurrentDomain.BaseDirectory;
        string usbipExe;
        string iniPath;
        string ip = "";
        string busid = "";
        int interval = 15;
        int failCount = 0;
        bool lastAttachOk = false;
        bool watching = false;
        Mutex mutex;

        TextBox txtIp;
        TextBox txtBusid;
        Button btnScan;
        Button btnConnect;
        Button btnDetach;
        Button btnStatus;
        CheckBox chkAuto;
        RichTextBox txtLog;
        Panel pill;
        Label lblStatus;
        System.Windows.Forms.Timer timer;

        public MainForm()
        {
            bool created;
            mutex = new Mutex(true, "USBIP-PrintClient-Mutex", out created);
            if (!created)
            {
                MessageBox.Show("USB/IP 打印客户端已在运行。", "提示",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                Close();
                return;
            }

            usbipExe = Path.Combine(dir, "usbip.exe");
            iniPath = Path.Combine(dir, "usbip-gui.ini");
            LoadCfg();
            InitUi();
            InitAutoState();

            // "--auto": launched by the logon scheduled task — start the
            // connect flow immediately (IP changes are handled by the
            // watchdog's automatic re-scan)
            foreach (string a in Environment.GetCommandLineArgs())
            {
                if (string.Equals(a, "--auto", StringComparison.OrdinalIgnoreCase))
                {
                    BeginInvoke((Action)(() => DoConnect()));
                    break;
                }
            }
        }

        // ---------- config ----------
        void LoadCfg()
        {
            if (!File.Exists(iniPath)) return;
            foreach (string line in File.ReadAllLines(iniPath))
            {
                Match m = Regex.Match(line, @"^\s*ip\s*=\s*(.+?)\s*$");
                if (m.Success) { ip = m.Groups[1].Value; continue; }
                m = Regex.Match(line, @"^\s*busid\s*=\s*(.*?)\s*$");
                if (m.Success) { busid = m.Groups[1].Value; continue; }
                m = Regex.Match(line, @"^\s*interval\s*=\s*(\d+)\s*$");
                if (m.Success) { int.TryParse(m.Groups[1].Value, out interval); }
            }
            if (!Regex.IsMatch(ip, @"^\d{1,3}(\.\d{1,3}){3}$")) ip = "";
            if (interval < 5 || interval > 300) interval = 15;
        }

        void SaveCfg()
        {
            File.WriteAllLines(iniPath, new string[]
            {
                "ip=" + ip,
                "busid=" + busid,
                "interval=" + interval
            });
        }

        // ---------- helpers ----------
        void AppendLog(string msg)
        {
            txtLog.SelectionStart = txtLog.TextLength;
            txtLog.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "]  " + msg + "\r\n");
            txtLog.ScrollToCaret();
        }

        void Log(string msg)
        {
            if (txtLog.InvokeRequired) { BeginInvoke((Action)(() => AppendLog(msg))); return; }
            AppendLog(msg);
        }

        void SetStatus(string text, string bg, string fg)
        {
            lblStatus.Text = "● " + text;
            lblStatus.ForeColor = ColorTranslator.FromHtml(fg);
            pill.BackColor = ColorTranslator.FromHtml(bg);
        }

        void SetBusy(bool on)
        {
            Cursor = on ? Cursors.WaitCursor : Cursors.Default;
            btnConnect.Enabled = !on;
            btnScan.Enabled = !on;
        }

        int RunUsbip(string args, out string output)
        {
            output = "";
            if (!File.Exists(usbipExe))
            {
                output = "usbip.exe not found in " + dir;
                return 1;
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(usbipExe, args);
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    // async reads: usbip attach spawns a daemon child that may
                    // inherit the pipes, so ReadToEnd() on the UI thread would
                    // block forever until the child exits
                    Task<string> so = p.StandardOutput.ReadToEndAsync();
                    Task<string> se = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(15000))
                    {
                        try { p.Kill(); } catch { }
                        output = "(timeout: usbip did not exit within 15s)";
                        return 1;
                    }
                    output = so.Wait(2000) ? so.Result : "";
                    output += se.Wait(2000) ? se.Result : "";
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                output = ex.Message;
                return 1;
            }
        }

        int RunExternal(string exe, string args, out string output)
        {
            output = "";
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    string so = p.StandardOutput.ReadToEnd();
                    string se = p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    output = so + se;
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                output = ex.Message;
                return 1;
            }
        }

        string GetBusid(string serverIp)
        {
            string output;
            RunUsbip("list -r " + serverIp, out output);
            Match m = Regex.Match(output, @"(?m)^\s*(\d+-\d+):");
            return m.Success ? m.Groups[1].Value : null;
        }

        // ---------- discovery ----------
        string Probe(string host)
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect(host, 3240, null, null);
                    if (ar.AsyncWaitHandle.WaitOne(800))
                    {
                        c.EndConnect(ar);
                        return host;
                    }
                }
            }
            catch { }
            return null;
        }

        string GetSubnet()
        {
            try
            {
                IPHostEntry entry = Dns.GetHostEntry(Dns.GetHostName());
                foreach (IPAddress a in entry.AddressList)
                {
                    string s = a.ToString();
                    if (a.AddressFamily == AddressFamily.InterNetwork &&
                        !IPAddress.IsLoopback(a) && !s.StartsWith("169.254"))
                    {
                        string[] parts = s.Split('.');
                        return parts[0] + "." + parts[1] + "." + parts[2] + ".";
                    }
                }
            }
            catch { }
            return null;
        }

        List<string> FindServers()
        {
            List<string> found = new List<string>();

            // fast path: mDNS host names advertised by the ESP32
            string[] names = new string[] { "usbip-server.local", "usbip-mfc7420.local" };
            foreach (string name in names)
            {
                try
                {
                    Task<IPHostEntry> t = Task.Factory.StartNew<IPHostEntry>(delegate
                    {
                        try { return Dns.GetHostEntry(name); }
                        catch { return null; }
                    });
                    if (!t.Wait(1500)) continue;
                    IPHostEntry entry = t.Result;
                    if (entry == null) continue;
                    foreach (IPAddress a in entry.AddressList)
                    {
                        if (a.AddressFamily == AddressFamily.InterNetwork)
                        {
                            found.Add(a.ToString());
                            break;
                        }
                    }
                }
                catch { }
            }
            if (found.Count > 0) return found.Distinct().ToList();

            // fallback: scan the local /24 for open TCP 3240
            string subnet = GetSubnet();
            if (subnet == null) return found;
            List<Task<string>> tasks = new List<Task<string>>();
            for (int i = 1; i < 255; i++)
            {
                string target = subnet + i;
                tasks.Add(Task.Factory.StartNew<string>(() => Probe(target)));
            }
            try { Task.WaitAll(tasks.ToArray(), 6000); } catch { }
            foreach (Task<string> t in tasks)
                if (t.Status == TaskStatus.RanToCompletion && t.Result != null)
                    found.Add(t.Result);
            return found.Distinct().ToList();
        }

        List<string> FindServersSync()
        {
            List<string> found = FindServers();
            LogScanResult(found);
            return found;
        }

        void LogScanResult(List<string> found)
        {
            if (found.Count == 0)
            {
                Log("[失败] 未发现设备。请确认打印机已插好、ESP32 已接入同一网段。");
                return;
            }
            foreach (string f in found) Log("  发现设备: " + f);
            if (found.Count > 1)
                Log("发现多台设备，已选用第一台（可在 IP 框中手动改用其他地址）。");
        }

        // ---------- connect / watchdog ----------
        void DoConnect()
        {
            SetBusy(true);
            string ipBox = txtIp.Text.Trim();
            string busidBox = txtBusid.Text.Trim();
            Task.Factory.StartNew(delegate
            {
                string useIp = ipBox;
                string useBusid = busidBox;

                if (useIp.Length == 0)
                {
                    Log("未填写 IP，开始自动扫描...");
                    List<string> found = FindServersSync();
                    if (found.Count == 0) { SetBusySafe(false); return; }
                    useIp = found[0];
                    SetIpSafe(useIp);
                }

                Log("检查 vhci 驱动...");
                string outp;
                int code = RunUsbip("install", out outp);
                if (code == 0 || outp.IndexOf("already exist", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    Log("vhci 驱动已就绪");
                }
                else
                {
                    Log("[警告] 驱动安装输出: " + outp.Trim());
                }

                if (useBusid.Length == 0)
                {
                    Log("正在探测 " + useIp + " 上的设备...");
                    useBusid = GetBusid(useIp);
                    if (useBusid == null)
                    {
                        Log("[错误] 未发现设备。请确认打印机已上电、ESP32 已联网。");
                        Log("（usbip list 原始输出见下方）");
                        Log(outp.Trim().Length > 0 ? outp.Trim() : "（服务器未返回设备列表）");
                        SetBusySafe(false);
                        return;
                    }
                    SetBusidSafe(useBusid);
                }

                Log("正在连接 " + useIp + " (" + useBusid + ") ...");
                code = RunUsbip("attach -r " + useIp + " -b " + useBusid, out outp);
                if (code == 0)
                {
                    ip = useIp; busid = useBusid; SaveCfg();
                    failCount = 0; lastAttachOk = true; watching = true;
                    BeginInvoke((Action)(() => timer.Start()));
                    Log("[OK] 设备已连接，看门狗已启动（每 " + interval + " 秒检查一次）。");
                    Log("提示: 断线会自动重连；打印机深度睡眠掉线无需干预。");
                    SetStatusSafe("已连接", "#DCFCE7", "#166534");
                }
                else
                {
                    Log("[连接失败] " + outp.Trim());
                    Log("看门狗将持续重试...");
                    failCount = 0; lastAttachOk = false; watching = true;
                    BeginInvoke((Action)(() => timer.Start()));
                    SetStatusSafe("重连中...", "#FEF3C7", "#92400E");
                }
                SetBusySafe(false);
            });
        }

        void Rescan()
        {
            Task.Factory.StartNew(delegate
            {
                List<string> found = FindServers();
                if (found.Count == 0) return;
                LogScanResult(found);
                string newIp = found[0];
                if (newIp != ip)
                {
                    ip = newIp; SaveCfg();
                    SetIpSafe(newIp);
                    Log("[OK] 服务器地址已更新为 " + newIp);
                }
                else
                {
                    Log("服务器地址未变化，继续重试...");
                }
            });
        }

        void SetBusySafe(bool on) { BeginInvoke((Action)(() => SetBusy(on))); }
        void SetStatusSafe(string t, string bg, string fg) { BeginInvoke((Action)(() => SetStatus(t, bg, fg))); }
        void SetIpSafe(string v) { BeginInvoke((Action)(() => { txtIp.Text = v; })); }
        void SetBusidSafe(string v) { BeginInvoke((Action)(() => { txtBusid.Text = v; })); }

        // ---------- autostart ----------
        void InitAutoState()
        {
            string outp;
            RunExternal("schtasks.exe", "/query /tn USBIP-PrintClient", out outp);
            chkAuto.Checked = outp.IndexOf("USBIP-PrintClient", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        void ToggleAuto(bool on)
        {
            string outp;
            if (on)
            {
                string exe = Path.Combine(dir, "USBIP-Client.exe");
                int code = RunExternal("schtasks.exe",
                    "/create /f /tn USBIP-PrintClient /tr \"\\\"" + exe + "\\\" --auto\" /sc onlogon /rl highest",
                    out outp);
                if (code == 0)
                {
                    Log("[OK] 已注册开机自动连接（登录时自动运行，无需 UAC）。");
                }
                else
                {
                    Log("[警告] 注册开机任务失败: " + outp.Trim());
                    BeginInvoke((Action)(() => { chkAuto.Checked = false; }));
                }
            }
            else
            {
                RunExternal("schtasks.exe", "/delete /f /tn USBIP-PrintClient", out outp);
                Log("[OK] 已取消开机自动连接。");
            }
        }

        // ---------- UI ----------
        Button MakeButton(string text, string hex, int x, int y, int w)
        {
            Button b = new Button();
            b.Text = text;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.BackColor = ColorTranslator.FromHtml(hex);
            b.ForeColor = Color.White;
            b.Location = new Point(x, y);
            b.Size = new Size(w, 34);
            b.Cursor = Cursors.Hand;
            b.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            return b;
        }

        void InitUi()
        {
            Text = "USB/IP 打印客户端";
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(700, 620);
            BackColor = ColorTranslator.FromHtml("#EEF2F7");
            Font = new Font("Segoe UI", 9.5f);

            // header
            Panel header = new Panel();
            header.Location = new Point(0, 0);
            header.Size = new Size(700, 70);
            header.BackColor = Color.White;
            Controls.Add(header);

            Label title = new Label();
            title.Text = "USB/IP 打印客户端";
            title.Font = new Font("Segoe UI", 14f, FontStyle.Bold);
            title.Location = new Point(20, 10);
            title.AutoSize = true;
            title.ForeColor = ColorTranslator.FromHtml("#0F172A");
            header.Controls.Add(title);

            Label subtitle = new Label();
            subtitle.Text = "ESP32-S3 USB/IP 打印服务器 · usbip-win 0.3.6-dev";
            subtitle.Font = new Font("Segoe UI", 8.5f);
            subtitle.Location = new Point(22, 42);
            subtitle.AutoSize = true;
            subtitle.ForeColor = ColorTranslator.FromHtml("#64748B");
            header.Controls.Add(subtitle);

            pill = new Panel();
            pill.Size = new Size(170, 32);
            pill.BackColor = ColorTranslator.FromHtml("#FEE2E2");
            pill.Location = new Point(700 - 170 - 20, 19);
            header.Controls.Add(pill);

            lblStatus = new Label();
            lblStatus.Dock = DockStyle.Fill;
            lblStatus.TextAlign = ContentAlignment.MiddleCenter;
            lblStatus.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            lblStatus.Text = "● 未连接";
            lblStatus.ForeColor = ColorTranslator.FromHtml("#B91C1C");
            pill.Controls.Add(lblStatus);

            // connection card
            Panel card = new Panel();
            card.Location = new Point(20, 88);
            card.Size = new Size(660, 118);
            card.BackColor = Color.White;
            Controls.Add(card);

            Label lblIp = new Label();
            lblIp.Text = "服务器 IP:";
            lblIp.Location = new Point(18, 22);
            lblIp.AutoSize = true;
            lblIp.ForeColor = ColorTranslator.FromHtml("#334155");
            card.Controls.Add(lblIp);

            txtIp = new TextBox();
            txtIp.Text = ip;
            txtIp.Location = new Point(100, 18);
            txtIp.Size = new Size(180, 26);
            card.Controls.Add(txtIp);

            btnScan = MakeButton("⟳ 自动扫描", "#0EA5E9", 296, 15, 100);
            btnScan.Click += delegate
            {
                SetBusy(true);
                Log("开始扫描 USB/IP 打印服务器...");
                Task.Factory.StartNew(delegate
                {
                    List<string> found = FindServersSync();
                    if (found.Count > 0)
                    {
                        ip = found[0];
                        SetIpSafe(ip);
                        SaveCfg();
                        Log("[OK] 已选用 " + ip);
                    }
                    SetBusySafe(false);
                });
            };
            card.Controls.Add(btnScan);

            Label lblBusid = new Label();
            lblBusid.Text = "设备 busid:";
            lblBusid.Location = new Point(412, 22);
            lblBusid.AutoSize = true;
            lblBusid.ForeColor = ColorTranslator.FromHtml("#334155");
            card.Controls.Add(lblBusid);

            txtBusid = new TextBox();
            txtBusid.Text = busid;
            txtBusid.Location = new Point(500, 18);
            txtBusid.Size = new Size(80, 26);
            card.Controls.Add(txtBusid);

            Label lblHint = new Label();
            lblHint.Text = "IP 和 busid 留空可自动发现；设置自动保存在 usbip-gui.ini。";
            lblHint.Location = new Point(18, 56);
            lblHint.AutoSize = true;
            lblHint.ForeColor = ColorTranslator.FromHtml("#94A3B8");
            lblHint.Font = new Font("Segoe UI", 8.5f);
            card.Controls.Add(lblHint);

            btnConnect = MakeButton("连接并保持在线", "#2563EB", 18, 72, 160);
            btnConnect.Click += delegate { DoConnect(); };
            card.Controls.Add(btnConnect);

            btnDetach = MakeButton("断开", "#64748B", 192, 72, 90);
            btnDetach.Click += delegate
            {
                string outp;
                RunUsbip("detach -p *", out outp);
                watching = false; lastAttachOk = false;
                timer.Stop();
                SetStatus("未连接", "#FEE2E2", "#B91C1C");
                Log("[OK] 已断开所有 USB/IP 设备。");
            };
            card.Controls.Add(btnDetach);

            btnStatus = MakeButton("查看端口状态", "#475569", 296, 72, 130);
            btnStatus.Click += delegate
            {
                string outp;
                RunUsbip("port", out outp);
                Log("---- usbip.exe port ----");
                Log(outp.Trim().Length > 0 ? outp.Trim() : "（无输出）");
                Log("------------------------");
            };
            card.Controls.Add(btnStatus);

            chkAuto = new CheckBox();
            chkAuto.Text = "开机自动连接";
            chkAuto.Location = new Point(452, 78);
            chkAuto.AutoSize = true;
            chkAuto.ForeColor = ColorTranslator.FromHtml("#334155");
            chkAuto.CheckedChanged += delegate { ToggleAuto(chkAuto.Checked); };
            card.Controls.Add(chkAuto);

            // log panel
            Label lblLog = new Label();
            lblLog.Text = "运行日志";
            lblLog.Location = new Point(22, 218);
            lblLog.AutoSize = true;
            lblLog.ForeColor = ColorTranslator.FromHtml("#475569");
            Controls.Add(lblLog);

            txtLog = new RichTextBox();
            txtLog.Location = new Point(20, 240);
            txtLog.Size = new Size(660, 358);
            txtLog.BackColor = ColorTranslator.FromHtml("#0F172A");
            txtLog.ForeColor = ColorTranslator.FromHtml("#93C5FD");
            txtLog.Font = new Font("Consolas", 9f);
            txtLog.ReadOnly = true;
            txtLog.BorderStyle = BorderStyle.None;
            Controls.Add(txtLog);

            // watchdog timer
            timer = new System.Windows.Forms.Timer();
            timer.Interval = interval * 1000;
            timer.Tick += delegate
            {
                if (!watching) return;
                string a = ip, b = busid;
                Task.Factory.StartNew(delegate
                {
                    string outp;
                    int code = RunUsbip("attach -r " + a + " -b " + b, out outp);
                    BeginInvoke((Action)(delegate
                    {
                        if (code == 0)
                        {
                            failCount = 0;
                            if (!lastAttachOk)
                            {
                                Log("[OK] 设备已重新连接。");
                                SetStatus("已连接", "#DCFCE7", "#166534");
                            }
                            lastAttachOk = true;
                        }
                        else
                        {
                            failCount++;
                            if (lastAttachOk)
                            {
                                Log("[掉线] 设备丢失，持续重试中...");
                                SetStatus("重连中...", "#FEF3C7", "#92400E");
                            }
                            lastAttachOk = false;
                            if (failCount == 4)
                            {
                                Log("[提示] 连续失败，IP 可能已变化，重新扫描...");
                                Rescan();
                            }
                        }
                    }));
                });
            };

            AppendLog("USB/IP 打印客户端已启动。");
            AppendLog("提示: 右侧\"查看端口状态\"可查看当前 attach 情况。");
            AppendLog("首次使用: 连接成功后安装佳能 LBP2900 驱动，之后即可直接打印。");
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            watching = false;
            try { mutex.ReleaseMutex(); } catch { }
            base.OnFormClosed(e);
        }
    }
}
