#!/usr/bin/env python3
"""rotator-sync: keep the running rotator folder identical to this repo's windows/ folder.

  --check [--quiet]   compare every file under windows/ at the ref with the live folder
  --pull              copy differing / missing files from the ref into the live folder (backs up first)
  --selftest          run the built-in checks

Config (rotator.local.json next to this script, all keys optional):
  repoClone  path of a local clone of the repo        (or pass --repo)
  liveDir    folder the rotator runs from             (default: the folder this script is in)
Run from inside the clone itself (liveDir in the clone), there is nothing to sync: --pull is refused and --check reports no drift; `git pull` is the update there.
Python standard library only. It only ever reads the clone: it never commits, pushes or opens a PR.
"""
import argparse
import contextlib
import fnmatch
import io
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
            fh.flush()
            os.fsync(fh.fileno())                      # a power cut after the replace must not leave an empty journal or state
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


def roll_back(plan):
    """Put back every file of a pull's plan [(dest, backup or None)] that was swapped (its .tmp-sync is gone): a replaced one from its backup,
    which only exists once complete (written as .part, then renamed), an added one removed. A file not swapped is left as it is, so a backup
    that died half-written never lands on an intact live file. Two passes, because the .tmp-sync files are the only record of which swaps happened and a
    rollback killed part-way must leave that record whole: pass 1 reads it for EVERY file before it changes any, then restores (copying a backup again, or
    removing an already-removed added file, is harmless, so a second run finishes what a killed one began); pass 2, once all of them are restored, removes the
    .tmp-sync and .part leftovers. -> (how many were put back, the paths that could not be)."""
    done, bad = 0, []
    swapped = [not os.path.exists(dest + ".tmp-sync") for dest, _ in plan]   # all decided before the first restore
    for (dest, bak), was_swapped in reversed(list(zip(plan, swapped))):
        try:
            if was_swapped and bak and os.path.exists(bak):
                shutil.copy2(bak, dest)
                done += 1
            elif was_swapped and not bak and os.path.exists(dest):
                os.remove(dest)
                done += 1
        except OSError:
            bad.append(dest)
    for dest, bak in plan:
        for junk in (bak and bak + ".part", dest + ".tmp-sync"):   # .part first: the .tmp-sync is the record, so it goes last; an added file has no backup (bak None)
            if junk:
                with contextlib.suppress(OSError):
                    os.remove(junk)
    return done, bad


def journal_files(j):
    """The journal's plan (its "files" list), or None when the journal could not be read or is not one (a lock, a crash mid-write before fsync)."""
    f = j.get("files") if isinstance(j, dict) else None
    return f if isinstance(f, list) else None


def update_finished(j):
    """True when no planned file of the journal's pull still has its .tmp-sync. A .tmp-sync goes away when its file is swapped in, and a rollback removes the
    leftovers only after it has restored every file, so none left means either every swap happened (the journal outlived the pull: its delete failed) or a
    rollback already put everything back. A pull killed before its first swap, or part-way through them, still has .tmp-sync files: not finished, rolled back.
    A journal with no readable plan is never "finished" (roll_back_journal leaves it in place)."""
    plan = journal_files(j)
    if plan is None:
        return False
    return not any(isinstance(e, list) and e and isinstance(e[0], str) and os.path.exists(e[0] + ".tmp-sync") for e in plan)


def roll_back_journal(jpath):
    """Roll back the journal at `jpath` and delete it (a delete that fails leaves it, with a warning). The caller holds the journal's lock. -> (put back, could not), or None when there is none, when every swap
    happened (no planned .tmp-sync is left: it is only deleted, nothing is restored), or when it cannot be read (left in place, with a warning: --pull stops on it)."""
    if not os.path.exists(jpath):
        return None                                     # the pull finished meanwhile and took its journal away
    j = load_json(jpath)
    if journal_files(j) is None:         # unreadable: no plan to judge the swaps by, so neither "finished" nor a rollback; --pull stops on it
        sys.stderr.write("rotator-sync: the update journal %s cannot be read just now (it may be held for a moment: try again); left in place."
                         " If it stays unreadable, check the live files, delete it by hand, then run --pull\n" % jpath)
        return None
    if update_finished(j):
        drop_journal(jpath)
        return None
    res = roll_back([tuple(e) for e in j.get("files") or []])
    drop_journal(jpath)                                 # one that cannot be deleted stays, with a warning; --pull checks for it
    return res


def drop_journal(jpath, tries=3, pause=0.2):
    """Delete a pull's journal, trying `tries` times (a Windows handle without share-delete is usually gone a moment later); one that still cannot be deleted is
    warned about, never an error (an update that is already in place must still report success)."""
    for n in range(tries):
        try:
            os.remove(jpath)
            return
        except FileNotFoundError:
            return
        except OSError as e:
            err = e
            if n + 1 < tries:
                time.sleep(pause)
    sys.stderr.write("rotator-sync: warning: could not delete the update journal %s (%s: %s); delete it by hand, or the next --check deletes it, since no swap is left to undo\n"
                     % (jpath, type(err).__name__, err))


def say_recovered(res):
    if res:
        done, bad = res
        sys.stderr.write("rotator-sync: recovered an interrupted update: %d file(s) put back%s\n" % (done, "; restore by hand: " + ", ".join(bad) if bad else ""))


def recover(state):
    """A --pull that died mid-swap left its journal (<state>.pull-journal.json): put every file back and say so. Skipped while a pull holds
    the journal's lock, so a --check never undoes a pull that is still running. (--pull itself holds that lock for its whole run and calls
    roll_back_journal directly: the lock is not re-entrant, a second handle on it would always be refused.)"""
    jpath = state + ".pull-journal.json"
    if not os.path.exists(jpath):
        return
    try:
        with state_lock(jpath, wait=0):
            res = roll_back_journal(jpath)
    except TimeoutError:
        return
    say_recovered(res)


def cmd_check(repo, live, ref, state, quiet):
    recover(state)
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
    # ONE lock spans the whole pull -- recovery, fetch, staging, swap, cleanup -- and is taken without waiting. The staged copies have fixed
    # <dest>.tmp-sync names, so a second pull that staged before it learned of the first would overwrite, then delete, the first one's files
    # mid-install. A second pull therefore stops here, before it has written anything.
    jpath = state + ".pull-journal.json"
    lock = state_lock(jpath, wait=0)
    try:
        lock.__enter__()
    except TimeoutError:
        sys.stderr.write("rotator-sync: another update is running; nothing was changed\n")
        return 1
    try:
        return pull_locked(repo, live, ref, state, jpath)
    finally:
        lock.__exit__(None, None, None)


SERVER_FILE = "usage-history.py"                  # the dashboard's server code: a running server keeps the old version until it is restarted
PAGE_FILES = ("usage-dashboard.template.html", "usage-sim.js")      # re-read on every request: new as soon as they are replaced
DASHBOARD_TASK = "Claude usage dashboard"           # the logon task usage-app-install.ps1 registers
PROXY_FILES = ("claude-rotate-proxy.py", "rotator_access.py")   # the long-running proxy loads both at start
PROXY_TASK = "Claude rotate proxy"


def pull_locked(repo, live, ref, state, jpath):
    say_recovered(roll_back_journal(jpath))
    if os.path.exists(jpath) and journal_files(load_json(jpath)) is None:
        sys.stderr.write("rotator-sync: the earlier update's journal %s cannot be read, so nothing was changed (see above)\n" % jpath)
        return 1
    if os.path.exists(jpath):                           # recovery could not delete it: staging would write a new journal over it
        sys.stderr.write("rotator-sync: the earlier update's journal %s could not be deleted; delete it by hand once nothing holds it, then run --pull again; nothing was changed\n" % jpath)
        return 1
    maybe_fetch(repo, ref, state, force=True)
    at = resolve(repo, ref)
    differing, missing = compare(repo, live, at)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    # All or nothing: a half-applied update (a script replaced before the new file it imports arrives) cannot start. So every new
    # version is read and written to a .tmp-sync sibling first, touching nothing live; only then is each one swapped in, after a
    # backup, and any failure puts back every file already swapped (and removes the ones added) before it is reported. Added files go in first,
    # so a new file a changed one imports is there before it; the plan is journaled before the first swap, so a killed pull is rolled back
    # by the next --pull or --check.
    for dirpath, _, names in os.walk(live):             # a killed run's leftover staged copies; this pull holds the journal's lock, so none belongs to a running one
        for n in names:
            if n.endswith(".tmp-sync"):
                with contextlib.suppress(OSError):
                    os.remove(os.path.join(dirpath, n))
    staged = []
    try:
        for rel in missing + differing:
            dest = os.path.join(live, *rel.split("/"))
            data = repo_bytes(repo, at, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest + ".tmp-sync", "wb") as fh:
                fh.write(data)
            staged.append((rel, dest))
    except BaseException:
        for rel in missing + differing:                 # the ones staged, and the one that failed half-written
            with contextlib.suppress(OSError):
                os.remove(os.path.join(live, *rel.split("/")) + ".tmp-sync")
        raise
    plan = [(dest, "%s.bak-sync-%s" % (dest, stamp) if rel in differing else None) for rel, dest in staged]
    if plan:
        write_state(jpath, {"files": plan})
    try:
        for dest, bak in plan:
            if bak:
                shutil.copy2(dest, bak + ".part")
                os.replace(bak + ".part", bak)          # a backup exists only once it is complete
            os.replace(dest + ".tmp-sync", dest)
        err = None
    except OSError as e:
        err, (_, bad) = e, roll_back(plan)
    drop_journal(jpath)                                 # a delete that fails is a warning: with no .tmp-sync left, recovery only deletes the journal
    if err:
        e = err
        sys.stderr.write("rotator-sync: the update failed (%s: %s); %s\n" % (type(e).__name__, e, "every file was put back as it was" if not bad else
                         "these could not be put back, restore them from their .bak-sync-%s copies: %s" % (stamp, ", ".join(bad))))
        record(repo, live, ref, state, at)
        return 1
    for rel, _ in staged:
        print("%s %s" % ("added   " if rel in missing else "replaced", rel))
    if not (differing or missing):
        print("rotator-sync: nothing to pull, live already matches the ref")
    if any(rel == SERVER_FILE for rel, _ in staged):
        print("rotator-sync: the usage dashboard's files changed; the page is already the new one, but the running server is still the old code: restart it now so the two match "
              "(Task Scheduler task \"%s\", or: Stop-ScheduledTask / Start-ScheduledTask -TaskName '%s'), and reload any open dashboard windows" % (DASHBOARD_TASK, DASHBOARD_TASK))
    elif any(rel in PAGE_FILES for rel, _ in staged):
        print("rotator-sync: the usage dashboard's page is updated (reload any open dashboard windows); if usage-history.py changed in an earlier pull and the dashboard "
              "was not restarted since, restart it (Task Scheduler task \"%s\")" % DASHBOARD_TASK)
    if any(rel in PROXY_FILES for rel, _ in staged):
        # the rotate proxy imported rotator_access.py at start; its task relaunches it within a minute once it is stopped
        print("rotator-sync: the rotate proxy's files changed; stop the running proxy (Task Scheduler task \"%s\") and it is "
              "relaunched with the new code within a minute" % PROXY_TASK)
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

        check("added files go in before changed ones", [os.path.basename(x) for x in swaps[:2]] == ["f.json", "missing.txt"])
        # a pull killed mid-swap leaves its journal: the next --check rolls everything back and says so
        swaps.clear()

        def killing_replace(src, dst):
            if str(src).endswith(".tmp-sync"):
                swaps.append(dst)
                if len(swaps) == 3:
                    raise KeyboardInterrupt
            return real_replace(src, dst)
        os.replace = killing_replace
        try:
            cmd_pull(repo, live, "HEAD", state)
        except KeyboardInterrupt:
            pass
        finally:
            os.replace = real_replace
        check("a killed pull leaves its journal and a half-applied live", os.path.exists(state + ".pull-journal.json") and os.path.exists(os.path.join(live, "missing.txt")))
        # a backup that died half-written never lands on an intact live file: only a swapped entry (no .tmp-sync left) is put back
        rb = os.path.join(root, "rb")
        os.makedirs(rb)
        for name, part, final in (("p.py", True, False), ("q.py", False, True)):
            write(os.path.join(rb, name), b"A" * 1000)
            write(os.path.join(rb, name + ".tmp-sync"), b"new")                # not swapped yet
            if part:
                write(os.path.join(rb, name + ".bak-sync-X.part"), b"A" * 300)  # the backup copy died at 300 bytes
            if final:
                write(os.path.join(rb, name + ".bak-sync-X"), b"A" * 300)       # a truncated backup under its final name (the old copy)
        got_ = roll_back([(os.path.join(rb, n), os.path.join(rb, n + ".bak-sync-X")) for n in ("p.py", "q.py")])
        check("an unswapped entry is left intact, its temps removed, and not counted",
              got_ == (0, []) and all(os.path.getsize(os.path.join(rb, n)) == 1000 for n in ("p.py", "q.py")) and sorted(os.listdir(rb)) == ["p.py", "q.py", "q.py.bak-sync-X"])
        import threading
        held_, go_ = threading.Event(), threading.Event()

        def holder_():
            with state_lock(state + ".pull-journal.json"):
                held_.set()
                go_.wait(5)
        th_ = threading.Thread(target=holder_)
        th_.start()
        held_.wait(5)
        recover(state)
        go_.set()
        th_.join()
        check("a running pull's journal is left alone", os.path.exists(state + ".pull-journal.json"))
        cmd_check(repo, live, "HEAD", state, True)
        check("the next --check rolls the interrupted update back", not os.path.exists(state + ".pull-journal.json")
              and {n: open(os.path.join(live, n), "rb").read() for n in before_} == before_ and not os.path.exists(os.path.join(live, "missing.txt"))
              and not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        # a journal that vanishes as recovery takes the lock (its pull just finished) is no error; a pull that cannot get the journal's lock
        # (another pull) stops with nothing changed and its staged copies removed
        real_lock, jp_ = state_lock, state + ".pull-journal.json"
        write_state(jp_, {"files": []})

        @contextlib.contextmanager
        def vanishing(path, wait=30):
            with real_lock(path, wait):
                with contextlib.suppress(OSError):
                    os.remove(jp_)
                yield
        globals()["state_lock"] = vanishing
        try:
            recover(state)
            ok_ = True
        except Exception:
            ok_ = False
        finally:
            globals()["state_lock"] = real_lock
        check("a journal that vanishes under the lock is no error", ok_)
        write(os.path.join(live, "b.py"), b"print(5)\n")
        held_, go_ = threading.Event(), threading.Event()
        th_ = threading.Thread(target=holder_)
        th_.start()
        held_.wait(5)
        write(os.path.join(live, "b.py.tmp-sync"), b"the first pull's staged copy")     # what the running pull has staged, under the fixed name
        globals()["state_lock"] = lambda path, wait=30: real_lock(path, 0.3 if path == jp_ else wait)
        try:
            rc_ = cmd_pull(repo, live, "HEAD", state)
        finally:
            globals()["state_lock"] = real_lock
            go_.set()
            th_.join()
        # the lock is taken before anything is staged: the blocked pull must not overwrite or delete the first pull's staged file
        check("a pull blocked by another pull does not touch the running pull's staged copies",
              rc_ == 1 and open(os.path.join(live, "b.py.tmp-sync"), "rb").read() == b"the first pull's staged copy")
        os.remove(os.path.join(live, "b.py.tmp-sync"))
        check("a pull blocked by another pull changes nothing and leaves no temp", rc_ == 1 and open(os.path.join(live, "b.py"), "rb").read() == b"print(5)\n"
              and not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        # an unreadable journal is neither treated as finished nor rolled back: it is left, and a --pull stops on it
        with open(jp_, "wb") as fh_:
            fh_.write(b"")
        check("an unreadable journal is left in place, not deleted as finished", roll_back_journal(jp_) is None and os.path.exists(jp_))
        check("... and a --pull stops on it", cmd_pull(repo, live, "HEAD", state) == 1 and os.path.exists(jp_))
        os.remove(jp_)
        # a stale journal is rolled back by a --pull itself, under the lock that pull already holds (the lock is not re-entrant)
        write(os.path.join(live, "stale-added.txt"), b"added by a killed pull\n")
        write_state(jp_, {"files": [[os.path.join(live, "stale-added.txt"), None], [os.path.join(live, "pending.txt"), None]]})   # the second was never swapped
        write(os.path.join(live, "pending.txt.tmp-sync"), b"staged by the killed pull\n")
        write(os.path.join(live, "orphan.txt.tmp-sync"), b"left by a pull killed while staging (no journal names it)\n")
        write(os.path.join(live, "b.py"), before_["b.py"])
        for n in os.listdir(live):
            if ".bak-sync-" in n:
                os.remove(os.path.join(live, n))

        # --pull: live is overwritten from the ref, each overwritten file backed up, local files untouched
        cmd_pull(repo, live, "HEAD", state)
        names = os.listdir(live)
        check("pull restored the files", compare(repo, live, "HEAD") == ([], []))
        check("a pull rolls back a stale journal first (and does not deadlock on its own lock)",
              not os.path.exists(os.path.join(live, "stale-added.txt")) and not os.path.exists(jp_))
        check("... and a pull removes the staged copies a killed run left, named by a journal or not",
              not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        check("pull backed up what it overwrote", sum(n.startswith("b.py.bak-sync-") for n in names) == 1
              and sum(n.startswith("a.ps1.bak-sync-") for n in names) == 1)
        check("pull left live-only and local files", "live-only.ps1" in names and "rotator.local.json" in names)
        check("state reset after pull", load_json(state)["differing"] == [])
        # a pull whose every swap succeeded but whose journal can be neither deleted nor rewritten (os.remove and os.replace on it both fail, as a Windows handle without
        # share-delete makes them): the delete is retried, then a warning, exit 0; the next --check sees that no planned file still has its .tmp-sync (every swap happened)
        write(os.path.join(live, "b.py"), b"a local edit\n")
        real_remove, real_replace2, removes_ = os.remove, os.replace, []

        def stuck_remove(path, *a, **kw):
            if path == jp_:
                removes_.append(path)
                raise PermissionError("in use")
            return real_remove(path, *a, **kw)

        def stuck_replace(src, dst, *a, **kw):
            if dst == jp_ and os.path.exists(jp_):          # the journal's first write goes through; a rewrite of it would not
                raise PermissionError("in use")
            return real_replace2(src, dst, *a, **kw)
        os.remove, os.replace = stuck_remove, stuck_replace
        buf = io.StringIO()
        try:
            with contextlib.redirect_stderr(buf), contextlib.redirect_stdout(io.StringIO()):
                rc_j = cmd_pull(repo, live, "HEAD", state)
        finally:
            os.remove, os.replace = real_remove, real_replace2
        check("a journal that cannot be deleted after a successful pull is a warning, not a failure, and the delete was retried",
              rc_j == 0 and "warning: could not delete the update journal" in buf.getvalue() and compare(repo, live, "HEAD") == ([], []) and len(removes_) == 3)
        check("... and the warning ends with what happens to the journal", buf.getvalue().rstrip().endswith("the next --check deletes it, since no swap is left to undo")
              and os.path.exists(jp_) and load_json(jp_).get("files") and not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        write(os.path.join(live, "b.py"), b"the user edited this after the pull\n")       # so "is the file still the new content?" is the wrong question
        live_before_ = {n: open(os.path.join(live, n), "rb").read() for n in os.listdir(live) if os.path.isfile(os.path.join(live, n))}
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            recover(state)
        check("the next --check deletes that journal, restores nothing and keeps the user's edit", not os.path.exists(jp_) and buf.getvalue() == ""
              and {n: open(os.path.join(live, n), "rb").read() for n in os.listdir(live) if os.path.isfile(os.path.join(live, n))} == live_before_)
        # a journal that recovery cannot delete stops the next --pull before it stages anything (a new journal would be written over it)
        write_state(jp_, {"files": [[os.path.join(live, "b.py"), None]]})
        live_before_ = {n: open(os.path.join(live, n), "rb").read() for n in os.listdir(live) if os.path.isfile(os.path.join(live, n))}
        os.remove, os.replace = stuck_remove, real_replace2
        buf = io.StringIO()
        try:
            with contextlib.redirect_stderr(buf), contextlib.redirect_stdout(io.StringIO()):
                rc_j = cmd_pull(repo, live, "HEAD", state)
        finally:
            os.remove = real_remove
        check("a --pull whose old journal cannot be deleted stops before staging, names the journal, and exits 1",
              rc_j == 1 and jp_ in buf.getvalue() and "delete it by hand" in buf.getvalue() and os.path.exists(jp_)
              and {n: open(os.path.join(live, n), "rb").read() for n in os.listdir(live) if os.path.isfile(os.path.join(live, n))} == live_before_)
        os.remove(jp_)
        # a planned file still staged means that swap did not happen: rolled back (a journal an older version wrote, which also recorded hashes, is judged the same way)
        write_state(jp_, {"files": [[os.path.join(live, "stale-added.txt"), None], [os.path.join(live, "pending.txt"), None]]})
        write(os.path.join(live, "stale-added.txt"), b"x\n")
        write(os.path.join(live, "pending.txt.tmp-sync"), b"staged\n")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            recover(state)
        check("... while a journal with a planned file still staged is rolled back", not os.path.exists(jp_) and not os.path.exists(os.path.join(live, "stale-added.txt"))
              and not os.path.exists(os.path.join(live, "pending.txt.tmp-sync")) and "recovered an interrupted update" in buf.getvalue())
        # a pull killed before its first swap: every planned file is still staged, so none is touched and the temps and journal go
        write(os.path.join(live, "b.py"), b"print(7)\n")
        swaps.clear()

        def killing_first(src, dst, *a, **kw):
            if str(src).endswith(".tmp-sync"):
                swaps.append(dst)
                raise KeyboardInterrupt
            return real_replace(src, dst, *a, **kw)
        os.replace = killing_first
        try:
            cmd_pull(repo, live, "HEAD", state)
        except KeyboardInterrupt:
            pass
        finally:
            os.replace = real_replace
        check("a pull killed before its first swap leaves its journal and its staged copies", os.path.exists(jp_) and len(swaps) == 1
              and sum(n.endswith(".tmp-sync") for n in os.listdir(live)) >= 1 and open(os.path.join(live, "b.py"), "rb").read() == b"print(7)\n")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            recover(state)
        check("... and recovery rolls it back: the live file is untouched, temps and journal gone",
              not os.path.exists(jp_) and open(os.path.join(live, "b.py"), "rb").read() == b"print(7)\n" and not any(n.endswith(".tmp-sync") for n in os.listdir(live)))
        for n in os.listdir(live):
            if ".bak-sync-" in n:
                os.remove(os.path.join(live, n))
        # a recovery killed part-way through its own rollback: the .tmp-sync files are the record of which swaps happened, so they must outlive the restores
        kr = os.path.join(root, "killed-rollback")
        st_k = os.path.join(kr, "state.json")
        jp_k = st_k + ".pull-journal.json"
        k_files = [os.path.join(kr, n) for n in ("f1.py", "f2.py", "f3.py")]
        k_plan = []
        for f_ in k_files:
            write(f_, b"OLD")
            write(f_ + ".tmp-sync", b"NEW")
            k_plan.append((f_, f_ + ".bak-sync-X"))
        write_state(jp_k, {"files": k_plan})
        for f_, bak_ in k_plan[:2]:                         # f1 and f2 swapped; f3's swap never happened
            shutil.copy2(f_, bak_)
            os.replace(f_ + ".tmp-sync", f_)
        real_copy, copies_ = shutil.copy2, []

        def killing_copy(src, dst, *a, **kw):
            copies_.append(dst)
            if len(copies_) == 2:                           # recovery restores f2, then dies before f1
                raise KeyboardInterrupt
            return real_copy(src, dst, *a, **kw)
        shutil.copy2 = killing_copy
        try:
            recover(st_k)
        except KeyboardInterrupt:
            pass
        finally:
            shutil.copy2 = real_copy
        check("a recovery killed part-way keeps the journal and the record of what was swapped", os.path.exists(jp_k) and len(copies_) == 2
              and any(os.path.exists(f_ + ".tmp-sync") for f_ in k_files) and not update_finished(load_json(jp_k)))
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            recover(st_k)
        check("... and the next recovery finishes it: every file OLD, no temps, journal gone",
              not os.path.exists(jp_k) and all(open(f_, "rb").read() == b"OLD" for f_ in k_files)
              and not any(".tmp-sync" in n or n.endswith(".part") for n in os.listdir(kr)))

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
        # roll_back of an added file (backup None) must not remove a relative "None.part" from the working directory
        cwd_, nd = os.getcwd(), os.path.join(root, "nonepart")
        write(os.path.join(nd, "None.part"), b"unrelated")
        os.chdir(nd)
        try:
            roll_back([(os.path.join(nd, "added.txt"), None)])
        finally:
            os.chdir(cwd_)
        check("roll_back of an added file leaves an unrelated None.part alone", os.path.exists(os.path.join(nd, "None.part")))
        # running from inside the clone: --pull is refused, --check reports no drift
        check("the clone's own windows/ folder is inside the clone", inside_repo(os.path.join(repo, "windows"), repo) and inside_repo(repo, repo)
              and not inside_repo(live, repo) and not inside_repo(repo + "-other", repo))
        st_in = os.path.join(root, "in-state.json")
        write(os.path.join(repo, "windows", "b.py"), b"print(1)\n")        # the working tree differs from the committed b.py: not drift
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc_in = main(["--check", "--repo", repo, "--live", os.path.join(repo, "windows"), "--state", st_in])
        check("--check inside the clone says to use git pull and reports no drift", rc_in == 0 and "git pull" in buf.getvalue()
              and load_json(st_in)["differing"] == [])
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rc_in = main(["--pull", "--repo", repo, "--live", os.path.join(repo, "windows"), "--state", st_in])
        check("--pull inside the clone is refused and changes nothing", rc_in == 1 and "git pull" in buf.getvalue()
              and open(os.path.join(repo, "windows", "b.py"), "rb").read() == b"print(1)\n")
        # a pull that replaces a dashboard file says to restart the dashboard
        repo2, live2, st2 = (os.path.join(root, n) for n in ("repo2", "live2", "state2.json"))
        os.makedirs(repo2)
        git(repo2, "init", "-q")
        for k_, v_ in (("user.name", "Self Test"), ("user.email", "selftest@example.com"), ("commit.gpgsign", "false"), ("core.autocrlf", "false")):
            git(repo2, "config", k_, v_)
        write(os.path.join(repo2, "windows", "usage-history.py"), b"new\n")
        write(os.path.join(repo2, "windows", "other.ps1"), b"o\n")
        git(repo2, "add", "--", "windows/usage-history.py", "windows/other.ps1")
        git(repo2, "commit", "-q", "-m", "init")
        write(os.path.join(live2, "usage-history.py"), b"old\n")
        write(os.path.join(live2, "other.ps1"), b"o\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc_2 = cmd_pull(repo2, live2, "HEAD", st2)
        check("a pull that replaces usage-history.py names the dashboard task to restart", rc_2 == 0 and DASHBOARD_TASK in buf.getvalue())
        write(os.path.join(live2, "other.ps1"), b"changed\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cmd_pull(repo2, live2, "HEAD", st2)
        check("... and one that replaces only other files does not", "restart" not in buf.getvalue())
        # only the page (template / usage-sim.js) replaced: already live, no restart; the server file as well: restart
        write(os.path.join(repo2, "windows", "usage-dashboard.template.html"), b"t\n")
        write(os.path.join(repo2, "windows", "usage-sim.js"), b"s\n")
        git(repo2, "add", "--", "windows/usage-dashboard.template.html", "windows/usage-sim.js")
        git(repo2, "commit", "-q", "-m", "page")
        write(os.path.join(live2, "usage-dashboard.template.html"), b"old\n")
        write(os.path.join(live2, "usage-sim.js"), b"old\n")
        write(os.path.join(live2, "usage-history.py"), b"new\n")
        write(os.path.join(live2, "other.ps1"), b"o\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc_3 = cmd_pull(repo2, live2, "HEAD", st2)
        check("a pull that replaces only the page says to reload open windows, and to restart only if an earlier pull's usage-history.py was not yet restarted",
              rc_3 == 0 and "reload any open dashboard windows" in buf.getvalue() and "changed in an earlier pull" in buf.getvalue() and "restart it now" not in buf.getvalue())
        write(os.path.join(live2, "usage-dashboard.template.html"), b"old\n")
        write(os.path.join(live2, "usage-history.py"), b"old\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cmd_pull(repo2, live2, "HEAD", st2)
        check("... and one that replaces the server file too says to restart, and to reload open windows", "restart it now" in buf.getvalue() and "reload any open dashboard windows" in buf.getvalue()
              and "changed in an earlier pull" not in buf.getvalue())
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


def inside_repo(live, repo):
    """True when the live folder is the clone's own windows/ folder or anywhere else inside the clone (real paths, case-insensitively on Windows)."""
    def real(p):
        return os.path.normcase(os.path.realpath(p))
    try:
        return os.path.commonpath([real(live), real(repo)]) == real(repo)
    except ValueError:                                  # different drives
        return False


IN_REPO = "rotator-sync: %s is inside the clone %s, so there is nothing to sync: update it with `git pull` in the clone"


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
    if inside_repo(live, repo):
        # Running from the clone itself: the files ARE the clone's working tree, so comparing them with the ref would only report whatever
        # the checkout is behind or ahead by as an "update available", and --pull would overwrite the working tree. `git pull` is the update here.
        if a.check:
            update_state(a.state, lambda st: st.update({"checked": int(time.time()), "ref": "%s (in the clone)" % a.ref, "differing": [], "missingLive": []}))
        if not a.quiet or a.pull:
            (sys.stdout if a.check else sys.stderr).write((IN_REPO % (live, repo)) + "\n")
        return 0 if a.check else 1
    if a.check:
        return cmd_check(repo, live, a.ref, a.state, a.quiet)
    return cmd_pull(repo, live, a.ref, a.state)


if __name__ == "__main__":
    sys.exit(main())
