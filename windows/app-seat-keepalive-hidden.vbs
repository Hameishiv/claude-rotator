' Runs claude-app-seat-keepalive.ps1 without flashing a console window.
' Used by the 'Claude app-seat keepalive' scheduled task (every 6 h). Same pattern as check-rotate-hidden.vbs.
Dim here : here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)   ' the rotator folder: this file sits in it
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File """ & here & "\claude-app-seat-keepalive.ps1""", 0, False
