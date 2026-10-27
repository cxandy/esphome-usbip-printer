# Bundled Windows USB/IP Client (usbip-win)

Pre-built binaries of [usbip-win](https://github.com/cezanne/usbip-win)
release **0.3.6-dev**, downloaded unmodified from the upstream release
(`usbip-win-0.3.6-dev.zip`). Debug symbols (`*.pdb`) were removed to keep the
repository small.

usbip-win is licensed under **GPL-2.0-or-later**. Source code:
https://github.com/cezanne/usbip-win

## Why this is bundled

The Linux `usbip` client is part of the kernel tools, but Windows has no
built-in USB/IP client. `usbipd-win` (the Microsoft-endorsed project) is a
*server* only — it shares Windows USB devices outward and cannot attach to a
remote USB/IP server. `usbip-win` is currently the only practical Windows
USB/IP *client*, and its vhci driver now ships with a Microsoft attestation
signature, so **no test-signing mode or reboot is needed** to attach a remote
device.

## Verified combination

These binaries were used successfully as the client of this very component:

- Server: ESP32-S3-ETH running this ESPHome component (USB/IP v1.1.1, TCP 3240)
- Device: Canon LBP-2900 (CAPT / host-based printer, `04a9:2676`)
- Client: Windows 10 22H2 x64
- Result: device attached, Canon CAPT driver bound to the virtual USB device,
  full CAPT handshake over bulk IN/OUT, test page printed

This makes host-based printers (CAPT, UFRII-LT, GDI) usable from Windows —
they cannot print through the RAW 9100 port because their proprietary data
stream must be rendered by the vendor driver talking directly to a USB device.

## Files

| File | Purpose |
|------|---------|
| `usbip.exe` | Command line client (list / install / attach / detach) |
| `attacher.exe` | Background helper that keeps the attach session alive (started automatically by `usbip.exe`) |
| `usbip_vhci_ude.inf/.cat/.sys` | vhci (UDE) virtual host controller driver — **attestation-signed**, this is what `install` uses |
| `usbip_vhci.inf/.cat/.sys` | vhci (WDM, KMDF) driver variant |
| `usbip_stub.sys` + `usbip_root.inf` | Stub driver — only needed to *share* a local Windows USB device to others (server side), not required for attaching |
| `usbipd.exe` | Server-side daemon, only needed for the sharing direction |
| `usb.ids` | USB vendor/device ID database used by `usbip list` |

## Quick start (admin PowerShell)

```powershell
cd tools\usbip-win-0.3.6-dev

# 1. Discover exported devices on the ESP32
.\usbip.exe list -r 192.168.137.194

# 2. Install the vhci driver (one-time, attestation-signed, no reboot)
.\usbip.exe install

# 3. Attach the device (busid from step 1, usually 1-1)
.\usbip.exe attach -r 192.168.137.194 -b 1-1

# Detach when done
.\usbip.exe detach -p *
```

## Even easier: one-click `attach.bat` or the GUI

For non-technical users there is no need to touch a terminal at all.

### GUI (recommended)

Double-click **`USBIP-Client.exe`** — a regular Windows application (C#
WinForms, prebuilt by CI, admin manifest embedded so it shows one UAC prompt
and opens directly, no console window). Source code lives in
[`tools/usbip-client/src/`](usbip-client/src/) and is rebuilt automatically
by GitHub Actions on every change.

Script launchers are still available as fallbacks: `USBIP-Client.vbs`
(PS/WPF version, no console window) and `USBIP-Client.bat` (shows a console
briefly).

- editable server IP and busid (busid auto-detected if left empty; settings
  persist in `usbip-gui.ini`)
- **自动扫描 (auto-discovery)** — finds the ESP32 automatically: first tries
  the mDNS host names the device advertises (`usbip-server.local`,
  `usbip-mfc7420.local`), then falls back to scanning the local /24 subnet for
  open TCP 3240. The watchdog also re-scans automatically when several
  attaches fail in a row (e.g. after a DHCP address change)
- **连接并保持在线** — installs the driver if needed, attaches, and starts a
  watchdog that re-attaches automatically whenever the device drops off
  (host-based printers disconnect/reconnect on deep sleep)
- **断开**, **查看端口状态**
- **开机自动连接** checkbox — registers/removes a logon scheduled task
  (`USBIP-PrintClient`, highest privileges, no UAC at logon)

### `attach.bat` (console variant)

Edit the `SERVER_IP` line at the top of `attach.bat` once, then:

- **Double-click `attach.bat`** — it self-elevates (one UAC click), installs
  the vhci driver if needed, auto-detects the busid, attaches the printer and
  stays open as a **watchdog** that re-attaches automatically every 15 s
  whenever the device drops off (host-based printers such as the LBP-2900
  disconnect/reconnect when entering deep sleep).
- `attach.bat autostart` — additionally registers a logon scheduled task
  (highest privileges), so the printer is attached automatically at every
  logon with no UAC prompt.
- `attach.bat detach` — detach everything.
- `attach.bat once` — attach once without the watchdog.

Notes:

- The attach is **not persistent**: after a reboot, run `attach.bat` again
  (or use the `autostart` task).
- Only one USB/IP client can be attached to the ESP32 at a time; while a
  client is attached the RAW print server (TCP 9100) rejects new connections.
- The remote device appears in Device Manager like a locally plugged-in USB
  device ("USB 打印支持" / *USB Printing Support* for printers). Install the
  vendor driver as usual and point it at that device.
