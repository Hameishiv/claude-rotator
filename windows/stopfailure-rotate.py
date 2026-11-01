"""StopFailure hook: a session just stopped on a rate limit, so run the rotation check NOW
instead of waiting up to 5 minutes for the scheduled tick (headroom's reactive backstop, 2026-10-30).

Fire-and-forget: launches `claude-cli-account.ps1 --check-rotate --now` hidden and returns at
once, so the stopping session never waits on it. The check itself decides whether to rotate (it
re-reads the ACTIVE seat, so a session that was on some other account costs one probe, nothing
more). Always exits 0: a broken backstop must never break a session.
"""
import json
import subprocess
import sys

TRIGGERS = {"rate_limit", "billing_error"}  # billing_error is how the CLI labels "usage limit reached"
CMD = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
       r"C:\Dev\Rotators\claude-cli-account.ps1", "--check-rotate", "--now", "--source", "StopFailure"]
CREATE_NO_WINDOW, BREAKAWAY = 0x08000000, 0x01000000


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return
    if event.get("error") not in TRIGGERS:
        return
    io = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    try:  # leave the session's job object so the check outlives the hook
        subprocess.Popen(CMD, creationflags=CREATE_NO_WINDOW | BREAKAWAY, **io)
    except OSError:
        subprocess.Popen(CMD, creationflags=CREATE_NO_WINDOW, **io)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
