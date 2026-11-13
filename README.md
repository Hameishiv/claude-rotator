# claude-rotator

Account-seat rotation for Claude Code across several subscription seats, plus the **Agent Dashboard**: one local
page showing the usage left on every Claude, Codex, xAI and Gemini seat you have.

- **windows/**: the PowerShell rotators. `claude-cli-account.ps1` watches each seat's usage and
  switches the CLI before a seat caps; `claude-rotate-proxy.py` is an optional local proxy that reads usage off every response and
  retries a capped request on the next seat; `claude-resume-sessions.ps1` nudges only sessions a
  usage limit actually stopped. Full notes: `windows/README-claude-rotator.md`.
- **linux/**: the same rotator as it runs on a Linux box (PowerShell 7 on Linux).
- **mods/seats/**: a Claude Code mod adding `/seats`, which prints seat status
  without a model turn.

**Quick start:** `windows/README-claude-rotator.md` -> *Quick start* (prerequisites, install, first run, and what each
dashboard tab needs). Paths, seat labels and account emails in the docs are examples (`seatN@example.com`); use your own.
Rotating subscriptions you own is between you and each provider's terms. Windows only for now.
