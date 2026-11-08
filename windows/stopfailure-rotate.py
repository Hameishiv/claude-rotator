"""StopFailure hook: a session just stopped on a quota limit or a subscription-disabled
403, so run the rotation check NOW instead of waiting up to 5 minutes for the scheduled
tick (headroom's reactive backstop, 2026-10-30).

The CLI does not always put the failure on the hook's top-level `error` field (that is why
a 403 kept logging "probe failed twice" and never rotated). When the field is absent this
reads only the transcript's newest API-error token. A normal stop, and a user message that
merely quotes the error, does not fire.

Fire-and-forget: launches `claude-cli-account.ps1 --check-rotate --now` and returns at
once, so the stopping session never waits on it. The check itself decides whether to rotate.
Always exits 0: a broken backstop must never break a session.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from rotator_access import classify_hook
CMD = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
       os.path.join(HERE, "claude-cli-account.ps1"), "--check-rotate", "--now", "--source", "StopFailure"]
CREATE_NO_WINDOW, BREAKAWAY = 0x08000000, 0x01000000


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
            if isinstance(err, str) and err.strip():
                return err.strip()[:500]
            # Some builds leave the code only in the displayed text of the API-error turn.
            try:
                text = entry["message"]["content"][0]["text"]
            except (KeyError, IndexError, TypeError):
                text = ""
            if isinstance(text, str):
                return text.strip()[:500]
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
    if not should_rotate(event):
        return
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
