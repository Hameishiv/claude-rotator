"""claude-rotate-proxy - local pass-through proxy for Claude Code TERMINAL / VS Code sessions
(Option C, 2026-10-30).

Two ideas borrowed from doxaras/claude-rotate (MIT), and nothing else:
  1. Read the usage headers off EVERY real response instead of probing on a 5-minute clock.
     They land in the same <label>/usage-cache[-fable].json files a probe writes (tagged
     src=proxy), so the watcher, --best and the Fable ladder all read them for free.
  2. On a QUOTA 429 (a window is "rejected"), ask the rotator to rotate now and retry the
     request once on the seat it picked, instead of letting the session stall.

The proxy never chooses an account. claude-cli-account.ps1 stays the brain (Fable rules, the
desktop-app seat, renewal order, the rate cap). The proxy always sends the ACTIVE seat's token,
re-read per request, so running sessions follow a rotation without a restart.

Only requests that carry one of the rotator's own setup-tokens are re-pointed. Anything else is
forwarded untouched. Binds 127.0.0.1 only. The desktop app cannot be routed through it: the app
sets ANTHROPIC_BASE_URL itself, and that beats every settings file (tested 2026-10-30).

Run:   pythonw -I claude-rotate-proxy.py          (the 'Claude rotate proxy' task does this)
Check: claude-rotate-proxy.py --self-test         (offline checks of the pure helpers)
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CLAUDE_ROTATE_PROXY_PORT", "18484"))
UPSTREAM = "api.anthropic.com"
ROOT = os.path.join(os.path.expanduser("~"), ".claude-cli-accounts")
ROTATOR_CMD = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
               r"C:\Dev\Rotators\claude-cli-account.ps1", "--check-rotate", "--now", "--source", "proxy"]
# Test harness only (claude-rotate-proxy-test.py): a fake plain-HTTP upstream, a sandbox seat
# store and a fake rotator. Never set in normal use.
TEST_UPSTREAM = os.environ.get("CLAUDE_ROTATE_PROXY_TEST_UPSTREAM")      # host:port, plain http
ROOT = os.environ.get("CLAUDE_ROTATE_PROXY_TEST_ROOT") or ROOT
if os.environ.get("CLAUDE_ROTATE_PROXY_TEST_ROTATOR"):
    ROTATOR_CMD = [sys.executable, "-I", os.environ["CLAUDE_ROTATE_PROXY_TEST_ROTATOR"]]
ACTIVE = os.path.join(ROOT, ".active")
LOG = os.path.join(ROOT, ".proxy-log.txt")
HOP = {"host", "connection", "keep-alive", "proxy-authorization", "proxy-connection", "te",
       "trailers", "transfer-encoding", "upgrade", "content-length", "accept-encoding"}
RL = "anthropic-ratelimit-unified-"
# usage-cache field -> response header. Same names Probe-Usage writes.
FIELDS = {"status": RL + "status", "s5_util": RL + "5h-utilization", "s5_stat": RL + "5h-status",
          "s5_reset": RL + "5h-reset", "w7_util": RL + "7d-utilization", "w7_stat": RL + "7d-status",
          "w7_reset": RL + "7d-reset", "oi7_util": RL + "7d_oi-utilization",
          "oi7_stat": RL + "7d_oi-status", "oi7_reset": RL + "7d_oi-reset",
          "claim": RL + "representative-claim", "org": "anthropic-organization-id"}
WRITE_EVERY = 5        # s between cache writes per seat (a rejection always writes at once)
ROTATE_COOLDOWN = 20   # s: after a rotation attempt that changed nothing, don't ask again yet
LOG_MAX = 1_000_000

_lock = threading.Lock()          # tokens, cache-write stamps, log
_rotate_lock = threading.Lock()   # one rotation request at a time
_state = {"tokens": {}, "by_label": {}, "loaded": 0.0, "written": {}, "last_rotate": 0.0}


def log(msg):
    line = "%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    with _lock:
        try:
            if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_MAX:
                os.replace(LOG, LOG + ".1")
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass


def load_tokens(force=False):
    """token -> label for every captured seat. Re-read at most every 15 s."""
    with _lock:
        if not force and time.time() - _state["loaded"] < 15:
            return _state["tokens"], _state["by_label"]
        tokens, by_label = {}, {}
        try:
            for name in os.listdir(ROOT):
                tf = os.path.join(ROOT, name, "token.txt")
                if name[:1] in "._" or not os.path.isfile(tf):
                    continue
                with open(tf, encoding="utf-8-sig") as f:
                    tok = f.read().strip()
                if tok:
                    tokens[tok] = name
                    by_label[name] = tok
        except OSError:
            pass
        _state.update(tokens=tokens, by_label=by_label, loaded=time.time())
        return tokens, by_label


def active_label():
    try:
        with open(ACTIVE, encoding="utf-8-sig") as f:
            return f.read().strip() or None
    except OSError:
        return None


def bearer(headers):
    auth = headers.get("authorization") or ""
    return auth[7:].strip() if auth.lower().startswith("bearer ") else None


def usage_record(label, status, model, headers):
    """The usage-cache 'data' object for one response, or None when it carried no usage."""
    data = {"label": label, "ok": True, "http": status, "model": model, "note": "", "src": "proxy"}
    for key, h in FIELDS.items():
        data[key] = headers.get(h)
    # A rejection is worth recording even with no utilisation numbers: it is what a --now check
    # must see (Grok review 2026-10-30).
    rejected = any(data[k] == "rejected" for k in ("status", "s5_stat", "w7_stat", "oi7_stat"))
    return data if (data["s5_util"] or data["oi7_util"] or rejected) else None


def is_quota_rejection(status, headers):
    """A 429 that means a window is spent (rotate), as opposed to a per-minute burst (wait)."""
    if status != 429:
        return False
    return any(headers.get(RL + k) == "rejected" for k in ("status", "5h-status", "7d-status", "7d_oi-status"))


def write_cache(label, data):
    """Atomic write of <label>/usage-cache.json (and -fable when the Fable window rode along)."""
    rejected = any(data.get(k) == "rejected" for k in ("status", "s5_stat", "w7_stat", "oi7_stat"))
    now = time.time()
    for suffix, present in (("", data.get("s5_util") or rejected), ("-fable", data.get("oi7_util"))):
        if not present:
            continue
        key = label + suffix
        with _lock:
            if not rejected and now - _state["written"].get(key, 0) < WRITE_EVERY:
                continue
            _state["written"][key] = now
        path = os.path.join(ROOT, label, "usage-cache%s.json" % suffix)
        tmp = "%s.tmp-%d-%d" % (path, os.getpid(), threading.get_ident())
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"ts": int(now), "data": data}, f)
            os.replace(tmp, path)
        except OSError as e:
            log("cache write failed for %s: %s" % (key, e))


def ask_rotator(seen_label):
    """Run the rotator's check now. Returns the active label afterwards."""
    with _rotate_lock:
        current = active_label()
        if current != seen_label:          # another request already rotated
            return current
        if time.time() - _state["last_rotate"] < ROTATE_COOLDOWN:
            return current
        log("quota 429 on '%s' - asking the rotator to rotate" % seen_label)
        # Wait up to 150 s, but NEVER kill the rotator on timeout: it may be mid-switch (it waits up
        # to 90 s for the check mutex first), and a kill there leaves .active, the env var and
        # .credentials.json disagreeing (Fable review 2026-10-30, P1-2). It finishes on its own.
        try:
            p = subprocess.Popen(ROTATOR_CMD, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, creationflags=0x08000000)
            try:
                p.wait(timeout=150)
            except subprocess.TimeoutExpired:
                log("rotator still running after 150 s - left to finish; this request gets the 429")
        except OSError as e:
            log("rotator call failed: %r" % e)
        after = active_label()
        log("rotator done: '%s' -> '%s'" % (seen_label, after))
        # Cool down only when nothing moved. After a real rotation, a 429 from the NEW seat must be
        # able to ask again at once (Grok review 2026-10-30).
        if after == seen_label:
            _state["last_rotate"] = time.time()
        return after


class Pool:
    """A few idle upstream TLS connections, so each request skips a fresh handshake."""

    def __init__(self, size=8):
        self.idle, self.size, self.lock = [], size, threading.Lock()

    def get(self):
        with self.lock:
            if self.idle:
                return self.idle.pop(), True
        if TEST_UPSTREAM:
            return http.client.HTTPConnection(TEST_UPSTREAM, timeout=30), False
        return http.client.HTTPSConnection(UPSTREAM, timeout=600), False

    def put(self, conn):
        with self.lock:
            if len(self.idle) < self.size:
                self.idle.append(conn)
                return
        conn.close()


POOL = Pool()


def send_upstream(method, path, body, headers):
    """One request. A reused connection the server already closed is retried once on a new one."""
    for attempt in (0, 1):
        conn, reused = POOL.get()
        try:
            conn.request(method, path, body=body, headers=headers)
            return conn, conn.getresponse()
        except (http.client.RemoteDisconnected, ConnectionError, BrokenPipeError, http.client.CannotSendRequest):
            conn.close()
            if not reused or attempt:
                raise
    raise RuntimeError("unreachable")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # close after each response: the body ends at EOF, SSE streams as-is

    def log_message(self, *args):
        pass

    def _read_body(self):
        if (self.headers.get("transfer-encoding") or "").lower() == "chunked":
            out = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return bytes(out)
                out += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("content-length") or 0)
        return self.rfile.read(n) if n else None

    def _health(self):
        body = json.dumps({"ok": True, "active": active_label(), "port": PORT}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _go(self):
        if self.path.startswith("/__proxy/health"):
            return self._health()
        body = self._read_body()
        fwd = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        fwd["accept-encoding"] = "identity"
        model = None
        if body and self.command == "POST":
            try:
                model = json.loads(body).get("model")
            except (ValueError, AttributeError):
                pass
        tokens, by_label = load_tokens()
        ours = bearer(self.headers) in tokens
        label = None
        for attempt in (0, 1):
            if ours:
                label = active_label()
                tok = by_label.get(label) if label else None
                if not tok:   # no usable active seat: send the caller's own token
                    tok, label = bearer(self.headers), tokens.get(bearer(self.headers))
                fwd = {k: v for k, v in fwd.items() if k.lower() != "authorization"}
                fwd["Authorization"] = "Bearer " + tok
            try:
                conn, r = send_upstream(self.command, self.path, body, fwd)
            except Exception as e:
                log("upstream error %s %s: %r" % (self.command, self.path.split("?")[0], e))
                self.send_error(502, "claude-rotate-proxy: upstream unreachable")
                return
            hdrs = {k.lower(): v for k, v in r.getheaders()}
            if label:
                rec = usage_record(label, r.status, model, hdrs)
                if rec:
                    write_cache(label, rec)
            if attempt == 0 and ours and is_quota_rejection(r.status, hdrs):
                spent = r.read()   # small JSON error body; keep it in case nothing better turns up
                self._release(conn, r)
                after = ask_rotator(label)
                if after and after != label and after in by_label:
                    log("retrying %s on '%s'" % (self.path.split("?")[0], after))
                    continue
                self._head(r)
                self.wfile.write(spent)
                return
            return self._relay(conn, r)

    @staticmethod
    def _release(conn, r):
        # Reuse only a connection whose response is fully closed. One handed back with a response
        # still open fails the NEXT request with ResponseNotReady after that request was already
        # sent - seen live 2026-10-30 on a streamed reply.
        if r.will_close or not r.isclosed():
            conn.close()
        else:
            POOL.put(conn)

    def _head(self, r):
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.end_headers()

    def _relay(self, conn, r):
        self._head(r)
        try:
            while True:
                chunk = r.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionError):   # the client went away mid-stream
            conn.close()
            return
        self._release(conn, r)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _go


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False   # on Windows SO_REUSEADDR lets a SECOND instance bind the port

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def self_test():
    h = {RL + "status": "allowed", RL + "5h-status": "rejected", RL + "5h-utilization": "1.02"}
    assert is_quota_rejection(429, h)
    assert not is_quota_rejection(429, {RL + "status": "allowed"})      # burst: no rotation
    assert not is_quota_rejection(200, h)
    assert is_quota_rejection(429, {RL + "7d_oi-status": "rejected"})   # Fable cap rotates too
    rec = usage_record("A", 200, "m", h)
    assert rec["s5_util"] == "1.02" and rec["s5_stat"] == "rejected" and rec["src"] == "proxy"
    assert usage_record("A", 200, "m", {}) is None
    assert bearer({"authorization": "Bearer abc"}) == "abc" and bearer({}) is None
    print("self-test ok")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    load_tokens(force=True)
    try:
        srv = Server(("127.0.0.1", PORT), Handler)
    except OSError as e:   # already running (the task re-launches every minute; that is fine)
        if "--verbose" in sys.argv:
            print("port %d busy: %s" % (PORT, e))
        return
    log("listening on 127.0.0.1:%d, active '%s', %d seats" % (PORT, active_label(), len(_state["by_label"])))
    srv.serve_forever()


if __name__ == "__main__":
    main()
