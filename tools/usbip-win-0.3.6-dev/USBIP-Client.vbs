' ============================================================
'  USB/IP Print Client GUI launcher - no console window.
'  Double-click this file instead of USBIP-Client.bat.
'  It elevates once (UAC) and starts the WPF UI hidden-console.
' ============================================================
Option Explicit

Dim fso, sh, dir, ps
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Shell.Application")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = dir & "\usbip-gui.ps1"

If Not fso.FileExists(ps) Then
    MsgBox "usbip-gui.ps1 not found next to this script:" & vbCrLf & ps, 16, "USB/IP Print Client"
    WScript.Quit 1
End If

' "runas" triggers the UAC prompt; 0 = SW_HIDE keeps the PowerShell
' console from ever appearing.
sh.ShellExecute "powershell.exe", _
    "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps & """", _
    "", "runas", 0
