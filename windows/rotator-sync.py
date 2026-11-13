#!/usr/bin/env python3
"""rotator-sync: keep the running rotator folder identical to this repo's windows/ folder.

  --check [--quiet]   compare every file under windows/ at the ref with the live folder
  --pull              copy differing / missing files from the ref into the live folder (backs up first)
  --push <branch>     commit the live files changed since the commit --pull installed, onto a new worktree of the
                      freshly fetched ref; refuses (and names the files) when the ref also changed one of them
  --selftest          run the built-in checks

Config (rotator.local.json next to this script, all keys optional):
  repoClone  path of a local clone of the repo        (or pass --repo)
  liveDir    folder the rotator runs from             (default: the folder this script is in)
Python standard library only. Never pushes and never opens a PR.
"""
import argparse
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
    st = load_json(state)
    st["fetched"] = int(time.time())
    write_state(state, st)


def write_state(state, data):
    os.makedirs(os.path.dirname(state) or ".", exist_ok=True)
    tmp = state + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, state)


def resolve(repo, ref):
    """The commit `ref` names now. Pull and push resolve it once, after fetching, so a fetch running meanwhile cannot move what they compare and write."""
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").stdout.decode().strip()


def record(repo, live, ref, state, at=None):
    """Compare live with `at` (a resolved commit; default `ref`) and write the drift state, labelled with `ref`."""
    differing, missing = compare(repo, live, at or ref)
    sha = git(repo, "rev-parse", "--short", at or ref).stdout.decode().strip()
    st = load_json(state)
    st.update({"checked": int(time.time()), "ref": "%s %s" % (ref, sha), "differing": sorted(differing + missing), "missingLive": missing})
    write_state(state, st)
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
    for rel in differing + missing:
        dest = os.path.join(live, *rel.split("/"))
        data = repo_bytes(repo, at, rel)        # first: a git failure must not leave a truncated live script
        if rel in differing:
            shutil.copy2(dest, "%s.bak-sync-%s" % (dest, stamp))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".tmp-sync"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, dest)
        print("%s %s" % ("added   " if rel in missing else "replaced", rel))
    if not (differing or missing):
        print("rotator-sync: nothing to pull, live already matches the ref")
    record(repo, live, ref, state, at)
    st = load_json(state)
    st["installed"] = at        # --push exports changes relative to this
    write_state(state, st)
    return 0


def match_style(live_bytes, repo_bytes_):
    """Give the live bytes the repo file's line endings and BOM, so a push diff shows only the real change."""
    body = live_bytes[len(BOM):] if live_bytes.startswith(BOM) else live_bytes
    body = body.replace(b"\r\n", b"\n")
    if b"\r\n" in repo_bytes_:
        body = body.replace(b"\n", b"\r\n")
    return (BOM if repo_bytes_.startswith(BOM) else b"") + body


def cmd_push(repo, live, ref, state, branch, worktree):
    """Export only what was changed live since the installed commit, onto the freshly fetched ref, so a hotfix to one
    file never carries a rollback of the ref's newer change to another."""
    base = load_json(state).get("installed")
    if not base or git(repo, "cat-file", "-e", base + "^{commit}", check=False).returncode:
        sys.stderr.write("rotator-sync: no installed commit recorded (or it is not in the clone): run --pull first\n")
        return 2
    maybe_fetch(repo, ref, state, force=True)
    at = resolve(repo, ref)
    changed, clash = [], []
    for rel in sorted(repo_files(repo, base)):
        path = os.path.join(live, *rel.split("/"))
        if not os.path.isfile(path):
            continue        # shortcut: a file deleted live is not exported; delete it in the repo by hand
        with open(path, "rb") as fh:
            if norm(fh.read()) == norm(repo_bytes(repo, base, rel)):
                continue
        changed.append(rel)
        up = git(repo, "show", "%s:%s%s" % (at, PREFIX, rel), check=False)
        if up.returncode or norm(up.stdout) != norm(repo_bytes(repo, base, rel)):
            clash.append(rel)
    if not changed:
        print("rotator-sync: no live file changed since the installed commit %s, nothing to push" % base[:9])
        return 0
    if clash:
        sys.stderr.write("rotator-sync: refusing to push: %s also changed since the installed commit %s:\n" % ("%s (%s)" % (ref, at[:9]), base[:9]))
        for rel in clash:
            sys.stderr.write("  both changed: %s\n" % rel)
        return 1
    if not worktree:
        root = r"C:\Dev\Temp" if os.path.isdir(r"C:\Dev\Temp") else tempfile.gettempdir()
        worktree = os.path.join(root, "wt-rotator-push-" + branch.replace("/", "-"))
    git(repo, "worktree", "add", "-b", branch, worktree, at)
    for rel in changed:
        with open(os.path.join(live, *rel.split("/")), "rb") as fh:
            data = match_style(fh.read(), repo_bytes(repo, at, rel))
        with open(os.path.join(worktree, "windows", *rel.split("/")), "wb") as fh:
            fh.write(data)
    git(worktree, "add", "--", *["windows/" + r for r in changed])
    git(worktree, "commit", "-q", "-m", "Sync live changes: " + ", ".join(changed))
    print("committed %d file(s) on branch %s: %s" % (len(changed), branch, ", ".join(changed)))
    print("worktree: " + worktree)
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

        # --push needs the commit --pull installed: without one it refuses and creates nothing
        write(os.path.join(live, "a.ps1"), b"one\nTWO\n")
        wt = os.path.join(root, "wt-push")
        check("push before any pull is refused", cmd_push(repo, live, "HEAD", state, "hotfix", wt) == 2 and not os.path.exists(wt))

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

        # --pull: live is overwritten from the ref, each overwritten file backed up, local files untouched
        cmd_pull(repo, live, "HEAD", state)
        names = os.listdir(live)
        check("pull restored the files", compare(repo, live, "HEAD") == ([], []))
        check("pull backed up what it overwrote", sum(n.startswith("b.py.bak-sync-") for n in names) == 1
              and sum(n.startswith("a.ps1.bak-sync-") for n in names) == 1)
        check("pull left live-only and local files", "live-only.ps1" in names and "rotator.local.json" in names)
        check("state reset after pull", load_json(state)["differing"] == [])
        check("pull recorded the installed commit", load_json(state).get("installed") == git(repo, "rev-parse", "HEAD").stdout.decode().strip())

        # --push exports only what changed live since the installed commit, onto the ref as it is now
        write(os.path.join(repo, "windows", "a.ps1"), b"one\r\nthree\r\n")      # upstream changes a.ps1 after the install
        git(repo, "add", "--", "windows/a.ps1")
        git(repo, "commit", "-q", "-m", "upstream")
        write(os.path.join(live, "b.py"), b"print(3)\n")                         # live hotfixes, LF
        write(os.path.join(live, "c.ps1"), b"y\n")
        write(os.path.join(live, "a.ps1"), b"one\nlocal\n")
        check("a file changed both live and upstream is refused", cmd_push(repo, live, "HEAD", state, "clash", wt) == 1 and not os.path.exists(wt)
              and git(repo, "show-ref", "--verify", "--quiet", "refs/heads/clash", check=False).returncode != 0)
        write(os.path.join(live, "a.ps1"), b"one\r\ntwo\r\n")                    # back to what was installed
        before = git(repo, "rev-parse", "HEAD").stdout
        check("push exit 0", cmd_push(repo, live, "HEAD", state, "hotfix", wt) == 0)
        check("push leaves the clone's HEAD alone", git(repo, "rev-parse", "HEAD").stdout == before)
        check("push committed only the live changes, on the new branch", git(wt, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip() == b"hotfix"
              and git(wt, "show", "--name-only", "--format=", "HEAD").stdout.split() == [b"windows/b.py", b"windows/c.ps1"])
        with open(os.path.join(wt, "windows", "a.ps1"), "rb") as fh:
            check("upstream's newer a.ps1 is not rolled back", fh.read() == b"one\r\nthree\r\n")
        with open(os.path.join(wt, "windows", "c.ps1"), "rb") as fh:
            check("pushed CRLF file kept its CRLF", fh.read() == b"y\r\n")
        git(repo, "worktree", "remove", "--" + "force", wt)

        # the ref is resolved once per operation: a fetch moving it mid-pull or mid-push changes neither what --pull records nor the push's base
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
            move("missing.txt", b"moved\n")
            return real_rb(*a)

        def racing_git(repo_, *args, **kw):
            if args[:2] == ("worktree", "add"):
                move("a.ps1", b"one\r\nupstream two\r\n")
            return real_git(repo_, *args, **kw)
        before = git(repo, "rev-parse", "HEAD").stdout.decode().strip()
        globals()["compare"] = racing_compare
        try:
            cmd_pull(repo, live, "HEAD", state)
        finally:
            globals().update(compare=real_compare, repo_bytes=real_rb)
        check("a fetch mid-pull: the commit it installed is recorded", len(moved) == 1 and load_json(state)["installed"] == before
              and compare(repo, live, before) == ([], []))
        write(os.path.join(live, "a.ps1"), b"one\nhot\n")
        globals()["git"] = racing_git
        try:
            check("push exit 0", cmd_push(repo, live, "HEAD", state, "hotfix2", wt) == 0)
        finally:
            globals()["git"] = real_git
        check("a fetch mid-push: the branch is built on the commit it checked", len(moved) == 2
              and git(wt, "rev-parse", "HEAD~1").stdout.decode().strip() == moved[0])
        git(repo, "worktree", "remove", "--" + "force", wt)
    finally:
        rmtree(root)
    print("rotator-sync selftest: all passed")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--pull", action="store_true")
    g.add_argument("--push", metavar="BRANCH")
    g.add_argument("--selftest", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="with --check: print nothing")
    ap.add_argument("--repo", help="local clone of the repo (default: repoClone in rotator.local.json)")
    ap.add_argument("--live", help="the rotator folder (default: liveDir in rotator.local.json, else this script's folder)")
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--worktree", help="with --push: where to create the worktree")
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
    if a.pull:
        return cmd_pull(repo, live, a.ref, a.state)
    return cmd_push(repo, live, a.ref, a.state, a.push, a.worktree)


if __name__ == "__main__":
    sys.exit(main())
