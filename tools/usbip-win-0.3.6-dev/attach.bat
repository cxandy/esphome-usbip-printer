@echo off
setlocal EnableDelayedExpansion
REM ============================================================
REM  One-click USB/IP attach for ESP32 print server
REM  Double-click to attach + keep alive (auto re-attach).
REM
REM  Usage:
REM    attach.bat              attach and keep alive (watchdog)
REM    attach.bat once         attach once and exit
REM    attach.bat autostart    register a logon scheduled task, then run
REM    attach.bat detach       detach everything and stop the watchdog
REM
REM  Config: edit the three lines below if your setup differs.
REM ============================================================

REM --- IP of the ESP32 print server ---------------------------
set "SERVER_IP=192.168.137.194"
REM --- busid; leave empty to auto-detect the first device -----
set "BUSID="
REM --- watchdog re-attach interval (seconds) ------------------
set "WATCH_INTERVAL=15"
REM ------------------------------------------------------------

cd /d "%~dp0"

REM --- self-elevate to administrator ---------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    exit /b
)

if /i "%~1"=="detach" goto :detach
if /i "%~1"=="autostart" call :autostart
if /i "%~1"=="autostart" set "WATCH=1"

REM --- make sure the vhci driver is installed (idempotent) -----
usbip.exe install >nul 2>&1

REM --- auto-detect busid if not configured ---------------------
if "%BUSID%"=="" (
    for /f "tokens=1 delims=: " %%a in ('usbip.exe list -r %SERVER_IP% 2^>nul ^| findstr /r /c:"^[0-9][0-9]*-[0-9][0-9]*:"') do set "BUSID=%%a"
)
if "%BUSID%"=="" (
    echo [ERROR] No USB device found on %SERVER_IP%.
    echo         Is the printer plugged in and the server reachable?
    pause
    exit /b 1
)

echo.
echo Server : %SERVER_IP%
echo Device : busid %BUSID%
echo.

REM --- initial attach (non-blocking; attacher.exe keeps it) ----
usbip.exe attach -r %SERVER_IP% -b %BUSID%
if %errorlevel%==0 (
    echo [OK] Attached successfully. Install the vendor driver now
    echo      if this is the first time (Device Manager shows the
    echo      device under "Universal Serial Bus controllers").
) else (
    echo [WARN] First attach attempt failed - the watchdog below
    echo        will keep retrying every %WATCH_INTERVAL%s.
)

if /i "%~1"=="once" exit /b 0

REM --- watchdog: re-attach whenever the device disappears ------
echo.
echo Watchdog running: re-attaching automatically every %WATCH_INTERVAL%s
echo if the printer drops off (e.g. after deep sleep). Close this
echo window to stop it.
echo.
:watch
timeout /t %WATCH_INTERVAL% /nobreak >nul
usbip.exe attach -r %SERVER_IP% -b %BUSID% >nul 2>&1
if %errorlevel%==0 echo [%date% %time%] (re-)attached %BUSID%
goto :watch

:detach
usbip.exe detach -p * >nul 2>&1
echo [OK] Detached all USB/IP devices.
timeout /t 3 >nul
exit /b 0

:autostart
echo Registering logon scheduled task "USBIP-Attach" (no UAC at logon)...
schtasks /create /f /tn "USBIP-Attach" /tr "\"%~f0\"" /sc onlogon /rl highest >nul 2>&1
if %errorlevel%==0 (
    echo [OK] Done. The printer will be attached automatically at every logon.
) else (
    echo [WARN] Could not create the scheduled task.
)
exit /b 0
