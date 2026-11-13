#!/usr/bin/env python3
"""rotator-sync: keep the running rotator folder identical to this repo's windows/ folder.

  --check [--quiet]   compare every file under windows/ at the ref with the live folder
  --pull              copy differing / missing files from the ref into the live folder (backs up first)
  --selftest          run the built-in checks

Config (rotator.local.json next to this script, all keys optional):
  repoClone  path of a local clone of the repo        (or pass --repo)
  liveDir    folder the rotator runs from             (default: the folder this script is in)
Python standard library only. It only ever reads the clone: it never commits, pushes or opens a PR.
"""
import argparse
import contextlib
import fnmatch
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "windows/"
FETCH_EVERY = 6 * 3600
DEFAULT_STATE = os.path.join(os.path.expanduser("~"), ".claude-cli-accounts", ".rotator-drift.json")
BOM = b"\xef\xbb\xbf"


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if check and p.returncode:
        raise SystemExit("git %s failed: %s" % (" ".join(args), p.stderr.decode("utf-8", "replace").strip()))
    return p


def norm(b):
    """Bytes compared as equal when they differ only by a UTF-8 BOM or CRLF vs LF."""
    if b.startswith(BOM):
        b = b[len(BOM):]
    return b.replace(b"\r\n", b"\n")


def is_local(rel):
    """Machine-local files (rotator.local.json, *.local.ps1) are never compared or touched; the .example. files are tracked."""
    name = os.path.basename(rel)
    return fnmatch.fnmatch(name, "*.local.*") and ".example." not in name


def repo_files(repo, ref):
    out = git(repo, "ls-tree", "-r", "--name-only", ref, PREFIX).stdout.decode("utf-8").splitlines()
    return [f[len(PREFIX):] for f in out if not is_local(f)]


def repo_bytes(repo, ref, rel):
    return git(repo, "show", "%s:%s%s" % (ref, PREFIX, rel)).stdout


def compare(repo, live, ref):
    differing, missing = [], []
    for rel in sorted(repo_files(repo, ref)):
        path = os.path.join(live, *rel.split("/"))
        if not os.path.isfile(path):
            missing.append(rel)
            continue
        with open(path, "rb") as fh:
            if norm(fh.read()) != norm(repo_bytes(repo, ref, rel)):
                differing.append(rel)
    return differing, missing


def load_json(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def is_remote_ref(repo, ref):
    return git(repo, "show-ref", "--verify", "--quiet", "refs/remotes/" + ref, check=False).returncode == 0


def maybe_fetch(repo, ref, state, force=False):
    if not is_remote_ref(repo, ref):
        return
    if not force and time.time() - float(load_json(state).get("fetched", 0)) < FETCH_EVERY:
        return
    p = git(repo, "fetch", check=False)
    if p.returncode:  # offline etc.: compare against what the clone already has
        sys.stderr.write("rotator-sync: fetch failed, using the clone as it is: %s\n" % p.stderr.decode("utf-8", "replace").strip())
        return
    update_state(state, lambda st: st.__setitem__("fetched", int(time.time())))


def write_state(state, data):
    """Replace the state file atomically, through a temp file of its own (two writers never share one)."""
    os.makedirs(os.path.dirname(state) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state) or ".", prefix=os.path.basename(state) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, state)
    except BaseException:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        raise


@contextlib.contextmanager
def state_lock(state, wait=30):
    """An OS lock on <state>.lock (msvcrt.locking / fcntl.flock), released when its holder exits: the dashboard's --check can overlap a
    --pull, and neither may write the state from a stale read. Waits up to `wait` s, then TimeoutError."""
    os.makedirs(os.path.dirname(state) or ".", exist_ok=True)
    fh = open(state + ".lock", "a+b")
    try:
        end = time.time() + wait
        while True:
            try:
                if os.name == "nt":
                    import msvcrt
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.time() >= end:
                    raise TimeoutError("state lock held over %d s: %s.lock" % (wait, state))
                time.sleep(0.1)
        try:
            yield
        finally:
            if os.name == "nt":
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    finally:
        fh.close()


def update_state(state, change):
    """One read-modify-write of the state file under state_lock(): `change(st)` edits only its own keys of the file as it is now."""
    with state_lock(state):
        st = load_json(state)
        change(st)
        write_state(state, st)


def resolve(repo, ref):
    """The commit `ref` names now. --pull resolves it once, after fetching, so a fetch running meanwhile cannot move what it compares and writes."""
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").stdout.decode().strip()


def record(repo, live, ref, state, at=None):
    """Compare live with `at` (a resolved commit; default `ref`) and write the drift state, labelled with `ref`."""
    differing, missing = compare(repo, live, at or ref)
    sha = git(repo, "rev-parse", "--short", at or ref).stdout.decode().strip()
    update_state(state, lambda st: st.update({"checked": int(time.time()), "ref": "%s %s" % (ref, sha), "differing": sorted(differing + missing),
                                              "missingLive": missing}))
    return differing, missing, sha


def cmd_check(repo, live, ref, state, quiet):
    maybe_fetch(repo, ref, state)
    differing, missing, sha = record(repo, live, ref, state)
    if not quiet:
        if not (differing or missing):
            print("rotator-sync: %s is identical to %s %s" % (live, ref, sha))
        else:
            print("rotator-sync: %s differs from %s %s" % (live, ref, sha))
            for f in differing:
                print("  differing:    " + f)
            for f in missing:
                print("  missing-live: " + f)
    return 1 if (differing or missing) else 0


def cmd_pull(repo, live, ref, state):
    maybe_fetch(repo, ref, state, force=True)
    at = resolve(repo, ref)
    differing, missing = compare(repo, live, at)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    # All or nothing: a half-applied update (a script replaced before the new file it imports arrives) cannot start. So every new
    # version is read and written to a .tmp-sync sibling first, touching nothing live; only then is each one swapped in, after a
    # backup, and any failure puts back every file already swapped (and removes the ones added) before it is reported.
    staged = []
    try:
        for rel in differing + missing:
            dest = os.path.join(live, *rel.split("/"))
            data = repo_bytes(repo, at, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest + ".tmp-sync", "wb") as fh:
                fh.write(data)
            staged.append((rel, dest))
    except BaseException:
        for _, dest in staged:
            with contextlib.suppress(OSError):
                os.remove(dest + ".tmp-sync")
        raise
    done = []                                   # (dest, its backup, or None for a file this pull added)
    try:
        for rel, dest in staged:
            bak = None
            if rel in differing:
                bak = "%s.bak-sync-%s" % (dest, stamp)
                shutil.copy2(dest, bak)
            os.replace(dest + ".tmp-sync", dest)
            done.append((dest, bak))
    except OSError as e:
        bad = []
        for dest, bak in reversed(done):
            try:
                if bak:
                    shutil.copy2(bak, dest)
                else:
                    os.remove(dest)
            except OSError:
                bad.append(dest)
        for _, dest in staged:
            with contextlib.suppress(OSError):
                os.remove(dest + ".tmp-sync")
        sys.stderr.write("rotator-sync: the update failed (%s: %s); %s\n" % (type(e).__name__, e, "every file was put back as it was" if not bad else
                         "these could not be put back, restore them from their .bak-sync-%s copies: %s" % (stamp, ", ".join(bad))))
        record(repo, live, ref, state, at)
        return 1
    for rel, _ in staged:
        print("%s %s" % ("added   " if rel in missing else "replaced", rel))
    if not (differing or missing):
        print("rotator-sync: nothing to pull, live already matches the ref")
    record(repo, live, ref, state, at)
    return 0


# ---------------------------------------------------------------------------------------------
def selftest():
    def rmtree(p):
        def onerr(fn, path, _):
            os.chmod(path, stat.S_IWRITE)
            fn(path)
        shutil.rmtree(p, onerror=onerr)

    def write(path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)

    root = tempfile.mkdtemp(prefix="rotator-sync-selftest-")
    try:
        repo, live, state = (os.path.join(root, n) for n in ("repo", "live", "state.json"))
        os.makedirs(repo)
        git(repo, "init", "-q")
        git(repo, "config", "user.name", "Self Test")
        git(repo, "config", "user.email", "selftest@example.com")
        git(repo, "config", "commit.gpgsign", "false")
        git(repo, "config", "core.autocrlf", "false")  # the real repo is `* -text`; keep the self-test bytes as written

        def check(label, cond):
            print("  %s  %s" % ("ok  " if cond else "FAIL", label))
            if not cond:
                raise SystemExit(1)

        files = {"a.ps1": b"one\r\ntwo\r\n", "b.py": b"print(1)\n", "c.ps1": b"x\r\n", "fixtures/f.json": b"{}\n", "missing.txt": b"m\n"}
        for rel, data in files.items():
            write(os.path.join(repo, "windows", rel), data)
        write(os.path.join(repo, "stray.txt"), b"not a fixture\n")      # an untracked file the fixture commit must not take
        git(repo, "add", "--", *["windows/" + rel for rel in files])
        check("the fixture files, and only they, are staged", git(repo, "diff", "--cached", "--name-only").stdout.decode().split()
              == sorted("windows/" + rel for rel in files))
        git(repo, "commit", "-q", "-m", "init")
        for rel, data in files.items():
            if rel != "missing.txt":
                write(os.path.join(live, rel), data)

        d, m = compare(repo, live, "HEAD")
        check("identical files are not reported; absent one is missing-live", d == [] and m == ["missing.txt"])
        write(os.path.join(live, "missing.txt"), b"m\n")
        check("fully identical -> exit 0", cmd_check(repo, live, "HEAD", state, True) == 0)
        write(os.path.join(live, "a.ps1"), BOM + b"one\ntwo\n")
        check("CRLF/LF and BOM only is the same", compare(repo, live, "HEAD") == ([], []))
        write(os.path.join(live, "b.py"), b"print(2)\n")
        write(os.path.join(live, "live-only.ps1"), b"x\n")
        write(os.path.join(live, "rotator.local.json"), b"{}\n")
        check("content difference -> exit 1", cmd_check(repo, live, "HEAD", state, True) == 1)
        d, m = compare(repo, live, "HEAD")
        check("only b.py differs; live-only and *.local.* ignored", d == ["b.py"] and m == [])
        st = load_json(state)
        check("state file written", st["differing"] == ["b.py"] and st["ref"].startswith("HEAD ") and st["checked"] > 0)
        os.remove(os.path.join(live, "fixtures", "f.json"))
        check("missing-live inside a subfolder", compare(repo, live, "HEAD") == (["b.py"], ["fixtures/f.json"]))

        write(os.path.join(live, "a.ps1"), b"one\nTWO\n")
        # --pull gets the repo bytes before it touches a live file: a git failure leaves the live script whole
        real_rb, seen = repo_bytes, []

        def failing_rb(repo_, ref_, rel_):
            seen.append(rel_)
            if rel_ == "b.py" and seen.count("b.py") > 1:      # compare() reads it once; the pull's own read fails
                raise SystemExit("git show failed")
            return real_rb(repo_, ref_, rel_)
        globals()["repo_bytes"] = failing_rb
        try:
            try:
                cmd_pull(repo, live, "HEAD", state)
            except SystemExit:
                pass
        finally:
            globals()["repo_bytes"] = real_rb
        with open(os.path.join(live, "b.py"), "rb") as fh:
            check("a failed pull leaves the live file intact", fh.read() == b"print(2)\n")
        check("a failed pull leaves no temp file", not any(n.endswith(".tmp-sync") for n in os.listdir(live)))

        # --pull is all or nothing: a swap failing part-way puts back every file already swapped and removes the ones it added
        before_ = {n: open(os.path.join(live, n), "rb").read() for n in ("a.ps1", "b.py", "c.ps1")}
        os.remove(os.path.join(live, "missing.txt"))
        real_replace, swaps = os.replace, []

        def failing_replace(src, dst):
            if str(src).endswith(".tmp-sync"):
                swaps.append(dst)
                if len(swaps) == 3:
                    raise PermissionError("in use")
            return real_replace(src, dst)
        os.replace = failing_replace
        try:
            rc_ = cmd_pull(repo, live, "HEAD", state)
        except OSError:
            rc_ = "raised"
        finally:
            os.replace = real_replace
        check("a failed swap reports failure", rc_ == 1 and len(swaps) == 3)
        check("... and live is exactly as before", {n: open(os.path.join(live, n), "rb").read() for n in before_} == before_
              and not os.path.exists(os.path.join(live, "missing.txt")) and not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        for n in os.listdir(live):
            if ".bak-sync-" in n:
                os.remove(os.path.join(live, n))

        # --pull: live is overwritten from the ref, each overwritten file backed up, local files untouched
        cmd_pull(repo, live, "HEAD", state)
        names = os.listdir(live)
        check("pull restored the files", compare(repo, live, "HEAD") == ([], []))
        check("pull backed up what it overwrote", sum(n.startswith("b.py.bak-sync-") for n in names) == 1
              and sum(n.startswith("a.ps1.bak-sync-") for n in names) == 1)
        check("pull left live-only and local files", "live-only.ps1" in names and "rotator.local.json" in names)
        check("state reset after pull", load_json(state)["differing"] == [])

        # the ref is resolved once: a fetch moving it mid-pull does not change what --pull installs
        write(os.path.join(live, "b.py"), b"print(3)\n")
        real_git, real_compare, real_rb, moved = git, compare, repo_bytes, []

        def move(rel, data):        # another process's fetch lands a new upstream commit
            write(os.path.join(repo, "windows", rel), data)
            real_git(repo, "add", "--", "windows/" + rel)
            real_git(repo, "commit", "-q", "-m", "moved")
            moved.append(real_git(repo, "rev-parse", "HEAD").stdout.decode().strip())

        def racing_compare(*a):
            out = real_compare(*a)
            globals()["repo_bytes"] = racing_rb
            return out

        def racing_rb(*a):
            globals()["repo_bytes"] = real_rb
            move("b.py", b"print(9)\n")             # a file this pull is replacing
            return real_rb(*a)

        before = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
        globals()["compare"] = racing_compare
        try:
            cmd_pull(repo, live, "HEAD", state)
        finally:
            globals().update(compare=real_compare, repo_bytes=real_rb)
        check("a fetch mid-pull: live is exactly the commit it resolved", len(moved) == 1 and compare(repo, live, before) == ([], []))
        # state updates are locked read-modify-writes through a temp file of their own: an overlapping --check keeps what another run wrote
        os.mkdir(state + ".tmp")                     # the old shared temp name, taken: a write must not depend on it
        check("state written past a taken .tmp name", cmd_check(repo, live, "HEAD", state, True) in (0, 1) and load_json(state)["checked"] > 0)
        import threading
        held = threading.Event()

        def fetch_side():                            # another run: reads the state under the lock, then writes `fetched` a moment later
            with state_lock(state):
                st_ = load_json(state)
                held.set()
                time.sleep(0.4)
                st_["fetched"] = 12345
                write_state(state, st_)
        st0 = load_json(state)
        st0.update(checked=0, ref="old")
        write_state(state, st0)
        th = threading.Thread(target=fetch_side)
        th.start()
        held.wait(5)
        record(repo, live, "HEAD", state)            # the dashboard's --check meanwhile
        th.join()
        st = load_json(state)
        check("an overlapping --check neither loses the other run's write nor its own result", st["fetched"] == 12345 and st["checked"] > 0 and st["ref"].startswith("HEAD "))
        # Idle priority: from Normal, this script lowers itself; the profile's rotator-sync function starts it at Idle and its shell
        # goes back to its own priority afterwards (a copy of the function runs a stand-in script that prints its own class)
        if os.name == "nt":
            probe = "import ctypes as c; k = c.WinDLL('kernel32'); k.GetCurrentProcess.restype = c.c_void_p; k.GetPriorityClass.argtypes = (c.c_void_p,); print(k.GetPriorityClass(k.GetCurrentProcess()))"
            r = subprocess.run([sys.executable, "-c", "import importlib.util as u, sys; s = u.spec_from_file_location('rs', sys.argv[1]); m = u.module_from_spec(s); "
                                "s.loader.exec_module(m); m.lower_priority(); " + probe.replace("import ctypes as c; ", "import ctypes as c; "), os.path.abspath(__file__)],
                               capture_output=True, creationflags=0x20, timeout=60)           # NORMAL_PRIORITY_CLASS: Idle below is lower_priority's doing
            check("rotator-sync lowers itself to Idle", r.stdout.split()[-1:] == [b"64"])
            fdir = os.path.join(root, "fn")
            os.makedirs(fdir)
            shutil.copy2(os.path.join(HERE, "rotator-functions.ps1"), fdir)
            write(os.path.join(fdir, "rotator-sync.py"), ("import sys\n" + probe.replace("; ", "\n") + "\nprint('|'.join(sys.argv[1:]))\n").encode())
            ps = ("(Get-Process -Id $PID).PriorityClass = 'Normal'; . '%s'; rotator-sync --check 'a b'; "
                  "'shell:' + (Get-Process -Id $PID).PriorityClass" % os.path.join(fdir, "rotator-functions.ps1"))
            r = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True, timeout=120)
            out = r.stdout.decode("utf-8", "replace").split()
            check("the rotator-sync function starts it at Idle and keeps its arguments, and its shell goes back", out[:1] == ["64"]
                  and "--check|a b" in r.stdout.decode("utf-8", "replace") and out[-1:] == ["shell:Normal"])
    finally:
        rmtree(root)
    print("rotator-sync selftest: all passed")
    return 0


def lower_priority():
    """This process at Idle CPU priority on Windows, before any work: git and every other child inherit it."""
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        k = ctypes.WinDLL("kernel32")
        k.GetCurrentProcess.restype = wintypes.HANDLE
        k.SetPriorityClass.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        k.SetPriorityClass(k.GetCurrentProcess(), 0x40)


def main(argv=None):
    lower_priority()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--pull", action="store_true")
    g.add_argument("--selftest", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="with --check: print nothing")
    ap.add_argument("--repo", help="local clone of the repo (default: repoClone in rotator.local.json)")
    ap.add_argument("--live", help="the rotator folder (default: liveDir in rotator.local.json, else this script's folder)")
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--state", default=DEFAULT_STATE, help="drift state file")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    cfg = load_json(os.path.join(HERE, "rotator.local.json"))
    repo = a.repo or cfg.get("repoClone")
    if not repo:
        raise SystemExit("rotator-sync: no clone: set repoClone in rotator.local.json or pass --repo")
    live = a.live or cfg.get("liveDir") or HERE
    if a.check:
        return cmd_check(repo, live, a.ref, a.state, a.quiet)
    return cmd_pull(repo, live, a.ref, a.state)


if __name__ == "__main__":
    sys.exit(main())
