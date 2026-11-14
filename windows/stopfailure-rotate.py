"""StopFailure hook: a session just stopped on a quota limit or a subscription-disabled
403, so run the rotation check NOW instead of waiting up to 5 minutes for the scheduled
tick (headroom's reactive backstop, 2026-10-30).

The CLI does not always put the failure on the hook's top-level `error` field (that is why
a 403 kept logging "probe failed twice" and never rotated). When the field is absent this
reads only the transcript's newest API-error token. A normal stop, and a user message that
merely quotes the error, does not fire.

Fire-and-forget: launches `claude-cli-account.ps1 --check-rotate --now` and returns at
once, so the stopping session never waits on it. The check itself decides whether to rotate.
On an access refusal it first writes the rotator's refusal marker (<seat>/access-disabled.json,
the file and fields claude-rotate-proxy.py writes) for the seat THIS session ran on: the one whose
token.txt holds the session's CLAUDE_CODE_OAUTH_TOKEN, never whatever .active says now. The check
then takes its refusal path for that seat, including the fallback when probes time out.
A session that goes through the rotate proxy (ANTHROPIC_BASE_URL at its loopback port) is not
marked here: the proxy swaps in the active seat's token on every request, so the inherited token
says nothing about which seat refused, and the proxy records refusals itself.
Always exits 0: a broken backstop must never break a session.
"""
import json
import os
import subprocess
import sys
import time
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from rotator_access import HOOK_ERRORS, classify_hook
CMD = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
       os.path.join(HERE, "claude-cli-account.ps1"), "--check-rotate", "--now", "--source", "StopFailure"]
CREATE_NO_WINDOW, BREAKAWAY = 0x08000000, 0x01000000
ROOT = os.environ.get("CLAUDE_ROTATOR_TEST_ROOT") or os.path.join(os.path.expanduser("~"), ".claude-cli-accounts")
ACCESS_COOLDOWN = 1800                                          # the rotator's $AccessCooldownSec
ACCESS_TOKENS = ("oauth_org_not_allowed", "subscription_disabled")


def session_seat(root=None):
    """The seat this session runs on: the label whose token.txt holds the session's CLAUDE_CODE_OAUTH_TOKEN (the hook inherits
    the session's environment), or None. Seat folders as the rotator counts them (not . or _). The token is never logged or returned."""
    tok = (os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or "").strip()
    root = root or ROOT
    if not tok:
        return None
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None
    for name in names:
        if name[:1] in "._":
            continue
        try:
            with open(os.path.join(root, name, "token.txt"), encoding="utf-8-sig") as handle:
                if handle.read().strip() == tok:
                    return name
        except OSError:
            continue
    return None


def via_proxy():
    """True when this session talks to the local rotate proxy (ANTHROPIC_BASE_URL at its loopback port): the proxy owns refusal attribution."""
    try:
        u = urlsplit((os.environ.get("ANTHROPIC_BASE_URL") or "").strip())
        port = int(os.environ.get("CLAUDE_ROTATE_PROXY_PORT") or 18484)
        return (u.hostname or "") in ("127.0.0.1", "localhost", "::1") and u.port == port
    except ValueError:
        return False


def mark_refused(label, code, root=None):
    """Write <label>/access-disabled.json as the rotator reads it. Never touches token.txt."""
    path = os.path.join(root or ROOT, label, "access-disabled.json")
    now = int(time.time())
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump({"ts": now, "until": now + ACCESS_COOLDOWN, "http": 403, "code": code, "kind": "subscription_disabled"}, handle)
    os.replace(tmp, path)


def transcript_api_error(path):
    """The newest assistant API-error token in a transcript, or ''.

    Only isApiErrorMessage entries count. User text is never returned, and the raw line
    is not logged.
    """
    if not path or not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            handle.seek(max(0, size - 65536))
            blob = handle.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = blob.splitlines()
    if size > 65536 and lines:
        lines = lines[1:]  # a tail read can start mid-line
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        if entry.get("type") not in ("user", "assistant") or entry.get("isMeta") or entry.get("isSidechain"):
            continue
        if entry.get("type") == "assistant" and entry.get("isApiErrorMessage"):
            err = entry.get("error")
            err = err.strip() if isinstance(err, str) else ""
            try:
                text = entry["message"]["content"][0]["text"]
            except (KeyError, IndexError, TypeError):
                text = ""
            text = text.strip() if isinstance(text, str) else ""
            # A known token says it all. Otherwise (none, or a generic one such as "unknown") the displayed text of the
            # API-error turn is where a refusal shows, so it is read too.
            if err in HOOK_ERRORS or not text:
                return err[:500]
            return ((err + " " + text) if err else text)[:500]
        return ""
    return ""


def should_rotate(event):
    path = event.get("transcript_path") if isinstance(event, dict) else None
    return classify_hook(event, transcript_api_error(path))


def spawn(cmd):
    io = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    if sys.platform != "win32":  # LINUX-PORT: creationflags is Windows-only; a new session outlives the hook
        subprocess.Popen(cmd, start_new_session=True, **io)
        return
    try:  # leave the session's job object so the check outlives the hook
        subprocess.Popen(cmd, creationflags=CREATE_NO_WINDOW | BREAKAWAY, **io)
    except OSError:
        subprocess.Popen(cmd, creationflags=CREATE_NO_WINDOW, **io)


def rotator_cmd():
    sink = os.environ.get("CLAUDE_ROTATOR_TEST_SINK")
    if sink:
        # Test harness only. Records that the hook fired, without starting the rotator.
        return [sys.executable, "-I", "-c",
                "import os; open(os.environ['CLAUDE_ROTATOR_TEST_SINK'],'a',encoding='utf-8').write('fired\\n')"]
    return CMD


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return
    why = should_rotate(event)
    if not why:
        return
    # A test run (the sink) never marks a real seat: only with its own sandbox root.
    if why in ACCESS_TOKENS and not via_proxy() and (os.environ.get("CLAUDE_ROTATOR_TEST_ROOT") or not os.environ.get("CLAUDE_ROTATOR_TEST_SINK")):
        try:
            seat = session_seat()
            if seat:
                mark_refused(seat, why)
        except Exception:
            pass
    try:
        spawn(rotator_cmd())
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
