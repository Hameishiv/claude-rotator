' Runs claude-cli-account.ps1 --check-rotate without flashing a console window.
' Used by the 'Claude usage auto-rotate' scheduled task (every 5 min).
' Same pattern as ~\.grok\bin\sync-app-history-hidden.vbs. Without it the task pops a visible
' pwsh window on every tick, which on 2026-08-16 showed a bare "TRIGGER" line and looked like a
' crash while the rotation was still working.
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File ""C:\Dev\Rotators\claude-cli-account.ps1"" --check-rotate", 0, False
