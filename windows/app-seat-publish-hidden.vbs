' Runs app-seat-publish.ps1 without flashing a console window.
' Used by the 'Claude app-seat heartbeat' scheduled task (every 5 min). Same pattern as check-rotate-hidden.vbs.
Dim here : here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)   ' the rotator folder: this file sits in it
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File """ & here & "\app-seat-publish.ps1""", 0, False
