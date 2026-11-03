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
transcript holds an owner answer after it parked -- typed, an AskUserQuestion pick, or a relayed
"Owner ruling for #N" (see Test-ParkedLockAnswered).
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
# answer AFTER it parked is treated as answered => inject. Lock JSON: `session` (transcript path), `parked_at` or else `ts` (epoch s).
# "Answered" means an owner answer timestamped after the park: something he typed (or cache-keeper
# resubmitted for him), an AskUserQuestion pick, or a ruling relayed from another session. It used to mean "the
# transcript file changed 600 s after parking", but a parked window keeps writing with nobody
# there: background task notifications, orchestrator cross-session messages, idle compactions,
# plugin prompts ("Resume", "Try again", /compact), a limit error on a notification turn. Each
# of those read as an answer and the window was woken for nothing (2026-11-02).
# Who wrote a line: current CLIs stamp `origin.kind` on it. `human` is the owner (typed, pasted --
# which opens with a <pasted_content> tag --, queued while a turn ran, or an accepted suggestion).
# `task-notification`, `peer` and plain `plugin` lines are not, whatever the text says, and that
# check runs before the AskUserQuestion branch, because a plugin can re-emit an old pick with a
# fresh stamp. Exceptions, each measured on real transcripts:
#  - a `plugin` line with `asUser` is cache-keeper resubmitting the owner's own held text after a
#    /compact; it is often the ONLY copy of his answer. It counts, unless it is one of cache-keeper's
#    own prompts ("Resume", "Try again", the usage-limit / handoff continuations) or the exact text
#    of a human line from before the park (a replay of an old message).
#  - the rotator's own ping ("Usage reset: ..." or the default "resume") is typed into the window
#    with WriteConsoleInput, so the CLI stamps it `human`/`typed`; it is excluded by its text.
#  - an owner ruling relayed by deliver_ruling.py arrives as a `peer` message (a meta user line, or a
#    queued_command attachment mid-turn) whose body starts "Owner ruling for #<N>"; it counts when N
#    is this lock's PR.
# Older lines with no `origin` fall back to the text: not meta, not a compaction summary, not opening
# with a tag, not "/compact" or "[Request interrupted".
# An AskUserQuestion pick comes back as a tool_result and counts, in either harness phrasing
# ("Your questions have been answered:" / "The user answered:" with at least one undismissed pick);
# every other tool_result does not.
# The whole transcript is streamed line by line: a busy window can write megabytes after the answer.
# No `session`, no `parked_at`/`ts`, or the transcript missing/unreadable => no evidence => stays parked.
function Get-OriginKind($o) { if ($null -ne $o -and $o.PSObject.Properties['kind']) { [string]$o.kind } else { $null } }
function Get-Prop($o, [string]$n) { if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
function Test-RotatorPing([string]$t) { $t = $t.Trim(); return ($t.StartsWith('Usage reset:') -or $t -ceq 'resume') }
function Test-CacheKeeperPrompt([string]$t) {
  $t = $t.Trim()
  return ($t -ceq 'Resume' -or $t -ceq 'Try again' -or $t -eq '/compact' -or
    $t.StartsWith('I hit my usage limit while you were working') -or $t.StartsWith('Handoff from my previous session'))
}
function Test-RelayedRuling($origin, $Pr) {
  if ((Get-OriginKind $origin) -ne 'peer') { return $false }
  if ([string](Get-Prop $origin 'body') -notmatch '^\s*Owner ruling for #(\d+)') { return $false }
  return ($null -eq $Pr -or [long]$Matches[1] -eq [long]$Pr)
}
function Get-LineText($e) {
  $c = $e.message.content
  $t = if ($c -is [string]) { $c } else { (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
  return ([string]$t).Trim()
}
# $Before: texts of human lines written before the park (a plugin replay of one is not new).
function Test-OwnerMessage($e, $Pr = $null, $Before = $null) {
  if ($e.type -eq 'attachment') {
    $a = $e.attachment
    if ($null -eq $a -or $a.type -ne 'queued_command') { return $false }
    if (Test-RelayedRuling $a.origin $Pr) { return $true }
    if ((Get-OriginKind $a.origin) -ne 'human') { return $false }
    $t = ([string]$a.prompt).Trim()
    return ($t -and -not (Test-RotatorPing $t))
  }
  if ($e.type -ne 'user' -or $e.isSidechain -or $e.isCompactSummary) { return $false }
  $kind = Get-OriginKind $e.origin
  if ($kind -eq 'peer') { return (Test-RelayedRuling $e.origin $Pr) }
  $resubmitted = ($kind -eq 'plugin' -and (Get-Prop $e.origin 'asUser') -eq $true)
  if ($e.isMeta -or ($kind -and $kind -ne 'human' -and -not $resubmitted)) { return $false }
  $text = Get-LineText $e
  if ($resubmitted) {
    return ($text -and -not $text.StartsWith('<') -and -not (Test-RotatorPing $text) -and
      -not (Test-CacheKeeperPrompt $text) -and -not ($Before -and $Before.Contains($text)))
  }
  foreach ($b in @($e.message.content | Where-Object { $_.type -eq 'tool_result' })) {
    $r = if ($b.content -is [string]) { $b.content } else { (@($b.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
    $r = ([string]$r).TrimStart()
    if ($r.StartsWith('Your questions have been answered:')) { return $true }
    if ($r.StartsWith('The user answered:') -and $r -match '"="(?!\[User dismissed)') { return $true }
  }
  if (-not $text -or (Test-RotatorPing $text)) { return $false }
  if ($kind) { return $true }
  return -not ($text.StartsWith('<') -or $text -eq '/compact' -or $text.StartsWith('[Request interrupted'))
}
# ConvertFrom-Json turns an ISO timestamp into a [datetime] under pwsh 7 and leaves a string under
# Windows PowerShell 5.1. Never round-trip the [datetime] through [string]: that drops the offset and
# re-parses in the current culture (day/month swap on en-GB, a local-offset shift everywhere).
function ConvertTo-UtcStamp($t) {
  if ($t -is [datetime]) { return [DateTimeOffset]$t.ToUniversalTime() }
  if ($t -is [DateTimeOffset]) { return $t }
  return [DateTimeOffset]::Parse([string]$t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}
function Test-ParkedLockAnswered {
  param([string]$LockPath)
  try {
    $lock = Get-Content -LiteralPath $LockPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # parked_at is the park moment; ts is a heartbeat the launcher re-stamps even while parked,
    # which would hide an answer given before the re-stamp. Locks parked before parked_at existed fall back to ts.
    $parkTs = if ($null -ne $lock.parked_at) { $lock.parked_at } else { $lock.ts }
    if (-not $lock.session -or $null -eq $parkTs) { return $false }
    $since = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$parkTs * 1000))
    $sinceKey = $since.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $fs = [IO.File]::Open([string]$lock.session, 'Open', 'Read', 'ReadWrite')
    $rd = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
    $before = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
      while ($null -ne ($l = $rd.ReadLine())) {
        # Cheap pre-filters before parsing: a user/attachment entry stamped at or after the park second.
        # The entry's own timestamp is the LAST one on the line: an attachment nests its own earlier
        # one first. (A "timestamp" quoted inside message text is JSON-escaped, so it cannot match.)
        if ($l -notmatch '"type"\s*:\s*"(user|attachment)"' -or $l -notmatch '.*"timestamp"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)') { continue }
        if ([string]::CompareOrdinal($Matches[1], $sinceKey) -lt 0) {
          # Before the park: remember what the owner typed, so a later plugin replay of it is not new.
          if ($l -match '"kind"\s*:\s*"human"') {
            try { $p0 = $l | ConvertFrom-Json -ErrorAction Stop; if ($p0.type -eq 'user') { $t0 = Get-LineText $p0; if ($t0) { [void]$before.Add($t0) } } } catch { }
          }
          continue
        }
        try { $e = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $e.timestamp) { continue }
        try { if ((ConvertTo-UtcStamp $e.timestamp) -le $since) { continue } } catch { continue }
        if (Test-OwnerMessage $e $lock.pr $before) { return $true }
      }
    } finally { $rd.Dispose(); $fs.Dispose() }
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
