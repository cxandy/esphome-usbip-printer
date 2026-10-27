@echo off
rem Launcher for the USB/IP print client GUI.
rem Self-elevates once, then opens the PowerShell WinForms UI.

cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0usbip-gui.ps1"
