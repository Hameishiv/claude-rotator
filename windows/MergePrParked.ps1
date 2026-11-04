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
Needs PowerShell 7 (every caller runs it under pwsh): under Windows PowerShell 5.1 the launcher
call throws (no ProcessStartInfo.ArgumentList there), which fails open, so every window is pinged.

FAIL-OPEN, in both functions. A session that is wrongly nudged costs one turn; a session that
is wrongly skipped never learns its quota is back. So every doubt answers "inject":
unidentifiable PR, no lock, unreadable lock, launcher missing, timeout, non-zero exit,
unparseable output, or any status other than exactly "parked" — and a parked lock whose session
transcript holds an owner answer from after it parked -- typed, an AskUserQuestion pick, or his
answer relayed from another session for this PR (see Test-ParkedLockAnswered).
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
# "Answered" means an owner answer from after the park: something he typed (or cache-keeper
# resubmitted for him), an AskUserQuestion pick, or a ruling relayed from another session. "After"
# is the entry's timestamp, except for a queued_command attachment (below), where it is file order. It used to mean "the
# transcript file changed 600 s after parking", but a parked window keeps writing with nobody
# there: background task notifications, orchestrator cross-session messages, idle compactions,
# plugin prompts ("Resume", "Try again", /compact), a limit error on a notification turn. Each
# of those read as an answer and the window was woken for nothing (2026-11-02).
# Who wrote a line: current CLIs stamp `origin.kind` on it. `human` is the owner (typed, pasted --
# which opens with a <pasted_content> tag --, queued while a turn ran, or an accepted suggestion).
# These kinds are automated and never count on their own (a `peer` line counts only when it relays
# his answer for this PR, below): `task-notification`, `peer`,
# `auto-continuation` (the CLI's "usage limit has reset"), `coordinator`, `observer`,
# `observer-activity`, `unclassified` (CLI schema: "never presumed human"), and `plugin` without
# `asUser`. That check runs before the AskUserQuestion branch, because a plugin can re-emit an old
# pick with a fresh stamp. Any other kind counts like `human`: `channel` and `slack-ping` carry a
# person's words from another surface, and an unknown future kind must not strand his answer.
# Exceptions, each measured on real transcripts:
#  - a `plugin` line with `asUser` is cache-keeper resubmitting a held message after a /compact (it
#    drops the original, so this is the only copy). It is judged like the owner's own line: his
#    typed or pasted text counts (after any leading <system-reminder> blocks the app prepended),
#    whether it lands as a user line or a queued_command attachment; cache-keeper's own "Resume" and
#    handoff text, the desktop app's "Try again", and the desktop and CLI usage-limit continuations when resubmitted, and
#    messages in a known wrapper tag (task notifications, slash-command echoes) do not.
#    Known gap: a resubmission keeps no trace of its first origin, so if cache-keeper ever resubmits
#    a SCHEDULED prompt (cold-cache path) it would count -- one wrong wake, the cheap direction.
#    None observed; a marker from cache-keeper would close it.
#  - the rotator's own ping ("Usage reset: ..." or the default "resume") is typed into the window
#    with WriteConsoleInput, so the CLI stamps it `human`/`typed`; it is excluded by its text.
#  - an owner answer relayed from another session counts when it is for this lock's PR: either
#    deliver_ruling.py's "Owner ruling for #<N>" (any case, "for" or "on", possibly wrapped), or
#    free text naming #<N> with answer wording ("the owner answered", "his words"), however it
#    is stored: a meta `peer` user line, a `peer` queued_command attachment mid-turn, or a
#    cache-keeper resubmission of the <cross-session-message>.
# Older lines with no `origin` fall back to the text: not meta, not a compaction summary, not opening
# with a tag, not "/compact" or "[Request interrupted".
# An AskUserQuestion pick comes back as a tool_result and counts, in either harness phrasing
# ("Your questions have been answered:" / "The user answered:") when at least one pick is neither a
# dismissal nor the rotator's ping, or when no pick can be parsed;
# every other tool_result does not.
# The whole transcript is streamed line by line: a busy window can write megabytes after the answer.
# No `session`, no `parked_at`/`ts`, or the transcript missing/unreadable => no evidence => stays parked.
function Get-OriginKind($o) { if ($null -ne $o -and $o.PSObject.Properties['kind']) { [string]$o.kind } else { $null } }
function Get-Prop($o, [string]$n) { if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
function Test-RotatorPing([string]$t) { $t = $t.Trim(); return ($t.StartsWith('Usage reset:') -or $t -ceq 'resume') }
function Test-CacheKeeperPrompt([string]$t) {
  $t = $t.Trim()
  return ($t -ceq 'Resume' -or $t -ceq 'Try again' -or $t -eq '/compact' -or
    $t.StartsWith('I hit my usage limit while you were working') -or $t.StartsWith('Your claude.ai usage limit has reset') -or
    $t.StartsWith('Handoff from my previous session'))
}
$script:NonOwnerKinds = @('task-notification', 'peer', 'auto-continuation', 'coordinator', 'observer', 'observer-activity', 'unclassified')
# Wrappers a non-owner message arrives in; a resubmission opening with one of these is not his text.
$script:WrapperTag = '^<(task-notification|side-sessions-event|ci-monitor-event|[a-z]+(?:-[a-z]+)*-event>|command-|local-command-|system-reminder)'
function Test-Resubmitted($origin) { return ((Get-OriginKind $origin) -eq 'plugin' -and (Get-Prop $origin 'asUser') -eq $true) }
# A cache-keeper resubmission: judged on its text, since it is the only copy of what it carries.
function Test-ResubmittedText([string]$text, $Pr) {
  $text = ($text -replace '^(?s)(\s*<system-reminder>.*?</system-reminder>)+\s*', '').Trim()
  if (-not $text -or (Test-RotatorPing $text) -or (Test-CacheKeeperPrompt $text)) { return $false }
  if ($text.StartsWith('<cross-session-message')) { return ((Test-RulingText $text $Pr) -eq $true) }
  return ($text -notmatch $script:WrapperTag)
}
# $null = no ruling in the text; otherwise whether it is for this PR.
function Test-RulingText([string]$t, $Pr) {
  # The wrapper's from-name ("Answer page PRs #6481/#6471") is the sender, not a mention.
  $t = $t -replace '<cross-session-message[^>]*>', ''
  # Relaying agents reword it ("owner ruling for #N", "OWNER RULING on #N"), so match loosely.
  $ms = [regex]::Matches($t, '(?i)owner ruling (?:for|on) (?:the )?#(\d+)')
  # Orchestrators also relay his answer in free text ("The owner answered your parked question on
  # PR #5727 ... His words, verbatim"). Count that when it names this PR and carries answer wording,
  # but NOT the orchestrator's acknowledgement of the park ("#5992 stays parked ... will relay his
  # words the moment he answers"): that marks the lock answered until the session re-parks, so every
  # limit stop in between would wake it -- the original bug. The veto is per SENTENCE: relays often
  # bundle "he answered X. Y is still open with him", and a whole-message veto threw the answer away.
  # A request to fetch his answer ("send me his answer", "has he answered?") is not one either.
  # The answer sentence (or the one before it: "...Gate E for #5985. His words: ...") must name this
  # PR, unless the whole message names no other PR: a broadcast listing several PRs must not hand one
  # PR's answer to all of them.
  # The PR is named as "#N", in a link ".../pull/N", or as the first word of his quoted reply right
  # after "his words"/"his answer"/"answered"/"said"/"chose"/"he typed"/"he replied", optionally ", verbatim"
  # (his words "6363 approve"); not a prompt like Reply "90 A" nor a list of options ("90 A" or "90 B").
  # A bold label on its own ("- **Design approval.**") is still judged, but does not use up the lookback;
  # a bold PR heading ("**#6481**") is not, so the next PR's section does not inherit the one before.
  # An orchestrator's park release ("not an owner ruling: your park condition has cleared, resume")
  # counts, deliberately: waking that window is what the release asks for.
  # Known gaps: an acknowledgement or request worded outside this list still counts (a wrong wake
  # until re-park). Missed: an answer worded outside the answer list, and, in a message naming another
  # PR too, an answer two or more sentences from this PR's number.
  $prNum = ([string]$Pr).Trim().TrimStart('0')
  $prRe = '(?i)(?:#|pull/|\b(?:words|his answer|answered|said|chose|(?:the owner|he) (?:typed|replied))(?:,? verbatim)?\W{0,5}["\u201C])0*' + [regex]::Escape($prNum) + '\b(?![^"\u201D]*["\u201D]\s*,?\s*or\s+["\u201C])'
  if ($null -ne $Pr -and $t -match $prRe) {
    $only = @([regex]::Matches($t, '(?:#|pull/)0*(\d+)\b') | Where-Object { $_.Groups[1].Value.TrimStart('0') -ne $prNum }).Count -eq 0
    $prev = ''
    # A sentence ends at . ! ? (plus any closing quote, bracket or bold marker), but not after e.g./i.e.
    foreach ($s in ($t -split '(?<=[.!?][)"''\u201D\u2019*\]]*)(?<!\b[eE]\.g\.|\b[iI]\.e\.)\s+|\r?\n')) {
      if (-not $s.Trim()) { continue }
      $label = $s -match '^[-*\s]*\*\*[^*]+\*\*\s*$' -and $s -notmatch '(?:#|pull/)\d'
      $named = $only -or $s -match $prRe -or $prev -match $prRe
      if (-not $label) { $prev = $s }
      if ($named -and
          $s -match "(?i)\b(owner(?:'s)? (?:answer|answers|approval|ruling|decision)|the owner (?:answered|said|ok'?ed|approved|picked|chose|decided)|he (?:answered|approved|ok'?ed)|he (?:chose|picked) (?:option )?(?:[A-D]\b|[\x22\u201C])|(?:the owner|he) (?:typed|replied)\W{0,5}[\x22\u201C]|his (?:answer|answers|words|ruling|approval|decision))\b" -and
          $s -notmatch "(?i)\b(stays? parked|still open|will relay|I'll relay|will send|I'll send|when he gives|until he answers|once he answers|when he answers|the moment he answers|without his answer|a?wait(?:ing)? (?:on |for )?(?:the )?owner|(?:approval|decision|answer):? (?:is )?(?:still )?(?:pending|needed)|put(?:ting)? .{0,40}\bto the owner|put (?:this|it) to him|if (?:the owner|he) (?:has )?already answered|relay (?:it|this|his \w+)|send me his|carry it to him|if he says|has he answered|needs (?:the owner|his)|unless his answer|to be confirmed by|may revisit)\b") {
        return $true
      }
    }
  }
  if ($ms.Count -eq 0) { return $null }
  if ($null -eq $Pr) { return $true }
  # Any ruling named in the text may be this PR's; an orchestrator's message can name several.
  foreach ($m in $ms) { if ($m.Groups[1].Value.TrimStart('0') -eq ([string]$Pr).Trim().TrimStart('0')) { return $true } }
  return $false
}
function Test-RelayedRuling($origin, [string]$fallbackText, $Pr) {
  if ((Get-OriginKind $origin) -ne 'peer') { return $false }
  $body = [string](Get-Prop $origin 'body'); if (-not $body) { $body = $fallbackText }
  return ((Test-RulingText $body $Pr) -eq $true)
}
function Get-LineText($e) {
  $c = $e.message.content
  $t = if ($c -is [string]) { $c } else { (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
  return ([string]$t).Trim()
}
function Test-OwnerMessage($e, $Pr = $null) {
  if ($e.type -eq 'attachment') {
    $a = $e.attachment
    if ($null -eq $a -or $a.type -ne 'queued_command') { return $false }
    if (Test-RelayedRuling $a.origin ([string]$a.prompt) $Pr) { return $true }
    if (Test-Resubmitted $a.origin) { return (Test-ResubmittedText ([string]$a.prompt) $Pr) }
    $ak = Get-OriginKind $a.origin
    if (-not $ak -or $ak -eq 'plugin' -or $script:NonOwnerKinds -contains $ak) { return $false }
    $t = ([string]$a.prompt).Trim()
    return ($t -and -not (Test-RotatorPing $t))
  }
  if ($e.type -ne 'user' -or $e.isSidechain -or $e.isCompactSummary) { return $false }
  $kind = Get-OriginKind $e.origin
  $text = Get-LineText $e
  if ($kind -eq 'peer') { return (Test-RelayedRuling $e.origin $text $Pr) }
  if ($e.isMeta) { return $false }
  if (Test-Resubmitted $e.origin) { return (Test-ResubmittedText $text $Pr) }
  if ($kind -eq 'plugin' -or ($kind -and $script:NonOwnerKinds -contains $kind)) { return $false }
  foreach ($b in @($e.message.content | Where-Object { $_.type -eq 'tool_result' })) {
    $r = if ($b.content -is [string]) { $b.content } else { (@($b.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
    $r = ([string]$r).TrimStart()
    if ($r.StartsWith('Your questions have been answered:') -or $r.StartsWith('The user answered:')) {
      $picks = @([regex]::Matches($r, '"="([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
      # One real pick is enough. A dismissal is not one, nor the rotator's own ping landing as the
      # pick text. "[User did not answer ... sent a message instead]" counts: something was typed.
      # No parsable pick (e.g. cut by compaction truncation), either phrasing: count it (fail-open).
      if ($picks.Count -eq 0) { return $true }
      if (@($picks | Where-Object { -not $_.StartsWith('[User dismissed') -and -not (Test-RotatorPing $_) }).Count -gt 0) { return $true }
    }
  }
  if ($text -and (Test-RotatorPing $text)) { return $false }
  if ($kind) {
    # A human line with no text (an image-only answer) still counts. A slash command he typed to
    # check something (/usage, /status: a <command-...> echo) is not an answer; a paste is.
    $bare = ($text -replace '^(?s)(\s*<system-reminder>.*?</system-reminder>)+\s*', '').Trim()
    if ($bare -and $bare -match $script:WrapperTag) {
      # A slash command he typed is his word ("/merge-pr 5978 resume"), except a bare status check
      # and cache-keeper's housekeeping commands (the desktop app stamps /keepwarm, /board human).
      if ($bare -match '<command-name>/?([^<]*)</command-name>') {
        $cmd = ($Matches[1].Trim() -split ':')[-1]
        $cargs = if ($bare -match '(?s)<command-args>(.*?)</command-args>') { $Matches[1].Trim() } else { '' }
        if (@('keepwarm', 'board', 'cache', 'handoff', 'seats') -contains $cmd -or $cmd -like 'ck-*') { return $false }
        return -not ($cargs -eq '' -and @('usage', 'status', 'cost', 'context') -contains $cmd)
      }
      return $false
    }
    return ($text -or @($e.message.content | Where-Object { $_.type -and $_.type -ne 'tool_result' }).Count -gt 0)
  }
  if (-not $text) { return $false }
  # No origin: also not the app's own canned continuations ("I hit my usage limit ... Please continue").
  return -not ($text.StartsWith('<') -or $text -eq '/compact' -or $text.StartsWith('[Request interrupted') -or
    (Test-CacheKeeperPrompt $text))
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
    # A queued_command attachment is stamped when he TYPED it, not when the session read it (it can sit
    # queued for minutes), so its stamp cannot say which side of the park it was read on. Its place in
    # the file can: it counts only when the conversation line (user/assistant) written most recently
    # before it is stamped at or after the park. Only user/assistant lines move the test, because
    # some other lines carry an older stamp than their place in the file: PreToolUse hook
    # attachments land after the tool_result with the hook's earlier time, and file-history-snapshot
    # lines expose only a nested older stamp. Not
    # "any earlier line": a compaction writes a boundary and then re-writes the retained history with
    # its ORIGINAL stamps, so a pre-park queued message reappears after a post-park line. So a
    # boundary resets the test, the compaction summary does not set it, and the copied history's old
    # stamps keep it reset until genuinely new lines follow.
    $prevAfter = $false
    $fs = [IO.File]::Open([string]$lock.session, 'Open', 'Read', 'ReadWrite')
    $rd = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
    try {
      while ($null -ne ($l = $rd.ReadLine())) {
        # Cheap pre-filters before parsing. The entry's own timestamp is the LAST one on the line: an
        # attachment nests its own copy first. (A "timestamp" quoted inside message text is
        # JSON-escaped, so it cannot match.)
        if ($l -notmatch '.*"timestamp"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)') { continue }
        $key = $Matches[1]
        $queued = $l -match '"type"\s*:\s*"attachment"' -and $l -match '"queued_command"'
        $readAfter = $prevAfter
        if ($l -match '"subtype"\s*:\s*"compact_boundary"') { $prevAfter = $false }
        elseif (-not $queued -and $l -notmatch '"isCompactSummary"\s*:\s*true' -and
                $l -match '"type"\s*:\s*"(user|assistant)"' -and
                $l -notmatch '"type"\s*:\s*"(attachment|file-history-snapshot)"') {
          $prevAfter = [string]::CompareOrdinal($key, $sinceKey) -ge 0
        }
        if ($l -notmatch '"type"\s*:\s*"(user|attachment)"') { continue }
        if ($queued) { if (-not $readAfter) { continue } }
        elseif ([string]::CompareOrdinal($key, $sinceKey) -lt 0) { continue }
        try { $e = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($e.type -ne 'attachment') {
          if (-not $e.timestamp) { continue }
          try { if ((ConvertTo-UtcStamp $e.timestamp) -le $since) { continue } } catch { continue }
        }
        # One odd line must not abandon the scan: a later line may hold his answer.
        try { if (Test-OwnerMessage $e $lock.pr) { return $true } } catch { continue }
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
