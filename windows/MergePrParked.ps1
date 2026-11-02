<#
MergePrParked.ps1 — dot-source for the "skip parked merge-pr reviews" logic used by
claude-resume-sessions.ps1 (owner ruling 2026-10-20, option A).

A merge-pr review that is PARKED is waiting on an owner decision. A rotation's "usage reset"
nudge wakes it for nothing: a wasted turn, an empty reply, and the pending question scrolls away.

Two functions, deliberately separate:

  Get-MergePrTarget   command line -> @{ Pr; Repo } | $null     (the window-to-PR mapping)
  Test-MergePrParked  -Repo -Pr    -> $true ONLY when parked    (the decision)

PORTABILITY: nothing here calls a Windows-only API (no CIM/WMI/registry/Win32). The caller
supplies the command line; this file only does regex, file reads and one child process. It runs
unchanged under pwsh on Linux/macOS, where the caller feeds it `/proc/<pid>/cmdline` instead.
Only the DEFAULTS are OS-flavoured (python vs python3), and both are overridable.

FAIL-OPEN, in both functions. A session that is wrongly nudged costs one turn; a session that
is wrongly skipped never learns its quota is back. So every doubt answers "inject":
unidentifiable PR, no lock, unreadable lock, launcher missing, timeout, non-zero exit,
unparseable output, or any status other than exactly "parked" — and a parked lock whose session
transcript holds an owner message typed after it parked (see Test-ParkedLockAnswered).
#>

# ---- window -> PR ---------------------------------------------------------------------------
# Ground truth is the launcher's own marker: every launcher-spawned review carries
# `--name merge-pr-<PR>` (merge_pr_launcher.live_windows matches the same thing). The window
# title is NOT used (`cmd /c start` titles are overwritten by the TUI), cwd is NOT used (a
# review's cwd is its worktree, shared across PRs), and `MERGE_PR_PR`/`MERGE_PR_REPO` live in
# the child's environment, which is unreadable from outside the process without PEB reads.
#
# The command line carries the PR number but NOT the repo, so the repo comes from the per-PR
# lock file under the merge-pr state dir (its JSON has a `repo` field). Two lock files for one
# PR number are one repo if they spell the same repo (pre-transfer key vs org key, any case), but
# DIFFERENT repos are ambiguous => $null. No lock file => nothing to be parked => $null (inject).
# A hand-launched `/merge-pr` window, or a review the owner reopened with `--resume`, has no
# `--name` and is not recognised, so it is nudged exactly as before.
function Get-MergePrStateDir {
  if ($env:MERGE_PR_STATE_DIR) { return $env:MERGE_PR_STATE_DIR }
  return (Join-Path (Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude-shared') 'state') 'merge-pr')
}

function Get-MergePrTarget {
  param([string]$CommandLine, [string]$StateDir = (Get-MergePrStateDir))
  if (-not $CommandLine) { return $null }
  # Linux /proc/<pid>/cmdline is NUL-delimited; treat NUL as the space it stands for.
  $CommandLine = $CommandLine -replace "`0", ' '
  if ($CommandLine -notmatch '(?:^|\s)--name\s+merge-pr-(\d{1,9})(?:\s|$)') { return $null }
  $pr = 0
  if (-not [int]::TryParse($Matches[1], [ref]$pr) -or $pr -lt 1) { return $null }
  try {
    # One repo only. Two lock files for the same PR number under DIFFERENT repos make the window
    # ambiguous (both are named merge-pr-<N>), and guessing could skip a working session: inject.
    # Same repo under two spellings (pre-/post-transfer key, case) is one repo.
    $repos = @(Get-ChildItem -LiteralPath (Join-Path $StateDir 'locks') -Filter "*__pr$pr.lock" -File -ErrorAction Stop |
               ForEach-Object { [string](Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).repo } |
               Group-Object { $_.ToLowerInvariant() })
    if ($repos.Count -ne 1) { return $null }
    $repo = $repos[0].Group[0]
  } catch { return $null }
  if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { return $null }
  return [pscustomobject]@{ Pr = $pr; Repo = $repo }
}

# ---- answered-but-still-parked --------------------------------------------------------------
# A lock leaves `parked` only when the session itself runs --unpark. If the owner answers while the
# seat is capped, that turn dies on the usage limit first, the lock stays `parked`, and skipping
# the window would strand his answer. So a parked lock whose session transcript shows an owner
# answer AFTER it parked is treated as answered => inject. Lock JSON: `session` (transcript path), `ts` (epoch s).
# "Answered" means a message the OWNER typed, timestamped after the park. It used to mean "the
# transcript file changed 600 s after parking", but a parked window keeps writing with nobody
# there: background task notifications, orchestrator cross-session messages, idle compactions,
# a limit error on a notification turn. Each of those read as an answer and the window was
# woken for nothing (2026-11-02). Not an answer: meta lines, compaction summaries, tool results,
# anything that opens with a tag (<task-notification>, <command-name>, <local-command-...>,
# <cross-session-message>) and the rotator's own "Usage reset:" ping.
# The whole transcript is scanned: a busy window can write megabytes after the answer.
# No `session`/`ts`, or the transcript missing/unreadable => no evidence of an answer => stays parked.
function Test-OwnerMessage($e) {
  if ($e.type -ne 'user' -or $e.isMeta -or $e.isSidechain -or $e.isCompactSummary) { return $false }
  $c = $e.message.content
  $text = if ($c -is [string]) { $c } else { (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
  $text = ([string]$text).TrimStart()
  return ($text -and -not $text.StartsWith('<') -and -not $text.StartsWith('Usage reset:'))
}
function Test-ParkedLockAnswered {
  param([string]$LockPath)
  try {
    $lock = Get-Content -LiteralPath $LockPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $lock.session -or $null -eq $lock.ts) { return $false }
    $since = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$lock.ts * 1000))
    $sinceKey = $since.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
    $fs = [IO.File]::Open([string]$lock.session, 'Open', 'Read', 'ReadWrite')
    try { $all = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8).ReadToEnd() } finally { $fs.Dispose() }
    foreach ($l in ($all -split "`n")) {
      # Cheap pre-filters before parsing: a user entry stamped at or after the park second.
      if ($l -notmatch '"type"\s*:\s*"user"' -or $l -notmatch '"timestamp"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)') { continue }
      if ([string]::CompareOrdinal($Matches[1], $sinceKey) -lt 0) { continue }
      try { $e = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (-not $e.timestamp -or [DateTimeOffset]::Parse([string]$e.timestamp) -le $since) { continue }
      if (Test-OwnerMessage $e) { return $true }
    }
    return $false
  } catch { return $false }
}

# ---- the decision ---------------------------------------------------------------------------
function Test-MergePrParked {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][int]$Pr,
    [int]$TimeoutSec = 10,
    [string]$Launcher,
    [string]$Python,
    # Test seam: scriptblock taking (@arguments) and returning @{ ExitCode; Stdout }.
    [scriptblock]$Invoke
  )
  try {
    if (-not $Launcher) {
      $Launcher = if ($env:MERGE_PR_LAUNCHER) { $env:MERGE_PR_LAUNCHER } else {
        Join-Path (Join-Path (Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude') 'skills') 'merge-pr') 'scripts/merge_pr_launcher.py'
      }
    }
    if (-not $Python) {
      # python3 first off Windows: a bare `python` can be Python 2 there, which dies on the launcher.
      $names = if ($IsWindows -eq $false) { 'python3', 'python' } else { 'python', 'python3' }
      $cmd = Get-Command $names -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      $Python = if ($cmd) { $cmd.Source } else { $names[0] }
    }
    $argList = @($Launcher, '--repo', $Repo, '--pr', [string]$Pr, '--lock-status')

    if ($Invoke) { $res = & $Invoke @argList }
    else {
      if (-not (Test-Path -LiteralPath $Launcher)) { return $false }
      $psi = [System.Diagnostics.ProcessStartInfo]::new($Python)
      foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $proc = [System.Diagnostics.Process]::Start($psi)
      $so = $proc.StandardOutput.ReadToEndAsync(); $se = $proc.StandardError.ReadToEndAsync()
      try {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
          try { $proc.Kill($true) } catch {}   # the pid we started (+ its children, e.g. gh), never by name
          [void]$proc.WaitForExit(2000)
          return $false
        }
        # Bounded flush: a bare WaitForExit() waits for pipe EOF, which a surviving child can withhold.
        if (-not ($so.Wait(2000) -and $se.Wait(2000))) { return $false }
        $res = @{ ExitCode = $proc.ExitCode; Stdout = $so.Result }
      } finally { $proc.Dispose() }
    }
    if ($res.ExitCode -ne 0) { return $false }
    $j = [string]$res.Stdout | ConvertFrom-Json -ErrorAction Stop
    if (-not ($j.status -is [string] -and $j.status -ceq 'parked')) { return $false }
    # Parked per the launcher; but if the owner has answered since (see Test-ParkedLockAnswered), wake it.
    if ($j.lock -is [string] -and $j.lock -and (Test-ParkedLockAnswered -LockPath $j.lock)) { return $false }
    return $true
  } catch { return $false }
}
