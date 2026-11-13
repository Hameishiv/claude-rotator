"""usage-history - record AI-seat usage over time and serve a local quota dashboard.

Each sample reads Claude seats' usage-cache[-fable].json (written by claude-rotate-proxy.py and the
rotator's own probes - sampling never probes a Claude seat), the Codex per-account rate-limit caches,
and, rarely, Grok (every 15 min, Cursor's Grok usage is the same xAI quota) over HTTPS. One line per sample goes to
.usage-history.jsonl and usage-dashboard.html is rewritten with the data inlined, so the page opens
from file:// with no server. The 'Claude usage dashboard' scheduled task runs --serve.

  usage-history.py             sample + render
  usage-history.py --render    render only
  usage-history.py --backfill [--days N]   rebuild past Claude history from .rotate-log.txt (default 7 days)
  usage-history.py --backtest            projection error of the Typical, 3h and 24h rates over the recorded history
  usage-history.py --serve [--port 8787]   local app: page, /api/data, POST /api/refresh, POST /api/switch, sampler thread
  usage-history.py --make-icons            write the app icons into <state dir>\\usage-app\\
  usage-history.py --selftest              run the checks

QUOTA_STATE_DIR, when set, redirects everything this script WRITES to that folder (seat caches are still
read from their real places).

shortcut: a seat that is used elsewhere (the desktop app, the VM) only updates when something
probes it (a rotation, /seats, --status), so its line moves in steps; add probing only if the
steps hide real burn.
"""
import bisect
import glob
import json
import math
import os
import re
import secrets
import shutil
import statistics
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".claude-cli-accounts")
STATE = os.environ.get("QUOTA_STATE_DIR") or ROOT
HIST = os.path.join(STATE, ".usage-history.jsonl")
EMAILS = os.path.join(STATE, ".usage-emails.json")
PCACHE = os.path.join(STATE, ".usage-providers.json")     # grok/gemini last result, provider emails and notes
APPLOG = os.path.join(STATE, ".usage-app-log.txt")
OUT = os.path.join(STATE, "usage-dashboard.html")
ICONS = os.path.join(STATE, "usage-app")
HERE = os.path.dirname(os.path.abspath(__file__))
KEEP_DAYS = 35
WEEK = 7 * 86400
DAY = 86400
WINDOWS = (1, 3, 6, 24)     # hours of history a burn rate is measured over
BUCKET = 900                # hist is thinned to one point per 15 minutes
DRIFT_EVERY = 6 * 3600      # rotator-sync --check runs at most this often
PY = ["py", "-3"]
BUCKET5 = 300               # imported history keeps one point per 5 minutes
GROK_EVERY, SAMPLE_EVERY = 900, 300

# provider id -> (name, [(window id, window label, default period s)], [(limit window id, limit label)])
PROVIDERS = {
    "claude": ("Claude", [("s", "5-hour", 18000), ("w", "Weekly", WEEK), ("f", "Fable weekly", WEEK)],
               [("w", "All models"), ("f", "Fable")]),
    "codex": ("Codex", [("s", "5-hour", 18000), ("w", "Weekly", WEEK)], [("w", "Weekly")]),
    "grok": ("xAI", [("w", "Weekly", WEEK)], [("w", "Weekly credits")]),
    "gemini": ("Gemini", None, None),      # its windows are whatever the language server reports
}
BADGE = {"cli": "CLI", "app": "App"}     # which seat is in use: the key under a provider's "inUse" -> the pill on the seat
PROVIDER_NOTE = {"grok": "Cursor's Grok usage counts against this same xAI quota."}


def _f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def say(*a):
    if sys.stdout:          # pythonw has no stdout
        print(*a)


def seats_of(rec, pid):
    """One record's per-account windows for a provider (Claude lives under the v1 key "s")."""
    return rec.get("s" if pid == "claude" else pid) or {}


# ---------------------------------------------------------------- readers

def read_seat(label):
    """Latest usage for one seat from its cache files, or None when it has no good reading."""
    rows = []
    for suf in ("", "-fable"):
        try:
            with open(os.path.join(ROOT, label, "usage-cache%s.json" % suf), encoding="utf-8-sig") as fh:
                c = json.load(fh)
        except (OSError, ValueError):
            continue
        d = c.get("data") or {}
        if d.get("ok") and d.get("access", "ok") == "ok":
            rows.append((c.get("ts") or 0, d))
    if not rows:
        return None
    rows.sort(key=lambda r: r[0])
    ts, d = rows[-1]  # the newest read wins for the windows both files carry
    fab = next((r[1] for r in reversed(rows) if _f(r[1].get("oi7_util")) is not None), {})
    return {"ts": ts, "s": _f(d.get("s5_util")), "sr": _f(d.get("s5_reset")),
            "w": _f(d.get("w7_util")), "wr": _f(d.get("w7_reset")),
            "f": _f(fab.get("oi7_util")), "fr": _f(fab.get("oi7_reset")),
            "st": d.get("s5_stat"), "wt": d.get("w7_stat"), "ft": fab.get("oi7_stat")}      # the API's own status per window: allowed, allowed_warning, rejected


def _read(path):
    """A small text file's content, trimmed; '' when it cannot be read."""
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def app_seat(app_root=None, appdata=None):
    """The seat the Claude desktop app is on, as Get-AppSeatLabel in claude-cli-account.ps1 finds it: %APPDATA%\\Claude\\config.json's lastKnownAccountUuid
    matched against <seat>/owner-uuid.txt (or `uuid=<id>` in meta.txt) under ~/.claude-app-seats, else that folder's .active. Read-only; None when unknown."""
    app_root = app_root or os.path.join(HOME, ".claude-app-seats")
    appdata = appdata or os.environ.get("APPDATA")
    uuid = ""
    if appdata:
        try:
            with open(os.path.join(appdata, "Claude", "config.json"), encoding="utf-8-sig") as fh:
                uuid = str(json.load(fh).get("lastKnownAccountUuid") or "")
        except (OSError, ValueError, AttributeError):
            pass
    if uuid:
        for d in sorted(glob.glob(os.path.join(app_root, "*"))):
            if os.path.basename(d).startswith(".") or not os.path.isdir(d):
                continue
            if _read(os.path.join(d, "owner-uuid.txt")) == uuid or "uuid=" + uuid in _read(os.path.join(d, "meta.txt")):
                return os.path.basename(d)
    return _read(os.path.join(app_root, ".active")) or None


def in_use(cli_root=None, app_root=None, appdata=None, codex_dir=None):
    """{provider: {"cli": seat, "app": seat}} for the seats in use right now (a missing one is left out). Claude: the CLI's ~/.claude-cli-accounts/.active
    and the desktop app's seat. Codex: the desktop app and the CLI share ~/.codex/auth.json, so only "app", the label in ~/.codex/.active-account."""
    out = {"claude": {}, "codex": {}}
    cli = _read(os.path.join(cli_root or ROOT, ".active"))
    app = app_seat(app_root, appdata)
    cx = _read(os.path.join(codex_dir or os.path.join(HOME, ".codex"), ".active-account"))
    for prov, k, v in (("claude", "cli", cli), ("claude", "app", app), ("codex", "app", cx)):
        if v:
            out[prov][k] = v
    return out


def read_claude():
    seats = {}
    for name in sorted(os.listdir(ROOT)):
        d = os.path.join(ROOT, name)
        if name[:1] in "._" or not os.path.isdir(d) or not glob.glob(os.path.join(d, "usage-cache*.json")):
            continue    # only a folder that holds a usage cache is a seat
        seats[name] = read_seat(name) or {"ok": False, "note": "no usable reading"}
    return seats


def parse_codex(c):
    """One rate-limits cache -> (seat dict or None, email). 10080 min is the weekly window, 300 the 5-hour.
    Banked resets, when the cache carries them (the statusband caches and rate-limits-survey.json share the shape):
    availableCount -> seat["banked"], credits [{title, expiresAt}] -> seat["bankedList"] (only those with an expiry; the count can be larger)."""
    seat = {"ts": int((_f(c.get("fetchedAt")) or 0) / 1000)}
    for part in ("primary", "secondary"):
        p = c.get(part)
        if not isinstance(p, dict):
            continue
        wid = {10080: "w", 300: "s"}.get(int(_f(p.get("windowDurationMins")) or 0))
        used, reset = _f(p.get("usedPercent")), _f(p.get("resetsAt"))
        if wid and used is not None:
            seat[wid], seat[wid + "r"], seat[wid + "p"] = used / 100, reset, 604800 if wid == "w" else 18000
    if len(seat) > 1:
        n = _f(c.get("availableCount"))
        if n is not None and n >= 0:
            seat["banked"] = int(n)
            cr = c.get("credits")
            seat["bankedList"] = sorted(({"title": str(x.get("title") or "Reset"), "expiresAt": int(e)} for x in (cr if isinstance(cr, list) else [])
                                         if isinstance(x, dict) and (e := _f(x.get("expiresAt"))) is not None), key=lambda x: x["expiresAt"])
    return (seat if len(seat) > 1 else None), c.get("accountEmail")


def _codex_caches(d):
    for fn in glob.glob(os.path.join(d, "cache-statusband-codex", "rate-limits*.json")):
        try:
            with open(fn, encoding="utf-8-sig") as fh:
                c = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(c, dict):
            yield c


def _newer(c, old):
    return old is None or (_f(c.get("fetchedAt")) or 0) > (_f(old.get("fetchedAt")) or 0)


def read_codex(cdir=None, sink=None):
    """({label: seat}, {label: email}) from the local caches only; never runs node or the network.
    `sink`, when given, collects (label, cache) for every cache that got a label, the older ones too.
    A home with no auth.json and no reading from any source reads "no saved login on this PC".
    Each home's own caches, plus the active login's (<cdir>/cache-statusband-codex), whose label is X of its
    identityKey "seat:X" when X is a home, else the home whose caches carry the same accountEmail. Newest fetchedAt wins."""
    cdir = cdir or os.path.join(HOME, ".codex")
    best, by_email = {}, {}
    login = {}
    for d in sorted(glob.glob(os.path.join(cdir, "homes", "*"))):
        label = os.path.basename(d)
        login[label] = os.path.isfile(os.path.join(d, "auth.json"))    # existence only: auth.json is never read
        best[label] = None
        for c in _codex_caches(d):
            if sink is not None:
                sink.append((label, c))
            if c.get("accountEmail"):
                by_email.setdefault(c["accountEmail"], label)
            if _newer(c, best[label]):
                best[label] = c
    for c in _codex_caches(cdir):
        m = re.fullmatch(r"seat:(.+)", str(c.get("identityKey") or ""))
        label = m.group(1) if m and m.group(1) in best else by_email.get(c.get("accountEmail"))
        if label and sink is not None:
            sink.append((label, c))
        if label and _newer(c, best[label]):
            best[label] = c
    seats, emails = {}, {}
    for label, c in best.items():
        seat, email = parse_codex(c) if c else (None, None)
        seats[label] = seat or {"ok": False, "note": "no usage cached yet" if login[label] else "no saved login on this PC"}
        if email:
            emails[label] = email
    return seats, emails


def parse_grok(j):
    """Billing response -> seat dict, or None when the shape is not the expected one."""
    from datetime import datetime
    try:
        cfg = j["config"]
        cp = cfg["currentPeriod"]
        start, end = (datetime.fromisoformat(cp[k]).timestamp() for k in ("start", "end"))
        used = float(cfg["creditUsagePercent"]) / 100
    except (KeyError, TypeError, ValueError):
        return None
    return {"w": used, "wr": int(end), "wp": int(end - start)}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def http_json(req, timeout=10):
    """(status, parsed json or None). Redirects are not followed; the caller's headers never leave the host."""
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, str(type(e).__name__)


def _bad(code, what):
    return "HTTP %s" % code if code else "network error (%s)" % what


def fetch_grok(now):
    """-> (seat, email) from one live GET. Never logs or returns the key."""
    try:
        with open(os.path.join(HOME, ".grok", "auth.json"), encoding="utf-8-sig") as fh:
            a = next(iter(json.load(fh).values()))
        key, email = a["key"], a.get("email")
    except (OSError, ValueError, KeyError, StopIteration, AttributeError):
        return {"ok": False, "note": "not signed in to Grok: run grok to sign in"}, None
    req = urllib.request.Request("https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                                 headers={"Authorization": "Bearer " + key})
    code, j = http_json(req)
    if code in (401, 403):
        return {"ok": False, "note": "sign-in expired: run grok to sign in again"}, email
    seat = parse_grok(j) if code == 200 else None
    if not seat:
        return {"ok": False, "note": "Grok usage unavailable (%s)" % (_bad(code, j) if code != 200 else "unexpected response")}, email
    seat["ts"] = int(now)
    return seat, email


LS_PATH = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
LS_BODY = json.dumps({"metadata": {"ideName": "antigravity", "extensionName": "antigravity", "locale": "en"}}).encode()
LS_PS = ("$ErrorActionPreference='SilentlyContinue';"       # the IDE's language server, or the CLI (agy.exe), which embeds one
         "$r=@(foreach($p in @(Get-CimInstance Win32_Process -Filter \"Name='language_server_windows_x64.exe' OR Name='agy.exe'\")){"
         "[pscustomobject]@{ProcessId=$p.ProcessId;CommandLine=$p.CommandLine;"
         "Ports=@(Get-NetTCPConnection -OwningProcess $p.ProcessId -State Listen | ForEach-Object{$_.LocalPort})}});"
         "ConvertTo-Json -InputObject $r -Compress -Depth 3")


LS_ADMIN = "Antigravity is running as administrator, so its quota can't be read. Start it from a normal (non-admin) window."
LS_AGY = "Open the Antigravity app to read Gemini quota (the agy CLI doesn't share it)"     # agy.exe hosts a server but its csrf token is not on its command line
LS_OFF = "Antigravity isn't running — open the Antigravity app to update"


def parse_ls_procs(text):
    """The probe's JSON -> [(csrf token, [listening ports])]; a process with a token but no port is dropped.
    A process whose command line is empty (Windows hides it from a normal process when the target runs as administrator)
    comes back as (None, []), once; one whose command line is readable but carries no token (agy.exe) as ("", []), once. Tokens are never logged."""
    try:
        j = json.loads(text)
    except (TypeError, ValueError):
        return []
    out, hidden, bare = [], False, False
    for p in [j] if isinstance(j, dict) else j if isinstance(j, list) else []:
        if not isinstance(p, dict):
            continue
        cmd = str(p.get("CommandLine") or "").strip()
        hidden = hidden or not cmd
        m = re.search(r"--csrf_token[=\s]+(\S+)", cmd)
        ports = p.get("Ports")
        ports = [x for x in (ports if isinstance(ports, list) else [ports]) if isinstance(x, int)]
        bare = bare or bool(cmd) and not m
        if m and ports:
            out.append((m.group(1).strip("\"'"), ports))
    return out + [(None, [])] * hidden + [("", [])] * bare


def ls_probe():
    """The one PowerShell call: Antigravity's language-server processes with their csrf token and listening ports."""
    if os.name != "nt":
        return []
    import base64
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand",
                            base64.b64encode(LS_PS.encode("utf-16-le")).decode()],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=30, creationflags=0x08000000)
    except (OSError, subprocess.SubprocessError):
        return []
    return parse_ls_procs(r.stdout.decode("utf-8", "replace"))


def query_ls(port, csrf):
    """GetUserStatus on 127.0.0.1:<port>, https (self-signed, so unverified: loopback only) then http; the parsed 200 body or None."""
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect, urllib.request.HTTPSHandler(context=ctx))
    for scheme in ("https", "http"):
        req = urllib.request.Request("%s://127.0.0.1:%d%s" % (scheme, int(port), LS_PATH), data=LS_BODY, method="POST",
                                     headers={"Content-Type": "application/json", "Connect-Protocol-Version": "1",
                                              "X-Codeium-Csrf-Token": csrf})
        try:
            with opener.open(req, timeout=5) as r:
                if r.status == 200:
                    return json.loads(r.read().decode("utf-8"))
        except (urllib.error.URLError, OSError, ValueError):
            pass
    return None


def gemini_slug(label):
    """A short stable window id for a limit label; the crc suffix keeps two long labels with one prefix apart."""
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:20] + "-%04x" % (zlib.crc32(label.encode("utf-8")) & 0xffff)


def parse_gemini(j, now):
    """GetUserStatus -> seat dict with one window per (remainingFraction, resetTime) group, or None when the shape is not the expected one.
    Window id = slug of the label (the distinct model families in the group); seat["n"] maps id -> label."""
    from datetime import datetime
    try:
        cfgs = j["userStatus"]["cascadeModelConfigData"]["clientModelConfigs"]
        groups = {}
        for c in cfgs:
            q = c.get("quotaInfo") if isinstance(c, dict) else None
            if not isinstance(q, dict) or not q.get("resetTime"):
                continue                # no quota on this model
            frac = round(float(q.get("remainingFraction") or 0), 4)     # proto3 JSON leaves a zero out
            reset = int(datetime.fromisoformat(q["resetTime"]).timestamp())
            fam = re.sub(r"\s*\((?:Low|Medium|High|XHigh)\)\s*$", "", str(c["label"])).strip()
            fams = groups.setdefault((frac, reset), [])
            if fam not in fams:
                fams.append(fam)
    except (KeyError, TypeError, ValueError, AttributeError):
        return None
    if not groups:
        return None
    seat = {"ts": int(now), "n": {}}
    for (frac, reset), fams in groups.items():
        label = " + ".join(fams)
        wid = gemini_slug(label)
        if wid in seat["n"] and seat[wid] >= 1 - frac:
            continue                    # two groups with one label: keep the more used
        seat["n"][wid], seat[wid], seat[wid + "r"], seat[wid + "p"] = label, round(1 - frac, 4), reset, 18000
    try:
        plan = j["userStatus"]["planStatus"]["planInfo"]["planName"]
        if isinstance(plan, str) and plan:
            seat["plan"] = plan
    except (KeyError, TypeError):
        pass
    return seat


def read_gemini(now, probe=ls_probe, query=query_ls):
    """(seat, note): the seat from the running Antigravity language server, else None with why - LS_ADMIN when a process exists
    whose command line cannot be read, LS_AGY when only a tokenless agy.exe is there, LS_OFF when none is running or no port answers."""
    hidden = bare = False
    for csrf, ports in probe():
        hidden, bare = hidden or csrf is None, bare or csrf == ""
        for port in ports if csrf else []:
            seat = parse_gemini(query(port, csrf), now)
            if seat:
                return seat, ""
    return None, LS_ADMIN if hidden else LS_AGY if bare else LS_OFF


def gemini_email():
    try:
        with open(os.path.join(HOME, ".gemini", "google_accounts.json"), encoding="utf-8-sig") as fh:
            e = json.load(fh).get("active")
        return e if isinstance(e, str) and e else None
    except (OSError, ValueError, AttributeError):
        return None


def load_pcache():
    try:
        with open(PCACHE, encoding="utf-8") as fh:
            c = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(c, dict):
        return {}
    c.pop("cursor", None)                                   # Cursor folded into Grok
    (c.get("emails") or {}).pop("cursor", None)
    return c


def save_pcache(c):
    tmp = PCACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(c, fh, separators=(",", ":"))
    os.replace(tmp, PCACHE)


def read_live(pid, label, fetch, every, now, force, cache):
    """A rate-limited live provider: reuse the last result inside `every` seconds unless forced."""
    c = cache.get(pid) or {}
    if not force and c.get("at") and now - c["at"] < every:
        return c.get("seat")
    seat, email = fetch(now)
    cache[pid] = {"at": int(now), "seat": seat}
    if email:
        cache.setdefault("emails", {}).setdefault(pid, {})[label] = email
    return seat


# ---------------------------------------------------------------- Claude reset credits (read-only)

CREDITS_EVERY = 6 * 3600     # one read per seat per 6 h, whatever the outcome; 429 and 401/403 also hold the seat for that long
CREDITS_URL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
CLI_FALLBACK = "2.1.322"     # claude-cli-account.ps1 Probe-Usage uses the same fallback when `claude` is not runnable
CREDIT_KINDS = {"session": "5-hour reset", "weekly": "Weekly reset", "fable": "Fable reset", "full": "Full reset", "other": "Reset"}
GRANT_ID = re.compile(r"[a-z0-9_-]{1,40}")
COMPLETE_TS = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})")
_ver = [0, ""]               # when `claude --version` was last read, and what it said


def credits_enabled(cfg=None):
    """`claudeResetCredits` in rotator.local.json (next to this script): false turns every Claude reset-credit call and the page column off. Default on."""
    try:
        with open(cfg or os.path.join(HERE, "rotator.local.json"), encoding="utf-8-sig") as fh:
            return json.load(fh).get("claudeResetCredits") is not False
    except (OSError, ValueError, AttributeError):
        return True


def claude_version(now, run=subprocess.run, which=shutil.which):
    """The installed Claude CLI's version (the usage endpoint's user-agent must track it), from `claude --version`, kept for 6 h; CLI_FALLBACK when it will not run."""
    if _ver[1] and now - _ver[0] < CREDITS_EVERY:
        return _ver[1]
    v = ""
    try:
        exe = which("claude")
        if exe:
            r = run([exe, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20,
                    creationflags=0x08000000 if os.name == "nt" else 0)
            m = re.match(r"\s*(\d+\.\d+\.\d+)", r.stdout or "")
            v = m.group(1) if m else ""
    except (OSError, subprocess.SubprocessError):
        pass
    _ver[0], _ver[1] = now, v or CLI_FALLBACK
    return _ver[1]


def _iso(s):
    """A complete ISO 8601 timestamp -> epoch seconds; None for anything else."""
    from datetime import datetime
    if not isinstance(s, str) or not COMPLETE_TS.fullmatch(s):
        return None
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def grant_kind(g):
    """Claude Code's own grouping: a grant that gives back weekly usage is a Fable reset, else its declared type, else what it clears."""
    if g.get("gives_back_weekly") is True:
        return "fable"
    if g.get("type") in ("session", "weekly", "full"):
        return g["type"]
    cl = g.get("clears")
    if isinstance(cl, list) and cl:
        five, other = "five_hour" in cl, any(x != "five_hour" for x in cl)
        return "session" if five and not other else "weekly" if other and not five else "full"
    return "other"


def parse_cedar(block, now):
    """The `cedar_ember` block of the usage response -> {"eligible": bool, "grants": [{id, kind, left, endsAt}]}, or None when the shape is not understood
    (no reading). Absent/null or eligible:false is a reading with no credits. Grants kept: id matches [a-z0-9_-]{1,40}, integer resets_left >= 0, not paused,
    not usable_now:false, ends_at absent or a complete timestamp still in the future."""
    if block is None:
        return {"eligible": False, "grants": []}
    if not isinstance(block, dict) or not isinstance(block.get("eligible"), bool):
        return None
    if not block["eligible"]:
        return {"eligible": False, "grants": []}
    raw, out = block.get("grants"), []
    for g in raw if isinstance(raw, list) else []:
        if not isinstance(g, dict) or not isinstance(g.get("id"), str) or not GRANT_ID.fullmatch(g["id"]):
            continue
        left, paused = g.get("resets_left"), g.get("paused")
        if not isinstance(left, int) or isinstance(left, bool) or left < 0 or paused is not False and paused is not None or paused:
            continue
        if g.get("usable_now") is False:
            continue
        ends = g.get("ends_at")
        end = None
        if ends is not None:
            end = _iso(ends)
            if end is None or end <= now:
                continue
        out.append({"id": g["id"], "kind": grant_kind(g), "left": left, "endsAt": end, "usable": g.get("usable_now") is True})
    nid = block.get("next_grant_id")
    return dict({"eligible": True, "grants": out}, **({"nextId": nid} if isinstance(nid, str) and GRANT_ID.fullmatch(nid) else {}))


def parse_usage(j, now):
    return parse_cedar(j.get("cedar_ember"), now) if isinstance(j, dict) else None


def token_seats():
    """The Claude seat labels that have a token file (the same one the rotator uses)."""
    return sorted(os.path.basename(os.path.dirname(f)) for f in glob.glob(os.path.join(ROOT, "*", "token.txt")) if os.path.basename(os.path.dirname(f))[:1] not in "._")


def read_credits(label, now, fetch=http_json, ver=None):
    """One GET of the seat's reset credits -> (state, reading): "ok" (reading), "rl" (429), "auth" (401/403), "none" (no token), "fail". The token stays in this
    function: never logged, stored or returned."""
    tok = _read(os.path.join(ROOT, label, "token.txt"))
    if not tok:
        return "none", None
    req = urllib.request.Request(CREDITS_URL, headers={"authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20",
                                                       "user-agent": "claude-cli/%s (external, cli)" % (ver or CLI_FALLBACK)})
    try:
        code, j = fetch(req)
    except Exception as e:   # shortcut: whatever a fetch raises is a failed read; only its type is kept
        return "fail", type(e).__name__
    if code == 429:
        return "rl", None
    if code in (401, 403):
        return "auth", None
    r = parse_usage(j, now) if code == 200 else None
    return ("ok", dict(r, ts=int(now))) if r else ("fail", None)


# ---------------------------------------------------------------- Claude Apply reset (owner-approved: one button per kind; the server picks the grant)

RESET_KINDS = ("fable", "full", "weekly", "session")      # the kinds the page may ask for, in button order; "other" grants get no button
RESET_URL = "https://api.anthropic.com/api/organizations/%s/reset_rate_limits"
CONSUME_TIMEOUT = 25
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def usable_grants(entry, kind, now):
    """The grants of `kind` an Apply may use, soonest expiry first (no expiry last): usable_now, resets left, unexpired. As in T3 Code's reader, nothing is
    usable unless the reading named a next grant that is itself usable. `entry` is a seat's provider-cache credits entry."""
    if not entry.get("eligible"):
        return []
    gs = [g for g in entry.get("grants") or [] if g.get("usable") and g["left"] > 0 and (g["endsAt"] is None or g["endsAt"] > now)]
    if not any(g["id"] == entry.get("nextId") for g in gs):
        return []
    return sorted((g for g in gs if g["kind"] == kind), key=lambda g: (g["endsAt"] is None, g["endsAt"] or 0))


def claude_org(label):
    """The seat's organization uuid, as the rotator's probe and proxy record it (usage-cache*.json data.org, from the anthropic-organization-id header); '' when unknown."""
    for suf in ("", "-fable"):
        try:
            with open(os.path.join(ROOT, label, "usage-cache%s.json" % suf), encoding="utf-8-sig") as fh:
                o = (json.load(fh).get("data") or {}).get("org")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(o, str) and UUID.fullmatch(o.strip()):
            return o.strip()
    return ""


def consume_reset(label, kind, gid, rid, fetch, ver=None):
    """One claim of grant `gid` with idempotency key `rid` -> ({"outcome", "text"}, settled). Not settled (no answer, a 5xx, `unavailable`) means the claim may
    or may not have landed: the caller keeps `rid` so a retry addresses the same claim. The token stays in this function: never logged, stored or returned."""
    tok, org, name = _read(os.path.join(ROOT, label, "token.txt")), claude_org(label), CREDIT_KINDS[kind]
    if not tok or not org:
        return {"outcome": "error", "text": "Seat %s is not signed in, or its organization is not known yet. Use Refresh all credentials, then try again." % label}, True
    req = urllib.request.Request(RESET_URL % org, method="POST", data=json.dumps({"program": "cedar_ember", "grant_id": gid, "request_id": rid}).encode("utf-8"),
                                 headers={"authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20", "content-type": "application/json",
                                          "user-agent": "claude-cli/%s (external, cli)" % (ver or CLI_FALLBACK)})
    try:
        code, j = fetch(req)
    except Exception as e:   # shortcut: whatever a fetch raises is an unanswered claim; only its type is kept
        code, j = 0, type(e).__name__
    if code == 429:
        return {"outcome": "error", "text": "Claude is rate limiting resets. Try again later."}, True
    if code in (401, 403):
        return {"outcome": "error", "text": "Seat %s needs to sign in to Claude again." % label}, True
    res = j.get("result") if code == 200 and isinstance(j, dict) else None
    done = {"reset": ("redeemed", "%s applied to seat %s." % (name, label)),
            "already_used": ("alreadyRedeemed", "That reset was already applied; nothing more was used."),
            "not_limited": ("nothingToReset", "Seat %s had nothing to reset right now." % label),
            "cooldown": ("error", "Claude resets are cooling down. Try again later."),
            "ineligible": ("noCredit", "Claude says seat %s has no %s to apply." % (label, name.lower()))}
    if isinstance(res, str) and res in done:
        return {"outcome": done[res][0], "text": done[res][1]}, True
    why = "Claude did not confirm it" if res == "unavailable" else "HTTP %s" % code if code else "Claude could not be reached"
    return {"outcome": "error", "text": "The reset on seat %s is unconfirmed (%s). If the seat is still limited in a minute, apply it again: the retry "
                                        "cannot use a second reset." % (label, why)}, False


def sample(now, force=False):
    rec = {"t": int(now), "s": read_claude()}
    cache = load_pcache()
    codex, cemails = read_codex()
    for label, fresh in (cache.get("codex_fresh") or {}).items():     # a reading taken after an applied reset, until the cache catches up
        if label in codex and (fresh.get("ts") or 0) > (codex[label].get("ts") or 0):
            codex[label] = fresh
    if codex:
        rec["codex"] = codex
        cache.setdefault("emails", {})["codex"] = cemails
    seat = read_live("grok", "grok", fetch_grok, GROK_EVERY, now, force, cache)
    if seat:
        rec["grok"] = {"grok": seat}
    seat, why = read_gemini(now)        # local call: read on every sample
    if seat:
        cache["gemini_last"], cache.setdefault("notes", {})["gemini"] = int(now), {}
        rec["gemini"] = {"antigravity": seat}
        if seat.get("plan"):
            cache.setdefault("pnote", {})["gemini"] = "Plan: " + seat["plan"]
    else:                               # not readable: the last recorded reading stays on show (its age is the Read column), with the reason
        cache.setdefault("notes", {})["gemini"] = {"antigravity": why}
        if not cache.get("gemini_last"):
            rec["gemini"] = {"antigravity": {"ok": False, "note": why}}
    email = gemini_email()
    if email:
        cache.setdefault("emails", {}).setdefault("gemini", {})["antigravity"] = email
    save_pcache(cache)
    return rec


# ---------------------------------------------------------------- seat weights

WCFG = {}     # set by set_weights(): {"seat": {pid: {label: w}}, "plan": {pid: {plan: w}}, "plans": {pid: {label: plan as the provider reports it}}}


def _wmap(x):
    """{provider: {key: weight}} from a config value; only finite numbers >= 0 are kept."""
    return {p: {str(k): float(v) for k, v in m.items() if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v < math.inf}
            for p, m in (x.items() if isinstance(x, dict) else ()) if isinstance(m, dict)}


def read_weights_cfg(cfg=None):
    """seatWeights and planWeights from rotator.local.json (next to this script): {"seat": {...}, "plan": {...}}, empty when absent or unreadable."""
    try:
        with open(cfg or os.path.join(HERE, "rotator.local.json"), encoding="utf-8-sig") as fh:
            j = json.load(fh)
    except (OSError, ValueError):
        j = None
    j = j if isinstance(j, dict) else {}
    return {"seat": _wmap(j.get("seatWeights")), "plan": _wmap(j.get("planWeights"))}


def set_weights(w):
    WCFG.clear()
    WCFG.update(w or {})


def wt(pid, label):
    """(weight, source) of one seat, the weight counting it as that many regular seats: seatWeights, else planWeights for the seat's detected plan, else 1.
    source is "seatWeights", "plan <name>" or None."""
    v = ((WCFG.get("seat") or {}).get(pid) or {}).get(label)
    if v is not None:
        return v, "seatWeights"
    plan = ((WCFG.get("plans") or {}).get(pid) or {}).get(label)
    pw = (WCFG.get("plan") or {}).get(pid) or {}
    v = pw.get(plan) if plan else None
    if v is None and plan:
        v = next((x for k, x in pw.items() if k.lower() == plan.lower()), None)
    return (v, "plan " + plan) if v is not None else (1.0, None)


# ---------------------------------------------------------------- history maths

def util_at(seat, key, t):
    """Fraction used at time t; 0 once the window's reset has passed, even if the reading is older."""
    u = seat.get(key)
    if u is None:
        return None
    r = seat.get(key + "r")
    if r and t >= r:
        return 0.0
    return min(max(u, 0.0), 1.0)


def remaining(rec, key, t=None, pid="claude"):
    """(pooled % left, seat count) for one history record; a seat counts as its weight (wt) x 100 %, so the pool's cap is 100 x the sum of the weights.
    A seat of weight 0 is left out."""
    t = rec["t"] if t is None else t
    us = [(w, u) for label, s in seats_of(rec, pid).items() if (w := wt(pid, label)[0]) > 0 and (u := util_at(s, key, t)) is not None]
    return sum(w * (1 - u) for w, u in us) * 100, len(us)


def _step(sa_all, sb_all, key, pid="claude"):
    """Fraction of one account used between two consecutive records, summed over accounts, each seat times its weight."""
    total = 0.0
    for label, sb in sb_all.items():
        sa, w = sa_all.get(label), wt(pid, label)[0]
        if not sa or w <= 0 or sa.get(key) is None or sb.get(key) is None:
            continue
        ra, rb = sa.get(key + "r") or 0, sb.get(key + "r") or 0
        if rb > ra + 3600:          # the window reset between the two readings
            total += w * sb[key]
        else:
            total += w * max(0.0, sb[key] - sa[key])
    return total


def prep(hist, key, pid="claude"):
    """Times and a running total of use, so a burn rate over any span is two lookups."""
    ts, cum = [h["t"] for h in hist], [0.0]
    for a, b in zip(hist, hist[1:]):
        cum.append(cum[-1] + _step(seats_of(a, pid), seats_of(b, pid), key, pid))
    return ts, cum


def burn_p(p, hours, now):
    """% of one regular seat used per hour over the last `hours` up to `now` (a weighted seat counts its weight), or None with under 15 min of history."""
    ts, cum = p
    hi = bisect.bisect_right(ts, now) - 1
    lo = bisect.bisect_left(ts, now - hours * 3600)
    if lo > 0:
        lo -= 1                      # the record just before the span anchors its start
    if hi - lo < 1:
        return None
    span = (ts[hi] - ts[lo]) / 3600
    if span < 0.25:
        return None
    return (cum[hi] - cum[lo]) * 100 / span


def burn(hist, key, hours, now, pid="claude"):
    return burn_p(prep(hist, key, pid), hours, now)


def hour_profile(rows, wid, pid="claude", gap=DAY):
    """Typical-day profile: expected %/h of one account for each local hour of the day (24 numbers) and its mean, or None with under 24 h of history.
    Each step between two consecutive records (reset-aware, as burn is) is spread over the hours it spans by time; the profile for an hour is the
    use that fell in it divided by the time covered for that hour in days, so a day with no records for an hour does not count as a day of zero use.
    A step longer than `gap` is skipped (its use cannot be placed); an hour with under 30 min covered gets the overall mean."""
    drop, cov = [0.0] * 24, [0.0] * 24
    for a, b in zip(rows, rows[1:]):
        ta, tb = a["t"], b["t"]
        if tb <= ta or tb - ta > gap:
            continue
        d = _step(seats_of(a, pid), seats_of(b, pid), wid, pid) * 100
        t = ta
        while t < tb:
            lt = time.localtime(t)
            nxt = min(tb, t + 3600 - lt.tm_min * 60 - lt.tm_sec)
            drop[lt.tm_hour] += d * (nxt - t) / (tb - ta)
            cov[lt.tm_hour] += nxt - t
            t = nxt
    if sum(cov) < DAY:
        return None
    mean = sum(drop) * 3600 / sum(cov)
    prof = [drop[h] * 3600 / cov[h] if cov[h] >= 1800 else mean for h in range(24)]
    return prof, sum(prof) / 24


def project(seats, rate, now, horizon=14 * DAY, step=600):
    """Python twin of quotaProject in usage-sim.js (pooled quota left, soonest-reset seat drains first); `rate` is %/h of one regular seat, or 24 of them by local hour.
    A seat's optional "w" (default 1) is how many regular seats it counts as: it holds that much, and its use is drained in those units; weight 0 is left out."""
    ss = [{"used": s.get("used") or 0, "reset": s.get("reset") or None, "period": s["period"] if (s.get("period") or 0) > 0 else 0, "w": s.get("w", 1)}
          for s in seats if s.get("w", 1) > 0]
    for s in ss:
        while s["reset"] and s["period"] and s["reset"] <= now:
            s["reset"] += s["period"]
    pts, empty, anyrate = [], None, (any(r > 0 for r in rate) if isinstance(rate, list) else rate > 0)
    t = now
    while t <= now + horizon:
        for s in ss:
            while s["reset"] and s["period"] and s["reset"] <= t:
                s["used"] = 0
                s["reset"] += s["period"]
        left = sum(s["w"] * (1 - s["used"]) for s in ss) * 100
        pts.append((t, round(left, 1)))
        if empty is None and anyrate and left < 0.05:
            empty = t
        r = rate[time.localtime(t).tm_hour] if isinstance(rate, list) else rate
        drain = r / 100 * step / 3600 if r > 0 else 0
        for s in sorted(ss, key=lambda s: s["reset"] or math.inf):
            if drain <= 0:
                break
            take = min(s["w"] * (1 - s["used"]), drain)
            s["used"] += take / s["w"]
            drain -= take
        t += step
    return pts, empty


def _roll(r, period, now):
    """The next reset after `now`, moving a stale one forward by whole periods."""
    if r and period and r <= now:
        r += period * math.ceil((now - r + 1) / period)
    return r


def _num(x, nd=1):
    return None if x is None else round(x, nd)


def prov_spec(pid, seats):
    """(name, [(window id, label, default period s)], [(limit window id, limit label)]); Gemini's windows are whatever its seat reports."""
    name, wins, lims = PROVIDERS[pid]
    if wins is None:
        wins = [(w, lbl, 18000) for s in seats.values() for w, lbl in (s.get("n") or {}).items()]
        lims = [(w, lbl) for w, lbl, _ in wins]
    return name, wins, lims


def latest_of(hist, pid):
    """The newest record carrying provider `pid`, a recorded one in preference to a rebuilt (b) one."""
    rows = [h for h in hist if seats_of(h, pid)]
    rec = next((h for h in reversed(rows) if not h.get("b")), rows[-1] if rows else {"t": 0})
    seats = dict(seats_of(rec, pid))
    for label, s in seats.items():          # a failed read keeps showing the last good one, with the failure as its note
        if s.get("ok") is False:
            good = next((x for x in (seats_of(h, pid).get(label) for h in reversed(rows)) if x and x.get("ok") is not False and x.get("ts")), None)
            if good:
                seats[label] = dict(good, note=s.get("note"))
    return dict(rec, **{"s" if pid == "claude" else pid: seats}) if seats else rec


def build_limit(hist, latest, pid, wid, label, now, dflt):
    seats = [(s, w) for label, s in seats_of(latest, pid).items() if (w := wt(pid, label)[0]) > 0 and util_at(s, wid, now) is not None]
    if not seats:
        return None
    rem = remaining(latest, wid, now, pid)[0]
    last, rows = {}, []
    for h in hist:                   # last record in each 15-minute bucket that has this window
        r, cnt = remaining(h, wid, pid=pid)
        if cnt:
            rows.append(h)
            last[h["t"] // BUCKET] = [h["t"], round(r, 1), 1 if h.get("b") else 0]
    p = prep(rows, wid, pid)         # burn only over records that carry this window, so a young provider reads null
    first = rows[0]["t"]
    lim = {"id": wid, "label": label, "cap": round(sum(w for _, w in seats) * 100, 2), "now": round(rem, 1), "hist": [last[k] for k in sorted(last)],
           "burn": {}, "drain": {}, "seats": []}
    prof = hour_profile(rows, wid, pid)
    if prof:
        lim["profile"], lim["typical"] = [round(x, 2) for x in prof[0]], round(prof[1], 2)
    for w in WINDOWS:
        lim["burn"][str(w)] = _num(burn_p(p, w, now))
        pts = []
        for t in range(int(now), int(first) - 1, -3600):
            b = burn_p(p, w, t)
            if b is not None:
                pts.append([t, round(b, 1)])
        lim["drain"][str(w)] = pts[::-1]
    for s, w in seats:
        period = s.get(wid + "p") or dflt[wid]
        r = s.get(wid + "r")
        lim["seats"].append(dict({"used": util_at(s, wid, now), "reset": None if r is None else int(_roll(r, period, now)),
                                  "period": int(period)}, **({"w": w} if w != 1 else {})))
    return lim


def build_provider(hist, pid, emails, now, extra):
    latest = latest_of(hist, pid)
    seats = seats_of(latest, pid)
    if not seats:
        return None
    name, wins, lims = prov_spec(pid, seats)
    accounts = []
    use = {k: v for k, v in ((extra.get("inUse") or {}).get(pid) or {}).items() if k in BADGE and v in seats}      # only a seat this provider shows
    sw = (extra.get("switch") or {}).get(pid) or {}
    for label in sorted(seats):
        s = seats[label]
        a = {"label": label, "email": (emails.get(pid) or {}).get(label), "ok": s.get("ok") is not False,
             "note": s.get("note") or ((extra.get("notes") or {}).get(pid) or {}).get(label) or "", "readAt": int(s["ts"]) if s.get("ts") else None, "windows": []}
        for wid, wlabel, dp in wins:
            u = util_at(s, wid, now)
            if u is None:
                continue
            period = s.get(wid + "p") or dp
            w = {"id": wid, "label": wlabel, "used": u, "reset": None if s.get(wid + "r") is None else int(_roll(s[wid + "r"], period, now))}
            if isinstance(s.get(wid + "t"), str) and not (s.get(wid + "r") and now >= s[wid + "r"]):
                w["stat"] = s[wid + "t"]            # a status read before the window reset says nothing about the new one
            if s.get(wid + "r") and now >= s[wid + "r"] > (s.get("ts") or 0):
                w["assumed"] = True         # the reset passed and nothing has been read since: 0 is rolled forward, not measured
            a["windows"].append(w)
        a["ok"] = a["ok"] and bool(a["windows"])
        a["badges"] = [BADGE[k] for k, v in use.items() if v == label]
        bs = next((x for x in (seats_of(h, pid).get(label) or {} for h in reversed(hist)) if x.get("banked") is not None), {})   # imported log records carry no credits
        w, wsrc = wt(pid, label)
        if w != 1:
            a["w"], a["wsrc"] = w, wsrc
        plan = ((WCFG.get("plans") or {}).get(pid) or {}).get(label)
        if plan:
            a["plan"] = plan
        if bs:                              # a credit past its expiry is gone, even if the cache is older than that
            live = [x for x in bs.get("bankedList") or [] if x["expiresAt"] > now]
            a["banked"], a["bankedList"] = max(bs["banked"] - (len(bs.get("bankedList") or []) - len(live)), len(live)), live
        cr = ((extra.get("credits") or {}).get(label) or {}) if pid == "claude" else {}
        if cr.get("ts"):                    # Claude's banked resets come from the read-only usage call, not from history
            a["bankedAt"] = int(cr["ts"])
            gs = sorted((g for g in cr.get("grants") or [] if g["left"] > 0 and (g["endsAt"] is None or g["endsAt"] > now)), key=lambda g: (g["endsAt"] is None, g["endsAt"] or 0))
            if cr.get("eligible") and gs:
                a["banked"] = sum(g["left"] for g in gs)
                a["bankedList"] = [dict({"title": CREDIT_KINDS.get(g["kind"], "Reset"), "expiresAt": g["endsAt"]}, **({"n": g["left"]} if g["left"] > 1 else {})) for g in gs]
        if cr.get("note"):
            a["bankedNote"] = cr["note"]
        acts = [r for r in sw if r != "best" and label in sw[r] and use.get("app" if r == "both" else r) != label]
        if acts:                            # the switch buttons: roles whose rotator can use this seat, minus the one it already holds
            a["switch"] = acts
        rk = [(k, usable_grants(cr, k, now)) for k in RESET_KINDS] if pid == "claude" and extra.get("claudeReset") else []
        if any(gs for _, gs in rk):         # what the Apply buttons and their dialog need: no grant ids, the server picks the grant again on the click
            a["resets"] = [{"kind": k, "left": sum(g["left"] for g in gs), "endsAt": gs[0]["endsAt"]} for k, gs in rk if gs]
        accounts.append(a)
    if pid == "codex":                      # measured weight check: tokens per 1 % against the weight-1 seats, over the sampled seats
        meas = measured_ratios((extra.get("codex") or {}).get("pairs") or {}, now)
        sug = weight_suggestions((extra.get("codex") or {}).get("pairs") or {}, now)
        for a in accounts:
            x, n = meas.get(a["label"], (None, 0))
            a["ratio"] = dict({"n": n}, **({"x": round(x, 2)} if x is not None else {}))
            if a["label"] in sug:
                a["suggest"] = {"w": sug[a["label"]][0], "n": sug[a["label"]][1]}
    dflt = {w: p for w, _, p in wins}
    limits = [x for x in (build_limit(hist, latest, pid, wid, lbl, now, dflt) for wid, lbl in lims) if x]
    out = {"id": pid, "name": name, "total": len(accounts), "loaded": sum(a["ok"] for a in accounts),
           "accounts": accounts, "limits": limits}
    if use:
        out["inUse"] = use
    if ("cli" if pid == "claude" else "both") in sw:
        out["best"] = True                                 # the header's best/next seat button: its rotator is here
    if pid == "codex":
        out["canReset"] = bool(extra.get("canReset"))      # the redeem script exists: the page may offer Apply reset
    if pid == "claude" and extra.get("claudeReset"):
        out["canReset"] = True                             # claudeResetCredits is on: the page may offer the per-kind Apply buttons
    note = PROVIDER_NOTE.get(pid) or (extra.get("pnote") or {}).get(pid)
    mixed = sorted({a["plan"] for a in accounts if a.get("plan") and "w" not in a})
    if len(mixed) > 1:                      # seats on different plans counted as equal: the pool is only meaningful once the user sizes them
        hint = "Seats are on different plans (%s) but count equally. Set planWeights or seatWeights in rotator.local.json." % ", ".join(mixed)
        note = note + " " + hint if note else hint
    if note:
        out["note"] = note
    return out


def build(hist, now, emails=None, app=False, extra=None):
    extra = extra or {}
    set_weights(extra.get("weights"))
    provs = [p for p in (build_provider(hist, pid, emails or {}, now, extra) for pid in PROVIDERS) if p]
    out = {"now": int(now), "app": app, "first": hist[0]["t"] if hist else None, "providers": provs}
    d = extra.get("drift")
    if d and d.get("differing"):
        out["drift"] = {"n": len(d["differing"]), "names": [str(x) for x in d["differing"]], "checked": int(_f(d.get("checked")) or 0) or None}
    return out


BT_TARGETS = (("claude", "w", "Claude all models"), ("claude", "f", "Claude Fable"), ("codex", "w", "Codex weekly"))
BT_METHODS = ("typical", "3h", "24h")


def backtest(hist, targets=BT_TARGETS, every=6 * 3600, ahead=DAY, fresh=6 * 3600, minpts=8):
    """How well each rate method projects 24 h ahead: {target label: {"n": origins, method: mean absolute error in pooled % points}}.
    An origin is every 6 h grid point with at least 24 h of history behind it and `ahead` of recorded history after it. Each method projects
    from the state at the origin (the last record at most `fresh` s old; `minpts` recorded points needed after it) with quotaProject's rules (typical: the hour profile of the history before the origin only; 3h, 24h: that burn
    held flat); the error at an origin is the mean |projected - recorded| over the recorded points in the next `ahead`, the figure is the mean over origins."""
    out = {}
    for pid, wid, label in targets:
        rows = [h for h in hist if remaining(h, wid, pid=pid)[1]]
        if len(rows) < 2:
            continue
        ts, dflt = [h["t"] for h in rows], {w: p for w, _, p in PROVIDERS[pid][1]}
        p, lefts = prep(rows, wid, pid), [remaining(h, wid, pid=pid)[0] for h in rows]
        errs = {m: [] for m in BT_METHODS}
        t0 = (ts[0] + DAY) // every * every + every
        while t0 + ahead <= ts[-1]:
            i = bisect.bisect_right(ts, t0) - 1
            actual = [(ts[j] - t0, lefts[j]) for j in range(i + 1, bisect.bisect_right(ts, t0 + ahead))]
            prof = hour_profile(rows[:i + 1], wid, pid) if t0 - ts[i] <= fresh else None
            rates = {"typical": prof and prof[0], "3h": burn_p(p, 3, t0), "24h": burn_p(p, 24, t0)}
            if len(actual) >= minpts and all(r is not None for r in rates.values()):
                seats = []
                for lab, s in seats_of(rows[i], pid).items():
                    u = util_at(s, wid, t0)
                    if u is not None:
                        per = s.get(wid + "p") or dflt[wid]
                        seats.append({"used": u, "reset": _roll(s.get(wid + "r"), per, t0), "period": per, "w": wt(pid, lab)[0]})
                for m, r in rates.items():
                    pts = project(seats, r, t0, ahead)[0]
                    errs[m].append(sum(abs(pts[round(dt / 600)][1] - v) for dt, v in actual) / len(actual))
            t0 += every
        if errs["typical"]:
            out[label] = dict({"n": len(errs["typical"]), "errs": errs}, **{m: sum(e) / len(e) for m, e in errs.items()})
    return out


def backtest_table(res):
    """Plain-text table of backtest(): per target and over all origins, then the method with the lowest overall error."""
    rows = [("Limit", "Origins") + BT_METHODS]
    allerr = {m: [] for m in BT_METHODS}
    for label, r in res.items():
        rows.append((label, str(r["n"])) + tuple("%.1f" % r[m] for m in BT_METHODS))
        for m in BT_METHODS:
            allerr[m] += r["errs"][m]
    if not allerr["typical"]:
        return "no limit has enough history to backtest", None
    mean = {m: sum(e) / len(e) for m, e in allerr.items()}
    best = min(BT_METHODS, key=lambda m: mean[m])
    rows.append(("All (per origin)", str(len(allerr["typical"]))) + tuple("%.1f" % mean[m] for m in BT_METHODS))
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    lines = ["  ".join(c.ljust(w[i]) if i == 0 else c.rjust(w[i]) for i, c in enumerate(r)) for r in rows]
    return chr(10).join(lines + ["mean absolute error in pooled %% points over 24 h; lowest overall: %s" % best]), best


def seat_emails(root, fallback):
    """{label: email} for Claude: each seat folder's email.txt (trimmed), else the backfill map's. token.txt is never read."""
    out = dict(fallback)
    for d in glob.glob(os.path.join(root, "*", "email.txt")):
        try:
            with open(d, encoding="utf-8-sig") as fh:
                e = fh.read().strip()
        except OSError:
            continue
        if e:
            out[os.path.basename(os.path.dirname(d))] = e
    return out


def load_emails():
    """{provider: {label: email}}: Claude's from the seat folders (backfill map as fallback), the others from their own readers."""
    out = dict(load_pcache().get("emails") or {})
    try:
        with open(EMAILS, encoding="utf-8") as fh:
            fb = json.load(fh)
    except (OSError, ValueError):
        fb = {}
    out["claude"] = seat_emails(ROOT, fb if isinstance(fb, dict) else {})
    return out


# ---------------------------------------------------------------- storage and rendering

def load_extra():
    """What build() takes besides history and emails: account/provider notes from the provider cache, the rotator drift file."""
    c, drift = load_pcache(), None
    plans, pairs = codex_measure()
    try:
        with open(os.path.join(ROOT, ".rotator-drift.json"), encoding="utf-8-sig") as fh:
            drift = json.load(fh)
    except (OSError, ValueError):
        pass
    return {"notes": c.get("notes"), "pnote": c.get("pnote"), "credits": c.get("credits") if credits_enabled() else None, "claudeReset": credits_enabled(), "drift": drift if isinstance(drift, dict) else None, "canReset": redeem_script() is not None, "inUse": in_use(), "switch": switch_targets(),
            "weights": dict(read_weights_cfg(), plans={"codex": plans}), "codex": {"pairs": pairs}}


def load():
    """The history, oldest first (imported points are appended out of order). Cursor's retired key is stripped, once, on disk too."""
    hist = []
    try:
        with open(HIST, encoding="utf-8") as fh:
            for line in fh:
                try:
                    hist.append(json.loads(line))
                except ValueError:
                    pass  # a torn last line from a run that was killed mid-write
    except OSError:
        pass
    old = [h for h in hist if "cursor" in h]
    for h in old:
        del h["cursor"]
    hist.sort(key=lambda h: h["t"])
    if old:
        write_all(hist)
    return hist


def write_all(hist):
    tmp = HIST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(h, separators=(",", ":")) + "\n" for h in hist)
    os.replace(tmp, HIST)


def save(hist, rec, now):
    """Append rec; once a day, rewrite the file without lines older than KEEP_DAYS."""
    if hist and hist[0]["t"] < now - (KEEP_DAYS + 1) * 86400:
        keep = [h for h in hist if h["t"] >= now - KEEP_DAYS * 86400] + [rec]
        write_all(keep)
        return keep
    with open(HIST, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
    return hist + [rec]


def page_html(data):
    def read(name):
        try:
            with open(os.path.join(HERE, name), encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            return ""
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    sim = read("usage-sim.js")
    # one pass, so neither inserted text can be re-scanned for the other placeholder
    return re.sub(r"__DATA__|__SIM__", lambda m: blob if m.group() == "__DATA__" else sim, read("usage-dashboard.template.html"))


def render(data):
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(page_html(data))
    os.replace(tmp, OUT)


# ---------------------------------------------------------------- codex history from session logs

CODEX_WIN = {10080: ("w", WEEK), 300: ("s", 18000)}     # window_minutes -> (window id, period s), as parse_codex does
SLOP = 120                                              # s: how far apart two resets_at may be and still be the same window


def rollout_files(cdir, now, since):
    """[(path, seat or None)]: rollout logs modified in the last KEEP_DAYS and after `since`. A home's log belongs to that seat; the active login's to None."""
    out = []
    for pat, home in ((os.path.join(cdir, "homes", "*", "sessions", "**", "rollout-*.jsonl"), True),
                      (os.path.join(cdir, "sessions", "**", "rollout-*.jsonl"), False)):
        for f in glob.glob(pat, recursive=True):
            try:
                mt = os.path.getmtime(f)
            except OSError:
                continue
            if mt >= now - KEEP_DAYS * DAY and mt > since:
                out.append((f, os.path.relpath(f, os.path.join(cdir, "homes")).split(os.sep)[0] if home else None))
    return out


def rollout_events(path):
    """(t, {window id: (used fraction, reset, period)}) for each usable token_count line, read streaming; bad lines are skipped."""
    from datetime import datetime
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"token_count"' not in line:
                    continue
                try:
                    j = json.loads(line)
                    p = j["payload"]
                    rl = p["rate_limits"] if p["type"] == "token_count" else None
                    t = datetime.fromisoformat(j["timestamp"]).timestamp()
                except (ValueError, KeyError, TypeError):
                    continue
                if not isinstance(rl, dict) or rl.get("limit_id") not in (None, "codex"):
                    continue            # another limit family (e.g. "premium") is not the plan's quota
                wins = {}
                for part in ("primary", "secondary"):
                    x = rl.get(part)
                    w = CODEX_WIN.get(int(_f(x.get("window_minutes")) or 0)) if isinstance(x, dict) else None
                    used, reset = (_f(x.get("used_percent")), _f(x.get("resets_at"))) if w else (None, None)
                    if used is not None and reset:
                        wins[w[0]] = (used / 100, int(reset), w[1])
                if wins:
                    yield int(t), wins
    except OSError:
        return


def codex_events(cdir, now, since, known):
    """[(t, seat, wins)] oldest first. `known` {window id: {reset: {seats}}} is seeded from the labelled caches; each home's own events add to it,
    and an active-login event goes to the one seat whose known reset for that window is within SLOP s (no match, or several seats: skipped)."""
    own, act = [], []
    for f, seat in rollout_files(cdir, now, since):
        (own if seat else act).extend((t, seat, w) for t, w in rollout_events(f))
    for _, seat, wins in own:
        for w, (_, r, _) in wins.items():
            known.setdefault(w, {}).setdefault(r, set()).add(seat)
    for t, _, wins in act:
        seats = {x for w, (_, r, _) in wins.items() for kr, ss in known.get(w, {}).items() if abs(kr - r) <= SLOP for x in ss}
        if len(seats) == 1:
            own.append((t, seats.pop(), wins))
    return sorted((e for e in own if e[0] >= now - KEEP_DAYS * DAY), key=lambda e: e[0])


def rollout_records(events, taken, rebuilt):
    """History records from attributed events: one per 5 minutes, each carrying every seat seen so far at its newest state;
    none in a 5-minute bucket listed in `taken` (a recorded point is never overwritten). `rebuilt` flags them b like the Claude backfill."""
    state, recs = {}, []
    for t, seat, wins in events:
        st = state.setdefault(seat, {})
        for w, (used, reset, period) in wins.items():
            st[w], st[w + "r"], st[w + "p"] = used, reset, period
        st["ts"] = t
        k = t // BUCKET5
        if k in taken:
            continue
        snap = {a: dict(b) for a, b in state.items()}
        if recs and recs[-1]["t"] // BUCKET5 == k:
            recs[-1]["codex"] = snap
        else:
            recs.append(dict({"t": t, "codex": snap}, **({"b": 1} if rebuilt else {})))
    return recs


def import_rollouts(hist, now, rebuilt, since=0, cdir=None):
    """-> (new records, {seat: (events, earliest t)}) from the Codex rollout logs; buckets `hist` already has a codex point in are left alone."""
    cdir = cdir or os.path.join(HOME, ".codex")
    sink, known = [], {}
    read_codex(cdir, sink)
    for label, c in sink:
        seat, _ = parse_codex(c)
        for w in "sw":
            if seat and seat.get(w + "r"):
                known.setdefault(w, {}).setdefault(int(seat[w + "r"]), set()).add(label)
    ev = codex_events(cdir, now, since, known)
    per = {}
    for t, seat, _ in ev:
        n, first = per.get(seat, (0, t))
        per[seat] = (n + 1, min(first, t))
    return rollout_records(ev, {h["t"] // BUCKET5 for h in hist if "codex" in h}, rebuilt), per


_ROLL = {}      # rollout path -> ((mtime, size), parsed events): a log is parsed again only when it changed


def rollout_tokens(path):
    """[(t, plan_type or None, weekly used %, weekly reset, tokens so far or None)] for each usable token_count line of one rollout log.
    Tokens are input minus cached input plus output (total_token_usage is cumulative over the session), so cached input, which costs next to nothing, does not count."""
    from datetime import datetime
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"token_count"' not in line:
                    continue
                try:
                    j = json.loads(line)
                    p = j["payload"]
                    rl = p["rate_limits"] if p["type"] == "token_count" else None
                    t = datetime.fromisoformat(j["timestamp"]).timestamp()
                except (ValueError, KeyError, TypeError):
                    continue
                if not isinstance(rl, dict) or rl.get("limit_id") not in (None, "codex"):
                    continue
                used = reset = tok = None
                for part in ("primary", "secondary"):
                    x = rl.get(part)
                    if isinstance(x, dict) and int(_f(x.get("window_minutes")) or 0) == 10080:
                        used, reset = _f(x.get("used_percent")), _f(x.get("resets_at"))
                info = p.get("info")
                u = info.get("total_token_usage") if isinstance(info, dict) else None
                if isinstance(u, dict) and _f(u.get("input_tokens")) is not None and _f(u.get("output_tokens")) is not None:
                    tok = _f(u["input_tokens"]) - (_f(u.get("cached_input_tokens")) or 0) + _f(u["output_tokens"])
                out.append((int(t), rl["plan_type"] if isinstance(rl.get("plan_type"), str) else None, used, reset, tok))
    except OSError:
        pass
    return out


def rollout_cached(path):
    try:
        st = os.stat(path)
    except OSError:
        return []
    key = (st.st_mtime, st.st_size)
    if path not in _ROLL or _ROLL[path][0] != key:
        _ROLL[path] = (key, rollout_tokens(path))
    return _ROLL[path][1]


def token_pairs(events):
    """[(t, tokens per 1 %)] from one log's events: from an anchor event to the next one whose weekly used % is at least 1 higher in the same window
    (resets within SLOP s of each other); that event becomes the anchor. Whole-percent readings tick only now and then, so the tokens between two ticks,
    not between two adjacent events, are what a percent costs. A new window or a token counter that went back starts over."""
    out, a = [], None
    for t, _, used, reset, tok in events:
        if used is None or reset is None or tok is None:
            continue
        if a is None or abs(reset - a[3]) > SLOP or used < a[1] or tok < a[2]:
            a = (t, used, tok, reset)
        elif used - a[1] >= 1:
            if tok > a[2]:
                out.append((t, (tok - a[2]) / (used - a[1])))
            a = (t, used, tok, reset)
    return out


def measured_ratios(pairs, now, days=21, minn=5):
    """{seat: (ratio or None, samples)} from codex_measure's pairs: a seat's median tokens per 1 % over the last `days` days (at least `minn` pairs, else no ratio),
    divided by the median of that figure over the weight-1 seats that have one. A sanity check on the configured weights, not an input to them."""
    recent, med, base = _measured(pairs, now, days, minn)
    return {s: (med[s] / base if s in med and base else None, len(v)) for s, v in recent.items()}


def _measured(pairs, now, days, minn):
    """(recent {seat: [(t, tokens per 1 %)]}, median {seat: tokens per 1 %} of the seats with `minn`, reference: the median over the weight-1 seats among them or None)."""
    recent = {s: [(t, v) for t, v in p if t >= now - days * DAY] for s, p in pairs.items()}
    med = {s: statistics.median(v for _, v in r) for s, r in recent.items() if len(r) >= minn}
    ref = [m for s, m in med.items() if wt("codex", s)[0] == 1]
    return recent, med, statistics.median(ref) if ref else None


def nice_weight(x):
    """A measured ratio as a weight worth typing: the nearest 0.5 below 3 (never 0, which would drop the seat), a whole number from 3 up."""
    return math.floor(x + .5) if x >= 3 else max(0.5, math.floor(x * 2 + .5) / 2)


def weight_suggestions(pairs, now, days=21, minn=20, steady=1.25, off=1.3):
    """{seat: (suggested weight, samples)} for the Codex seats whose measured ratio deserves a different weight: at least `minn` samples in the last `days` days, the
    older and the newer half of them (by time) each within `steady` of the other against the same reference, and the ratio more than `off` away from the seat's current
    weight once rounded by nice_weight to something else. A suggestion only: nothing applies it."""
    recent, med, base = _measured(pairs, now, days, 5)
    out = {}
    for s, r in recent.items():
        if not base or len(r) < minn:
            continue
        v = [x for _, x in sorted(r)]
        old, new = (statistics.median(h) / base for h in (v[:len(v) // 2], v[len(v) // 2:]))
        w, x = wt("codex", s)[0], med[s] / base
        if max(old, new) / min(old, new) <= steady and w > 0 and max(x / w, w / x) > off and nice_weight(x) != w:
            out[s] = (nice_weight(x), len(r))
    return out


def codex_measure(cdir=None, now=None):
    """({seat: plan_type}, {seat: [(t, tokens per 1 % of weekly use)]}) from the rollout logs. A home's log belongs to that seat; an active-login event to the one
    seat whose known weekly reset (the caches', and the homes' events') is within SLOP s of its own (none or several: skipped), as codex_events does.
    The plan is the newest event's plan_type."""
    cdir, now = cdir or os.path.join(HOME, ".codex"), now or time.time()
    files, known, sink = rollout_files(cdir, now, 0), {}, []
    read_codex(cdir, sink)
    for label, c in sink:
        seat, _ = parse_codex(c)
        if seat and seat.get("wr"):
            known.setdefault(int(seat["wr"]), set()).add(label)
    chunks = [(seat, rollout_cached(f)) for f, seat in files if seat]
    for seat, ev in chunks:
        for e in ev:
            if e[3]:
                known.setdefault(int(e[3]), set()).add(seat)
    for f, seat in files:
        by = {}
        for e in ([] if seat else rollout_cached(f)):
            ss = {s for kr, x in known.items() if e[3] and abs(kr - e[3]) <= SLOP for s in x}
            if len(ss) == 1:
                by.setdefault(ss.pop(), []).append(e)
        chunks += by.items()
    plans, newest, pairs = {}, {}, {}
    for seat, ev in chunks:
        for t, plan, *_ in ev:
            if plan and t >= newest.get(seat, 0):
                plans[seat], newest[seat] = plan, t
        pairs.setdefault(seat, []).extend(token_pairs(ev))
    return plans, pairs


# ---------------------------------------------------------------- backfill from .rotate-log.txt

LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+(.*)$")
LOG_EMAIL = re.compile(r"-> (\w) \(([^)\s]+@[^)\s]+)\)")


def _pct(m, i=1):
    return min(max(int(m.group(i)), 0), 100) / 100


def parse_log_line(msg):
    """-> {label: {"w": x, "f": y}} (fractions, only the keys this line carries)."""
    m = re.match(r"ROTATED '\w' -> (\w) \(.*?\) session \d+%, weekly (\d+)%(?:, fable (\d+)%)?", msg)
    if m:
        v = {"w": _pct(m, 2)}
        if m.group(3) is not None:
            v["f"] = _pct(m, 3)
        return {m.group(1): v}
    if msg.startswith("NO USABLE TARGET"):
        return {lab: {"w": min(int(w), 100) / 100} for lab, w in re.findall(r"\b(\w)=s\d+%/w(\d+)%", msg)}
    m = re.match(r"TRIGGER: active account '(\w)'", msg)
    if m:
        v = {}
        c = re.search(r"(FABLE|WEEKLY) window CAPPED at (\d+)%", msg)
        if c:
            v["f" if c.group(1) == "FABLE" else "w"] = _pct(c, 2)
        c = re.search(r"\bweekly (\d+)%", msg)
        if c:
            v["w"] = _pct(c)
        return {m.group(1): v} if v else {}
    return {}


def backfill_records(log_text, latest_seats, start, end):
    """-> (records, {label: email}). Records cover [start, end) and carry each label's weekly (w) and Fable (f)
    value forward until its reset grid says it went back to 0."""
    grids = {(lab, k): s[k + "r"] for lab, s in latest_seats.items() for k in ("w", "f") if _f(s.get(k + "r"))}
    events, emails = [], {}
    for line in log_text.splitlines():
        m = LOG_LINE.match(line)
        if not m:
            continue
        t = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
        e = LOG_EMAIL.search(m.group(2))
        if e and e.group(1) in latest_seats and re.match(r"(ROTATED|DRY RUN)", m.group(2)):
            emails[e.group(1)] = e.group(2)        # the log is chronological, so the newest wins
        if start <= t < end:
            vals = {lab: v for lab, v in parse_log_line(m.group(2)).items() if lab in latest_seats}
            if vals:
                events.append((int(t), vals))

    def nxt(lab, k, t):
        r = grids.get((lab, k))
        return None if r is None else r - ((r - t - 1) // WEEK) * WEEK      # the first grid reset after t

    state, recs = {}, []
    for t, vals in sorted(events, key=lambda e: e[0]):
        for lab, v in vals.items():
            for k, x in v.items():
                if (lab, k) in grids:
                    state[(lab, k)] = (x, nxt(lab, k, t))
        seats = {}
        for (lab, k), (x, rst) in state.items():
            seats.setdefault(lab, {}).update({k: x if t < rst else 0.0, k + "r": nxt(lab, k, t)})
        rec = {"t": t, "s": seats, "b": 1}
        if recs and t - recs[-1]["t"] < 300:
            recs[-1]["s"] = seats                   # at most one record per 5 minutes
        else:
            recs.append(rec)
    return recs, emails


def when(t):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(t))


def backfill_claude(real, days, now):
    """Rebuilt Claude records from the rotate log (None when it cannot run), written emails included."""
    seated = [h for h in real if "s" in h]
    if not seated:
        say("backfill: no real Claude history yet, nothing to anchor the reset grid to")
        return None
    try:
        with open(os.path.join(ROOT, ".rotate-log.txt"), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        say("backfill: cannot read the rotate log (%s)" % type(e).__name__)
        return None
    recs, emails = backfill_records(text, seated[-1]["s"], now - days * 86400, seated[0]["t"])
    if emails:
        with open(EMAILS + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(emails, fh)
        os.replace(EMAILS + ".tmp", EMAILS)
    labels = sorted({lab for r in recs for lab in r["s"]})
    say("backfill: claude %d records (labels %s, %s), %d emails" % (len(recs), ",".join(labels) or "-",
                                                                   "%s .. %s" % (when(recs[0]["t"]), when(recs[-1]["t"])) if recs else "none", len(emails)))
    return recs


def backfill(days):
    """Rebuild past history (flagged b): Claude from the rotate log, Codex from the session logs. Recorded points are never touched."""
    hist = load()
    real, now = [h for h in hist if not h.get("b")], time.time()
    claude = backfill_claude(real, days, now)
    if claude is None:                  # keep what an earlier backfill rebuilt
        claude = [h for h in hist if h.get("b") and "s" in h]
    codex, per = import_rollouts(real, now, True)
    write_all(sorted(real + claude + codex, key=lambda h: h["t"]))
    say("backfill: codex %d records, %s" % (len(codex), "; ".join("%s %d events from %s" % (k, n, when(f)) for k, (n, f) in sorted(per.items())) or "no events"))


# ---------------------------------------------------------------- local app

def applog(msg):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(APPLOG, "a", encoding="utf-8") as fh:
            fh.write("%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
        if os.path.getsize(APPLOG) > 200_000:
            with open(APPLOG, "rb") as fh:
                data = fh.read()
            data = data[len(data) // 2:]
            with open(APPLOG, "wb") as fh:
                fh.write(data[data.find(b"\n") + 1:])
    except OSError:
        pass


def host_ok(host, port):
    """DNS-rebinding guard: only the literal loopback names on our own port."""
    return (host or "").lower() in ("127.0.0.1:%d" % port, "localhost:%d" % port)


def manifest():
    return {"name": "Quota Management", "short_name": "Quota Management", "start_url": "/", "display": "standalone",
            "background_color": "#0c0a09", "theme_color": "#0c0a09",
            "icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
                      {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png"},
                      {"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml"}]}


REDEEM_DEFAULT = os.path.join(HOME, ".claude", "skills", "merge-pr", "scripts", "codex_redeem_reset.py")
RESET_TIMEOUT = 90


def redeem_script(cfg=None):
    """The Codex redeem script's path: `codexRedeemScript` in rotator.local.json (next to this script), else the merge-pr skill's; None when the file is missing."""
    try:
        with open(cfg or os.path.join(HERE, "rotator.local.json"), encoding="utf-8-sig") as fh:
            p = json.load(fh).get("codexRedeemScript")
    except (OSError, ValueError, AttributeError):
        p = None
    p = os.path.expanduser(p) if isinstance(p, str) and p else REDEEM_DEFAULT
    return p if os.path.isfile(p) else None


def codex_homes(cdir=None):
    """The Codex seat labels: the folder names under ~/.codex/homes."""
    return sorted(os.path.basename(d) for d in glob.glob(os.path.join(cdir or os.path.join(HOME, ".codex"), "homes", "*")) if os.path.isdir(d))


def valid_seat(seat, homes):
    """A seat the reset may be applied to: letters only, and one of the Codex homes (exact match)."""
    return isinstance(seat, str) and re.fullmatch(r"[A-Za-z]+", seat) is not None and seat in homes


def codex_seat_from_read(rl, now):
    """The redeem script's read-only `rate_limits_before` -> a codex seat dict, or None. Like the Codex rotator, with no window durations the
    secondary slot is the weekly window and the primary the 5-hour one; a lone primary is the weekly."""
    def slot(k):
        w = rl.get(k) if isinstance(rl, dict) else None
        return w if isinstance(w, dict) and _f(w.get("used_percent")) is not None else None
    p, s = slot("primary"), slot("secondary")
    weekly, session = (s, p) if s else (p, None)
    seat = {"ts": int(now)}
    for wid, w, per in (("w", weekly, WEEK), ("s", session, 18000)):
        if w:
            seat[wid], seat[wid + "r"], seat[wid + "p"] = _f(w["used_percent"]) / 100, _f(w.get("resets_at")), per
    if len(seat) == 1:
        return None
    n = _f(rl.get("banked_reset_credits"))
    if n is not None and n >= 0:
        seat["banked"] = int(n)
        seat["bankedList"] = sorted(({"title": str(x.get("title") or "Reset"), "expiresAt": int(e)} for x in rl.get("banked_reset_details") or []
                                     if isinstance(x, dict) and (e := _f(x.get("expires_at"))) is not None), key=lambda x: x["expiresAt"])
    return seat


def reset_result(seat, rep):
    """The redeem script's JSON report -> {"outcome": redeemed|alreadyRedeemed|nothingToReset|noCredit|error, "text"}; nothing from the report but its status, outcome and a trimmed error."""
    rep = rep if isinstance(rep, dict) else {}
    st, oc = rep.get("status"), rep.get("outcome")
    if st == "no_credit":
        return {"outcome": "noCredit", "text": "Seat %s has no banked reset to apply." % seat}
    if st == "redeemed":
        key = re.sub(r"[^a-z]", "", oc.lower()) if isinstance(oc, str) else ""
        o = {"alreadyredeemed": "alreadyRedeemed", "nothingtoreset": "nothingToReset"}.get(key, "redeemed")
        return {"outcome": o, "text": {"redeemed": "Reset applied to seat %s." % seat, "alreadyRedeemed": "That reset was already applied; nothing more was used.",
                                       "nothingToReset": "Seat %s had nothing to reset right now." % seat}[o]}
    err = re.sub(r"[A-Za-z0-9_\-.]{40,}", "[redacted]", re.sub(r"\s+", " ", str(rep.get("error") or "")))[:160]
    return {"outcome": "error", "text": "The reset did not go through" + (": " + err if err else ".")}


def run_reset(seat, script, now, run=subprocess.run):
    """Apply one banked reset on `seat` (the script's --confirm), then read the seat again (its read-only mode): (result for the page, new seat reading or None).
    Both calls have no window and RESET_TIMEOUT s; neither the script's stderr nor any token is kept."""
    def call(*extra):
        r = run(PY + [script, "--account", seat] + list(extra), stdin=subprocess.DEVNULL, capture_output=True, timeout=RESET_TIMEOUT,
                creationflags=0x08000000 if os.name == "nt" else 0)
        try:
            return json.loads(r.stdout.decode("utf-8", "replace"))
        except ValueError:
            return {"status": "error", "error": "unreadable output (exit %s)" % r.returncode}
    try:
        res = reset_result(seat, call("--confirm"))
    except (OSError, subprocess.SubprocessError) as e:
        return {"outcome": "error", "text": "The reset did not go through: %s." % type(e).__name__}, None
    try:
        rep = call()
    except (OSError, subprocess.SubprocessError):
        return res, None
    return res, (codex_seat_from_read(rep.get("rate_limits_before"), now) if rep.get("status") == "checked" else None)


SWITCH_TIMEOUT = 120                                     # s: an app rotator closes the app, switches and reopens it
SWITCH_ROLES = {"claude": ("cli", "app", "best"), "codex": ("both", "best")}     # what /api/switch accepts; Codex's CLI and app share one login
SEAT_RE = re.compile(r"[A-Za-z]+")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
EMAIL_RE = re.compile(r"[^\s@()<>\"',;]+@[^\s@()<>\"',;]+\.[A-Za-z]{2,}")


def switch_targets(here=None, cli_root=None, app_root=None, codex_dir=None):
    """{provider: {role: [seats]}}: the seats each rotator can switch to (letters-only names): Claude CLI seats with a token.txt, Claude app seats with a
    captured config.json, Codex homes with a saved auth.json. A role is left out when its rotator script is not next to this one (the Codex rotators are
    not in the public repo)."""
    here = here or HERE

    def seats(d, need):
        return sorted(os.path.basename(x) for x in glob.glob(os.path.join(d, "*")) if SEAT_RE.fullmatch(os.path.basename(x)) and os.path.isfile(os.path.join(x, need)))
    out, cl = {}, {}
    if os.path.isfile(os.path.join(here, "claude-cli-account.ps1")):
        cl["cli"] = seats(cli_root or ROOT, "token.txt")
    if os.path.isfile(os.path.join(here, "claude-app-rotator.ps1")):
        cl["app"] = seats(app_root or os.path.join(HOME, ".claude-app-seats"), "config.json")
    if cl:
        out["claude"] = cl
    if os.path.isfile(os.path.join(here, "codex-app-rotator.ps1")):
        out["codex"] = {"both": seats(os.path.join(codex_dir or os.path.join(HOME, ".codex"), "homes"), "auth.json")}
    return out


def switch_check(body, targets):
    """(provider, role, seat) for a valid /api/switch body, else None. The provider and role must be known and their rotator present; the seat must be
    letters only and one that rotator can use. "best" takes no seat (the rotator picks)."""
    if not isinstance(body, dict):
        return None
    p, r, s = body.get("provider"), body.get("role"), body.get("seat")
    if not isinstance(p, str) or not isinstance(r, str) or r not in SWITCH_ROLES.get(p, ()):
        return None
    t = targets.get(p) or {}
    if r == "best":
        return (p, r, None) if ("cli" if p == "claude" else "both") in t else None
    if not isinstance(s, str) or not SEAT_RE.fullmatch(s) or s not in t.get(r, ()):
        return None
    return p, r, s


def switch_argv(provider, role, seat, here=None):
    """The rotator call for one dashboard action, as an argv list (no shell). Claude's "best" is `--switch best` (`--best` only prints the ranking);
    `--no-usage` leaves the switch result as the CLI rotator's last line. Codex's "best" is the rotator's --rotate."""
    def ps(name, *a):
        return ["pwsh", "-NoProfile", "-File", os.path.join(here or HERE, name)] + list(a)
    if provider == "claude":
        if role == "app":
            return ps("claude-app-rotator.ps1", "--switch", seat, "--relaunch")
        return ps("claude-cli-account.ps1", "--switch", "best" if role == "best" else seat, "--no-usage")
    return ps("codex-app-rotator.ps1", "--rotate") if role == "best" else ps("codex-app-rotator.ps1", "--switch", seat)


def switch_outcome(rc, out):
    """{"outcome": ok|error, "text"}: the exit code and the rotator's last meaningful line (the last unindented one), without colour codes, tokens or
    email addresses."""
    lines = [x for x in (ANSI.sub("", y).rstrip() for y in (out or "").splitlines()) if x.strip()]
    last = next((x for x in reversed(lines) if not x[:1].isspace()), lines[-1] if lines else "").strip()
    t = re.sub(r"sk-ant-[A-Za-z0-9_\-]+", "[redacted]", last)
    t = re.sub(r"(?i)bearer\s+\S+", "Bearer [redacted]", t)
    t = re.sub(r"[A-Za-z0-9_\-.+/=]{40,}", "[redacted]", t)
    t = re.sub(r"\s+", " ", EMAIL_RE.sub("[email]", t))[:200]
    head = "Done" if rc == 0 else "Failed (exit %s)" % rc
    return {"outcome": "ok" if rc == 0 else "error", "text": head + (": " + t if t else ".")}


SWITCH_RUNNING = "Still switching; the dashboard will update when it finishes."


def switch_result(p, outs):
    """switch_outcome() for a finished rotator process and its (stdout, stderr); stderr only when stdout said nothing."""
    out = (outs[0] or b"").decode("utf-8", "replace")
    return switch_outcome(p.returncode, out if out.strip() else (outs[1] or b"").decode("utf-8", "replace"))


def run_switch(argv, popen=subprocess.Popen):
    """Start one rotator call with no window and wait up to SWITCH_TIMEOUT s -> (switch_result(), None). A rotator still running then is NEVER killed (a kill
    mid-switch can leave a login moved aside but not replaced): -> ({"outcome": "running", ...}, the process), and the caller waits for it."""
    try:
        p = popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x08000000 if os.name == "nt" else 0)
    except (OSError, subprocess.SubprocessError) as e:
        return {"outcome": "error", "text": "The rotator could not run: %s." % type(e).__name__}, None
    try:
        return switch_result(p, p.communicate(timeout=SWITCH_TIMEOUT)), None
    except subprocess.TimeoutExpired:                    # communicate() can be called again without losing output
        return {"outcome": "running", "text": SWITCH_RUNNING}, p


class Store:
    """The in-memory history and the last built blob, shared by the sampler thread and the request threads."""

    def __init__(self):
        self.lock = threading.RLock()
        self.hist = load()
        self.refreshing = threading.Lock()
        self.blob = build(self.hist, time.time(), load_emails(), True, load_extra())

    def import_codex(self, now, cdir=None):
        """Recorded points from the rollout logs modified since the last import (the mtime watermark lives in the provider cache)."""
        cache = load_pcache()
        since = cache.get("codex_import") or now        # the first run has nothing to catch up on: --backfill covers the past
        try:
            new, _ = import_rollouts(self.hist, now, False, since, cdir)
        except Exception as e:   # shortcut: a log we cannot read must not stop the sample
            applog("codex import error: %s: %s" % (type(e).__name__, e))
            return
        cache["codex_import"] = int(now)
        save_pcache(cache)
        if new:
            with open(HIST, "a", encoding="utf-8") as fh:
                fh.writelines(json.dumps(r, separators=(",", ":")) + "\n" for r in new)
            self.hist = sorted(self.hist + new, key=lambda h: h["t"])

    def drift_check(self, now, here=None, py=None):
        """rotator-sync.py --check --quiet at most every DRIFT_EVERY, when the script sits next to this one. It writes .rotator-drift.json; its exit code and output are ignored."""
        script = os.path.join(here or HERE, "rotator-sync.py")
        with self.lock:
            cache = load_pcache()
            if not os.path.isfile(script) or now - (cache.get("drift_run") or 0) < DRIFT_EVERY:
                return False
            cache["drift_run"] = int(now)           # first, so a hang or crash is not retried every sample
            save_pcache(cache)
        try:
            subprocess.run((py or PY) + [script, "--check", "--quiet"], stdin=subprocess.DEVNULL, capture_output=True, timeout=120,
                           creationflags=0x08000000 if os.name == "nt" else 0)
        except (OSError, subprocess.SubprocessError):
            pass
        return True

    def credits_read(self, label, now, fetch=http_json, force=False, ver=None):
        """Read one Claude seat's reset credits into the provider cache (`credits`: {seat: {ts, eligible, grants, next, hold, note}}). `next` is claimed before the
        call, so a crash is not retried every sample; `hold` (429 and 401/403) is respected even by a forced read. Returns the read's state, or None when it was skipped."""
        with self.lock:
            cache = load_pcache()
            e = cache.setdefault("credits", {}).setdefault(label, {})
            if now < (e.get("hold") or 0) or (not force and now < (e.get("next") or 0)):
                return None
            e["next"] = int(now + CREDITS_EVERY)
            save_pcache(cache)
        state, rd = read_credits(label, now, fetch, ver or claude_version(now))
        with self.lock:
            cache = load_pcache()
            e = cache.setdefault("credits", {}).setdefault(label, {})
            if state == "ok":
                e.update(ts=rd["ts"], eligible=rd["eligible"], grants=rd["grants"])
                e.pop("note", None), e.pop("hold", None), e.pop("nextId", None)
                if rd.get("nextId"):
                    e["nextId"] = rd["nextId"]
            elif state in ("rl", "auth"):
                e["hold"] = int(now + CREDITS_EVERY)
                e["note"] = "rate limited" if state == "rl" else "sign-in needed"
            save_pcache(cache)
        return state

    def credits_tick(self, now, fetch=http_json, cfg=None, labels=None):
        """The sampler's share: at most ONE seat per tick, the one whose next read is oldest and due; seats without a token file are not read. Off with claudeResetCredits:false."""
        if not credits_enabled(cfg):
            return None
        with self.lock:
            cr = load_pcache().get("credits") or {}
        due = sorted((max((cr.get(l) or {}).get("next") or 0, (cr.get(l) or {}).get("hold") or 0), l)
                     for l in (token_seats() if labels is None else labels))
        if not due or due[0][0] > now:
            return None
        return due[0][1], self.credits_read(due[0][1], now, fetch)

    def rebuild(self, now):
        self.blob = build(self.hist, now, load_emails(), True, load_extra())
        render(dict(self.blob, app=False))
        return self.blob

    def take(self, force=False):
        with self.lock:
            now = time.time()
            self.hist = save(self.hist, sample(now, force), now)
            self.import_codex(now)
            return self.rebuild(now)

    def codex_reset(self, seat, script, run=subprocess.run):
        """Apply one banked reset on a Codex seat and record the reading taken after it (the caller holds `refreshing`). Returns {"outcome", "text"}."""
        res, new = run_reset(seat, script, time.time(), run)
        applog("codex reset: seat %s -> %s" % (seat, res["outcome"]))
        if new:
            with self.lock:
                now = time.time()
                cache = load_pcache()
                cache.setdefault("codex_fresh", {})[seat] = new       # sample() prefers it until the seat's own cache is newer
                save_pcache(cache)
                last = next((dict(h["codex"]) for h in reversed(self.hist) if h.get("codex")), {})
                last[seat] = new
                self.hist = save(self.hist, {"t": int(now), "codex": last}, now)
                self.rebuild(now)
        return res

    def switch(self, provider, role, seat, popen=subprocess.Popen, here=None):
        """Run one rotator action (the caller holds `refreshing`), log it, and rebuild, which reads the in-use seats again so the badges move. A rotator still
        running after SWITCH_TIMEOUT s is never killed: a background thread takes over `refreshing` (other actions get 409 meanwhile), waits for it with no
        upper bound, logs and rebuilds, then releases the lock. The result's outcome is then "running" and the caller must NOT release the lock."""
        what = "%s %s%s" % (provider, role, " " + seat if seat else "")
        res, p = run_switch(switch_argv(provider, role, seat, here), popen)
        if p is None:
            self.switch_done(what, res)
            return res
        applog("switch: %s -> still running after %d s (pid %s); waiting for it" % (what, SWITCH_TIMEOUT, p.pid))
        threading.Thread(target=self.switch_wait, args=(what, p), daemon=True).start()
        return res

    def switch_wait(self, what, p):
        """The waiter for a rotator that outlived SWITCH_TIMEOUT: its outcome, logged and rebuilt, then `refreshing` back, whatever happens."""
        try:
            try:
                res = switch_result(p, p.communicate())
            except Exception as e:   # shortcut: a broken pipe must not keep the lock
                res = {"outcome": "error", "text": "Lost track of the rotator: %s." % type(e).__name__}
            self.switch_done(what, res)
        except Exception as e:   # shortcut: same broad catch as the handlers
            applog("switch error: %s: %s" % (type(e).__name__, e))
        finally:
            self.refreshing.release()

    def switch_done(self, what, res):
        applog("switch: %s -> %s" % (what, res["text"]))
        with self.lock:
            self.rebuild(time.time())

    def claude_reset(self, seat, kind, fetch=None, new_id=None):
        """Apply one banked Claude reset of `kind` on `seat` (the caller holds `refreshing`), then re-read that seat's credits. The grant is picked here, from
        the last reading, never taken from the page. The request id is saved before the call and kept while the outcome is unconfirmed, so a retry of the same
        grant reuses it; a settled outcome drops it. Returns {"outcome", "text"}."""
        now = time.time()
        with self.lock:
            cache = load_pcache()
            gs = usable_grants((cache.get("credits") or {}).get(seat) or {}, kind, now)
            if not gs:
                return {"outcome": "noCredit", "text": "Seat %s has no %s to apply." % (seat, CREDIT_KINDS[kind].lower())}
            key = seat + ":" + gs[0]["id"]
            claims = {k: v for k, v in (cache.get("credits_claims") or {}).items() if isinstance(v, dict) and now - (v.get("at") or 0) < DAY}
            if key not in claims:
                claims[key] = {"id": (new_id or (lambda: secrets.token_urlsafe(16)))(), "at": int(now)}
            cache["credits_claims"] = claims
            save_pcache(cache)
        res, settled = consume_reset(seat, kind, gs[0]["id"], claims[key]["id"], fetch or (lambda r: http_json(r, CONSUME_TIMEOUT)), claude_version(now))
        applog("claude reset: seat %s %s -> %s%s" % (seat, kind, res["outcome"], "" if settled else " (unconfirmed)"))
        if settled:
            with self.lock:
                cache = load_pcache()
                (cache.get("credits_claims") or {}).pop(key, None)
                save_pcache(cache)
        self.credits_read(seat, time.time(), fetch or http_json, force=True)      # still honours a 429 / sign-in hold
        with self.lock:
            self.rebuild(time.time())
        return res


def probe_claude():
    """The one live Claude read: the rotator's own --status, with no console window."""
    script = os.path.join(HERE, "claude-cli-account.ps1")
    r = subprocess.run(["pwsh", "-NoProfile", "-File", script, "--status"], stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=180, creationflags=0x08000000 if os.name == "nt" else 0)
    return r.returncode


def make_handler(store, port):
    """The request handler over `store`, answering only on 127.0.0.1/localhost:`port` (a function of its own so the selftest can drive it)."""
    from http.server import BaseHTTPRequestHandler
    ctype = {"/icon.svg": ("icon.svg", "image/svg+xml"), "/icon-192.png": ("icon-192.png", "image/png"),
             "/icon-512.png": ("icon-512.png", "image/png")}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass                                   # pythonw has no stderr

        def send(self, code, body=b"", ct="text/plain; charset=utf-8"):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def js(self, code, obj):
            self.send(code, json.dumps(obj, separators=(",", ":")), "application/json")

        def do_GET(self):
            if not host_ok(self.headers.get("Host"), port):
                return self.send(403, "forbidden")
            path = self.path.split("?")[0]
            if path == "/":
                return self.send(200, page_html(store.blob), "text/html; charset=utf-8")
            if path == "/api/data":
                return self.js(200, store.blob)
            if path == "/manifest.webmanifest":
                return self.send(200, json.dumps(manifest()), "application/manifest+json")
            if path in ctype:
                try:
                    with open(os.path.join(ICONS, ctype[path][0]), "rb") as fh:
                        return self.send(200, fh.read(), ctype[path][1])
                except OSError:
                    pass
            self.send(404, "not found")

        def refuse(self, code, msg):
            """Read a small request body before refusing: replying unread lets Windows abort the connection before the client sees the code."""
            try:
                n = int(self.headers.get("Content-Length") or 0)
                if 0 < n <= 1024:
                    self.rfile.read(n)
            except (ValueError, OSError):
                pass
            return self.send(code, msg)

        def do_POST(self):
            if not host_ok(self.headers.get("Host"), port):
                return self.refuse(403, "forbidden")
            path = self.path.split("?")[0]
            if path not in ("/api/refresh", "/api/codex-reset", "/api/claude-reset", "/api/switch"):
                return self.refuse(404, "not found")
            if self.headers.get("X-Quota-App") != "1":
                return self.refuse(403, "forbidden")
            if path == "/api/codex-reset":
                return self.codex_reset()
            if path == "/api/claude-reset":
                return self.claude_reset()
            if path == "/api/switch":
                return self.switch()
            if not store.refreshing.acquire(blocking=False):
                return self.send(409, "a refresh is already running")
            try:
                try:
                    rc = probe_claude()
                except (OSError, subprocess.SubprocessError) as e:
                    rc = type(e).__name__
                blob = store.take(force=True)
                applog("refresh: claude probe -> %s, %d providers" % (rc, len(blob["providers"])))
                self.js(200, blob)
            except Exception as e:   # shortcut: broad catch so one bad request never kills the server thread
                applog("refresh error: %s: %s" % (type(e).__name__, e))
                self.js(500, {"error": type(e).__name__})
            finally:
                store.refreshing.release()

        def codex_reset(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                seat = json.loads(self.rfile.read(n)).get("seat") if 0 < n <= 1024 else None
            except (ValueError, AttributeError):
                seat = None
            script = redeem_script()
            if not script:
                return self.js(404, {"outcome": "error", "text": "The reset script was not found on this PC."})
            if not valid_seat(seat, codex_homes()):
                return self.js(400, {"outcome": "error", "text": "Unknown Codex seat."})
            if not store.refreshing.acquire(blocking=False):
                return self.js(409, {"outcome": "error", "text": "A refresh is running; try again in a minute."})
            try:
                self.js(200, store.codex_reset(seat, script))
            except Exception as e:   # shortcut: same broad catch as refresh
                applog("codex reset error: %s: %s" % (type(e).__name__, e))
                self.js(500, {"outcome": "error", "text": "The reset did not go through: %s." % type(e).__name__})
            finally:
                store.refreshing.release()

        def claude_reset(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                b = json.loads(self.rfile.read(n)) if 0 < n <= 1024 else {}
                seat, kind = b.get("seat"), b.get("kind")
            except (ValueError, AttributeError):
                seat = kind = None
            if not credits_enabled():
                return self.js(404, {"outcome": "error", "text": "Claude resets are switched off on this PC (claudeResetCredits in rotator.local.json)."})
            if not valid_seat(seat, token_seats()) or not isinstance(kind, str) or kind not in RESET_KINDS:
                return self.js(400, {"outcome": "error", "text": "Unknown Claude seat or reset kind."})
            if not store.refreshing.acquire(blocking=False):
                return self.js(409, {"outcome": "error", "text": "A refresh or another reset is running; try again in a minute."})
            try:
                self.js(200, store.claude_reset(seat, kind))
            except Exception as e:   # shortcut: same broad catch as refresh
                applog("claude reset error: %s: %s" % (type(e).__name__, e))
                self.js(500, {"outcome": "error", "text": "The reset did not go through: %s." % type(e).__name__})
            finally:
                store.refreshing.release()

        def switch(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                b = json.loads(self.rfile.read(n)) if 0 < n <= 1024 else None
            except (ValueError, AttributeError):
                b = None
            ok = switch_check(b, switch_targets())
            if not ok:
                return self.js(400, {"outcome": "error", "text": "Unknown provider, role or seat."})
            if not store.refreshing.acquire(blocking=False):
                return self.js(409, {"outcome": "error", "text": "Another action is running; try again in a minute."})
            handed = False
            try:
                res = store.switch(*ok)
                handed = res["outcome"] == "running"            # the rotator outlived the wait: its waiter thread now holds the lock
                self.js(202 if handed else 200, res)
            except Exception as e:   # shortcut: same broad catch as refresh
                applog("switch error: %s: %s" % (type(e).__name__, e))
                self.js(500, {"outcome": "error", "text": "The switch did not run: %s." % type(e).__name__})
            finally:
                if not handed:
                    store.refreshing.release()

    return H


def serve(port):
    from http.server import ThreadingHTTPServer
    store = Store()
    H = make_handler(store, port)

    def sampler():
        while True:
            try:
                store.drift_check(time.time())
                store.credits_tick(time.time())
                store.take()
            except Exception as e:   # shortcut: same, the loop must keep sampling
                applog("sample error: %s: %s" % (type(e).__name__, e))
            time.sleep(SAMPLE_EVERY)

    if not os.path.isfile(os.path.join(ICONS, "icon-512.png")):
        make_icons()
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    except OSError as e:
        applog("cannot listen on 127.0.0.1:%d (%s)" % (port, e))
        return 1
    threading.Thread(target=sampler, daemon=True).start()
    applog("serving on 127.0.0.1:%d" % port)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


# ---------------------------------------------------------------- icons (pure python, no PIL)

BG, ORANGE, TRACK = (23, 20, 18), (251, 146, 60), (41, 37, 36)


def icon_pixels(size):
    """RGBA rows: a rounded dark square with an orange ring gauge about 3/4 full, 2x2 supersampled."""
    rows, c, rad = [], size / 2, size * 0.2
    r_out, r_in = size * 0.34, size * 0.24
    sub = (0.25, 0.75)
    for y in range(size):
        row = bytearray()
        for x in range(size):
            acc = [0, 0, 0, 0]
            for oy in sub:
                for ox in sub:
                    px, py = x + ox, y + oy
                    qx, qy = abs(px - c) - (c - rad), abs(py - c) - (c - rad)
                    if math.hypot(max(qx, 0), max(qy, 0)) > rad:
                        continue                    # outside the rounded corner
                    col = BG
                    dx, dy = px - c, py - c
                    if r_in <= math.hypot(dx, dy) <= r_out:
                        col = ORANGE if math.atan2(dx, -dy) % (2 * math.pi) < 1.5 * math.pi else TRACK
                    acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 255
            n = acc[3] // 255
            row += bytes((acc[0] // n, acc[1] // n, acc[2] // n, acc[3] // 4)) if n else b"\0\0\0\0"
        rows.append(bytes(row))
    return rows


def png(size):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    raw = b"".join(b"\0" + r for r in icon_pixels(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def ico(png_bytes):
    """A one-image .ico holding a 256 px PNG (width/height 0 means 256)."""
    return struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png_bytes), 22) + png_bytes


SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="102" fill="#171412"/>'
       '<circle cx="256" cy="256" r="148" fill="none" stroke="#292524" stroke-width="51"/>'
       '<path d="M256 108 A148 148 0 1 1 108 256" fill="none" stroke="#fb923c" stroke-width="51"/></svg>')


def make_icons():
    os.makedirs(ICONS, exist_ok=True)
    for name, data in (("icon-192.png", png(192)), ("icon-512.png", png(512)), ("icon.ico", ico(png(256))),
                       ("icon.svg", SVG.encode("utf-8"))):
        with open(os.path.join(ICONS, name), "wb") as fh:
            fh.write(data)
    say("icons written to " + ICONS)


# ---------------------------------------------------------------- selftest

def selftest():
    T, R = 1_800_000_000, 1_800_000_000 + 3 * 86400

    def rec(t, **seats):
        return {"t": t, "s": {k: {"w": v[0], "wr": v[1]} for k, v in seats.items()}}

    g = [{"t": T, "grok": {"grok": {"ts": T, "w": 0.2}}}, {"t": T + 300, "grok": {"grok": {"ok": False, "note": "expired"}}}]
    lg = latest_of(g, "grok")["grok"]["grok"]
    assert lg["w"] == 0.2 and lg["note"] == "expired" and g[1]["grok"]["grok"].get("w") is None, lg   # last good kept, history untouched
    h = [rec(T, A=(0.10, R), B=(0.5, R)), rec(T + 3600, A=(0.20, R), B=(0.5, R))]
    assert abs(burn(h, "w", 3, T + 3600) - 10) < 1e-9
    h = [rec(T, A=(0.90, R)), rec(T + 3600, A=(0.05, R + WEEK))]          # weekly reset in between
    assert abs(burn(h, "w", 3, T + 3600) - 5) < 1e-9
    assert burn(h[:1], "w", 3, T) is None
    assert burn(h, "w", 3, T + 100) is None                                # records after `now` are not used
    assert util_at({"w": 0.7, "wr": R}, "w", R + 1) == 0.0                 # stale reading past its reset
    assert remaining(rec(T, A=(0.25, R), B=(1.0, R)), "w") == (75.0, 2)

    # banked resets: a cache with credits (sorted, those without an expiry left out), one without, a count above the list, an expired credit
    c = {"fetchedAt": 1793592327005, "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1794124925}, "secondary": None,
         "availableCount": 3, "credits": [{"title": "Full reset", "expiresAt": 1796166737}, {"title": "Full reset (Weekly + 5 hr)", "expiresAt": 1794009823}, {"title": "no expiry"}, "junk"]}
    seat, _ = parse_codex(c)
    assert seat["banked"] == 3 and seat["bankedList"] == [{"title": "Full reset (Weekly + 5 hr)", "expiresAt": 1794009823}, {"title": "Full reset", "expiresAt": 1796166737}], seat
    assert "banked" not in parse_codex(dict(c, availableCount=None))[0] and "bankedList" not in parse_codex({k: v for k, v in c.items() if k != "availableCount"})[0]
    assert parse_codex(dict(c, availableCount=0, credits=None))[0]["bankedList"] == [] and parse_codex({"availableCount": 2, "credits": []})[0] is None
    bh = [{"t": 1794500000, "codex": {"A": dict(seat, ts=1794500000), "B": {"w": 0.1, "wr": 1794700000, "wp": WEEK, "ts": 1794500000}}},
          {"t": 1794500300, "codex": {"A": {"w": 0.2, "wr": 1794124925 + WEEK, "wp": WEEK, "ts": 1794500300}, "B": {"w": 0.1, "wr": 1794700000, "wp": WEEK, "ts": 1794500300}}}]       # newer, imported from a log: no credits
    ba = build(bh, 1794510000, {}, False, {})["providers"][0]["accounts"]
    assert ba[0]["banked"] == 2 and ba[0]["bankedList"] == [{"title": "Full reset", "expiresAt": 1796166737}], ba[0]    # the expired credit drops out of count and list
    assert "banked" not in ba[1]
    assert build([{"t": 1, "codex": {"A": dict(seat, banked=5, bankedList=seat["bankedList"][1:])}}], 1794510000, {}, False, {})["providers"][0]["accounts"][0]["banked"] == 5      # count above the list kept
    # codex cache: weekly only, then weekly + 5 hour, then nothing usable
    c = {"fetchedAt": 1793592327005, "accountEmail": "x@y", "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1794124925}, "secondary": None}
    seat, email = parse_codex(c)
    assert seat == {"ts": 1793592327, "w": 0.13, "wr": 1794124925, "wp": 604800} and email == "x@y", seat
    c["primary"], c["secondary"] = ({"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 5}, {"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 9})
    seat, _ = parse_codex(c)
    assert seat["s"] == 0.4 and seat["sp"] == 18000 and seat["w"] == 0.07 and seat["wr"] == 9
    c["primary"], c["secondary"] = {"usedPercent": 1, "windowDurationMins": 60, "resetsAt": 5}, None
    assert parse_codex(c)[0] is None                                       # an unknown window is ignored

    # read_codex: homes' own caches + the active login's, on a synthetic ~/.codex
    import tempfile
    def cx(ms, used, key=None, email=None):
        return {"fetchedAt": ms, "identityKey": key, "accountEmail": email,
                "primary": {"usedPercent": used, "windowDurationMins": 10080, "resetsAt": 9}, "secondary": None}
    def put(d, name, obj):
        os.makedirs(os.path.join(d, "cache-statusband-codex"), exist_ok=True)
        with open(os.path.join(d, "cache-statusband-codex", name), "w", encoding="utf-8") as fh:
            json.dump(obj, fh)
    with tempfile.TemporaryDirectory() as td:
        for lab in "ABCD":
            os.makedirs(os.path.join(td, "homes", lab))
            open(os.path.join(td, "homes", lab, "auth.json"), "w").close()          # existence only: never read
        for lab in "EF":
            os.makedirs(os.path.join(td, "homes", lab))                              # C: empty folders, no saved login
        put(os.path.join(td, "homes", "B"), "rate-limits-1.json", cx(2_000_000, 10, "seat:B", "b@x"))
        put(os.path.join(td, "homes", "D"), "rate-limits-1.json", cx(2_000_000, 20, None, "d@x"))
        put(td, "rate-limits.json", cx(1_000_000, 50, "seat:C", "c@x"))              # seat:X, X a home -> C
        put(td, "rate-limits-b.json", cx(3_000_000, 60, "seat:B", "b@x"))            # newer than B's own -> wins
        put(td, "rate-limits-d.json", cx(4_000_000, 70, "other", "d@x"))             # email match -> D, newer -> wins
        put(td, "rate-limits-c2.json", cx(500_000, 99, "seat:C", "c@x"))            # older than C's other reading -> loses
        put(td, "rate-limits-z.json", cx(9_000_000, 80, "seat:Z", "z@x"))            # unknown seat and email -> skipped
        put(td, "rate-limits-f.json", cx(5_000_000, 30, "seat:F", "f@x"))            # no auth.json but a reading -> shown
        seats, em = read_codex(td)
    assert list(seats) == ["A", "B", "C", "D", "E", "F"] and seats["A"] == {"ok": False, "note": "no usage cached yet"}, seats
    assert seats["E"] == {"ok": False, "note": "no saved login on this PC"} and seats["F"]["w"] == 0.3, seats      # C
    assert seats["B"]["w"] == 0.6 and seats["C"]["w"] == 0.5 and seats["D"]["w"] == 0.7, seats
    assert em == {"B": "b@x", "C": "c@x", "D": "d@x", "F": "f@x"}, em

    # Claude emails: email.txt wins (trimmed), the backfill map fills in only when the file is missing or empty
    with tempfile.TemporaryDirectory() as td:
        for lab, txt in (("A", " new-a@x.org " + os.linesep), ("B", "  " + os.linesep), ("C", None), ("D", "d@x.org")):
            os.makedirs(os.path.join(td, lab))
            open(os.path.join(td, lab, "token.txt"), "w").write("SECRET")
            if txt is not None:
                open(os.path.join(td, lab, "email.txt"), "w", encoding="utf-8", newline="").write(txt)
        assert seat_emails(td, {"A": "old-a@x.org", "B": "b@x.org", "C": "c@x.org"}) == {"A": "new-a@x.org", "B": "b@x.org", "C": "c@x.org", "D": "d@x.org"}
        assert seat_emails(os.path.join(td, "nope"), {"A": "a"}) == {"A": "a"}

    # grok and cursor responses
    g = parse_grok({"config": {"currentPeriod": {"type": "X", "start": "2026-11-09T22:57:09.651+00:00", "end": "2026-11-16T22:57:09.651+00:00"}, "creditUsagePercent": 22.0}})
    assert g["w"] == 0.22 and g["wp"] == WEEK and g["wr"] - 1_700_000_000 > 0, g
    assert parse_grok({"error": 1}) is None and parse_grok(None) is None
    assert "cursor" not in PROVIDERS and not any(n in globals() for n in ("fetch_cursor", "parse_cursor"))     # A: Cursor is gone
    assert PROVIDERS["grok"][0] == "xAI" and PROVIDERS["gemini"][0] == "Gemini" and manifest()["name"] == "Quota Management" and "same xAI quota" in PROVIDER_NOTE["grok"]

    # A: history lines and the provider cache lose the retired cursor key, on disk
    global HIST, PCACHE
    with tempfile.TemporaryDirectory() as td:
        HIST, PCACHE, keep = os.path.join(td, "h.jsonl"), os.path.join(td, "p.json"), (HIST, PCACHE)
        try:
            with open(HIST, "w", encoding="utf-8") as fh:
                fh.write('{"t":9,"cursor":{"cursor":{"m":1}}}' + chr(10) + '{"t":5,"grok":{"grok":{"w":0.1}}}' + chr(10) + 'not json' + chr(10))
            with open(PCACHE, "w", encoding="utf-8") as fh:
                json.dump({"cursor": {"at": 1}, "emails": {"cursor": {"cursor": "c@x"}, "grok": {"grok": "g@x"}}}, fh)
            assert [h["t"] for h in load()] == [5, 9] and "cursor" not in open(HIST, encoding="utf-8").read()
            assert load_pcache() == {"emails": {"grok": {"grok": "g@x"}}}
        finally:
            HIST, PCACHE = keep

    # B: Gemini (Antigravity) from synthetic language-server JSON
    def cfg(label, frac, reset="2026-11-12T20:15:30Z"):
        q = {"resetTime": reset}
        if frac is not None:
            q["remainingFraction"] = frac
        return {"label": label, "quotaInfo": q}
    gj = {"userStatus": {"planStatus": {"planInfo": {"planName": "Pro"}}, "cascadeModelConfigData": {"clientModelConfigs": [
        cfg("Gemini 3.8 Flash (High)", 1.0), cfg("Gemini 3.8 Flash (Low)", 1.0),
        cfg("Claude Opus 5.5 (High)", 0.9), cfg("Claude Sonnet 5.5 (Medium)", 0.9), cfg("GPT-OSS 120B (Medium)", 0.9),
        {"label": "Some Model (no quota)"}, cfg("Gemini Drained", None), cfg("Claude Opus 5.5 (XHigh)", 0.9)]}}}
    g = parse_gemini(gj, 1000)
    rst = 1_794_514_530                                                     # 2026-11-12T20:15:30Z
    assert [g["n"][w] for w in g["n"]] == ["Gemini 3.8 Flash", "Claude Opus 5.5 + Claude Sonnet 5.5 + GPT-OSS 120B", "Gemini Drained"], g["n"]
    f_id, c_id, d_id = g["n"]
    assert (g[f_id], g[c_id], g[d_id]) == (0.0, 0.1, 1.0) and g[c_id + "r"] == g[f_id + "r"] and g[c_id + "p"] == 18000, g
    assert g["plan"] == "Pro" and g["ts"] == 1000 and f_id == gemini_slug("Gemini 3.8 Flash") and len(c_id) < 30
    assert abs(g[c_id + "r"] - __import__("datetime").datetime(2026, 11, 12, 20, 15, 30, tzinfo=__import__("datetime").timezone.utc).timestamp()) == 0
    gj["userStatus"]["cascadeModelConfigData"]["clientModelConfigs"][2]["quotaInfo"]["resetTime"] = "2026-11-12T21:00:00Z"
    assert len(parse_gemini(gj, 1)["n"]) == 4                                 # a different reset is its own limit
    assert parse_gemini({"userStatus": {}}, 1) is None and parse_gemini(None, 1) is None and parse_gemini({"userStatus": {"cascadeModelConfigData": {"clientModelConfigs": []}}}, 1) is None
    procs = '[{"ProcessId":1,"CommandLine":"x.exe --a b --csrf_token tok1 --c","Ports":[4000,4001]},{"ProcessId":2,"CommandLine":"x.exe","Ports":[5]},{"ProcessId":3,"CommandLine":"--csrf_token t3","Ports":9},{"ProcessId":4,"CommandLine":"--csrf_token=t4","Ports":[7]}]'
    assert parse_ls_procs(procs) == [("tok1", [4000, 4001]), ("t3", [9]), ("t4", [7]), ("", [])] and parse_ls_procs("") == [] and parse_ls_procs("null") == []
    tried = []
    def fq(port, csrf):
        tried.append((port, csrf))
        return gj if port == 4001 else None
    assert read_gemini(7, lambda: parse_ls_procs(procs), fq)[0]["ts"] == 7 and tried == [(4000, "tok1"), (4001, "tok1")]
    assert read_gemini(7, lambda: [], fq) == (None, LS_OFF) and read_gemini(7, lambda: [("t", [1])], lambda p, c: None) == (None, LS_OFF)     # not running / no port answers
    # 4: a process (the IDE server or agy.exe) whose command line is empty/unreadable means it runs as administrator; nothing else is tried to read its token
    adm = '[{"ProcessId":9,"CommandLine":null,"Ports":[3]},{"ProcessId":10,"CommandLine":"","Ports":[]}]'
    assert parse_ls_procs(adm) == [(None, [])] and parse_ls_procs('{"ProcessId":9,"CommandLine":"  ","Ports":[3]}') == [(None, [])]
    assert parse_ls_procs('[{"ProcessId":9,"CommandLine":"agy.exe --hub","Ports":[3]}]') == [("", [])]              # readable but no token: nothing to ask, but it is running
    assert parse_ls_procs('[{"CommandLine":"a --csrf_token t","Ports":[]}]') == []                                  # a token but no port: dropped
    tried.clear()
    assert read_gemini(7, lambda: parse_ls_procs(adm), fq) == (None, LS_ADMIN) and tried == []
    assert read_gemini(7, lambda: parse_ls_procs('[' + adm[1:-1] + ',{"CommandLine":"x --csrf_token=t5","Ports":[4001]}]'), fq)[0]["ts"] == 7      # a readable server still wins
    # 1: agy.exe alone (readable command line, no token) -> the Antigravity-app note; with a hidden process the administrator note wins; with a tokened server that answers, the seat
    agy = '{"ProcessId":11,"CommandLine":"agy.exe --hub","Ports":[6]}'
    tried.clear()
    assert read_gemini(7, lambda: parse_ls_procs("[" + agy + "]"), fq) == (None, LS_AGY) and tried == []
    assert read_gemini(7, lambda: parse_ls_procs("[" + agy + "," + adm[1:-1] + "]"), fq) == (None, LS_ADMIN)
    assert read_gemini(7, lambda: parse_ls_procs("[" + agy + ',{"CommandLine":"x --csrf_token=t5","Ports":[4001]}]'), fq)[0]["ts"] == 7
    assert read_gemini(7, lambda: parse_ls_procs("[" + agy + ',{"CommandLine":"x --csrf_token=t5","Ports":[4000]}]'), fq) == (None, LS_AGY)       # server there but silent
    assert LS_ADMIN == "Antigravity is running as administrator, so its quota can't be read. Start it from a normal (non-admin) window."
    assert LS_AGY == "Open the Antigravity app to read Gemini quota (the agy CLI doesn't share it)" and LS_OFF == "Antigravity isn't running — open the Antigravity app to update" and "agy.exe" in LS_PS and "language_server_windows_x64.exe" in LS_PS and "Start-Process" not in LS_PS and "RunAs" not in LS_PS
    gh = [{"t": 1000 + 300 * i, "gemini": {"antigravity": dict(g, ts=1000 + 300 * i)}} for i in range(4)]
    gb = build(gh, 5000, {"gemini": {"antigravity": "me@x"}}, True, {"notes": {"gemini": {"antigravity": LS_OFF}}, "pnote": {"gemini": "Plan: Pro"}})["providers"][0]
    assert gb["id"] == "gemini" and gb["name"] == "Gemini" and gb["note"] == "Plan: Pro" and gb["total"] == gb["loaded"] == 1
    assert [x["label"] for x in gb["limits"]] == ["Gemini 3.8 Flash", "Claude Opus 5.5 + Claude Sonnet 5.5 + GPT-OSS 120B", "Gemini Drained"]
    assert gb["accounts"][0]["email"] == "me@x" and gb["accounts"][0]["note"] == LS_OFF and gb["accounts"][0]["readAt"] == 1900
    assert gb["limits"][1]["seats"][0]["period"] == 18000 and gb["limits"][1]["now"] == 90.0
    gh = [dict(h, t=rst - 3600 + 300 * i) for i, h in enumerate(gh)]
    gb = build(gh, rst - 2000, {}, True, {})["providers"][0]
    assert gb["limits"][1]["now"] == 90.0 and gb["limits"][1]["seats"][0]["reset"] == rst and gb["accounts"][0]["note"] == ""
    nr = build([{"t": 5, "gemini": {"antigravity": {"ok": False, "note": LS_ADMIN}}}], 9, {}, False, {})["providers"][0]
    assert nr["loaded"] == 0 and nr["limits"] == [] and nr["accounts"][0]["note"] == LS_ADMIN

    # D: Codex history from rollout logs (synthetic ~/.codex)
    from datetime import datetime, timezone
    N = 1_800_000_000
    def iso(t):
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123Z")
    def tc(t, wk=None, h5=None, lid="codex"):
        rl = {"limit_id": lid, "primary": None, "secondary": None}
        if h5:
            rl["primary"] = {"used_percent": h5[0], "window_minutes": 300, "resets_at": h5[1]}
        if wk:
            rl["secondary" if h5 else "primary"] = {"used_percent": wk[0], "window_minutes": 10080, "resets_at": wk[1]}
        return json.dumps({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count", "rate_limits": rl}})
    def roll(path, lines, mtime):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(chr(10).join(lines) + chr(10))
        os.utime(path, (mtime, mtime))
    WA, WB = N + 400_000, N + 500_000                                   # A's and B's weekly resets
    with tempfile.TemporaryDirectory() as td:
        for lab in "AB":
            os.makedirs(os.path.join(td, "homes", lab))
        roll(os.path.join(td, "homes", "A", "sessions", "2026", "11", "rollout-a.jsonl"), [
            tc(N - 7200, wk=(10, WA)), "not json {", json.dumps({"timestamp": iso(N), "payload": {"type": "agent_message"}}),
            tc(N - 7200 + 100, wk=(11, WA)),                              # same 5-minute bucket: one record
            tc(N - 3600, wk=(20, WA), h5=(5, N - 3000)), tc(N - 1800, wk=(21, WA), h5=(9, N - 3000), lid="premium")], N - 100)
        roll(os.path.join(td, "homes", "B", "sessions", "rollout-b.jsonl"), [tc(N - 3000, wk=(40, WB))], N - 100)
        roll(os.path.join(td, "homes", "B", "sessions", "rollout-old.jsonl"), [tc(N - 40 * 86400, wk=(1, 5))], N - 40 * 86400)
        roll(os.path.join(td, "sessions", "2026", "11", "rollout-act.jsonl"), [
            tc(N - 2500, wk=(25, WA + 60)),                               # within 120 s of A's reset -> A
            tc(N - 2400, wk=(45, WB - 119)),                              # -> B
            tc(N - 2300, wk=(1, N + 123_456)),                            # matches nobody: skipped
            tc(N - 2200, wk=(99, WA + 500)),                              # 500 s off: skipped
            tc(N - 2100, wk=(26, WA + 90_000 - 40), h5=(3, N - 2000))], N - 100)    # matches only the active-login cache for seat A below
        put(td, "rate-limits-1.json", {"fetchedAt": 1, "identityKey": "seat:A", "accountEmail": "a@x",
                                       "primary": {"usedPercent": 1, "windowDurationMins": 10080, "resetsAt": WA + 90_000}})
        ev = codex_events(td, N, 0, {"w": {WA + 90_000: {"A"}}})
        got = [(t - N, s_) for t, s_, _ in ev]
        assert got == [(-7200, "A"), (-7100, "A"), (-3600, "A"), (-3000, "B"), (-2500, "A"), (-2400, "B"), (-2100, "A")], got
        assert all(t >= N - 35 * 86400 for t, _, _ in ev)                  # the 40-day-old file was never read
        assert ev[0][2] == {"w": (0.10, WA, WEEK)} and ev[2][2]["s"] == (0.05, N - 3000, 18000) and "premium" not in str(ev)
        recs, per = import_rollouts([], N, True, 0, td)
        assert per == {"A": (5, N - 7200), "B": (2, N - 3000)}, per
        assert all(r["b"] == 1 for r in recs) and [r["t"] for r in recs] == sorted(r["t"] for r in recs)
        assert len({r["t"] // 300 for r in recs}) == len(recs)                  # one record per 5 minutes
        assert recs[0]["codex"] == {"A": {"w": 0.11, "wr": WA, "wp": WEEK, "ts": N - 7100}}, recs[0]   # the later of the two in the bucket
        last = recs[-1]["codex"]
        assert last["B"]["w"] == 0.45 and last["A"]["w"] == 0.26 and last["A"]["s"] == 0.03 and last["A"]["wr"] == WA + 90_000 - 40, last   # carried forward, per seat
        b2 = next(r for r in recs if r["t"] // 300 == (N - 3000) // 300)
        assert set(b2["codex"]) == {"A", "B"} and b2["codex"]["A"]["w"] == 0.2
        # a recorded point is never overwritten; sampler imports are recorded, not rebuilt; the mtime watermark skips old files
        taken = [{"t": N - 3600, "codex": {"A": {"w": 0.5}}}]
        recs2, _ = import_rollouts(taken, N, False, 0, td)
        assert len(recs2) == len(recs) - 1 and all("b" not in r and r["t"] // 300 != (N - 3600) // 300 for r in recs2)
        assert import_rollouts([], N, False, N - 50, td)[0] == [] and import_rollouts([], N, False, N - 200, td)[1]["B"][0] == 2
        # imported records feed the dashboard: pooled weekly history per seat, and a codex-only newest record does not hide Claude
        hh = sorted([{"t": N - 9000, "s": {"X": {"w": 0.1, "wr": N + 9999}}}] + recs, key=lambda h: h["t"])
        cb = build(hh, N, {}, False, {})
        assert [p["id"] for p in cb["providers"]] == ["claude", "codex"] and cb["providers"][1]["limits"][0]["hist"][0][2] == 1
        # the sampler's import: nothing on the first run (sets the watermark), then only files modified since, recorded (not b), merged in time order
        keep, HIST, PCACHE = (HIST, PCACHE), os.path.join(td, "h.jsonl"), os.path.join(td, "p.json")
        try:
            st = Store.__new__(Store)
            st.hist = [{"t": N - 5000, "s": {}}, {"t": N, "s": {}}]
            st.import_codex(N + 20, td)
            assert st.hist == [{"t": N - 5000, "s": {}}, {"t": N, "s": {}}] and load_pcache()["codex_import"] == N + 20 and not os.path.exists(HIST)
            roll(os.path.join(td, "homes", "A", "sessions", "rollout-new.jsonl"), [tc(N + 5, wk=(30, WA))], N + 30)
            st.import_codex(N + 40, td)
            assert [h["t"] for h in st.hist] == [N - 5000, N, N + 5] and "b" not in st.hist[2] and st.hist[2]["codex"]["A"]["w"] == 0.3
            assert [json.loads(x)["t"] for x in open(HIST, encoding="utf-8")] == [N + 5] and load_pcache()["codex_import"] == N + 40
            st.import_codex(N + 60, td)
            assert len(st.hist) == 3
        finally:
            HIST, PCACHE = keep
        # an active-login event inside SLOP of two seats' resets is skipped, of one seat's is that seat's
        roll(os.path.join(td, "sessions", "rollout-amb.jsonl"), [tc(N - 100, wk=(7, WA + 25))], N - 50)
        def amb(known):
            return [(t, s_) for t, s_, _ in codex_events(td, N, N - 60, known) if t == N - 100]
        assert amb({"w": {WA: {"A"}, WA + 50: {"B"}}}) == [] and amb({"w": {WA: {"A"}, WA + 500: {"B"}}}) == [(N - 100, "A")]

    # E: the drift file shows in the blob only when it lists differing files; the 6-hourly check runs the script once per interval
    assert "drift" not in build([], 5, {}, False, {"drift": None}) and "drift" not in build([], 5, {}, False, {"drift": {"checked": 1, "ref": "r", "differing": []}})
    assert build([], 5, {}, False, {"drift": {"checked": 1, "ref": "r", "differing": ["a.ps1", "b.py"]}})["drift"] == {"n": 2, "names": ["a.ps1", "b.py"], "checked": 1}
    assert build([], 5, {}, False, {"drift": {"ref": "r", "differing": ["a"]}})["drift"]["checked"] is None
    with tempfile.TemporaryDirectory() as td:
        keep, PCACHE = PCACHE, os.path.join(td, "p.json")
        try:
            mark = os.path.join(td, "ran.txt")
            st = Store.__new__(Store)
            st.lock = threading.RLock()
            assert not st.drift_check(1000 * DRIFT_EVERY, td, [sys.executable])                       # no rotator-sync.py next to us: nothing runs
            open(os.path.join(td, "rotator-sync.py"), "w").write("import sys;open(%r,'a').write(' '.join(sys.argv[1:]) + chr(10))" % mark)
            assert st.drift_check(1000 * DRIFT_EVERY, td, [sys.executable]) and open(mark).read() == "--check --quiet" + chr(10)
            assert not st.drift_check(1000 * DRIFT_EVERY + DRIFT_EVERY - 1, td, [sys.executable]) and open(mark).read().count("--check") == 1
            assert st.drift_check(1000 * DRIFT_EVERY + DRIFT_EVERY, td, [sys.executable]) and open(mark).read().count("--check") == 2
        finally:
            PCACHE = keep

    # 4: Codex Apply reset - seat validation, the script lookup (a missing script hides the action), outcome mapping, the two script calls
    homes = ["A", "B", "Cc"]
    cb = [{"t": 1794500000, "codex": {"A": {"w": 0.3, "wr": 1794700000, "wp": WEEK, "ts": 1794500000, "banked": 1, "bankedList": []}}}]
    assert valid_seat("A", homes) and valid_seat("Cc", homes)
    assert not any(valid_seat(x, homes) for x in ("a", "AB", "", "A ", "A/../B", "D", None, 5, ["A"], "A\n", "..", "A;B"))
    with tempfile.TemporaryDirectory() as td:
        cfg, scr = os.path.join(td, "rotator.local.json"), os.path.join(td, "redeem.py")
        open(scr, "w").write("")
        assert redeem_script(os.path.join(td, "none.json")) in (None, REDEEM_DEFAULT)                               # no config: the default, if it exists
        open(cfg, "w").write(json.dumps({"codexRedeemScript": scr}))
        assert redeem_script(cfg) == scr
        open(cfg, "w").write(json.dumps({"codexRedeemScript": os.path.join(td, "missing.py")}))
        assert redeem_script(cfg) is None                                                                            # configured but missing: no action
        assert build(cb, 1794500100, {}, False, {"canReset": redeem_script(cfg) is not None})["providers"][0]["canReset"] is False       # ... so the blob hides the button
        open(cfg, "w").write("not json")
        assert redeem_script(cfg) in (None, REDEEM_DEFAULT)
        os.makedirs(os.path.join(td, "homes", "A")), os.makedirs(os.path.join(td, "homes", "B")), open(os.path.join(td, "homes", "x.txt"), "w").close()
        assert codex_homes(td) == ["A", "B"]
    assert build(cb, 1794500100, {}, False, {"canReset": True})["providers"][0]["canReset"] is True
    assert "canReset" not in build([{"t": 1, "s": {"A": {"w": 0.1, "wr": 9}}}], 5, {}, False, {"canReset": True})["providers"][0]
    r = reset_result
    assert r("A", {"status": "no_credit"}) == {"outcome": "noCredit", "text": "Seat A has no banked reset to apply."}
    assert r("A", {"status": "redeemed", "outcome": "redeemed"})["outcome"] == "redeemed" and r("A", {"status": "redeemed", "outcome": {"x": 1}})["outcome"] == "redeemed"
    assert r("A", {"status": "redeemed", "outcome": "already_redeemed"})["outcome"] == "alreadyRedeemed" and r("A", {"status": "redeemed", "outcome": "NothingToReset"})["outcome"] == "nothingToReset"
    e = r("A", {"status": "error", "error": "consume failed: " + "x" * 80 + " " + "ab" * 400})
    assert e["outcome"] == "error" and len(e["text"]) < 220 and "x" * 40 not in e["text"] and r("A", None)["outcome"] == "error" and r("A", {"status": "checked"})["outcome"] == "error"
    rd = {"status": "checked", "rate_limits_before": {"banked_reset_credits": 2, "banked_reset_details": [{"title": "Full reset", "expires_at": 1796166737}, {"title": "n"}],
                                                   "primary": {"used_percent": 40, "resets_at": 1794510000}, "secondary": {"used_percent": 7, "resets_at": 1795000000}}}
    cs = codex_seat_from_read(rd["rate_limits_before"], 1794500000)
    assert cs == {"ts": 1794500000, "w": 0.07, "wr": 1795000000, "wp": WEEK, "s": 0.4, "sr": 1794510000, "sp": 18000, "banked": 2, "bankedList": [{"title": "Full reset", "expiresAt": 1796166737}]}, cs
    assert codex_seat_from_read({"primary": {"used_percent": 5, "resets_at": 9}, "secondary": {}}, 1)["w"] == 0.05 and codex_seat_from_read({}, 1) is None and codex_seat_from_read(None, 1) is None
    calls = []
    class Out:
        def __init__(self, o, rc=0):
            self.stdout, self.returncode = json.dumps(o).encode(), rc
    def fake(argv, **kw):
        calls.append((argv, kw))
        return Out({"status": "redeemed", "outcome": "redeemed", "token": "SECRET"} if "--confirm" in argv else rd)
    res, new = run_reset("A", "/x/redeem.py", 1794500000, fake)
    assert res == {"outcome": "redeemed", "text": "Reset applied to seat A."} and new == cs and "SECRET" not in json.dumps(res)
    assert calls[0][0] == PY + ["/x/redeem.py", "--account", "A", "--confirm"] and calls[1][0] == PY + ["/x/redeem.py", "--account", "A"]
    assert all(k["timeout"] == 90 and k["stdin"] == subprocess.DEVNULL and k["capture_output"] for _, k in calls) and all(k["creationflags"] == (0x08000000 if os.name == "nt" else 0) for _, k in calls)
    def boom(argv, **kw):
        raise subprocess.TimeoutExpired(argv, 90)
    assert run_reset("A", "/x", 1, boom) == ({"outcome": "error", "text": "The reset did not go through: TimeoutExpired."}, None)
    def junk(argv, **kw):
        o = Out({})
        o.stdout = b"<html>"
        return o
    assert run_reset("A", "/x", 1, junk)[0]["outcome"] == "error"
    calls.clear()
    def once(argv, **kw):
        if "--confirm" in argv:
            return fake(argv, **kw)
        raise OSError("gone")
    assert run_reset("A", "/x", 1, once) == ({"outcome": "redeemed", "text": "Reset applied to seat A."}, None)         # the follow-up read failing keeps the result

    # 5: which seat is in use - the desktop app's seat by uuid (owner-uuid.txt, then meta.txt), else its .active; the CLI's .active; Codex's .active-account
    with tempfile.TemporaryDirectory() as td:
        ar, cr, ad, cx = (os.path.join(td, n) for n in ("app", "cli", "appdata", "codex"))
        for d in (os.path.join(ar, "A"), os.path.join(ar, "B"), os.path.join(ar, "C"), os.path.join(ad, "Claude"), cr, cx):
            os.makedirs(d)
        open(os.path.join(ar, "A", "owner-uuid.txt"), "w").write("u-1" + os.linesep)
        open(os.path.join(ar, "B", "meta.txt"), "w").write("name=x" + os.linesep + "uuid=u-2" + os.linesep)
        open(os.path.join(ar, "C", "owner-uuid.txt"), "w").write("u-3")
        open(os.path.join(ar, ".active"), "w").write(" C" + os.linesep)
        os.makedirs(os.path.join(ar, ".hidden"))
        open(os.path.join(ar, ".hidden", "owner-uuid.txt"), "w").write("u-9")
        open(os.path.join(cr, ".active"), "w", encoding="utf-8-sig").write("D\n")
        open(os.path.join(cx, ".active-account"), "w").write("A")
        def cfg(u):
            json.dump({"lastKnownAccountUuid": u}, open(os.path.join(ad, "Claude", "config.json"), "w"))
        cfg("u-1")
        assert app_seat(ar, ad) == "A"
        cfg("u-2")
        assert app_seat(ar, ad) == "B"                                                       # found in meta.txt
        cfg("u-nope")
        assert app_seat(ar, ad) == "C"                                                       # unknown uuid: the folder's .active
        cfg("u-9")
        assert app_seat(ar, ad) == "C"                                                       # a dot folder is not a seat
        assert app_seat(ar, os.path.join(td, "none")) == "C" and app_seat(os.path.join(td, "none"), ad) is None
        cfg("u-2")
        assert in_use(cr, ar, ad, cx) == {"claude": {"cli": "D", "app": "B"}, "codex": {"app": "A"}}
        assert in_use(os.path.join(td, "x"), os.path.join(td, "x"), ad, os.path.join(td, "x")) == {"claude": {}, "codex": {}}
    ub = build([{"t": 5, "s": {"A": {"w": 0.1, "wr": 9, "ts": 5}, "B": {"w": 0.2, "wr": 9, "ts": 5}}, "codex": {"A": {"w": 0.1, "wr": 9, "wp": WEEK, "ts": 5}}}], 6, {}, False,
               {"inUse": {"claude": {"cli": "B", "app": "B"}, "codex": {"app": "A", "cli": "Z"}}})["providers"]
    assert [a["badges"] for a in ub[0]["accounts"]] == [[], ["CLI", "App"]] and ub[0]["inUse"] == {"cli": "B", "app": "B"} and [a["badges"] for a in ub[1]["accounts"]] == [["App"]] and ub[1]["inUse"] == {"app": "A"}
    ub = build([{"t": 5, "s": {"A": {"w": 0.1, "wr": 9, "ts": 5}}}], 6, {}, False, {"inUse": {"claude": {"cli": "Q"}}})["providers"][0]
    assert ub["accounts"][0]["badges"] == [] and "inUse" not in ub                          # a seat the provider does not list shows nothing

    # Host guard
    assert host_ok("127.0.0.1:8787", 8787) and host_ok("localhost:8787", 8787)
    assert not host_ok("evil.example:8787", 8787) and not host_ok("127.0.0.1:8788", 8787)
    assert not host_ok("127.0.0.1", 8787) and not host_ok(None, 8787) and not host_ok("127.0.0.1:8787.evil.com", 8787)

    # backfill: every line type, a reset boundary, the 5-minute dedupe, idempotence
    L = 1_800_000_000
    wr = L + 3 * 86400                           # A's weekly reset grid: wr - k * 7 days
    latest = {"A": {"w": 0.5, "wr": wr, "f": 0.1, "fr": wr}, "B": {"w": 0.2, "wr": wr + 7200}, "F": {"w": 0.3, "wr": wr}}

    def ts(t):
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
    log = "\n".join([
        ts(L - 9 * 86400) + "  ROTATED 'F' -> A (a@x.org) session 0%, weekly 41%, fable 14%",                  # before the window
        ts(L - 5 * 86400) + "  NO USABLE TARGET - staying on 'C'. B=s0%/w80% (capped)",                         # B w .8, resets at L-4d+2h
        ts(L - 4 * 86400) + "  ROTATED 'F' -> A (a@x.org) session 0%, weekly 41%, fable 14%",                  # A w .41 f .14
        ts(L - 4 * 86400 + 100) + "  TRIGGER: active account 'A' FABLE window CAPPED at 100% (Gate C cannot run) [via StopFailure]",  # within 5 min
        ts(L - 3 * 86400) + "  NO USABLE TARGET - staying on 'C'. A=s0%/w77% F=s0%/w99% Z=s0%/w5% C=s100%/w61% E=s102%/w34% (note)",
        ts(L - 2 * 86400) + "  TRIGGER: active account 'B' WEEKLY window CAPPED at 100% (session 20%) [via proxy]",
        ts(L - 2 * 86400 + 600) + "  TRIGGER: active account 'F' session at 83% burning 0.4%/min -> 85% by the next probe, bar 85% (weekly 78%, left to burn)",
        ts(L - 86400) + "  TRIGGER: active account 'B' at 49% (session 49%, weekly 49%) >= 1%",
        ts(L - 86400 + 5) + "  TRIGGER: active account 'F' SESSION window CAPPED at 100% (weekly 61%) [via StopFailure]",
        ts(L - 86000) + "  DRY RUN: would rotate 'B' -> E (b@x.org) worst 0%, fable 0%",
        ts(L - 85000) + "  DRY RUN: would rotate 'F' -> B (new-b@x.org) worst 0%, fable 0%",
        ts(L - 80000) + "  something else entirely",
    ])
    recs, em = backfill_records(log, latest, L - 8 * 86400, L)
    assert em == {"A": "a@x.org", "B": "new-b@x.org"}, em                  # newest email per label, only labels we know
    assert all(r.get("b") == 1 and all("s" not in s for s in r["s"].values()) for r in recs)
    ts_ = [r["t"] for r in recs]
    assert ts_ == sorted(ts_) and all(b - a >= 300 for a, b in zip(ts_, ts_[1:])), ts_   # 5-minute dedupe
    assert recs[0]["t"] == int(L - 5 * 86400) and recs[0]["s"] == {"B": {"w": 0.8, "wr": wr + 7200 - 7 * 86400}}, recs[0]
    first = recs[1]["s"]
    assert first["A"] == {"w": 0.41, "wr": wr, "f": 1.0, "fr": wr}, first          # the capped f (100 s later) folded in
    assert first["B"]["w"] == 0.8 and "F" not in first
    nut = next(r for r in recs if r["t"] == int(L - 3 * 86400))
    assert nut["s"]["A"]["w"] == 0.77 and nut["s"]["F"]["w"] == 0.99 and "Z" not in nut["s"]
    assert nut["s"]["A"]["f"] == 1.0                                          # carried: no reset before wr
    assert nut["s"]["B"] == {"w": 0.0, "wr": wr + 7200}, nut["s"]["B"]        # carried across B's reset grid line => 0
    wk = next(r for r in recs if r["t"] == int(L - 2 * 86400))
    assert wk["s"]["B"]["w"] == 1.0                                           # WEEKLY capped
    assert wk["s"]["A"]["w"] == 0.77                                          # carried forward (same grid week)
    last = recs[-1]["s"]
    assert last["F"]["w"] == 0.61 and last["B"]["w"] == 0.49, last        # (weekly N%) and the "at 49%" forms
    # idempotent: dropping the old "b" records and re-merging gives the same list
    real = [{"t": L, "s": latest}]
    merged = sorted(real + recs, key=lambda h: h["t"])
    again = sorted([h for h in merged if not h.get("b")] + backfill_records(log, latest, L - 8 * 86400, L)[0], key=lambda h: h["t"])
    assert again == merged

    # 3: typical-day profile and the backtest, on two synthetic weeks (local midnight start) that use 1 %/h of one account in local hours 9-16 only
    base, u, syn = time.mktime((2026, 1, 5, 0, 0, 0, 0, 0, -1)), 0.0, []
    for k in range(14 * 288):
        t = int(base + k * 300)
        u = 0.0 if k % 2016 == 0 else u + (0.01 / 12 if 9 <= time.localtime(t - 300).tm_hour < 17 else 0)
        syn.append({"t": t, "s": {"A": {"w": u, "wr": base + (k // 2016 + 1) * WEEK, "ts": t}}})
    prof, typ = hour_profile(syn, "w")
    assert all(abs(prof[h] - 1.0) < 0.05 for h in range(9, 17)) and all(prof[h] < 0.05 for h in list(range(9)) + list(range(17, 24))), prof
    assert abs(typ - 8 / 24) < 0.02 and hour_profile(syn[:200], "w") is None                 # under 24 h of history: no profile
    assert hour_profile([syn[0], dict(syn[0], t=syn[0]["t"] + 30 * 3600)], "w") is None         # a step longer than a day cannot be placed
    sl = build(syn, syn[-1]["t"], {}, False)["providers"][0]["limits"][0]
    assert len(sl["profile"]) == 24 and sl["typical"] == round(typ, 2) and "profile" not in build(syn[:200], syn[199]["t"], {}, False)["providers"][0]["limits"][0]
    mid = base
    two = lambda: [{"used": 0, "reset": mid + 30 * DAY, "period": WEEK}] * 2
    flat, only0 = project(two(), 50, mid, 5 * 3600), project(two(), [100] + [0] * 23, mid, 5 * 3600)         # twins of the node test cases
    assert flat[1] == mid + 14400 and project(two(), [50] * 24, mid, 5 * 3600) == flat and only0[1] is None and dict(only0[0])[mid + 3600] == 100.0 and only0[0][-1][1] == 100.0
    assert project(two(), [100, 50] + [0] * 22, mid, 7200)[0][-1] == (mid + 7200, 50.0)
    bt = backtest(syn, (("claude", "w", "x"),))["x"]
    assert bt["n"] >= 40 and bt["typical"] < 1 and bt["typical"] * 5 < min(bt["3h"], bt["24h"]), bt          # the profile follows the day, a flat burn cannot
    table, best = backtest_table({"x": bt})
    assert best == "typical" and "lowest overall: typical" in table and backtest_table({})[1] is None

    # build: 15-minute downsample, generic windows, drain
    now = L + 5 * 3600
    hist = []
    for i in range(0, 6 * 3600, 300):           # a record every 5 min, 6 hours, claude A used 0.01 more each step
        hist.append({"t": L + i, "s": {"A": {"w": 0.01 * (i // 300) / 10, "wr": L + 90000, "ts": L + i}},
                     "grok": {"grok": {"w": 0.2, "wr": L + 40000, "wp": 604800, "ts": L}}})
    hist[3]["b"] = 1
    blob = build(hist, now, {"claude": {"A": "a@x.org"}}, True)
    assert [p["id"] for p in blob["providers"]] == ["claude", "grok"] and blob["app"] is True and blob["first"] == L
    cl, gk = blob["providers"]
    assert cl["accounts"][0]["email"] == "a@x.org" and cl["total"] == cl["loaded"] == 1
    lim = next(x for x in cl["limits"] if x["id"] == "w")
    assert [x["id"] for x in cl["limits"]] == ["w"] and lim["cap"] == 100       # no Fable data -> no f limit
    stamps = [p[0] for p in lim["hist"]]
    assert all(b - a >= 1 for a, b in zip(stamps, stamps[1:])) and len({t // 900 for t in stamps}) == len(stamps)
    assert len(lim["hist"]) == 24 and lim["hist"][0][2] == 0
    assert lim["hist"][1][0] == L + 1500 and lim["hist"][1][2] == 0            # last record of bucket 0 is t=L+600
    bf = next(p for p in lim["hist"] if p[0] // 900 == (L + 900) // 900)
    assert bf[2] == 0                                                          # hist[3] was the first of its bucket, not the last
    assert abs(lim["burn"]["1"] - 1.2) < 0.06 and lim["burn"]["24"] is not None
    dr = lim["drain"]["1"]
    assert dr and all(b[0] - a[0] == 3600 for a, b in zip(dr, dr[1:])) and dr[-1][0] == now, dr[-2:]
    assert lim["seats"] == [{"used": 0.01 * 71 / 10, "reset": L + 90000, "period": WEEK}], lim["seats"]
    assert gk["limits"][0]["label"] == "Weekly credits" and gk["limits"][0]["burn"]["1"] == 0.0
    assert gk["accounts"][0]["windows"][0]["reset"] == L + 40000
    assert gk["name"] == "xAI" and gk["note"] == PROVIDER_NOTE["grok"] and "note" not in cl
    # a window whose reset passed counts as 0 used and its reset rolls forward
    stale = build([{"t": L, "s": {"A": {"w": 0.9, "wr": L - 10, "ts": L - 99}}}], L, {}, False)["providers"][0]
    assert stale["limits"][0]["now"] == 100.0 and stale["accounts"][0]["windows"][0] == {"id": "w", "label": "Weekly", "used": 0.0, "reset": L - 10 + WEEK, "assumed": True}
    fresh = build([{"t": L, "s": {"A": {"w": 0.9, "wr": L + 10, "ts": L - 99}, "B": {"w": 0.3, "wr": L - 10, "ts": L - 5}}}], L, {}, False)["providers"][0]["accounts"]
    assert "assumed" not in fresh[0]["windows"][0] and "assumed" not in fresh[1]["windows"][0]      # reset still ahead / read after the reset: a real value
    # 6: the API status per window travels with the seat into the blob, and not past the window's reset
    sa = build([{"t": L, "s": {"A": {"w": 0.9, "wr": L + 10, "ts": L - 5, "wt": "allowed_warning", "st": "rejected", "ft": None}, "B": {"w": 0.3, "wr": L - 10, "ts": L - 99, "wt": "rejected"}}}], L, {}, False)["providers"][0]["accounts"]
    assert sa[0]["windows"][0]["stat"] == "allowed_warning" and "stat" not in sa[1]["windows"][0]
    keep_root, rd = ROOT, tempfile.mkdtemp()
    try:
        globals()["ROOT"] = rd
        os.makedirs(os.path.join(rd, "A"))
        for fn, ts_, dd in (("usage-cache.json", 100, {"s5_util": .1, "s5_reset": 9, "w7_util": .5, "w7_reset": 9, "s5_stat": "allowed", "w7_stat": "allowed_warning", "oi7_stat": None}),
                            ("usage-cache-fable.json", 90, {"oi7_util": .2, "oi7_reset": 9, "oi7_stat": "rejected", "s5_stat": "x", "w7_stat": "y"})):
            json.dump({"ts": ts_, "data": dict(dd, ok=True, access="ok")}, open(os.path.join(rd, "A", fn), "w"))
        rs_ = read_seat("A")
        assert (rs_["st"], rs_["wt"], rs_["ft"], rs_["f"]) == ("allowed", "allowed_warning", "rejected", 0.2), rs_      # s/w from the newest read, Fable's from the one that carries it
    finally:
        globals()["ROOT"] = keep_root
        __import__("shutil").rmtree(rd, ignore_errors=True)
    assert stale["limits"][0]["burn"] == {"1": None, "3": None, "6": None, "24": None} and stale["limits"][0]["drain"]["1"] == []
    assert build([], L)["providers"] == [] and build([], L)["first"] is None
    # F: seat weights (seatWeights, then planWeights by the detected plan, then 1) and Codex plan detection from the rollout logs
    def tk(t, used, reset, inp, cached, out, plan="team"):
        return json.dumps({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count",
                           "info": {"total_token_usage": {"input_tokens": inp, "cached_input_tokens": cached, "output_tokens": out}},
                           "rate_limits": {"limit_id": "codex", "plan_type": plan, "primary": {"used_percent": used, "window_minutes": 10080, "resets_at": reset}, "secondary": None}}})
    WA, WB = N + 400_000, N + 500_000
    with tempfile.TemporaryDirectory() as td:
        for lab in "AB":
            os.makedirs(os.path.join(td, "homes", lab))
        roll(os.path.join(td, "homes", "A", "sessions", "rollout-a.jsonl"), [tk(N - 5000, 10, WA, 100, 0, 0, "team")], N - 100)
        roll(os.path.join(td, "homes", "B", "sessions", "rollout-b.jsonl"), [tk(N - 4000, 40, WB, 100, 0, 0, "pro")], N - 100)
        roll(os.path.join(td, "sessions", "rollout-act.jsonl"), [tk(N - 3000, 11, WA + 30, 1, 0, 0, "team"), tk(N - 2000, 3, N + 777, 1, 0, 0, "ghost")], N - 100)
        plans = codex_measure(td, N)[0]
        assert plans == {"A": "team", "B": "pro"}, plans       # the active-login event is A's by its reset; the one matching nobody is skipped
        cfgp = os.path.join(td, "cfg.json")
        json.dump({"seatWeights": {"codex": {"B": 5, "X": -1, "Y": "5", "Z": True}, "claude": {"A": 0.5}}, "planWeights": {"codex": {"Pro": 3, "team": 1}}, "junk": 1}, open(cfgp, "w"))
        c = read_weights_cfg(cfgp)
        assert c == {"seat": {"codex": {"B": 5.0}, "claude": {"A": 0.5}}, "plan": {"codex": {"Pro": 3.0, "team": 1.0}}}, c      # negative, string and bool weights are dropped
        assert read_weights_cfg(os.path.join(td, "none.json")) == {"seat": {}, "plan": {}}
        set_weights(dict(c, plans={"codex": plans}))
        assert wt("codex", "B") == (5.0, "seatWeights") and wt("codex", "A") == (1.0, "plan team")      # a seat's own weight beats its plan's
        assert wt("claude", "A") == (0.5, "seatWeights") and wt("claude", "Z") == (1.0, None) and wt("grok", "q") == (1.0, None)
        assert wt("codex", "B") == (5.0, "seatWeights") and WCFG["plan"]["codex"]["Pro"] == 3.0
        set_weights(dict(c, seat={}, plans={"codex": plans}))
        assert wt("codex", "B") == (3.0, "plan pro")           # plan names match without regard to case
        ch = [{"t": N, "codex": {s: {"w": .2, "wr": N + 9999, "wp": WEEK, "ts": N} for s in "AB"}}]
        acc = build(ch, N, {}, False, {"weights": dict(c, seat={}, plans={"codex": plans})})["providers"][0]["accounts"]
        assert "w" not in acc[0] and acc[0]["plan"] == "team" and acc[1]["w"] == 3.0 and acc[1]["wsrc"] == "plan pro" and acc[1]["plan"] == "pro", acc
        set_weights({"seat": {}, "plan": {}, "plans": {"codex": {"A": "team", "B": "pro"}}})
        mp = build_provider([{"t": 1, "codex": {"A": {"ts": 1, "w": 0.1}, "B": {"ts": 1, "w": 0.1}}}], "codex", {}, 2, {})
        assert "different plans (pro, team)" in mp["note"], mp.get("note")
        assert "w" not in build(ch, N, {}, False, {})["providers"][0]["accounts"][1]       # no extra: weights reset to 1
    # G: the pool is weighted: a x5 seat B next to a regular seat A
    set_weights({"seat": {"claude": {"B": 5.0, "Z": 0.0}}})
    far = T + 30 * 86400
    assert remaining(rec(T, A=(0.5, far), B=(0.1, far)), "w") == (500.0, 2)         # (0.5 + 5 x 0.9) x 100 of a 600 cap
    assert remaining(rec(T, A=(0.5, far), B=(0.1, far), Z=(0.0, far)), "w") == (500.0, 2)      # weight 0 is left out
    hw = [rec(T, A=(0.1, far), B=(0.1, far)), rec(T + 3600, A=(0.2, far), B=(0.12, far))]
    assert abs(burn(hw, "w", 3, T + 3600) - 20) < 1e-9                                # A +10 % and B +2 % x 5, in weighted % per hour
    pw, ew = project([{"used": 0, "reset": far, "period": WEEK}, {"used": 0, "reset": far, "period": WEEK, "w": 5}], 100, T, 8 * 3600)
    assert dict(pw)[T] == 600 and dict(pw)[T + 3600] == 500 and ew == T + 6 * 3600, (ew, pw[:3])      # 100 %/h = one regular seat an hour
    pw, ew = project([{"used": 0, "reset": far, "period": WEEK}, {"used": 0, "reset": T + 1800, "period": WEEK, "w": 5}], 600, T, 3600)
    assert [dict(pw)[T + d] for d in (600, 1200, 1800, 2400)] == [500, 400, 600, 500]       # 600 %/h = a regular seat per 10 min, taken from the x5 seat (resets first), which refills at 1800
    assert project([{"used": 0.5, "reset": far, "period": WEEK, "w": 0}], 100, T, 600)[0][0][1] == 0.0      # a seat of weight 0 holds nothing
    wl = build([rec(T, A=(0.5, far), B=(0.1, far), Z=(0.9, far))], T, {}, False, {"weights": {"seat": {"claude": {"B": 5.0, "Z": 0.0}}}})["providers"][0]
    lm = wl["limits"][0]
    assert lm["cap"] == 600 and lm["now"] == 500.0 and [s.get("w") for s in lm["seats"]] == [None, 5.0] and lm["hist"][0][1] == 500.0, lm      # Z is out of the pool
    assert [a.get("w") for a in wl["accounts"]] == [None, 5.0, 0.0] and wl["accounts"][1]["wsrc"] == "seatWeights"
    set_weights(None)
    # H: measured ratio of a Codex seat's capacity: uncached tokens per 1 % of weekly use over the last 21 days, against the weight-1 seats
    def steps(t0, start, n, per, reset):
        """An anchor event, then n whole-percent ticks each preceded by a half-way event at the old percent; `per` = (input, cached, output) tokens added per percent."""
        ev, used, tot = [tk(t0, start, reset, 0, 0, 0)], start, [0, 0, 0]
        for i in range(n):
            for half, u in ((1, used), (2, used + 1)):
                tot = [tot[0] + per[0] / 2, tot[1] + per[1] / 2, tot[2] + per[2] / 2]
                ev.append(tk(t0 + 1200 * i + 600 * half, u, reset, int(tot[0]), int(tot[1]), int(tot[2])))
            used += 1
        return ev
    with tempfile.TemporaryDirectory() as td:
        for lab in "ABCD":
            os.makedirs(os.path.join(td, "homes", lab))
        # per percent, uncached = input - cached + output: A 1500 - 700 + 200 = 1000 tokens, B 6000 - 2500 + 1500 = 5000, C 1000 but only 3 percents
        roll(os.path.join(td, "homes", "A", "sessions", "rollout-a.jsonl"), steps(N - 80_000, 10, 8, (1500, 700, 200), WA)
             + steps(N - 40 * 86400 + 100, 10, 8, (10_000_000, 0, 0), WA - 30 * 86400), N - 100)       # old pairs (a different window, 40 days back) are not counted
        roll(os.path.join(td, "homes", "B", "sessions", "rollout-b.jsonl"), steps(N - 80_000, 40, 8, (6000, 2500, 1500), WB), N - 100)
        roll(os.path.join(td, "homes", "C", "sessions", "rollout-c.jsonl"), steps(N - 80_000, 5, 3, (1500, 700, 200), WB + 100_000), N - 100)
        plans, pairs = codex_measure(td, N)
        assert len(pairs["A"]) == 8 + 8 and len(pairs["B"]) == 8 and len(pairs["C"]) == 3 and "D" not in pairs, {k: len(v) for k, v in pairs.items()}     # ticks, not adjacent events
        assert sorted(round(v) for t, v in pairs["B"]) == [5000] * 8 and sorted(round(v) for t, v in pairs["C"]) == [1000] * 3, pairs["B"]
        set_weights({"seat": {"codex": {"B": 5.0}}})
        m = measured_ratios(pairs, N)
        assert m["A"] == (1.0, 8) and m["B"] == (5.0, 8) and m["C"] == (None, 3), m      # 5 pairs needed; A's 40-day-old pairs left out; B over the weight-1 seat A
        set_weights(None)
        m = measured_ratios(pairs, N)           # every seat weight 1: the reference is the median of A and B (3000)
        assert abs(m["B"][0] - 5000 / 3000) < 1e-9 and abs(m["A"][0] - 1000 / 3000) < 1e-9
        assert measured_ratios({"A": [(N, 1000.0)] * 4}, N) == {"A": (None, 4)} and measured_ratios({}, N) == {}
        # a token counter that goes back (a new session) and a window change start a fresh anchor; a tick with no tokens in it is skipped
        e = lambda t, u, r, k: (t, None, u, r, k)
        assert token_pairs([e(1, 10, 99, 100), e(2, 11, 99, 50), e(3, 12, 99, 250), e(4, 13, 99, 250), e(5, 14, 99 + 5000, 900), e(6, 15, 99 + 5000, 1900)]) == [(3, 200.0), (6, 1000.0)]
        blob = build([{"t": N, "codex": {s: {"w": .2, "wr": N + 9999, "wp": WEEK, "ts": N} for s in "ABCD"}}], N, {}, False,
                     {"weights": {"seat": {"codex": {"B": 5.0}}}, "codex": {"pairs": pairs}})["providers"][0]["accounts"]
        assert [a["ratio"] for a in blob] == [{"n": 8, "x": 1.0}, {"n": 8, "x": 5.0}, {"n": 3}, {"n": 0}], [a["ratio"] for a in blob]
        assert "ratio" not in build([{"t": N, "s": {"A": {"w": .2, "wr": N + 9999}}}], N, {}, False, {})["providers"][0]["accounts"][0]       # Codex only
        set_weights(None)
    # I: a suggested weight for a Codex seat, from the same pairs: at least 20 samples, steady older and newer halves, more than 30 % off the weight, rounded
    def at(*vals):
        """(t, tokens per 1 %) samples an hour apart, the last one now."""
        return [(N - (len(vals) - 1 - i) * 3600, float(v)) for i, v in enumerate(vals)]
    refs = {"A": at(*[1000] * 8), "C": at(*[1000] * 8)}
    sug = lambda b, w=None: (set_weights({"seat": {"codex": {"B": w}}} if w is not None else None), weight_suggestions(dict(refs, B=b), N))[1]
    assert sug(at(*[3000] * 24)) == {"B": (3, 24)}                                           # qualifies: x3, steady
    assert sug(at(*[3000] * 19)) == {} and sug(at(*[3000] * 20)) == {"B": (3, 20)}          # 20 samples are enough, 19 are not
    assert sug(at(*[2000] * 12 + [4000] * 12)) == {} and sug(at(*[4000] * 12 + [2000] * 12)) == {}      # unsteady: the halves are 2x apart, whichever way
    assert sug(at(*[2800] * 12 + [3500] * 12)) == {"B": (3, 24)}                             # halves 1.25 apart: still steady
    assert sug(at(*[2800] * 12 + [3600] * 12)) == {}                                         # 1.29 apart: not
    assert sug(at(*[1250] * 24)) == {} and sug(at(*[1350] * 24)) == {"B": (1.5, 24)}        # within 30 % of the weight 1: nothing; beyond it: 1.35 -> 1.5
    assert sug(at(*[760] * 24)) == {}                                                        # 1 / 0.76 is off, but the nearest 0.5 is the weight itself
    assert sug(at(*[5200] * 24), 5.0) == {} and sug(at(*[3000] * 24), 5.0) == {"B": (3, 24)}    # against a configured weight
    assert sug(at(*[3000] * 24), 0.0) == {}                                                  # weight 0: left out, nothing to suggest
    assert sug(at(*[3000] * 24)) != {} and weight_suggestions({"B": at(*[3000] * 24)}, N) == {}      # no weight-1 seat to measure against
    assert sug([(t - 30 * 86400, v) for t, v in at(*[3000] * 24)]) == {}                     # older than 21 days: not counted
    assert [nice_weight(x) for x in (0.2, 0.74, 0.76, 1.3, 2.74, 2.76, 2.9, 3.4, 3.5, 4.5, 11.6)] == [0.5, 0.5, 1.0, 1.5, 2.5, 3, 3, 3, 4, 5, 12]
    bl = build([{"t": N, "codex": {s: {"w": .2, "wr": N + 9999, "wp": WEEK, "ts": N} for s in "ABC"}}], N, {}, False,
               {"codex": {"pairs": dict(refs, B=at(*[3000] * 24))}})["providers"][0]["accounts"]
    assert [a.get("suggest") for a in bl] == [None, {"w": 3, "n": 24}, None] and type(bl[1]["suggest"]["w"]) is int, bl
    set_weights(None)
    # the page keeps both placeholders from being re-scanned and escapes </
    assert "</" not in json.dumps({"x": "</script>"}, separators=(",", ":")).replace("</", "<\\/")
    # J: Claude reset credits (read-only): the parser, the version, the per-seat 6-hourly schedule (one seat per tick, 429 and sign-in holds, the kill switch). No network: fetch is injected.
    JN, ISO = 1_800_000_000, lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    gr = lambda i, left=1, **k: dict({"id": i, "resets_left": left, "usable_now": True}, **k)
    blk = {"eligible": True, "grants": [gr("g1", 2, gives_back_weekly=True, ends_at=ISO(JN + 3 * DAY)), gr("g2", 1, type="full", ends_at=ISO(JN + 5 * DAY)),
                                         gr("g3", 4, type="full", paused=True), gr("g4", 1, type="full", ends_at=ISO(JN - 5)), gr("BAD id", 1), gr("g6", -1), gr("g7", 1.5),
                                         gr("g8", 0, type="weekly"), gr("g9", 1, type="session"), gr("g10", 1, clears=["five_hour"]), gr("g11", 1, clears=["weekly", "five_hour"]),
                                         gr("g12", 1, type="x"), gr("g13", 1, usable_now=False), gr("g14", 1, ends_at="soon"), gr("g15", True), "junk", None, gr("x" * 41, 1)],
           "next_grant_id": "g1"}
    pc_ = parse_cedar(blk, JN)
    assert pc_["eligible"] and [(g["id"], g["kind"], g["left"]) for g in pc_["grants"]] == [("g1", "fable", 2), ("g2", "full", 1), ("g8", "weekly", 0), ("g9", "session", 1),
                                                                                           ("g10", "session", 1), ("g11", "full", 1), ("g12", "other", 1)], pc_
    assert pc_["grants"][0]["endsAt"] == JN + 3 * DAY and pc_["grants"][3]["endsAt"] is None
    assert parse_cedar(None, JN) == parse_cedar({"eligible": False, "grants": [gr("a")]}, JN) == {"eligible": False, "grants": []}
    assert parse_cedar({"eligible": True}, JN) == {"eligible": True, "grants": []} and parse_cedar({"eligible": True, "grants": "x"}, JN)["grants"] == []
    assert all(parse_cedar(x, JN) is None for x in ("junk", 5, [], {}, {"eligible": "yes"}, {"grants": []}))
    assert parse_usage({"x": 1}, JN) == {"eligible": False, "grants": []} and parse_usage([1], JN) is None and parse_usage(None, JN) is None
    assert parse_usage({"cedar_ember": {"eligible": 1}}, JN) is None
    # the installed version: from `claude --version`, kept 6 h, a fallback when it will not run or says nothing usable
    class _R:
        def __init__(self, out):
            self.stdout = out
    vs = []
    ok_run = lambda argv, **kw: (vs.append(argv), _R("2.1.400 (Claude Code)\n"))[1]
    _ver[:] = [0, ""]
    assert claude_version(JN, ok_run, lambda n: "C:/x/claude.exe") == "2.1.400" and vs == [["C:/x/claude.exe", "--version"]]
    assert claude_version(JN + 60, ok_run, lambda n: "C:/x/claude.exe") == "2.1.400" and len(vs) == 1        # kept, not re-read
    assert claude_version(JN + CREDITS_EVERY, lambda argv, **kw: _R("garbage"), lambda n: "c") == CLI_FALLBACK

    def raising(argv, **kw):
        raise OSError("nope")
    assert claude_version(JN + 3 * CREDITS_EVERY, raising, lambda n: "c") == CLI_FALLBACK and claude_version(JN + 6 * CREDITS_EVERY, ok_run, lambda n: None) == CLI_FALLBACK
    _ver[:] = [JN + 99 * CREDITS_EVERY, "2.1.400"]                                        # pinned: the schedule below must not run the real `claude --version`
    # the schedule, against a temp seat root and provider cache
    keep_root, keep_pc, jd = ROOT, PCACHE, tempfile.mkdtemp()
    try:
        globals()["ROOT"], globals()["PCACHE"] = jd, os.path.join(jd, "p.json")
        for lab_ in "ABC":
            os.makedirs(os.path.join(jd, lab_))
            open(os.path.join(jd, lab_, "token.txt"), "w").write("secret-" + lab_)
        os.makedirs(os.path.join(jd, "D"))                                                   # no token file: never read
        calls = []

        def fake(plan):
            def f(req):
                calls.append((req.full_url, req.get_header("Authorization"), req.get_header("User-agent"), req.get_header("Anthropic-beta"), req.get_method()))
                return plan.get(req.get_header("Authorization")[7:].split("secret-")[1], (200, {"cedar_ember": blk}))
            return f
        st = Store.__new__(Store)
        st.lock = threading.RLock()
        plan = {"B": (429, None), "C": (401, None)}
        fx = fake(plan)
        r1 = st.credits_tick(JN, fx, "no-such-config.json")
        assert r1 == ("A", "ok") and len(calls) == 1 and calls[0][0] == CREDITS_URL and calls[0][4] == "GET"             # one seat per tick
        assert calls[0][1] == "Bearer secret-A" and calls[0][2].startswith("claude-cli/") and calls[0][2].endswith(" (external, cli)") and calls[0][3] == "oauth-2025-04-20"
        assert st.credits_tick(JN + 300, fx, "no-such-config.json") == ("B", "rl") and st.credits_tick(JN + 600, fx, "no-such-config.json") == ("C", "auth")
        assert st.credits_tick(JN + 900, fx, "no-such-config.json") is None and len(calls) == 3          # D has no token; A, B, C are not due for 6 h
        cc = load_pcache()["credits"]
        assert cc["A"]["eligible"] is True and cc["A"]["ts"] == JN and [g["id"] for g in cc["A"]["grants"]][:2] == ["g1", "g2"] and cc["A"]["next"] == JN + CREDITS_EVERY
        assert cc["B"]["note"] == "rate limited" and cc["B"]["hold"] == JN + 300 + CREDITS_EVERY and "ts" not in cc["B"] and cc["C"]["note"] == "sign-in needed"
        assert "secret-" not in open(PCACHE).read()                                                      # the token is never stored
        assert st.credits_read("B", JN + CREDITS_EVERY, fx, force=True) is None and len(calls) == 3      # a forced read still honours a 429 hold
        assert st.credits_tick(JN + CREDITS_EVERY - 1, fx, "no-such-config.json") is None
        plan.clear()
        assert st.credits_tick(JN + CREDITS_EVERY, fx, "no-such-config.json") == ("A", "ok") and len(calls) == 4      # A is due again; B (held to +300) and C follow in order
        assert st.credits_tick(JN + CREDITS_EVERY + 300, fx, "no-such-config.json") == ("B", "ok") and "hold" not in load_pcache()["credits"]["B"] and "note" not in load_pcache()["credits"]["B"]
        bad = fake({"A": (500, None), "B": (200, {"cedar_ember": "junk"}), "C": (0, "URLError")})
        before = load_pcache()["credits"]["A"]["grants"]
        assert st.credits_read("A", JN + 2 * CREDITS_EVERY, bad) == "fail" and load_pcache()["credits"]["A"]["grants"] == before     # any other failure keeps the last good reading
        assert st.credits_read("B", JN + 2 * CREDITS_EVERY + 1000, bad) == "fail" and st.credits_read("C", JN + 2 * CREDITS_EVERY + 1000, bad) == "fail"
        assert st.credits_read("A", JN + 2 * CREDITS_EVERY + 5, bad) is None                             # failures count as the 6-hourly attempt too
        assert st.credits_read("A", JN + 3 * CREDITS_EVERY, lambda req: 1 / 0) == "fail"                  # a raising fetch is a failed read, not a crash
        n_ = len(calls)
        off = os.path.join(jd, "off.json")
        open(off, "w").write('{"claudeResetCredits": false}')
        assert credits_enabled(off) is False and credits_enabled(os.path.join(jd, "none.json")) and credits_enabled(os.path.join(jd, "p.json"))
        assert st.credits_tick(JN + 9 * CREDITS_EVERY, fx, off) is None and len(calls) == n_              # the kill switch: no call at all
        # build: the grants become the banked column (a count, a muted line per grant); not eligible / no reading / expired show nothing
        ex = {"credits": {"A": {"ts": JN, "eligible": True, "grants": parse_cedar(blk, JN)["grants"]},
                          "B": {"ts": JN, "eligible": False, "grants": []}, "C": {"note": "sign-in needed"}}}
        ba_ = build([{"t": JN, "s": {k: {"w": 0.1, "wr": JN + 9, "ts": JN} for k in "ABCD"}}], JN + 10, {}, False, ex)["providers"][0]["accounts"]
        assert ba_[0]["banked"] == 7 and ba_[0]["bankedAt"] == JN and [(x["title"], x.get("n")) for x in ba_[0]["bankedList"]] == [
            ("Fable reset", 2), ("Full reset", None), ("5-hour reset", None), ("5-hour reset", None), ("Full reset", None), ("Reset", None)], ba_[0]
        assert ba_[0]["bankedList"][0]["expiresAt"] == JN + 3 * DAY and ba_[0]["bankedList"][-1]["expiresAt"] is None                 # no expiry sorts last
        assert "banked" not in ba_[1] and ba_[1]["bankedAt"] == JN and "bankedAt" not in ba_[2] and ba_[2]["bankedNote"] == "sign-in needed" and "banked" not in ba_[3]
        gone = build([{"t": JN, "s": {"A": {"w": 0.1, "wr": JN + 9, "ts": JN}}}], JN + 4 * DAY, {}, False, ex)["providers"][0]["accounts"][0]       # the Fable grant (3 d) has expired by now
        assert gone["banked"] == 5 and gone["bankedList"][0]["title"] == "Full reset"
        assert "banked" not in build([{"t": JN, "s": {"A": {"w": 0.1, "wr": JN + 9, "ts": JN}}}], JN, {}, False, {})["providers"][0]["accounts"][0]
    finally:
        globals()["ROOT"], globals()["PCACHE"] = keep_root, keep_pc
        _ver[:] = [0, ""]
        __import__("shutil").rmtree(jd, ignore_errors=True)
    # K: Claude Apply reset - the grant the server picks, the claim (request id kept while unconfirmed), every outcome, the re-read after, and the HTTP guards.
    # No network: fetch is injected, and the handler runs on a spare loopback port against a fake store.
    import http.client
    from http.server import ThreadingHTTPServer
    KN = int(time.time())                                                                # Store.claude_reset reads the clock itself
    kblk = {"eligible": True, "next_grant_id": "g1", "grants": [gr("g1", 2, gives_back_weekly=True, ends_at=ISO(KN + 3 * DAY)), gr("g2", 1, type="full", ends_at=ISO(KN + 5 * DAY)),
            gr("g8", 0, type="weekly"), gr("g9", 1, type="session"), gr("g10", 1, clears=["five_hour"]), gr("g11", 1, clears=["weekly", "five_hour"]), gr("g12", 1, type="x"),
            gr("g13", 1, type="full", usable_now=False), gr("g3", 4, type="full", paused=True)]}
    kb = parse_cedar(kblk, KN)
    assert kb["nextId"] == "g1" and [g["usable"] for g in kb["grants"]][:2] == [True, True] and "nextId" not in parse_cedar(dict(kblk, next_grant_id="BAD id"), KN)
    assert parse_cedar(dict(kblk, grants=[gr("u1", 1, type="full", usable_now="yes")]), KN)["grants"][0]["usable"] is False        # only a real true is usable
    ke = dict(kb, ts=KN)
    assert [g["id"] for g in usable_grants(ke, "fable", KN)] == ["g1"] and [g["id"] for g in usable_grants(ke, "full", KN)] == ["g2", "g11"]   # soonest first, no expiry last
    assert [g["id"] for g in usable_grants(ke, "session", KN)] == ["g9", "g10"] and usable_grants(ke, "weekly", KN) == []                  # g8 has no resets left
    assert usable_grants(dict(ke, nextId="g3"), "full", KN) == [] and usable_grants({k: v for k, v in ke.items() if k != "nextId"}, "full", KN) == []   # T3's next-grant gate
    assert usable_grants(dict(ke, eligible=False), "fable", KN) == [] and usable_grants({}, "fable", KN) == []
    assert usable_grants(ke, "fable", KN + 3 * DAY) == []                                                                                 # expired by now
    kh = [{"t": KN, "s": {"A": {"w": 0.1, "wr": KN + 9, "ts": KN}, "B": {"w": 0.1, "wr": KN + 9, "ts": KN}}}]
    kx = {"credits": {"A": ke, "B": dict(ke, nextId=None)}, "claudeReset": True}
    kp = build(kh, KN + 10, {}, False, kx)["providers"][0]
    assert kp["canReset"] is True and kp["accounts"][0]["resets"] == [{"kind": "fable", "left": 2, "endsAt": KN + 3 * DAY}, {"kind": "full", "left": 2, "endsAt": KN + 5 * DAY},
                                                                      {"kind": "session", "left": 2, "endsAt": None}], kp["accounts"][0]
    assert "resets" not in kp["accounts"][1] and kp["accounts"][1]["banked"] == 7                       # counted, but no Apply without the next grant
    assert "g1" not in json.dumps(kp)                                                                   # no grant id reaches the page
    kp = build(kh, KN + 10, {}, False, dict(kx, claudeReset=False))["providers"][0]
    assert "canReset" not in kp and "resets" not in kp["accounts"][0] and kp["accounts"][0]["banked"] == 7                # switched off: the count stays, the buttons go
    keep = {k: globals()[k] for k in ("ROOT", "PCACHE", "APPLOG", "STATE", "credits_enabled")}
    kd = tempfile.mkdtemp()
    _ver[:] = [KN + DAY, "2.1.400"]                                                       # pinned: no real `claude --version`
    try:
        globals().update(ROOT=kd, PCACHE=os.path.join(kd, "p.json"), APPLOG=os.path.join(kd, "app.log"), STATE=kd)
        ORG = "0f0e0d0c-0b0a-4908-8706-050403020100"
        for lab_ in "AB":
            os.makedirs(os.path.join(kd, lab_))
            open(os.path.join(kd, lab_, "token.txt"), "w").write("secret-" + lab_)
        open(os.path.join(kd, "A", "usage-cache.json"), "w").write(json.dumps({"ts": KN, "data": {"ok": True, "org": ORG}}))
        open(os.path.join(kd, "B", "usage-cache.json"), "w").write(json.dumps({"ts": KN, "data": {"ok": True, "org": "not-a-uuid"}}))
        assert claude_org("A") == ORG and claude_org("B") == "" and claude_org("Z") == ""
        kc, post = [], [(200, {"result": "reset"})]

        def kf(req):
            kc.append((req.get_method(), req.full_url, req.data, req.get_header("Authorization"), req.get_header("Content-type"), req.get_header("Anthropic-beta"),
                       req.get_header("User-agent")))
            if req.get_method() == "GET":
                return 200, {"cedar_ember": dict(kblk, grants=[x for x in kblk["grants"] if not (isinstance(x, dict) and x.get("id") == "g1")])}   # g1 spent
            r_ = post.pop(0)
            if isinstance(r_, Exception):
                raise r_
            return r_
        ks = Store.__new__(Store)
        ks.lock, ks.rebuild = threading.RLock(), lambda now: None
        save_pcache({"credits": {"A": dict(ke), "B": dict(ke)}})
        ids = iter("rid%d" % i for i in range(1, 99))
        nid = lambda: next(ids)
        r_ = ks.claude_reset("A", "fable", kf, nid)
        assert r_ == {"outcome": "redeemed", "text": "Fable reset applied to seat A."}, r_
        assert kc[0][:3] == ("POST", RESET_URL % ORG, b'{"program": "cedar_ember", "grant_id": "g1", "request_id": "rid1"}'), kc[0]
        assert RESET_URL % ORG == "https://api.anthropic.com/api/organizations/%s/reset_rate_limits" % ORG
        assert kc[0][3:6] == ("Bearer secret-A", "application/json", "oauth-2025-04-20") and kc[0][6].startswith("claude-cli/") and kc[0][6].endswith(" (external, cli)")
        assert kc[1][:2] == ("GET", CREDITS_URL) and len(kc) == 2                                           # the seat is read again straight after
        pc = load_pcache()
        assert pc["credits_claims"] == {} and [g["id"] for g in pc["credits"]["A"]["grants"]][0] == "g2" and usable_grants(pc["credits"]["A"], "fable", KN) == []
        assert "secret-" not in open(PCACHE).read() and "secret-" not in open(APPLOG).read() and "seat A fable -> redeemed" in open(APPLOG).read()
        # an unconfirmed claim keeps its request id; the retry of the same grant reuses it; a settled answer drops it
        save_pcache({"credits": {"A": dict(ke)}})
        kc.clear(), post.extend([TimeoutError("t"), (200, {"result": "already_used"}), (200, {"result": "reset"})])
        r_ = ks.claude_reset("A", "full", kf, nid)
        cl = load_pcache()["credits_claims"]
        assert r_["outcome"] == "error" and "unconfirmed (Claude could not be reached)" in r_["text"] and list(cl) == ["A:g2"] and cl["A:g2"]["id"] == "rid2"
        save_pcache(dict(load_pcache(), credits={"A": dict(ke)}))                                            # the re-read dropped g1, the next grant: put the reading back
        r_ = ks.claude_reset("A", "full", kf, nid)
        assert r_ == {"outcome": "alreadyRedeemed", "text": "That reset was already applied; nothing more was used."} and b'"request_id": "rid2"' in kc[2][2]
        assert load_pcache()["credits_claims"] == {}
        save_pcache(dict(load_pcache(), credits={"A": dict(ke)}))
        ks.claude_reset("A", "full", kf, nid)
        assert b'"request_id": "rid3"' in kc[4][2]                                                          # a new claim, a new id
        # every other outcome
        for ans, oc, text, kept in [((200, {"result": "not_limited"}), "nothingToReset", "Seat A had nothing to reset right now.", False),
                                    ((200, {"result": "ineligible"}), "noCredit", "Claude says seat A has no 5-hour reset to apply.", False),
                                    ((200, {"result": "cooldown"}), "error", "Claude resets are cooling down. Try again later.", False),
                                    ((429, None), "error", "Claude is rate limiting resets.", False),
                                    ((401, None), "error", "Seat A needs to sign in to Claude again.", False),
                                    ((403, None), "error", "Seat A needs to sign in to Claude again.", False),
                                    ((200, {"result": "unavailable"}), "error", "unconfirmed (Claude did not confirm it)", True),
                                    ((200, {"result": "who knows"}), "error", "unconfirmed (HTTP 200)", True),
                                    ((200, ["x"]), "error", "unconfirmed (HTTP 200)", True),
                                    ((502, None), "error", "unconfirmed (HTTP 502)", True),
                                    ((0, "URLError"), "error", "unconfirmed (Claude could not be reached)", True)]:
            save_pcache({"credits": {"A": dict(ke)}})
            post.append(ans)
            r_ = ks.claude_reset("A", "session" if oc == "noCredit" else "fable", kf, nid)
            assert r_["outcome"] == oc and text in r_["text"], (ans, r_)
            assert bool(load_pcache().get("credits_claims")) is kept, (ans, load_pcache().get("credits_claims"))
        assert not post
        # nothing to claim, or no organization: no call at all
        n_ = len(kc)
        save_pcache({"credits": {"A": dict(ke, nextId=None), "B": dict(ke)}})
        assert ks.claude_reset("A", "fable", kf, nid) == {"outcome": "noCredit", "text": "Seat A has no fable reset to apply."} and len(kc) == n_
        assert ks.claude_reset("A", "weekly", kf, nid)["outcome"] == "noCredit" and len(kc) == n_
        r_ = ks.claude_reset("B", "fable", kf, nid)
        assert r_["outcome"] == "error" and "organization is not known" in r_["text"] and [c[0] for c in kc[n_:]] == ["GET"]   # only the re-read
        assert load_pcache()["credits_claims"] == {}
        # the HTTP guards, on a spare loopback port with a fake store
        hs = Store.__new__(Store)
        hs.lock, hs.refreshing, hs.blob, hc = threading.RLock(), threading.Lock(), {}, []
        hs.claude_reset = lambda seat, kind: (hc.append((seat, kind)), {"outcome": "redeemed", "text": "ok"})[1]
        srv = ThreadingHTTPServer(("127.0.0.1", 0), __import__("http.server").server.BaseHTTPRequestHandler)
        port = srv.server_address[1]
        srv.RequestHandlerClass = make_handler(hs, port)
        threading.Thread(target=srv.serve_forever, daemon=True).start()

        def hp(body, host="127.0.0.1:%d" % port, app="1", path="/api/claude-reset"):
            cn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            raw = body if isinstance(body, bytes) else json.dumps(body).encode()
            try:
                cn.request("POST", path, raw, dict({"Host": host, "Content-Type": "application/json"}, **({"X-Quota-App": app} if app else {})))
                rp = cn.getresponse()
                out = (rp.status, rp.read())
            except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
                if len(raw) <= 1024:
                    raise
                out = (400, b"")                  # an oversized body is refused unread; Windows may abort the send before the 400 is read
            cn.close()
            return out
        try:
            ok_ = {"seat": "A", "kind": "fable"}
            assert hp(ok_, host="evil.example:%d" % port)[0] == 403 and hp(ok_, app=None)[0] == 403 and hp(ok_, app="0")[0] == 403 and not hc
            for bad in ({"seat": "Z", "kind": "fable"}, {"seat": "A/../B", "kind": "fable"}, {"seat": "a", "kind": "fable"}, {"seat": "A", "kind": "other"},
                        {"seat": "A", "kind": ["fable"]}, {"seat": "A"}, {"seat": "A", "kind": "fable", "pad": "x" * 1100}, ["A"], b"not json", b""):
                assert hp(bad)[0] == 400, bad
            assert not hc
            st_, body_ = hp(dict(ok_, grant_id="g9"))                                                       # a grant id from the page is ignored
            assert st_ == 200 and json.loads(body_) == {"outcome": "redeemed", "text": "ok"} and hc == [("A", "fable")]
            hs.refreshing.acquire()
            assert hp(ok_)[0] == 409 and len(hc) == 1                                                       # single flight with refresh and the Codex reset
            hs.refreshing.release()
            globals()["credits_enabled"] = lambda cfg=None: False
            assert hp(ok_)[0] == 404 and len(hc) == 1                                                       # the kill switch
        finally:
            srv.shutdown()
            srv.server_close()
    finally:
        globals().update(keep)
        _ver[:] = [0, ""]
        __import__("shutil").rmtree(kd, ignore_errors=True)
    # L: the dashboard's switch actions - which seats each rotator can use, the argv per action (an injected runner; no rotator ever runs), the outcome
    # text (no tokens, no emails), the badges/buttons in the blob, and the HTTP guards on a spare loopback port with a fake store.
    ld = __import__("tempfile").mkdtemp(prefix="qsw-")
    keep = {k: globals()[k] for k in ("APPLOG", "switch_targets")}
    try:
        here, cli_r, app_r, cx_r = (os.path.join(ld, x) for x in ("here", "cli", "app", "codex"))
        for d, names, need in ((cli_r, ("A", "B", ".inactive", "_old", "C1", "D"), "token.txt"), (app_r, ("A", "B", "C"), "config.json"),
                               (os.path.join(cx_r, "homes"), ("A", "B", "Z"), "auth.json")):
            for n in names:
                os.makedirs(os.path.join(d, n))
                if n not in ("D", "C", "Z"):                              # D/C/Z: a seat folder with nothing to switch to
                    open(os.path.join(d, n, need), "w").close()
        os.makedirs(here)
        assert switch_targets(here, cli_r, app_r, cx_r) == {}                                                   # no rotator next to this script
        for n in ("claude-cli-account.ps1", "claude-app-rotator.ps1"):
            open(os.path.join(here, n), "w").close()
        tg = switch_targets(here, cli_r, app_r, cx_r)
        assert tg == {"claude": {"cli": ["A", "B"], "app": ["A", "B"]}}, tg                                     # no Codex rotator here: no Codex buttons
        open(os.path.join(here, "codex-app-rotator.ps1"), "w").close()
        tg = switch_targets(here, cli_r, app_r, cx_r)
        assert tg["codex"] == {"both": ["A", "B"]}, tg
        # argv per action: a list, the script next to this one, the exact flags
        ps = lambda n: ["pwsh", "-NoProfile", "-File", os.path.join(here, n)]
        assert switch_argv("claude", "cli", "B", here) == ps("claude-cli-account.ps1") + ["--switch", "B", "--no-usage"]
        assert switch_argv("claude", "app", "B", here) == ps("claude-app-rotator.ps1") + ["--switch", "B", "--relaunch"]
        assert switch_argv("claude", "best", None, here) == ps("claude-cli-account.ps1") + ["--switch", "best", "--no-usage"]
        assert switch_argv("codex", "both", "A", here) == ps("codex-app-rotator.ps1") + ["--switch", "A"]
        assert switch_argv("codex", "best", None, here) == ps("codex-app-rotator.ps1") + ["--rotate"]
        # validation
        assert switch_check({"provider": "claude", "role": "cli", "seat": "A"}, tg) == ("claude", "cli", "A")
        assert switch_check({"provider": "claude", "role": "best", "seat": "x/../y"}, tg) == ("claude", "best", None)     # best ignores any seat
        assert switch_check({"provider": "codex", "role": "both", "seat": "B"}, tg) == ("codex", "both", "B")
        for bad in ({"provider": "claude", "role": "cli", "seat": "D"}, {"provider": "claude", "role": "app", "seat": "C"}, {"provider": "codex", "role": "both", "seat": "Z"},
                    {"provider": "claude", "role": "cli", "seat": "a"}, {"provider": "claude", "role": "cli", "seat": "A/../B"}, {"provider": "claude", "role": "cli", "seat": ["A"]},
                    {"provider": "claude", "role": "cli"}, {"provider": "claude", "role": "both", "seat": "A"}, {"provider": "codex", "role": "cli", "seat": "A"},
                    {"provider": "codex", "role": "app", "seat": "A"}, {"provider": "grok", "role": "best"}, {"provider": ["claude"], "role": "cli", "seat": "A"},
                    {"provider": "claude", "role": {"x": 1}, "seat": "A"}, ["claude"], None, "x"):
            assert switch_check(bad, tg) is None, bad
        assert switch_check({"provider": "codex", "role": "best"}, {"claude": tg["claude"]}) is None                # no Codex rotator: no Codex best
        assert switch_check({"provider": "claude", "role": "best"}, {"claude": {"app": ["A"]}}) is None              # Claude best needs the CLI rotator
        # outcome text: the last unindented line, colour codes gone, tokens and emails redacted
        tok = "sk-ant-oat01-" + "x" * 50
        o_ = switch_outcome(0, "\x1b[32mActive CLI account -> 'B' (someone@example.com).\x1b[0m\r\n  New terminals + VS Code use it immediately\r\n\r\n")
        assert o_ == {"outcome": "ok", "text": "Done: Active CLI account -> 'B' ([email])."}, o_
        o_ = switch_outcome(1, "ABORTED: still running, token " + tok + " Bearer abc.def and " + "Q" * 45)
        assert o_["outcome"] == "error" and o_["text"].startswith("Failed (exit 1): ABORTED") and "sk-ant" not in o_["text"] and "abc.def" not in o_["text"] and "Q" * 40 not in o_["text"], o_
        assert switch_outcome(3, "") == {"outcome": "error", "text": "Failed (exit 3)."} and switch_outcome(0, None)["text"] == "Done."
        assert len(switch_outcome(0, "y " * 300)["text"]) <= 206
        assert switch_outcome(0, "  only indented\n")["text"] == "Done: only indented"
        # the runner: argv as given, no window, waits SWITCH_TIMEOUT; stderr when stdout is empty; a missing pwsh is an error, never a raise; a rotator
        # that outlives the wait is handed back still running, never killed
        seen = []

        class P_:
            """A fake rotator process: finishes at once, or (slow) outlives every timed wait and finishes only when `go` is set. Records kill/terminate."""
            def __init__(self, rc, out, err=b"", slow=False):
                self.rc, self.outs, self.slow, self.go, self.calls, self.returncode, self.pid = rc, (out, err), slow, threading.Event(), [], None, 4242

            def communicate(self, timeout=None):
                self.calls.append(("communicate", timeout))
                if self.slow and timeout is not None:
                    raise subprocess.TimeoutExpired("pwsh", timeout)
                if self.slow:
                    assert self.go.wait(10), "fake rotator never released"
                self.returncode = self.rc
                return self.outs

            def kill(self):
                self.calls.append("kill")

            def terminate(self):
                self.calls.append("terminate")

        def pop(proc):
            return lambda argv, **kw: (seen.append((argv, kw)), proc)[1]
        a_ = switch_argv("claude", "app", "B", here)
        p_ = P_(0, b"Relaunched the Claude app on seat B.\r\n")
        assert run_switch(a_, pop(p_)) == ({"outcome": "ok", "text": "Done: Relaunched the Claude app on seat B."}, None) and p_.calls == [("communicate", SWITCH_TIMEOUT)]
        assert seen[0][0] == a_ and SWITCH_TIMEOUT == 120 and seen[0][1]["stdin"] == subprocess.DEVNULL and seen[0][1]["stdout"] == seen[0][1]["stderr"] == subprocess.PIPE
        assert seen[0][1]["creationflags"] == (0x08000000 if os.name == "nt" else 0) and "shell" not in seen[0][1] and "timeout" not in seen[0][1]
        assert run_switch(a_, pop(P_(1, b"  \r\n", b"pwsh: boom\r\n"))) == ({"outcome": "error", "text": "Failed (exit 1): pwsh: boom"}, None)

        def gone(argv, **kw):
            raise FileNotFoundError("pwsh")
        assert run_switch(a_, gone) == ({"outcome": "error", "text": "The rotator could not run: FileNotFoundError."}, None)
        p_ = P_(0, b"", slow=True)
        assert run_switch(a_, pop(p_)) == ({"outcome": "running", "text": SWITCH_RUNNING}, p_) and p_.calls == [("communicate", 120)]       # no kill, no terminate
        # Store.switch: runs the argv for the action, logs without tokens, rebuilds (which re-reads in_use)
        globals()["APPLOG"] = os.path.join(ld, "log.txt")
        fs = Store.__new__(Store)
        fs.lock, rb = threading.RLock(), []
        fs.rebuild = lambda now: rb.append(now)
        seen.clear()
        assert fs.switch("codex", "best", None, pop(P_(0, b"The app will come up on the new account. " + tok.encode())), here)["outcome"] == "ok"
        assert [x[0] for x in seen] == [ps("codex-app-rotator.ps1") + ["--rotate"]] and len(rb) == 1
        lg = open(APPLOG, encoding="utf-8").read()
        assert "switch: codex best -> Done: The app will come up on the new account." in lg and "sk-ant" not in lg, lg
        # the blob: per-seat roles minus the role the seat holds; the header button only with its rotator
        sh_ = [{"t": 5, "s": {k: {"w": 0.1, "wr": 9, "ts": 5} for k in "ABD"}, "codex": {k: {"w": 0.1, "wr": 9, "ts": 5} for k in "AB"}}]
        sp = build(sh_, 6, {}, True, {"switch": tg, "inUse": {"claude": {"cli": "A", "app": "B"}, "codex": {"app": "A"}}})["providers"]
        assert [a_.get("switch") for a_ in sp[0]["accounts"]] == [["app"], ["cli"], None] and sp[0]["best"] is True       # D has no token: no button
        assert [a_.get("switch") for a_ in sp[1]["accounts"]] == [None, ["both"]] and sp[1]["best"] is True
        sp = build(sh_, 6, {}, True, {"switch": {"claude": {"app": ["A"]}}})["providers"]
        assert "best" not in sp[0] and "best" not in sp[1] and sp[0]["accounts"][0]["switch"] == ["app"] and "switch" not in sp[1]["accounts"][0]
        # the HTTP guards
        globals()["switch_targets"] = lambda *a, **k: tg
        hs = Store.__new__(Store)
        hs.lock, hs.refreshing, hs.blob, hc = threading.RLock(), threading.Lock(), {}, []
        hs.switch = lambda p, r, s: (hc.append((p, r, s)), {"outcome": "ok", "text": "Done."})[1]
        srv = ThreadingHTTPServer(("127.0.0.1", 0), __import__("http.server").server.BaseHTTPRequestHandler)
        port = srv.server_address[1]
        srv.RequestHandlerClass = make_handler(hs, port)
        threading.Thread(target=srv.serve_forever, daemon=True).start()

        def hq(body, host="127.0.0.1:%d" % port, app="1"):
            cn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            raw = body if isinstance(body, bytes) else json.dumps(body).encode()
            try:
                cn.request("POST", "/api/switch", raw, dict({"Host": host, "Content-Type": "application/json"}, **({"X-Quota-App": app} if app else {})))
                rp = cn.getresponse()
                out = (rp.status, rp.read())
            except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
                if len(raw) <= 1024:
                    raise
                out = (400, b"")                  # an oversized body is refused unread; Windows may abort the send before the 400 is read
            cn.close()
            return out
        try:
            ok_ = {"provider": "claude", "role": "app", "seat": "B"}
            assert hq(ok_, host="evil.example:%d" % port)[0] == 403 and hq(ok_, host="127.0.0.1:1")[0] == 403 and hq(ok_, app=None)[0] == 403 and hq(ok_, app="0")[0] == 403 and not hc
            for bad in ({"provider": "claude", "role": "app", "seat": "C"}, {"provider": "claude", "role": "app", "seat": "B;calc"}, {"provider": "codex", "role": "cli", "seat": "A"},
                        dict(ok_, pad="x" * 1100), ["claude"], b"not json", b""):
                assert hq(bad)[0] == 400, bad
            assert not hc
            st_, body_ = hq(ok_)
            assert st_ == 200 and json.loads(body_) == {"outcome": "ok", "text": "Done."} and hc == [("claude", "app", "B")]
            assert hq({"provider": "codex", "role": "best", "seat": "A"})[0] == 200 and hc[-1] == ("codex", "best", None)
            hs.refreshing.acquire()
            assert hq(ok_)[0] == 409 and len(hc) == 2                                                       # single flight with refresh and the resets
            hs.refreshing.release()
            hs.switch = lambda p, r, s: 1 / 0
            assert hq(ok_)[0] == 500 and hs.refreshing.acquire(timeout=5)                                   # a crash still releases the lock (just after the reply)
            hs.refreshing.release()
            # a rotator that outlives the 120 s wait: 202 + "still switching", never killed, the lock held (409) until it exits, then logged, rebuilt, released
            hs.rebuild, rb = (lambda now: rb.append(now)), []
            p_ = P_(0, b"Relaunched the Claude app on seat B.\r\n", slow=True)
            hs.switch = lambda p, r, s: Store.switch(hs, p, r, s, pop(p_), here)
            st_, body_ = hq(ok_)
            assert st_ == 202 and json.loads(body_) == {"outcome": "running", "text": SWITCH_RUNNING}, (st_, body_)
            assert hq(ok_)[0] == 409 and hq(ok_)[0] == 409 and not hs.refreshing.acquire(blocking=False) and not rb
            assert "switch: claude app B -> still running after 120 s (pid 4242); waiting for it" in open(APPLOG, encoding="utf-8").read()
            p_.go.set()
            for _ in range(500):
                if hs.refreshing.acquire(blocking=False):
                    break
                time.sleep(0.01)
            else:
                raise AssertionError("the waiter never released the lock")
            hs.refreshing.release()
            assert p_.calls == [("communicate", 120), ("communicate", None)] and len(rb) == 1, p_.calls        # waited with no bound; no kill, no terminate
            assert "switch: claude app B -> Done: Relaunched the Claude app on seat B." in open(APPLOG, encoding="utf-8").read()
            hs.switch = lambda p, r, s: Store.switch(hs, p, r, s, pop(P_(0, b"ok")), here)
            assert hq(ok_)[0] == 200 and hs.refreshing.acquire(timeout=5)
            hs.refreshing.release()
        finally:
            srv.shutdown()
            srv.server_close()
    finally:
        globals().update(keep)
        __import__("shutil").rmtree(ld, ignore_errors=True)
    # icons: a valid PNG signature and an ICO header
    assert png(16)[:8] == b"\x89PNG\r\n\x1a\n" and ico(png(16))[:6] == b"\0\0\1\0\1\0"
    say("usage-history selftest: ok")


def main():
    if "--selftest" in sys.argv:
        return selftest()
    if "--make-icons" in sys.argv:
        return make_icons()
    os.makedirs(STATE, exist_ok=True)

    def arg(flag, default):
        return int(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default
    if "--backfill" in sys.argv:
        return backfill(arg("--days", 7))
    if "--backtest" in sys.argv:
        set_weights(load_extra()["weights"])
        say(backtest_table(backtest(load()))[0])
        return 0
    if "--serve" in sys.argv:
        return serve(arg("--port", 8787))
    now = time.time()
    hist = load()
    if "--render" not in sys.argv:
        hist = save(hist, sample(now), now)
    render(build(hist, now, load_emails(), extra=load_extra()))


if __name__ == "__main__":
    sys.exit(main())
