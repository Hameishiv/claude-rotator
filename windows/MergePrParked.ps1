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
#    deliver_ruling.py's "Owner ruling for #<N>" at the start of a line (any case, "for" or "on",
#    possibly wrapped; mid-sentence it is judged as free text, with the vetoes), or
#    free text naming #<N> with answer wording ("the owner answered", "his words"), or an
#    orchestrator's park release ("the blocker you parked on is cleared"), even naming no PR, however it
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
# The harness can put <system-reminder> blocks in front of the injected ping; they are not part of it.
function Test-RotatorPing([string]$t) {
  $t = ($t -replace '^(?s)(\s*<system-reminder>.*?</system-reminder>)+\s*', '').Trim()
  return ($t.StartsWith('Usage reset:') -or $t -ceq 'resume')
}
function Test-CacheKeeperPrompt([string]$t) {
  $t = $t.Trim()
  return ($t -ceq 'Resume' -or $t -ceq 'Try again' -or $t -eq '/compact' -or
    $t.StartsWith('I hit my usage limit while you were working') -or $t.StartsWith('Your claude.ai usage limit has reset') -or
    $t.StartsWith('Handoff from my previous session'))
}
$script:NonOwnerKinds = @('task-notification', 'peer', 'auto-continuation', 'coordinator', 'observer', 'observer-activity', 'unclassified')
# Wrappers a non-owner message arrives in; a resubmission opening with one of these is not his text.
$script:WrapperTag = '^<(task-notification|side-sessions-event|ci-monitor-event|[a-z]+(?:-[a-z]+)*-event>|command-|local-command-|system-reminder|agent-message)'
function Test-Resubmitted($origin) { return ((Get-OriginKind $origin) -eq 'plugin' -and (Get-Prop $origin 'asUser') -eq $true) }
# A cache-keeper resubmission: judged on its text, since it is the only copy of what it carries.
function Test-ResubmittedText([string]$text, $Pr) {
  $text = ($text -replace '^(?s)(\s*<system-reminder>.*?</system-reminder>)+\s*', '').Trim()
  # A peer message can carry the harness's display prefix in front of its wrapper.
  $text = ($text -replace '^Another Claude session sent a message(?: while you were working)?:\s*', '').Trim()
  if (-not $text -or (Test-RotatorPing $text) -or (Test-CacheKeeperPrompt $text)) { return $false }
  if ($text.StartsWith('<cross-session-message')) { return ((Test-RulingText $text $Pr) -eq $true) }
  return ($text -notmatch $script:WrapperTag)
}
# $null = no ruling in the text; otherwise whether it is for this PR.
function Test-RulingText([string]$t, $Pr) {
  # The wrapper's from-name ("Answer page PRs #6481/#6471") is the sender, not a mention.
  $t = $t -replace '</?cross-session-message[^>]*>', ''
  # Relaying agents reword it ("owner ruling for #N", "OWNER RULING on #N"), so match the case loosely,
  # but only at the start of a line, where every deliver_ruling.py relay puts it. Mid-sentence
  # ("Flight coordinator: OWNER RULING on #N", "stays parked until the owner ruling on #N") it goes
  # through the free-text check below and its vetoes instead, which still counts the real reworded ones.
  # Known gap: this match has no vetoes, so a line-start status line ("Owner ruling for #N: none yet")
  # counts (a wrong wake until re-park).
  $ms = [regex]::Matches($t, '(?im)^[\s>*_#-]*owner ruling (?:for|on) (?:the )?#(\d+)')
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
  # after "his/these/owner's words", "his answer", "answered", "said", "chose", "he typed" or "he replied",
  # optionally ", verbatim" (his words "6363 approve"); not a prompt like Reply "90 A", nor a quoted reply that
  # opens a list of options ("90 A" or "90 B").
  # A bold label on its own ("- **Design approval.**") is still judged, but does not use up the lookback;
  # a bold PR heading ("**#6481**") is not, so the next PR's section does not inherit the one before.
  # An orchestrator's park release ("your park condition has cleared", "the blocker you parked on is
  # cleared", "Unpark your own lock with --unpark --pr N") counts, deliberately: waking that window is
  # what it asks for. --pr N names the PR, and a release that names no PR at all counts too.
  # Known gaps: an acknowledgement or request worded outside this list still counts (a wrong wake
  # until re-park). Missed: an answer worded outside the answer list, and, in a message naming another
  # PR too, an answer two or more sentences from this PR's number; a park release that names the PR
  # whose merge cleared it ("#6400 merged, so your park condition has cleared").
  $prNum = ([string]$Pr).Trim().TrimStart('0')
  # An issue or comment number, singular or in a list ("issues #5079 and #5080"), is not a PR.
  $notIssue = '(?<!\b(?:issues?|comments?) (?:#\d+(?:,\s*(?:and\s+|or\s+)?|\s+(?:and|or)\s+))*)'
  $n = '0*' + [regex]::Escape($prNum) + '\b'
  $lead = '(?:(?:his|these|with the|(?:the )?owner''s) words|his answer|answered|said|chose|(?:the owner|he) (?:typed|replied))(?:,? verbatim)?\W{0,5}["\u201C]'
  # A number his quoted reply opens with is a quantity, not a PR, when a unit follows ("48 hours is fine").
  $unit = '(?!\s*(?:%|(?:hours?|hrs?|days?|minutes?|mins?|seconds?|secs?|weeks?|months?|years?|GB|MB|KB)\b))'
  # An issue or comment reference is not this PR either, as for $numRe below.
  $prRe = '(?i)' + $notIssue + '(?:#|pull/|--pr\s+)' + $n + '|\b' + $lead + $n + $unit +
    '(?![^"\u201C\u201D\r\n]*["\u201D]\s*,?\s*or\s+["\u201C])'
  # Every PR the message names, in the same forms; "no other PR" and "no PR at all" are judged on these.
  # Two digits or more: "#1" and an option list's "1 B, 2 replace" are not PRs.
  $numRe = '(?i)(?:' + $notIssue + '(?:#|pull/|--pr\s+)0*(\d{2,})\b|\b' + $lead + '0*(\d{2,})\b' + $unit + ')'
  $nums = @([regex]::Matches($t, $numRe) | ForEach-Object { ($_.Groups[1].Value + $_.Groups[2].Value).TrimStart('0') })
  # "not an owner question" tells a parked window its question was never his to answer: carry on.
  # "not an owner ruling" alone is NOT a release: orchestrators label any status note or opinion with it.
  $release = '(?i)(?<!\bnot |n[''\u2019]t |\bcannot |\bnever |\bdo not )\b(?:park(?: condition)? (?:has been |is |has )?cleared|blocker you parked on is cleared|unpark your own lock|release the park|(?:not|isn[''\u2019]t) an owner question)\b'
  # Holds that veto answer WORDING only, never a release sentence ("Your park condition has cleared,
  # though #N still needs his approval at Gate E" is a release).
  # Known gaps: other hold phrasings ("no owner decision yet", "he hasn't answered") are not held, and
  # a release sentence is judged without these holds, so another PR's release beside this PR's hold
  # ("Unpark ... --pr 91; #N still needs his approval") or a conditional one counts (a wrong wake
  # until re-park); and these holds judge the whole sentence, so another PR's hold beside
  # this PR's answer ("He approved #N; #M still needs his approval") vetoes it (a missed answer).
  # Negated, it is not a hold: "he approved A, so it no longer needs his sign-off".
  # Known gap (wrong wake): "Keep parked until his answer arrives" (a live relay to #6673, 2026-11-05)
  # counts. Holding it was tried and dropped: every wording of it also caught negated or past-tense
  # answers ("you don't need to keep it parked", "it was parked until his answer; he approved A").
  $answerHold = '(?i)\b(?:(?<!\b(?:no longer|not|nothing(?: else| more)?|nobody|no one|neither(?: [\w-]+)?) )needs (?:the owner|his)|no (?:owner )?answer yet)\b'
  $answerWord = "(?i)\b((?<!\bnot an |n['\u2019]t an |\bwithout (?:an? |the )?)owner(?:'s)? (?:answer|answers|approval|ruling|decision)|the owner (?:answered|said|ok'?ed|approved|picked|chose|decided)|he (?:answered|approved|ok'?ed)|he (?:chose|picked)(?= (?:option [A-D]\b|(?-i:[A-D])\b|[\x22\u201C]))|(?:the owner|he) (?:typed|replied)(?=\W{0,5}[\x22\u201C])|his (?:answer|answers|words|ruling|approval|decision))\b"
  # Known gaps (missed answer): a negated "stays parked" / "still open" ("it no longer stays parked") still
  # vetoes; and a quote spanning sentences is split before its quotes are matched, so a hold word in an
  # early sentence of his multi-sentence quote (His words: "Q2 is still open. Approve A.") vetoes it.
  $byRelease = $null -ne $Pr -and $t -notmatch $prRe -and $nums.Count -eq 0 -and $t -match $release
  if ($null -ne $Pr -and ($t -match $prRe -or $byRelease)) {
    $only = @($nums | Where-Object { $_ -ne $prNum }).Count -eq 0
    $prev = ''
    # A sentence ends at . ! ? (plus any closing quote, bracket or bold marker), but not after e.g./i.e.
    foreach ($s in ($t -split '(?<=[.!?][)"''\u201D\u2019*\]]*)(?<!\b[eE]\.g\.|\b[iI]\.e\.)\s+|\r?\n')) {
      if (-not $s.Trim()) { continue }
      $label = $s -match '^[-*\s]*\*\*[^*]+\*\*\s*$' -and $s -notmatch '(?:#|pull/)\d'
      # The lookback does not apply to a sentence that names a different PR itself.
      # A plain #N / pull/N / --pr N outside his quoted words (not an issue or comment number), or the
      # PR his quoted reply opens with ("His words "91 A""); a PR mentioned later inside his quote is not one.
      # Another PR inside his quote is not a mention for $otherHere (except that reply-opening number,
      # which is recognised only as a bare number: "#91 is fine" opening his quote is a known wrong wake).
      # This PR's own #N inside a quote does name it ($prRe reads the whole sentence).
      # Quoted text also escapes the vetoes whenever answer wording appears outside the quotes
      # ("His words: "A, leave Q2 still open"", He replied "..."). So a quoted label with no answer
      # wording beside it (#N's body says "awaiting owner approval") is judged whole, but one beside
      # unquoted answer wording is not (a wrong wake). Each straight or curly double-quoted span is
      # replaced by an empty straight pair, because the "he replied/typed/chose" answer wording needs a
      # mark after it; one left-to-right pass, so a stray straight mark inside a curly quote does not
      # pair across it unless an unpaired straight mark comes earlier in the sentence.
      # Known gaps (missed answer): a mixed pair (curly one end, straight the other) and single-quoted,
      # backtick or blockquoted words are not blanked, so a hold word inside them still vetoes.
      $unquoted = $s -replace '"[^"]*"|\u201C[^\u201D]*\u201D', '""'
      $vetoText = if ($unquoted -match $answerWord) { $unquoted } else { $s }
      $otherHere = @(@([regex]::Matches($unquoted, '(?i)' + $notIssue + '(?:#|pull/|--pr\s+)0*(\d{2,})\b')) +
        @([regex]::Matches($s, '(?i)\b' + $lead + '0*(\d{2,})\b' + $unit)) | Where-Object { $_.Groups[1].Value.TrimStart('0') -ne $prNum }).Count -gt 0
      $named = $only -or $s -match $prRe -or ($prev -match $prRe -and -not $otherHere)
      if (-not $label) { $prev = $s }
      if ($named -and
          (($s -match $release -and $s -notmatch '\?[)"''\u201D\u2019*\]]*\s*$') -or (-not $byRelease -and $vetoText -notmatch $answerHold -and $s -match $answerWord)) -and
          $vetoText -notmatch "(?i)\b(stays? parked|still open|will relay|I'll relay|will send|I'll send|when he gives|until he answers|once he answers|(?:until|once|when) he rules|when he answers|after he answers|once he replies|when he replies|the moment he answers|without his answer|(?<!\bno (?:further |more )?|\bnot |n['\u2019]t |\bno longer )(?:a?wait(?:s|ing)? (?:on |for )?(?:the )?owner|(?:approval|decision|answer):? (?:is )?(?:still )?(?:pending|needed))|put(?:ting)? .{0,40}\bto the owner|put (?:this|it) to him|if (?:the owner|he) (?:has )?already answered|relay (?:it|this|his \w+)|send me his|carry it to him|if he says|has he answered|unless his answer|to be confirmed by|may revisit|has not come|(?<!\bno longer |\bnot |n['\u2019]t )blocked on (?:the owner|his)|forward(?:ing)? (?:his|the owner)|pass (?:it|them) on|due (?:tonight|tomorrow|later))\b") {
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
# A slash command that is never an owner answer: cache-keeper's housekeeping commands (the desktop app
# stamps /keepwarm, /board human) with any arguments, and a status check only when bare. One list for
# the typed (<command-name>) and the queued (raw prompt) paths. /compact is not an answer either.
function Test-NonAnswerCommand([string]$cmd, [string]$cargs) {
  if (@('keepwarm', 'board', 'cache', 'handoff', 'seats', 'compact') -contains $cmd -or $cmd -like 'ck-*') { return $true }
  return ($cargs -eq '' -and @('usage', 'status', 'cost', 'context') -contains $cmd)
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
    if (-not $t -or (Test-RotatorPing $t)) { return $false }
    # A slash command typed mid-turn: housekeeping and a bare status check are not an answer.
    if ($t -match '(?s)^/(\S+)\s*(.*)$' -and (Test-NonAnswerCommand (($Matches[1] -split ':')[-1]) $Matches[2].Trim())) { return $false }
    return $true
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
        return -not (Test-NonAnswerCommand $cmd $cargs)
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
  # The transcript read runs inside the synchronous ping loop, under the rotation mutex and the
  # proxy's 150 s wait on a held request (a 217 MB transcript took about two minutes). BudgetSec is
  # this process's CPU time for the scan (a live 37 MB transcript took 3.4-4.6 s at idle priority on a
  # loaded machine; it is mostly the per-line pre-filters, and still rises somewhat under load);
  # WallSec is a backstop for a starved process. Past either, the lock counts as answered, so the
  # window is pinged: the fail-open direction, which is what every limit-stopped window got before
  # this check. Both are read before every JSON parse and every 512 lines. If the CPU time cannot be
  # read, only the wall clock bounds the scan.
  # PassSec bounds the whole resume pass: claude-resume-sessions.ps1 checks every window in one
  # process, one after another, inside the rotation mutex, so the scans' wall time is summed across
  # calls in this process ($script:ParkedScanPassSpent). Once the pass has spent PassSec, each further
  # parked window counts as answered without a scan (fail-open, pinged).
  param([string]$LockPath, [double]$BudgetSec = 15, [double]$WallSec = 60, [double]$PassSec = 60,
    # Test seam: returns this process's CPU seconds. A throw (or $null) leaves only the wall clock bounding the scan.
    [scriptblock]$CpuProbe = { [Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalSeconds })
  if ($null -eq $script:ParkedScanPassSpent) { $script:ParkedScanPassSpent = 0.0 }
  $left = $PassSec - $script:ParkedScanPassSpent
  if ($left -le 0) { return $true }
  if ($left -lt $WallSec) { $WallSec = $left }
  $sw = [Diagnostics.Stopwatch]::StartNew()
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
    $cpuNow = { try { & $CpuProbe } catch { $null } }
    $cpu0 = & $cpuNow
    $n = 0
    $fs = [IO.File]::Open([string]$lock.session, 'Open', 'Read', 'ReadWrite')
    $rd = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
    try {
      while ($null -ne ($l = $rd.ReadLine())) {
        if ((++$n % 512) -eq 0 -and (($null -ne $cpu0 -and ((& $cpuNow) - $cpu0) -ge $BudgetSec) -or $sw.Elapsed.TotalSeconds -ge $WallSec)) { return $true }
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
          # Same second as the park: the seconds key cannot say which side, so compare in full.
          $c = [string]::CompareOrdinal($key, $sinceKey)
          $prevAfter = if ($c -ne 0) { $c -gt 0 } else {
            try { ($l -match '.*"timestamp"\s*:\s*"([^"]+)"') -and (ConvertTo-UtcStamp $Matches[1]) -ge $since } catch { $false }
          }
        }
        if ($l -notmatch '"type"\s*:\s*"(user|attachment)"') { continue }
        if ($queued) { if (-not $readAfter) { continue } }
        elseif ([string]::CompareOrdinal($key, $sinceKey) -lt 0) { continue }
        if ((($null -ne $cpu0 -and ((& $cpuNow) - $cpu0) -ge $BudgetSec) -or $sw.Elapsed.TotalSeconds -ge $WallSec)) { return $true }
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
  } catch { return $false } finally { $script:ParkedScanPassSpent += $sw.Elapsed.TotalSeconds }
}

# ---- the decision ---------------------------------------------------------------------------
function Test-MergePrParked {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][int]$Pr,
    [int]$TimeoutSec = 30,   # the real launcher takes ~3 s; 10 s raced it on a loaded machine and failed open
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
