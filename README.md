# claude-rotator

Account-seat rotation for Claude Code, built for one person running many
long-lived agent sessions across several subscription seats.

- **windows/**: the PowerShell rotators. `claude-cli-account.ps1` watches each seat's usage and
  switches the CLI before a seat caps; `claude-rotate-proxy.py` is an optional local proxy that reads usage off every response and
  retries a capped request on the next seat; `claude-resume-sessions.ps1` nudges only sessions a
  usage limit actually stopped. Full notes: `windows/README-claude-rotator.md`.
- **linux/**: the same rotator as it runs on a Linux box (PowerShell 7 on Linux).
- **mods/seats/**: a Claude Code mod adding `/seats`, which prints seat status
  without a model turn.

Paths, seat labels and account emails are placeholders (`seatN@example.com`); set your own.
This is a working personal setup shared as reference, not a packaged tool. Rotating
subscriptions you own is between you and each provider's terms.
