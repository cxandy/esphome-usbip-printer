# ESPHome USB/IP Server for Printer

A USB/IP server that runs on a Waveshare ESP32-S3-ETH board as an [ESPHome](https://esphome.io/) component. It bridges a locally connected USB device to a remote Linux machine over Ethernet, using the standard [USB/IP](https://www.kernel.org/doc/html/latest/usb/usbip_protocol.html) protocol.

```
 Linux Client                  ESP32-S3-ETH               USB Device
 ──────────────                ────────────               ──────────
 usbip attach ──► TCP:3240 ──► USB/IP server ──► USB ──► Printer
 CUPS / lp    ◄── USB/IP   ◄── component     ◄── USB ◄── Keyboard, ...
```

The Linux host sees the USB device as if it were directly attached. All USB operations (control transfers, bulk IN/OUT, descriptors) are forwarded transparently.

Implemented with help of AI. This is a POC. Verified with:

- **HP LaserJet P1102w** (Linux client + automatic Smart Install firmware upload)
- **Canon LBP-2900** (CAPT / host-based printer) via the **Windows usbip-win client** — see [3b](#3b-attach-from-windows-with-usbip-win-required-for-capt-host-based-printers)
- **Brother MFC-7420** via the RAW print server (it speaks PCL5e) and via USB/IP

## Features

- Standard USB/IP v1.1.1 protocol — works with the `usbip` tools shipped with the Linux kernel **and** the `usbip-win` client on Windows
- Windows client binaries bundled in [`tools/usbip-win-0.3.6-dev/`](tools/usbip-win-0.3.6-dev/) (attestation-signed vhci driver, no test-signing mode needed)
- USB device hot-plug detection (connect and disconnect at runtime)
- Automatic HP Smart Install firmware upload for HP LaserJet P1102w printer
- Workaround for ESP32-S3 DWC2 bulk OUT DMA silicon bug
- JetDirect-style RAW print server (TCP 9100) so Windows/macOS/Linux can print without any USB/IP client (printers speaking a standard language such as PCL/PS only — CAPT/host-based printers need the USB/IP client)
- mDNS discovery (`_usbip._tcp`) that carries the current IP address in the TXT record
- Info card: the device prints its own IP address on the attached printer, so even a user without Home Assistant can find it

## Prerequisites

- **Hardware:** [Waveshare ESP32-S3-ETH](https://www.waveshare.com/wiki/ESP32-S3-ETH) (or any ESP32-S3 board with Ethernet and exposed USB host pins)
- **Framework:** [ESPHome](https://esphome.io/) 2025.12+ with ESP-IDF backend
- **Linux client:** `usbip` utilities (package `linux-tools-common` on Ubuntu/Debian)
- **Windows client:** [usbip-win](https://github.com/cezanne/usbip-win) — a copy is bundled in [`tools/usbip-win-0.3.6-dev/`](tools/usbip-win-0.3.6-dev/)

## Getting Started

### 1. Set up the Python virtual environment

```bash
python3 -m venv virtenv
source virtenv/bin/activate
pip install esphome
```

### 2. Build and flash

```bash
source virtenv/bin/activate
esphome compile usbip_config.yaml
esphome upload usbip_config.yaml
```

### 3. Attach from Linux

```bash
# Discover
usbip list -r <esp32-ip>

# Attach
sudo usbip attach -r <esp32-ip> -b 1-1

# Verify
lsusb

# Detach
sudo usbip detach -p 0
```

Once attached, the device appears as a native USB device. Use it with CUPS, `lp`, or any standard driver.

### 3b. Attach from Windows with usbip-win (required for CAPT / host-based printers)

Windows has no built-in USB/IP client: `usbipd-win` is a *server* only (it
shares Windows USB devices outward and cannot attach to a remote USB/IP
server). The practical Windows client is [`usbip-win`](https://github.com/cezanne/usbip-win);
a ready-to-use copy of release **0.3.6-dev** is bundled in
[`tools/usbip-win-0.3.6-dev/`](tools/usbip-win-0.3.6-dev/). Its vhci driver
ships with a Microsoft attestation signature, so **no test-signing mode and no
reboot** are needed to attach a remote device.

Open an **admin** PowerShell in the tools folder and run:

```powershell
cd tools\usbip-win-0.3.6-dev

# Discover exported devices on the ESP32
.\usbip.exe list -r <esp32-ip>
#   → e.g. "1-1: Canon, Inc. : LBP2900 (04a9:2676)"

# Install the vhci driver (one-time)
.\usbip.exe install

# Attach the printer (busid from the list output, usually 1-1)
.\usbip.exe attach -r <esp32-ip> -b 1-1
#   → "succesfully attached to port 0"
```

The printer then appears in Device Manager as if it were plugged in locally
(*USB Printing Support* / “USB 打印支持” under Universal Serial Bus
controllers). Install the vendor driver as usual — the Canon CAPT driver, for
example, binds to the virtual USB device and prints normally. This was
verified end-to-end with a Canon LBP-2900, whose proprietary CAPT data stream
cannot be pushed through the RAW port.

**One-click variant:** don't want to touch a terminal? Edit the `SERVER_IP`
line in [`tools/usbip-win-0.3.6-dev/attach.bat`](tools/usbip-win-0.3.6-dev/attach.bat)
and simply double-click it. The script self-elevates, installs the driver if
needed, auto-detects the busid, attaches the printer, and runs a watchdog
that re-attaches automatically whenever the device drops off (host-based
printers disconnect/reconnect on deep sleep). `attach.bat autostart` makes it
run automatically at every logon. See
[`tools/README.md`](tools/README.md) for details.

Notes:

- `usbip.exe` requests administrator elevation automatically (UAC prompt).
- The attach is **not persistent**: after a reboot run `attach` again.
- Only one USB/IP client can be attached at a time; while a client is
  attached the RAW print server (TCP 9100) rejects new connections.
- Detach with `.\usbip.exe detach -p *`.

**Which path for which printer?**

| Printer type | Examples | Recommended path |
|--------------|----------|------------------|
| Speaks a standard language (PCL5e/PCL6/PS) | Brother MFC-7420, most office lasers | RAW 9100 (see next section) — no client software |
| Host-based (CAPT, UFRII-LT, GDI) | Canon LBP-2900/3000, MF3010, entry-level MFPs | usbip-win attach (this section) |

### 3c. Print from Windows without a USB/IP client (RAW 9100)

```yaml
usbip:
  port: 3240
  raw_print_port: 9100
```

On the Windows machine: *Settings → Printers & scanners → Add printer → Add a
printer using a TCP/IP address or host name* → host `192.168.18.103` → pick the
printer's own driver (the MFC-7420 speaks PCL5e, so any PCL laser driver works).

The raw stream is forwarded to the printer's bulk OUT endpoint, split into
64-byte max-packet-size chunks to work around the DWC2 bulk OUT DMA freeze.

### 3d. Finding the device without Home Assistant

A user who has no Home Assistant still has to learn the device's IP address. The
component offers three independent ways to do that, and none of them requires
guessing an address.

**1. The printer prints it — `print_info_card: true`**

Once the USB printer is enumerated and the network is up, the device sends a
small card to the printer over USB containing the device name, the IP address,
the `.local` host name, the web UI URL, and the TCP ports:

```
USB/IP PRINT SERVER
--------------------------------
Device : usbip-mfc7420
Host   : usbip-mfc7420.local

192.168.18.103          <- printed in 22pt

Web UI  : http://192.168.18.103/
Print   : TCP 9100  (raw, JetDirect)
USB/IP  : TCP 3240
--------------------------------
To print from a computer, add a network printer
using the IP address above:
  Windows: Add printer > TCP/IP > <IP>
  macOS  : Add printer > IP > <IP>
  Linux  : use the Web UI above to find the
           attached USB printer's address.
```

The card is plain PCL 5e ASCII text (no code page or font dependency) and is
printed once per boot, so re-plugging the printer does not waste a page.

It can also be printed on demand with the **Print Info Card** button, which is
useful after the address changed (for example after a DHCP reservation was
added in the router):

```yaml
usbip:
  id: my_usbip
  ...

button:
  - platform: template
    name: "Print Info Card"
    on_press:
      - lambda: |-
          id(my_usbip).print_info_card();
```

**2. mDNS — `mdns_discovery: true`**

The device advertises itself as `_usbip._tcp` and puts its current IP address
into the TXT record:

```console
$ dns-sd -B _usbip._tcp          # macOS / Linux (Bonjour)
$ avahi-browse -rt _usbip._tcp   # Linux
```

| TXT key | Value |
|----------|-------|
| `ip` | current IPv4 address of the device |
| `host` | `<name>.local` host name |
| `usbip` | USB/IP port (3240) |
| `raw` | RAW print port (9100), if enabled |
| `web` | web server port |
| `vid` / `pid` | USB vendor / product ID of the attached printer |

The record is refreshed automatically when the address changes (e.g. after a
DHCP renewal).

**3. Fallback access point**

The example configuration also starts a fallback AP (`usbip-mfc7420`) with a
captive portal. If the device cannot reach the configured WiFi network, the
user joins that AP and the captive portal page shows the current status.

**Tip for production:** give the device a fixed address. A DHCP reservation in
the router is the simplest option; `static_ip:` in the ESPHome config is the
alternative. Then the printed address never changes.

## Configuration

### Component parameters

```yaml
usbip:
  port: 3240                        # optional, default 3240
  printer_firmware: sihpP1102.dl    # optional, HP P1102w only
  raw_print_port: 9100              # optional, default 0 (off)
  print_info_card: true             # optional, default false
  mdns_discovery: true              # optional, default true
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `port` | No | `3240` | TCP port for the USB/IP server. 3240 is the standard Linux USB/IP port. |
| `printer_firmware` | No | — | Path to an HP printer firmware blob (relative to config file). When set, the firmware is embedded into flash at compile time and automatically uploaded whenever the printer is plugged in. |
| `raw_print_port` | No | `0` (off) | Enables a JetDirect-style RAW print server (TCP 9100). A plain TCP client — e.g. a Windows *Standard TCP/IP Port* printer — can push a print job straight to the attached USB printer without any USB/IP client on the printing machine. |
| `print_info_card` | No | `false` | Prints a card with the device name, IP address and ports on the attached printer once it is enumerated and the network is up. Lets a user without Home Assistant find the device. |
| `mdns_discovery` | No | `true` | Advertises the print server as `_usbip._tcp` via mDNS, with the current IP address in the TXT record. Requires the ESPHome `mdns` component (loaded automatically with `network`). |

### Required ESP-IDF sdkconfig options

These must be set under `esp32.framework.sdkconfig_options`:

| Option | Value | Reason |
|--------|-------|--------|
| `CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE` | `"1024"` | Printers return large descriptors and Device ID strings (up to ~1 KB). The ESP-IDF default of 256 bytes causes truncated responses. |
| `CONFIG_USB_HOST_HW_BUFFER_BIAS_BALANCED` | `y` | Balances the DWC2 internal FIFO between IN and OUT endpoints. The default bias toward periodic endpoints starves bulk transfers. |
| `CONFIG_USB_HOST_ENABLE_ENUM_FILTER_CALLBACK` | `y` | Lets the component accept all USB devices and control which configuration is selected during enumeration. |
| `CONFIG_SPIRAM` | `n` | The DWC2 DMA engine requires internal SRAM. PSRAM-backed buffers cause silent DMA failures or bus contention. |

### Required build flags

```yaml
esphome:
  platformio_options:
    build_flags:
      - -DCONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE=1024
      - -DCONFIG_USB_HOST_HW_BUFFER_BIAS_BALANCED=1
```

These mirror the sdkconfig values as preprocessor defines. Some ESP-IDF headers check these via `#ifdef`, so both the sdkconfig entry and the build flag are needed.

### Logger baud rate

```yaml
logger:
  baud_rate: 0
```

**Mandatory.** The ESP32-S3 USB pins (GPIO19/20) are shared between JTAG/serial and USB Host mode. `baud_rate: 0` releases them for USB Host. Log output is available via the ESPHome web server or Home Assistant API instead.

### Full example

See [`usbip_config.yaml`](usbip_config.yaml) for a complete working configuration including Ethernet, web server, OTA, and diagnostics.


## Technical Details

### USB/IP Protocol

The component implements USB/IP protocol version 0x0111 over a single TCP connection:

| Message | Direction | Purpose |
|---------|-----------|---------|
| `OP_REQ_DEVLIST` / `OP_REP_DEVLIST` | Client ← → Server | List connected USB devices with descriptors |
| `OP_REQ_IMPORT` / `OP_REP_IMPORT` | Client ← → Server | Attach a device; connection switches to URB mode |
| `USBIP_CMD_SUBMIT` / `USBIP_RET_SUBMIT` | Client ← → Server | Forward USB Request Blocks (control + bulk transfers) |
| `USBIP_CMD_UNLINK` / `USBIP_RET_UNLINK` | Client ← → Server | Cancel pending transfers |

### ESP32-S3 DWC2 Bulk OUT Bug

The ESP32-S3 uses a Synopsys DWC2 USB controller in Scatter-Gather DMA mode. This mode has a silicon bug: **bulk OUT transfers requiring multiple DMA descriptors freeze the controller**. Any OUT transfer larger than one max-packet-size (64 bytes for Full-Speed) triggers the freeze.

**Workaround:** Bulk OUT data is split into individual 64-byte MPS chunks, each submitted as a separate transfer via the ESP-IDF API. Single-descriptor transfers avoid the bug. ESP-IDF handles DATA0/DATA1 toggle tracking internally.

A direct Buffer DMA mode fallback (`USE_DIRECT_BULK_OUT=1`) that bypasses ESP-IDF is included in the source but disabled by default.

### Bulk IN Alignment

ESP-IDF rejects bulk IN transfers whose size is not a multiple of the endpoint max packet size (`ESP_ERR_INVALID_ARG`). The component rounds up all IN buffer allocations to the next 64-byte boundary.

### Device Hot-Plug

1. **Connect** — a background daemon task detects USB port events and sets flags. The main ESPHome loop opens the device, reads descriptors, claims interfaces, and caches configuration data.
2. **Disconnect** — interfaces are released, the device handle is closed, and the USB/IP TCP connection is terminated so the Linux client immediately detects the removal.
3. **Fallback discovery** — if the ESP-IDF `NEW_DEV` callback doesn't fire (a known edge case), the daemon scans addresses 1–10 after 5.5 seconds.

### HP P1102w Firmware Upload

The HP LaserJet P1102w powers up as a USB Mass Storage device ("Smart Install"). It must receive a firmware blob before switching to Printer class mode. When `printer_firmware` is configured, this happens automatically:

1. **Detect** — mass storage interface (class 0x08) on an HP VID triggers the flow
2. **Mode switch** — SCSI vendor command 0xD0 sent via CBW; device disconnects and re-enumerates
3. **Upload** — firmware sent in 64-byte chunks; progress logged every 10%
4. **Ready** — device re-enumerates with firmware loaded (`FWVER:` appears in Device ID)

The firmware is volatile (lost on every power cycle), so the upload repeats on every replug.

### Print Job Tracking

Bulk OUT activity is tracked to provide print job visibility in the logs:

- **Start** — first bulk OUT after 5 seconds of idle
- **Progress** — bytes sent, transfer count, and throughput logged every 2 seconds
- **Data preview** — first 48 bytes shown in ASCII/hex to identify the data format (PJL, ZJS, PCL, etc.)
- **End** — 5 seconds of inactivity after the last transfer

### Transfer Synchronization

USB transfers in ESP-IDF are asynchronous. The component uses a sequence-numbered semaphore pattern to match completions to requests:

1. `prepare_transfer()` assigns a unique sequence number and clears completion state
2. The transfer callback only accepts completions matching the expected sequence number
3. `wait_for_transfer()` actively pumps USB host events while waiting, preventing deadlocks between the ESPHome main loop and the USB daemon task


## Limitations

- Only one USB device is supported at a time (single-port USB host)
- Only one USB/IP client can be connected at a time
- Isochronous and interrupt transfers are not implemented (bulk and control only)
- Full-Speed devices only (12 Mbit/s) — the ESP32-S3 USB host does not support High-Speed
- PSRAM must be disabled due to DMA constraints
- The ESP-IDF 5.5 mDNS responder can stop answering *multicast* queries a while
  after boot (the service record itself stays intact and still answers unicast
  queries). The IP card and the web UI are not affected by this.

## Troubleshooting

| Symptom | Cause | Fix                                                                |
|---------|-------|--------------------------------------------------------------------|
| `usbip list` shows no devices | Printer not enumerated yet | Wait 10 seconds after boot; check web log for "Device enumerated"  |
| `usbip attach` hangs | Firewall blocking port 3240 | Open TCP port 3240 on the network                                  |
| Bulk OUT transfers fail / timeout | SG-DMA freeze with large transfers | Already mitigated by MPS chunking; check logs for STALL/NAK errors |
| `baud_rate` error on boot | Logger using USB pins | Set `logger: baud_rate: 0`                                         |
| Printer stuck in mass storage mode | Firmware not configured or upload failed | Add `printer_firmware: sihpP1102.dl` to config; verify file exists |
| Linux sees device but printing fails | Wrong driver or data format | Use `foo2zjs` for HP P1102w; verify with `lpstat -t`               |
| `usbip.exe list` fails on Windows | Elevation / firewall | Run from an **admin** PowerShell; allow the UAC prompt; check TCP 3240 |
| Windows attach succeeds but CAPT driver can't find printer | Driver probed before attach completed | Attach first, then install the driver, or rescan in Device Manager |
| RAW 9100 refuses connections | A USB/IP client is attached, or printer not ready | Detach with `usbip.exe detach -p *`; check web log for printer state |
| Printer drops off USB and re-enumerates | Deep sleep of host-based printers (e.g. LBP2900) | Usually harmless; use a short shielded cable; attach again if needed |
