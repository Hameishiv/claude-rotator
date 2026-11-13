"""Fixture tests for the StopFailure hook and for which seat directories the proxy will load.

No network. No real tokens. Run:  python3 windows/test-stopfailure-rotate.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rotator_access import classify_hook, is_subscription_disabled

def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

hook = _load("stopfailure_rotate", "stopfailure-rotate.py")

SECRET = "sk-ant-oat01-SUPERSECRETTOKENVALUE"
fail = 0


def check(name, ok, detail=""):
    global fail
    if ok:
        print("  PASS ", name)
    else:
        fail += 1
        print("  FAIL ", name, detail)


def test_fixtures():
    with open(os.path.join(HERE, "fixtures", "access-responses.json"), encoding="utf-8") as handle:
        cases = json.load(handle)
    for case in cases:
        got = is_subscription_disabled(case["status"], case["body"])
        check("fixture http %s disabled=%s" % (case["status"], case["disabled"]), got is case["disabled"], repr(got))


def test_classify():
    check("rate_limit fires", classify_hook({"error": "rate_limit"}) == "rate_limit")
    check("billing_error fires", classify_hook({"error": "billing_error"}) == "billing_error")
    check("oauth_org_not_allowed fires", classify_hook({"error": "oauth_org_not_allowed"}) == "oauth_org_not_allowed")
    check("phrase in the error field fires",
          classify_hook({"error": "403 permission_error: OAuth authentication is currently not allowed for this organization."})
          == "oauth_org_not_allowed")
    check("normal stop does not fire", classify_hook({"error": None, "last_assistant_message": "done"}) is None)
    # A user quoting the outage in the hook payload must not rotate. Only error / api_error count.
    check("quoted phrase outside the error field does not fire",
          classify_hook({"last_assistant_message": "oauth_org_not_allowed"}) is None)
    check("transcript token fires when the event has no error",
          classify_hook({}, "oauth_org_not_allowed") == "oauth_org_not_allowed")
    check("empty transcript does not fire", classify_hook({}) is None)


def test_transcript_reader():
    path = os.path.join(tempfile.mkdtemp(prefix="sf-"), "s.jsonl")
    user = {"type": "user", "message": {"role": "user", "content": "please ignore oauth_org_not_allowed"}}
    normal = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(user) + "\n" + json.dumps(normal) + "\n")
    check("user quotation is not an API error", hook.transcript_api_error(path) == "")
    denied = {"type": "assistant", "isApiErrorMessage": True, "error": "oauth_org_not_allowed",
              "message": {"role": "assistant", "content": [{"type": "text", "text": "Your organization has disabled Claude subscription access for Claude Code"}]}}
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(denied) + "\n")
    check("newest API error token is read", hook.transcript_api_error(path) == "oauth_org_not_allowed")
    check("should_rotate uses that token", hook.should_rotate({"transcript_path": path}) == "oauth_org_not_allowed")
    check("token text is not required to contain the secret", SECRET not in hook.transcript_api_error(path))


def test_spawn_gate():
    sink = os.path.join(tempfile.mkdtemp(prefix="sf-sink-"), "fired.txt")
    env = dict(os.environ, CLAUDE_ROTATOR_TEST_SINK=sink, CLAUDE_ROTATOR_TEST_ROOT=tempfile.mkdtemp(prefix="sf-root-"))
    env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)        # never this session's real token: no real seat can be matched or marked
    script = os.path.join(HERE, "stopfailure-rotate.py")

    def run(event, expect):
        if os.path.exists(sink):
            os.remove(sink)
        subprocess.run([sys.executable, "-I", script], input=json.dumps(event).encode(),
                       env=env, check=False, timeout=15)
        # The hook starts a detached child that writes the sink after the hook has returned, so
        # wait for it (a loaded machine takes seconds); when none is expected, give a stray one time to land.
        deadline = time.time() + (15 if expect else 2)
        while time.time() < deadline and not os.path.exists(sink):
            time.sleep(0.05)
        return os.path.exists(sink)

    check("hook spawns on oauth_org_not_allowed", run({"error": "oauth_org_not_allowed"}, True))
    check("hook does not spawn on a normal stop", not run({"stop_hook_active": False}, False))
    path = os.path.join(tempfile.mkdtemp(prefix="sf-tr-"), "t.jsonl")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "user", "message": {"content": "oauth_org_not_allowed"}}) + "\n")
        handle.write(json.dumps({"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit",
                                  "message": {"content": [{"type": "text", "text": "limit"}]}}) + "\n")
    check("hook spawns from the transcript when error is absent", run({"transcript_path": path}, True))


def test_refusal_marks_the_sessions_seat():
    """An access refusal writes the rotator's marker for the seat the SESSION ran on (its own token), not the active one."""
    root = tempfile.mkdtemp(prefix="sf-seat-")
    for label, token in (("A", "tok-A"), ("B", "tok-B"), ("_old", "tok-B"), (".inactive", "tok-B")):
        os.makedirs(os.path.join(root, label))
        with open(os.path.join(root, label, "token.txt"), "w", encoding="utf-8") as handle:
            handle.write(token + "\n")
    with open(os.path.join(root, ".active"), "w", encoding="utf-8") as handle:
        handle.write("A")                           # another session already moved .active on
    sink = os.path.join(root, "fired.txt")
    script = os.path.join(HERE, "stopfailure-rotate.py")
    env = dict(os.environ, CLAUDE_ROTATOR_TEST_SINK=sink, CLAUDE_ROTATOR_TEST_ROOT=root, CLAUDE_CODE_OAUTH_TOKEN="tok-B")
    env.pop("ANTHROPIC_BASE_URL", None)             # a direct session
    env.pop("CLAUDE_ROTATE_PROXY_PORT", None)
    keep = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "tok-B"
    try:
        check("the session's seat is found by its token", hook.session_seat(root) == "B")
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "tok-none"
        check("an unknown token is no seat", hook.session_seat(root) is None)
    finally:
        if keep is None:
            os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        else:
            os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = keep

    def run(event):
        subprocess.run([sys.executable, "-I", script], input=json.dumps(event).encode(), env=env, check=False, timeout=15)
    run({"error": "rate_limit"})
    check("a quota stop writes no marker", not any(os.path.exists(os.path.join(root, l, "access-disabled.json")) for l in "AB"))
    run({"error": "403 permission_error: OAuth authentication is currently not allowed for this organization."})
    mb = os.path.join(root, "B", "access-disabled.json")
    data = json.load(open(mb, encoding="utf-8")) if os.path.exists(mb) else {}
    check("the refusal marks the session's seat B with its reason", data.get("code") == "oauth_org_not_allowed" and data.get("http") == 403
          and data.get("kind") == "subscription_disabled" and data.get("until", 0) - data.get("ts", 0) == 1800, repr(data))
    check("the active seat A is not marked", not os.path.exists(os.path.join(root, "A", "access-disabled.json")))
    check("the marker holds no token", "tok-" not in open(mb, encoding="utf-8").read() if os.path.exists(mb) else False)
    check("the token files are untouched", open(os.path.join(root, "B", "token.txt"), encoding="utf-8").read() == "tok-B\n")
    # through the rotate proxy the inherited token is not the seat that refused (the proxy swaps tokens): the proxy owns attribution
    os.remove(mb)
    if os.path.exists(sink):
        os.remove(sink)
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:18484"
    run({"error": "oauth_org_not_allowed"})
    deadline = time.time() + 15
    while time.time() < deadline and not os.path.exists(sink):
        time.sleep(0.05)
    check("a proxied session marks no seat, and the check still runs", not os.path.exists(mb) and os.path.exists(sink))
    env["ANTHROPIC_BASE_URL"] = "https://api.anthropic.com"
    run({"error": "oauth_org_not_allowed"})
    check("a direct session with an explicit API URL is still marked", os.path.exists(mb))


def test_seat_dirs_not_letters():
    root = tempfile.mkdtemp(prefix="seats-")
    for label, token in (("A", "tok-A"), ("B", SECRET)):
        os.makedirs(os.path.join(root, label))
        with open(os.path.join(root, label, "token.txt"), "w", encoding="utf-8") as handle:
            handle.write(token)
    os.makedirs(os.path.join(root, ".inactive", "L"))
    with open(os.path.join(root, ".inactive", "L", "token.txt"), "w", encoding="utf-8") as handle:
        handle.write(SECRET)
    os.makedirs(os.path.join(root, "_old"))
    with open(os.path.join(root, "_old", "token.txt"), "w", encoding="utf-8") as handle:
        handle.write("tok-old")
    os.environ["CLAUDE_ROTATE_PROXY_TEST_ROOT"] = root
    spec = importlib.util.spec_from_file_location("claude_rotate_proxy_under_test", os.path.join(HERE, "claude-rotate-proxy.py"))
    proxy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proxy)
    tokens, by_label = proxy.load_tokens(force=True)
    check("A is a loaded seat", "A" in by_label and by_label["A"] == "tok-A", str(sorted(by_label)))
    check("B is a loaded seat", by_label.get("B") == SECRET)
    check(".inactive identity is not a seat", "L" not in by_label and "_old" not in by_label, str(sorted(by_label)))
    check("secret is the token value, not a log line", SECRET not in json.dumps(list(by_label)))


def main():
    print("stopfailure + seat discovery")
    test_fixtures()
    test_classify()
    test_transcript_reader()
    test_spawn_gate()
    test_refusal_marks_the_sessions_seat()
    test_seat_dirs_not_letters()
    if fail:
        print("%d FAILED" % fail)
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
