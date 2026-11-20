"""claude-rotate-proxy - local pass-through proxy for Claude Code TERMINAL / VS Code sessions
(Option C, 2026-10-30).

Two ideas borrowed from doxaras/claude-rotate (MIT), and nothing else:
  1. Read the usage headers off EVERY real response instead of probing on a 5-minute clock.
     They land in the same <label>/usage-cache[-fable].json files a probe writes (tagged
     src=proxy), so the watcher, --best and the Fable ladder all read them for free.
  2. On a QUOTA 429 (a window is "rejected"), or on an explicit subscription-disabled 403,
     ask the rotator to rotate now and retry the request once on the seat it picked.
     A network failure is not either of those and does not mark a seat disabled.

The proxy never chooses an account. claude-cli-account.ps1 stays the brain (Fable rules, the
desktop-app seat, renewal order, the rate cap). The proxy always sends the ACTIVE seat's token,
re-read per request, so running sessions follow a rotation without a restart.

Only requests that carry one of the rotator's own setup-tokens are re-pointed. Anything else is
forwarded untouched. Binds 127.0.0.1 only. The desktop app cannot be routed through it: the app
sets ANTHROPIC_BASE_URL itself, and that beats every settings file (tested 2026-10-30).

Run:   pythonw -I claude-rotate-proxy.py          (the 'Claude rotate proxy' task does this)
Check: claude-rotate-proxy.py --self-test         (offline checks: pure helpers, and cache writes in a temp root)
"""
import http.client
from contextlib import contextmanager
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from rotator_access import access_code, is_subscription_disabled, marker_belongs, token_fingerprint

PORT = int(os.environ.get("CLAUDE_ROTATE_PROXY_PORT", "18484"))
UPSTREAM = "api.anthropic.com"
ROOT = os.path.join(os.path.expanduser("~"), ".claude-cli-accounts")
ROTATOR_CMD = ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
               os.path.join(_HERE, "claude-cli-account.ps1"), "--check-rotate", "--now", "--source", "proxy"]
ACCESS_COOLDOWN = 1800
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
WRITE_EVERY = 5        # s between cache writes per seat. A rejection skips it, and so does a Fable reading while this
                       # proxy last saw a Fable rejection in that file. After a failed write, nothing is written for this long.
CACHE_LOCK_TRIES = 40  # x 25 ms: a cold PowerShell writer can hold the cache lock for over 100 ms
ROTATE_COOLDOWN = 20   # s: after a rotation attempt that changed nothing, don't ask again yet
LOG_MAX = 1_000_000

_lock = threading.Lock()          # tokens and log
_cache_locks = {}                  # same-process writers to each cache path
_rotate_lock = threading.Lock()   # one rotation request at a time
_state = {"tokens": {}, "by_label": {}, "loaded": 0.0, "written": {}, "last_rotate": 0.0,
          "fable_capped": set(), "failed": {}}   # -fable keys whose file held a rejection when this proxy last read or wrote it


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
    return data if (data["s5_util"] or data["oi7_util"] or data["oi7_stat"] or rejected) else None


def is_quota_rejection(status, headers):
    """A 429 that means a window is spent (rotate), as opposed to a per-minute burst (wait)."""
    if status != 429:
        return False
    return any(headers.get(RL + k) == "rejected" for k in ("status", "5h-status", "7d-status", "7d_oi-status"))


@contextmanager
def lock_cache(stream):
    """Take the same byte-range lock as the PowerShell cache writer."""
    stream.seek(0)
    if os.name == "nt":
        import msvcrt
        acquire = lambda: msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        release = lambda: msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        acquire = lambda: fcntl.lockf(stream, fcntl.LOCK_EX | fcntl.LOCK_NB, 1)
        release = lambda: fcntl.lockf(stream, fcntl.LOCK_UN, 1)
    for attempt in range(CACHE_LOCK_TRIES):
        try:
            acquire()
            break
        except OSError:
            if attempt == CACHE_LOCK_TRIES - 1:
                raise
            time.sleep(0.025)
    try:
        yield
    finally:
        release()


def read_cache_for_update(path):
    for attempt in range(2):
        try:
            with open(path, encoding="utf-8-sig") as f:
                entry = json.load(f)
            if isinstance(entry, dict) and isinstance(entry.get("data"), dict):
                extra = entry.get("fable_cap")
                if not extra or (isinstance(extra, dict) and isinstance(extra.get("data"), dict)):
                    return entry
        except FileNotFoundError:
            return {}
        except ValueError:
            pass
        if not attempt:
            time.sleep(0.025)   # An older PowerShell writer might still be publishing in place.
    return {}


def observed_ms(entry):
    try:
        return int(entry.get("observed_ms") or int(entry.get("ts") or 0) * 1000)
    except (TypeError, ValueError, OverflowError):
        return 0


def fable_observed_ms(entry):
    reading = entry.get("fable_cap") or entry
    data = reading.get("data", {})
    try:
        status = int(data.get("http") or 0)
    except (TypeError, ValueError, OverflowError):
        status = 0   # malformed metadata must not block the write that repairs it
    if data.get("ok") and (data.get("oi7_stat") or data.get("oi7_util") is not None or 200 <= status < 300):
        return observed_ms(reading)
    try:
        return int(entry.get("fable_confirmed_ms") or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


DEFAULT_WINDOW = ("s5_util", "s5_stat", "w7_util", "w7_stat")


def default_fable_observation(cached):
    """The newest Fable observation in a default-cache record: its own proxy reading, or the one nested under it."""
    old = cached.get("data", {})
    nested = cached.get("fable_cap")
    if old.get("src") == "proxy" and old.get("ok") and (old.get("oi7_stat") or old.get("oi7_util") is not None):
        own = {"ts": cached.get("ts"), "observed_ms": observed_ms(cached), "data": old}
        if not nested or observed_ms(nested) <= own["observed_ms"]:
            return own
    return nested


def other_limit_rejection(data):
    """A rejection whose Fable window names a status that is not rejected: some other limit refused it."""
    return data.get("status") == "rejected" and bool(data.get("oi7_stat")) and data.get("oi7_stat") != "rejected"


def cache_entry(prior, suffix, entry, has_fable):
    if suffix:
        # Keep the last measurement and its timestamp for the watcher and usage history.
        # A future-dated measurement (a clock set back) is not kept, or its timestamp would outlive this write.
        if (entry["data"].get("oi7_util") is None and prior.get("data", {}).get("oi7_util") is not None
                and observed_ms(prior) <= entry["observed_ms"]):
            return {**prior, "fable_cap": entry}
    elif has_fable and all(entry["data"].get(k) is None for k in DEFAULT_WINDOW) and prior.get("data") and             observed_ms(prior) <= entry["observed_ms"] and not other_limit_rejection(entry["data"]):
        # A Fable-only response names no default window: keep the default reading (and any cap it holds) and add this
        # as the Fable backup, as the -fable file nests a status-only reading. A newer nested observation it raced
        # (and not future-dated) stays. A rejection whose Fable window says it is not the Fable cap (another limit's,
        # e.g. claim five_hour with no 5h fields) is stored at the top level, where default-cap readers see it.
        nested = prior.get("fable_cap")
        if nested and entry["observed_ms"] < observed_ms(nested) <= time.time_ns() // 1_000_000:
            return prior
        return {**prior, "fable_cap": entry}
    elif not has_fable:
        # A default-only write must not lose the default cache's copy of a Fable observation (a rejection or an
        # allowance): an older proxy's only copy, the backup when the -fable write was skipped, or a nested
        # Fable-only response.
        cap = default_fable_observation(prior)
        # A future-dated cap (a clock set back) is dropped, or it would come back once the clock passes it.
        if cap and observed_ms(cap) <= time.time_ns() // 1_000_000:   # not future-dated; a newer cap is kept
            entry["fable_cap"] = cap
    else:
        # A full Fable reading, or a Fable-only response with no default reading to nest under (stored at the top
        # level), is the newer Fable word, unless a Fable observation it raced (nested a moment later by another
        # response) is newer still and not future-dated: keep that one.
        cap = default_fable_observation(prior)
        if cap and entry["observed_ms"] < observed_ms(cap) <= time.time_ns() // 1_000_000:
            entry["fable_cap"] = cap
    return entry


def write_cache(label, data):
    """Atomic write of <label>/usage-cache.json (and -fable when the Fable window rode along)."""
    rejected = any(data.get(k) == "rejected" for k in ("status", "s5_stat", "w7_stat", "oi7_stat"))
    has_fable = data.get("oi7_util") or data.get("oi7_stat")
    receipt = time.time_ns() // 1_000_000
    mono = time.monotonic()   # throttle and backoff: a clock set back must not stall writes
    never = float("-inf")
    for suffix, present in (("", data.get("s5_util") or rejected), ("-fable", has_fable)):
        if not present:
            continue
        key = label + suffix
        # Throttle before any lock or file read: this runs before the response reaches the client.
        if mono - _state["failed"].get(key, never) < WRITE_EVERY:
            continue   # the lock was just stuck: at most one lock wait per WRITE_EVERY, whatever the reading
        if (not rejected and mono - _state["written"].get(key, never) < WRITE_EVERY
                and not (suffix and key in _state["fable_capped"])):
            continue
        path = os.path.join(ROOT, label, "usage-cache%s.json" % suffix)
        tmp = "%s.tmp-%d-%d" % (path, os.getpid(), threading.get_ident())
        with _lock:
            local_guard = _cache_locks.setdefault(path, threading.Lock())
        failure = None
        with local_guard:
            # Re-checked here: threads queued behind a failed write must not each wait out the lock again.
            if mono - _state["failed"].get(key, never) < WRITE_EVERY or (
                    not rejected and not suffix and mono - _state["written"].get(key, never) < WRITE_EVERY):
                continue
            try:
                with open(path + ".lock", "a+b") as guard, lock_cache(guard):
                    prior = read_cache_for_update(path)
                    effective = (prior.get("fable_cap") if suffix else None) or prior
                    if suffix:
                        # Learned on each read. A rejection another writer saved since is seen on the next unthrottled write.
                        if effective.get("data", {}).get("oi7_stat") == "rejected":
                            _state["fable_capped"].add(key)
                        else:
                            _state["fable_capped"].discard(key)
                    previous_ms = fable_observed_ms(prior) if suffix else observed_ms(effective)
                    # An older reading never replaces a newer one. On a same-millisecond tie a rejection wins.
                    if previous_ms <= time.time_ns() // 1_000_000 and (
                            receipt < previous_ms or (receipt == previous_ms and not rejected)):
                        continue
                    clears_fable_cap = suffix and effective.get("data", {}).get("oi7_stat") == "rejected"
                    if not rejected and not clears_fable_cap and mono - _state["written"].get(key, never) < WRITE_EVERY:
                        continue
                    entry = cache_entry(prior, suffix, {"ts": receipt // 1000, "observed_ms": receipt, "data": data}, has_fable)
                    with open(tmp, "w", encoding="utf-8") as f:
                        json.dump(entry, f)
                    try:
                        os.replace(tmp, path)
                    except PermissionError:
                        time.sleep(0.025)
                        os.replace(tmp, path)
                    _state["written"][key] = mono
                    if suffix:
                        if ((entry.get("fable_cap") or entry).get("data", {}).get("oi7_stat") == "rejected"):
                            _state["fable_capped"].add(key)
                        else:
                            _state["fable_capped"].discard(key)
            except Exception as e:   # a cache write must never stop the response from being relayed
                _state["failed"][key] = mono   # recorded before the next queued thread can take the lock
                failure = e
        if failure:
            log("cache write failed for %s: %s" % (key, failure))


# The proxy's own refusal (no eligible seat left), in the API's canonical shape: the code and wording every refusal classifier keys on
# (rotator_access.DISABLED_MARKERS, claude-resume-sessions.ps1 Test-StoppedByLimit), so a session it stopped counts as an access stop.
# The same bytes are a case in fixtures/access-responses.json.
LOCAL_REFUSAL = (b'{"type":"error","error":{"type":"permission_error","message":"Your organization has disabled Claude subscription access for '
                 b'Claude Code on this seat (oauth_org_not_allowed), and no other eligible seat is available."},"error_code":"oauth_org_not_allowed"}')


def access_marker_path(label):
    return os.path.join(ROOT, label, "access-disabled.json")


def seat_token(label):
    """The seat's CURRENT token.txt, read fresh (not the 15 s load_tokens cache), or "" when it is missing, unreadable or empty."""
    try:
        with open(os.path.join(ROOT, label, "token.txt"), encoding="utf-8-sig") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def access_disabled_fresh(label):
    """True when this seat's subscription-disabled cooldown has not elapsed AND the marker still belongs to the seat's current token: a marker
    names the refused token's fingerprint (`tok`) and is ignored once token.txt holds a different one (a replaced credential). A marker without
    `tok`, or an unreadable token.txt, keeps the plain cooldown rule. The token is hashed, never returned or logged."""
    if not label:
        return False
    try:
        with open(access_marker_path(label), encoding="utf-8") as handle:
            data = json.load(handle)
        if float(data.get("until") or 0) <= time.time():
            return False
        return marker_belongs(data.get("tok"), seat_token(label))
    except (OSError, ValueError, TypeError):
        return False


def write_access_disabled(label, code, tok=None):
    """Record the refusal. `tok` is the token that was actually sent upstream and refused (not a re-read of token.txt, which may already hold a
    replacement); only its fingerprint is written. Does not create, rewrite, or delete token.txt."""
    if not label:
        return
    directory = os.path.join(ROOT, label)
    now = int(time.time())
    payload = {"ts": now, "until": now + ACCESS_COOLDOWN, "http": 403,
               "code": code or "subscription_disabled", "kind": "subscription_disabled"}
    if tok:
        payload["tok"] = token_fingerprint(tok)
    path = access_marker_path(label)
    tmp = "%s.tmp-%d-%d" % (path, os.getpid(), threading.get_ident())
    try:
        os.makedirs(directory, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, path)
    except OSError as exc:
        log("access marker write failed for %s: %s" % (label, exc))


def write_health(ok, label, reason):
    path = os.path.join(ROOT, ".seat-health.json")
    payload = {"ok": bool(ok), "active": label, "reason": reason, "ts": int(time.time())}
    tmp = "%s.tmp-%d-%d" % (path, os.getpid(), threading.get_ident())
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, path)
    except OSError as exc:
        log("health write failed: %s" % exc)


def health_state():
    """Process liveness is not health. A fresh access refusal on the active seat is not ok. The saved health file is believed only as long as
    its evidence: a saved "subscription_disabled" only while the seat's refusal marker is fresh (checked first), a saved "exhausted" only for
    ACCESS_COOLDOWN after it was written, so a recovered seat is not reported unhealthy for ever when no watcher rewrites the file."""
    label = active_label()
    if label and access_disabled_fresh(label):
        return False, label, "subscription_disabled"
    try:
        with open(os.path.join(ROOT, ".seat-health.json"), encoding="utf-8") as handle:
            data = json.load(handle)
        if (data.get("active") == label and data.get("ok") is False and data.get("reason") == "exhausted"
                and time.time() - float(data.get("ts") or 0) < ACCESS_COOLDOWN):
            return False, label, "exhausted"
    except (OSError, ValueError, TypeError):
        pass
    return True, label, "ready"


def ask_rotator(seen_label, reason="quota 429"):
    """Run the rotator's check now. Returns the active label afterwards."""
    with _rotate_lock:
        current = active_label()
        if current != seen_label:          # another request already rotated
            return current
        if time.time() - _state["last_rotate"] < ROTATE_COOLDOWN:
            return current
        log("%s on '%s' - asking the rotator to rotate" % (reason, seen_label))
        # Wait up to 150 s, but NEVER kill the rotator on timeout: it may be mid-switch (it waits up
        # to 90 s for the check mutex first), and a kill there leaves .active, the env var and
        # .credentials.json disagreeing (Fable review 2026-10-30, P1-2). It finishes on its own.
        try:
            # LINUX-PORT: creationflags is Windows-only (ValueError on POSIX); own session instead,
            # so the rotator is never killed with the proxy's process group.
            plat = dict(creationflags=0x08000000) if sys.platform == "win32" else dict(start_new_session=True)
            p = subprocess.Popen(ROTATOR_CMD, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, **plat)
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
        ok, label, reason = health_state()
        body = json.dumps({"ok": ok, "active": label, "port": PORT, "reason": reason}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _refuse_disabled(self, label):
        # No upstream call. The body names the condition and never a token.
        log("not sending; '%s' subscription disabled and no other eligible seat" % label)
        write_health(False, label, "subscription_disabled")
        msg = LOCAL_REFUSAL
        self.send_response(403)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)

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
                # Known-disabled seats are not sent upstream. One ask of the rotator, then either
                # the seat it picked or a local 403. A network failure never reaches this branch.
                if label and access_disabled_fresh(label):
                    if attempt >= 1:
                        return self._refuse_disabled(label)
                    after = ask_rotator(label, "subscription disabled")
                    if not after or after == label or access_disabled_fresh(after) or after not in by_label:
                        return self._refuse_disabled(label)
                    label = after
                tok = by_label.get(label) if label else None
                if not tok:   # no usable active seat: send the caller's own token
                    tok, label = bearer(self.headers), tokens.get(bearer(self.headers))
                fwd = {k: v for k, v in fwd.items() if k.lower() != "authorization"}
                fwd["Authorization"] = "Bearer " + tok
            try:
                conn, r = send_upstream(self.command, self.path, body, fwd)
            except Exception as e:
                # Unreachable upstream is not an access refusal. Do not mark any seat disabled.
                log("upstream error %s %s: %r" % (self.command, self.path.split("?")[0], type(e).__name__))
                self.send_error(502, "claude-rotate-proxy: upstream unreachable")
                return
            hdrs = {k.lower(): v for k, v in r.getheaders()}
            if label:
                rec = usage_record(label, r.status, model, hdrs)
                if rec:
                    write_cache(label, rec)
            if ours and r.status == 403:
                spent = r.read()
                self._release(conn, r)
                if is_subscription_disabled(r.status, spent):
                    # Recorded on either attempt (the retry's seat can be the refused one); only the rotation and retry are limited to the first.
                    code = access_code(spent) or "subscription_disabled"
                    write_access_disabled(label, code, tok)       # the token this request carried, not a fresh read of token.txt
                    write_health(False, label, "subscription_disabled")
                    log("403 subscription disabled on '%s' (%s)" % (label, code))
                    after = ask_rotator(label, "403 subscription disabled") if attempt == 0 else None
                    if after and after != label and after in by_label and not access_disabled_fresh(after):
                        log("retrying %s on '%s'" % (self.path.split("?")[0], after))
                        continue
                    self._head(r)
                    self.wfile.write(spent)
                    return
                # A different 403 is not a subscription disable. Relay it; mark nothing.
                self._head(r)
                self.wfile.write(spent)
                return
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
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "fixtures", "access-responses.json"), encoding="utf-8") as handle:
        for case in json.load(handle):
            got = is_subscription_disabled(case["status"], case["body"])
            assert got is case["disabled"], (case["status"], got, case["disabled"])
    assert access_code(b'{"error_code":"oauth_org_not_allowed"}') == "oauth_org_not_allowed"
    assert is_subscription_disabled(403, LOCAL_REFUSAL) and access_code(LOCAL_REFUSAL) == "oauth_org_not_allowed"
    with open(os.path.join(here, "fixtures", "access-responses.json"), encoding="utf-8") as handle:
        assert any(c["body"] == LOCAL_REFUSAL.decode() and c["disabled"] is True for c in json.load(handle)), "the local refusal is not a shared fixture"
    assert not is_subscription_disabled(0, "disabled Claude subscription access")
    marker_self_test()
    cache_self_test()
    print("self-test ok")


def cache_self_test():
    """write_cache against a sandbox root: repair of malformed metadata, same-millisecond ties, carried allowances."""
    import shutil, tempfile
    global ROOT, LOG
    saved, ROOT = ROOT, tempfile.mkdtemp(prefix="crp-cache-")
    saved_log, LOG = LOG, os.path.join(ROOT, ".proxy-log.txt")
    real_ns = time.time_ns
    try:
        os.makedirs(os.path.join(ROOT, "S"))
        fable = os.path.join(ROOT, "S", "usage-cache-fable.json")
        default = os.path.join(ROOT, "S", "usage-cache.json")
        load = lambda path: json.load(open(path, encoding="utf-8"))
        with open(fable, "w", encoding="utf-8") as f:
            json.dump({"ts": 1, "data": {"ok": True, "http": "x", "oi7_stat": "rejected"}}, f)
        write_cache("S", {"ok": True, "http": 200, "src": "proxy", "oi7_stat": "allowed"})
        assert load(fable)["data"]["oi7_stat"] == "allowed", "malformed http blocked its own repair"
        tick = real_ns() + 10 ** 9
        time.time_ns = lambda: tick
        _state["written"].clear()
        write_cache("S", {"ok": True, "http": 200, "src": "proxy", "oi7_stat": "allowed"})
        write_cache("S", {"ok": True, "http": 429, "src": "proxy", "oi7_stat": "rejected"})
        assert load(fable)["data"]["oi7_stat"] == "rejected", "a same-millisecond rejection was dropped"
        write_cache("S", {"ok": True, "http": 200, "src": "proxy", "oi7_stat": "allowed"})
        assert load(fable)["data"]["oi7_stat"] == "rejected", "a same-millisecond allowance replaced a rejection"
        time.time_ns = real_ns
        _state["written"].clear()
        with open(default, "w", encoding="utf-8") as f:
            json.dump({"ts": 2, "observed_ms": 2000, "data": {"ok": True, "src": "proxy", "s5_util": "0.1", "oi7_stat": "allowed"}}, f)
        write_cache("S", {"ok": True, "http": 200, "src": "proxy", "s5_util": "0.2"})
        assert load(default).get("fable_cap", {}).get("data", {}).get("oi7_stat") == "allowed", "a default refresh lost a Fable allowance"
        _state["written"].clear()
        with open(default, "w", encoding="utf-8") as f:
            json.dump({"ts": 3, "observed_ms": 3000, "data": {"ok": True, "src": "proxy", "s5_util": "0.3", "oi7_util": "0.5"}}, f)
        write_cache("S", {"ok": True, "http": 200, "src": "proxy", "s5_util": "0.4"})
        assert load(default).get("fable_cap", {}).get("data", {}).get("oi7_util") == "0.5", "a default refresh lost a Fable utilization reading"
        with open(default, "w", encoding="utf-8") as f:
            json.dump({"ts": 4, "observed_ms": 4000, "data": {"ok": True, "src": "proxy", "s5_stat": "rejected", "status": "rejected"}}, f)
        write_cache("S", {"ok": True, "http": 429, "src": "proxy", "status": "rejected", "oi7_stat": "rejected"})
        saved_default = load(default)
        assert saved_default["data"].get("s5_stat") == "rejected" and saved_default["fable_cap"]["data"]["oi7_stat"] == "rejected",             "a Fable-only rejection replaced the default cap"
        with open(fable, "w", encoding="utf-8") as f:
            f.write('{"ts": 5, "observed_ms": Infinity, "data": {"ok": true, "http": 200, "oi7_stat": "allowed"}}')
        _state["failed"].clear()
        write_cache("S", {"ok": True, "http": 429, "src": "proxy", "oi7_stat": "rejected"})   # must not raise
        time.time_ns = real_ns
        now = time.time_ns() // 1_000_000
        nested = {"ts": now // 1000, "observed_ms": now - 10, "data": {"ok": True, "src": "proxy", "http": 429, "oi7_stat": "rejected"}}
        prior = {"ts": (now - 5000) // 1000, "observed_ms": now - 5000, "data": {"ok": True, "src": "proxy", "s5_util": 0.1}, "fable_cap": nested}
        late = {"ts": (now - 2000) // 1000, "observed_ms": now - 2000, "data": {"ok": True, "src": "proxy", "s5_util": 0.2}}
        assert cache_entry(prior, "", dict(late), False).get("fable_cap") == nested, "a late default write dropped a newer Fable rejection"
        future = dict(nested, observed_ms=now + 3_600_000)
        assert "fable_cap" not in cache_entry(dict(prior, fable_cap=future), "", dict(late), False), "a future-dated cap was carried"
        late_full = {"ts": (now - 2000) // 1000, "observed_ms": now - 2000, "data": {"ok": True, "src": "proxy", "s5_util": 0.2, "oi7_stat": "allowed", "oi7_util": 0.3}}
        assert cache_entry(prior, "", dict(late_full), True).get("fable_cap") == nested, "a late full Fable reading dropped a newer Fable rejection"
        older = dict(nested, observed_ms=now - 9000)
        assert "fable_cap" not in cache_entry(dict(prior, fable_cap=older), "", dict(late_full), True), "a full Fable reading kept an older Fable cap"
        late_only = {"ts": (now - 2000) // 1000, "observed_ms": now - 2000, "data": {"ok": True, "src": "proxy", "http": 200, "oi7_stat": "allowed"}}
        assert cache_entry(prior, "", dict(late_only), True).get("fable_cap") == nested, "a late Fable-only response replaced a newer nested Fable observation"
        assert cache_entry(dict(prior, fable_cap=older), "", dict(late_only), True)["fable_cap"]["observed_ms"] == now - 2000, "a Fable-only response did not replace an older nested observation"
        assert cache_entry(dict(prior, fable_cap=dict(nested, observed_ms=now + 3_600_000)), "", dict(late_only), True)["fable_cap"]["observed_ms"] == now - 2000, "a future-dated nested observation blocked a Fable-only response"
        for fable_word in ("allowed", "allowed_warning"):
            other = {"ts": now // 1000, "observed_ms": now, "data": {"ok": True, "src": "proxy", "http": 429, "status": "rejected",
                                                                     "claim": "five_hour", "oi7_stat": fable_word}}
            stored = cache_entry(dict(prior), "", dict(other), True)
            assert stored["data"].get("status") == "rejected" and stored["data"].get("claim") == "five_hour",                 "another limit's sparse rejection was nested out of the default readers' sight"
    finally:
        time.time_ns = real_ns
        _state["written"].clear(); _state["failed"].clear(); _state["fable_capped"].clear()
        shutil.rmtree(ROOT, ignore_errors=True)
        ROOT, LOG = saved, saved_log


def marker_self_test():
    """A refusal marker names the refused token and applies only while the seat still holds it. Sandbox root; fake tokens built at runtime."""
    import tempfile
    global ROOT
    saved, ROOT = ROOT, tempfile.mkdtemp(prefix="crp-marker-")
    try:
        os.makedirs(os.path.join(ROOT, "S"))
        tx, ty = "fake-token-" + "x" * 8, "fake-token-" + "y" * 8
        assert token_fingerprint("abc") == "ba7816bf8f01cfea"                    # SHA-256("abc")[:16]; the PowerShell side asserts the same literal
        put = lambda s: open(os.path.join(ROOT, "S", "token.txt"), "w", encoding="utf-8").write(s + "\n")
        put(tx)
        write_access_disabled("S", "oauth_org_not_allowed", tx)
        marker = json.load(open(access_marker_path("S"), encoding="utf-8"))
        assert marker["tok"] == token_fingerprint(tx) and tx not in json.dumps(marker) and marker["kind"] == "subscription_disabled", marker
        assert access_disabled_fresh("S")                                          # the seat still holds the refused token
        put(ty)
        assert not access_disabled_fresh("S")                                      # --replace stored another: the marker belongs to the old credential
        write_access_disabled("S", "oauth_org_not_allowed", tx)                    # a late refusal for the OLD token (in flight / cached 15 s) lands after the swap
        assert not access_disabled_fresh("S")                                      # ... and still does not exclude the healthy replacement
        write_access_disabled("S", "oauth_org_not_allowed", ty)
        assert access_disabled_fresh("S")                                          # a refusal of the token it now holds counts
        write_access_disabled("S", "oauth_org_not_allowed")                        # no token known: a marker without `tok`, as older code wrote
        assert "tok" not in json.load(open(access_marker_path("S"), encoding="utf-8")) and access_disabled_fresh("S")
        put(tx)
        assert access_disabled_fresh("S")                                          # without `tok` it is honoured whatever token.txt holds
        write_access_disabled("S", "oauth_org_not_allowed", tx)
        os.remove(os.path.join(ROOT, "S", "token.txt"))
        assert access_disabled_fresh("S")                                          # token.txt missing: today's behaviour
    finally:
        ROOT = saved


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
