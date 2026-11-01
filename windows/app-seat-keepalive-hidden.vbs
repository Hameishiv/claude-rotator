' Runs claude-app-seat-keepalive.ps1 without flashing a console window.
' Used by the 'Claude app-seat keepalive' scheduled task (every 6 h). Same pattern as check-rotate-hidden.vbs.
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File ""C:\Dev\Rotators\claude-app-seat-keepalive.ps1""", 0, False
