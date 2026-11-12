#!/usr/bin/env python3
"""rotator-sync: keep the running rotator folder identical to this repo's windows/ folder.

  --check [--quiet]   compare every file under windows/ at the ref with the live folder
  --pull              copy differing / missing files from the ref into the live folder (backs up first)
  --push <branch>     copy differing live files into a new worktree of the clone and commit them there
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


def record(repo, live, ref, state):
    differing, missing = compare(repo, live, ref)
    sha = git(repo, "rev-parse", "--short", ref).stdout.decode().strip()
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
    differing, missing = compare(repo, live, ref)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for rel in differing + missing:
        dest = os.path.join(live, *rel.split("/"))
        if rel in differing:
            shutil.copy2(dest, "%s.bak-sync-%s" % (dest, stamp))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(repo_bytes(repo, ref, rel))
        print("%s %s" % ("added   " if rel in missing else "replaced", rel))
    if not (differing or missing):
        print("rotator-sync: nothing to pull, live already matches the ref")
    record(repo, live, ref, state)
    return 0


def match_style(live_bytes, repo_bytes_):
    """Give the live bytes the repo file's line endings and BOM, so a push diff shows only the real change."""
    body = live_bytes[len(BOM):] if live_bytes.startswith(BOM) else live_bytes
    body = body.replace(b"\r\n", b"\n")
    if b"\r\n" in repo_bytes_:
        body = body.replace(b"\n", b"\r\n")
    return (BOM if repo_bytes_.startswith(BOM) else b"") + body


def cmd_push(repo, live, ref, state, branch, worktree):
    differing, _ = compare(repo, live, ref)
    if not differing:
        print("rotator-sync: no differing live files, nothing to push")
        return 0
    if not worktree:
        base = r"C:\Dev\Temp" if os.path.isdir(r"C:\Dev\Temp") else tempfile.gettempdir()
        worktree = os.path.join(base, "wt-rotator-push-" + branch.replace("/", "-"))
    git(repo, "worktree", "add", "-b", branch, worktree, ref)
    for rel in differing:
        with open(os.path.join(live, *rel.split("/")), "rb") as fh:
            data = match_style(fh.read(), repo_bytes(repo, ref, rel))
        with open(os.path.join(worktree, "windows", *rel.split("/")), "wb") as fh:
            fh.write(data)
    git(worktree, "add", "--", *["windows/" + r for r in differing])
    git(worktree, "commit", "-q", "-m", "Sync live changes: " + ", ".join(differing))
    print("committed %d file(s) on branch %s: %s" % (len(differing), branch, ", ".join(differing)))
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
        files = {"a.ps1": b"one\r\ntwo\r\n", "b.py": b"print(1)\n", "fixtures/f.json": b"{}\n", "missing.txt": b"m\n"}
        for rel, data in files.items():
            write(os.path.join(repo, "windows", rel), data)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "init")
        for rel, data in files.items():
            if rel != "missing.txt":
                write(os.path.join(live, rel), data)

        def check(label, cond):
            print("  %s  %s" % ("ok  " if cond else "FAIL", label))
            if not cond:
                raise SystemExit(1)

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

        # --push: live b.py (LF) becomes a commit; a CRLF repo file keeps its CRLF
        write(os.path.join(live, "a.ps1"), b"one\nTWO\n")
        wt = os.path.join(root, "wt-push")
        before = git(repo, "rev-parse", "HEAD").stdout
        cmd_push(repo, live, "HEAD", state, "hotfix", wt)
        check("push leaves the clone's HEAD alone", git(repo, "rev-parse", "HEAD").stdout == before)
        check("push committed on the new branch", git(wt, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip() == b"hotfix"
              and git(wt, "show", "--name-only", "--format=", "HEAD").stdout.split() == [b"windows/a.ps1", b"windows/b.py"])
        with open(os.path.join(wt, "windows", "a.ps1"), "rb") as fh:
            check("pushed CRLF file kept its CRLF", fh.read() == b"one\r\nTWO\r\n")
        git(repo, "worktree", "remove", "--force", wt)

        # --pull: live is overwritten from the ref, each overwritten file backed up, local files untouched
        cmd_pull(repo, live, "HEAD", state)
        names = os.listdir(live)
        check("pull restored the files", compare(repo, live, "HEAD") == ([], []))
        check("pull backed up what it overwrote", sum(n.startswith("b.py.bak-sync-") for n in names) == 1
              and sum(n.startswith("a.ps1.bak-sync-") for n in names) == 1)
        check("pull left live-only and local files", "live-only.ps1" in names and "rotator.local.json" in names)
        check("state reset after pull", load_json(state)["differing"] == [])
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
