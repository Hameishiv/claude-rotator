' Runs app-seat-publish.ps1 without flashing a console window.
' Used by the 'Claude app-seat heartbeat' scheduled task (every 5 min). Same pattern as check-rotate-hidden.vbs.
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File ""C:\Dev\Rotators\app-seat-publish.ps1""", 0, False
