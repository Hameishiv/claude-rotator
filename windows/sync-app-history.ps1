#Requires -Version 7.5
# (ConvertFrom-Json -DateKind needs 7.5; on an older pwsh every record would look unreadable)
<#
  sync-app-history.ps1  --  make SUBSTANTIVE or UNFINISHED CLI / cross-account Claude Code
  sessions show up in the Claude Code DESKTOP APP's session history, and archive old ones.

  WHY THIS EXISTS
  ---------------
  The CLI writes every session transcript to  ~/.claude/projects/<encoded-cwd>/<id>.jsonl.
  The desktop APP lists only sessions it has a pointer record for, in its own private index:
      %APPDATA%\Claude\claude-code-sessions\<account-uuid>\<workspace-guid>\local_<guid>.json
  This script creates pointer records for transcripts the app never recorded, in EVERY
  account bucket (an account that never tracked the workspace is seeded with the shared
  workspace guid -- it is identical across accounts). It never removes a record.

  AUTO-ARCHIVE
  ------------
  A -Cwd session whose transcript is on this machine and was last written more than -MaxAgeDays ago
  (default 7, UTC; 0 or less = off) is ARCHIVED on every seat. It is remembered in .flag-state.json (autoArchived:
  session id -> value), so this sync does not archive it again for age while the entry stays. The value is one of four kinds:
    <iso date>   archived for age by this sync. If its transcript is written again after that date and is recent (a resume, or a CLI
                 process exiting after a long idle: it appends a few lines) it is
                 un-archived once and archived again when stale (unless its records were all
                 removed and recreated meanwhile: then it simply stays un-archived).
    kept <iso>   you un-archived it (a change the sync sees, at any age and in any run, when the entry is absent or a date), or a record carries autoArchiveExempt
                 (the app appears to set it: inferred, issue #16). Never archived for age again.
    seen <iso>   it was already archived on some seat when it became due: left alone, never revived.
    revive <iso> an un-archive the sync started and is finishing (a record write failed part way); the next run that is not held
                 resolves it: un-archived -> entry removed (so it is archived for age again when stale); archived -> seen.
  If the state save fails, the sync errs toward leaving the session as it is (after an archive or revive it may then
  be recorded as seen or kept; both keep it as it is). A failed record write is finished on the next run (below).
  Limit: an un-archive the sync never saw as a change (made before this version first ran, or with the state
  file deleted) is not known.
  Not archived: a session pinned (isStarred, as this run resolves it), written in the last 10 minutes, one with a
  record known from the last run that can't be read, or one whose pin write failed this run. If an archive write fails on
  one record, the other records are still archived and the failed one is archived next run. With a state file from before the record map (no 'cli'
  map), any unreadable known record holds every session and nothing is saved. It runs in the flag step, so only
  while the app is closed; otherwise it waits for the next run. Records are never moved or deleted.

  WHAT IS COPIED to the seats that lack it
  ----------------------------------------
  A session must be RECENT (last activity within -MaxAgeDays, default 7; 0 = no limit)
  AND match a keep category below. A pinned session of -Cwd whose transcript is on this machine
  is copied too, whatever its age.

  1. SUBSTANTIVE work (the only category kept by default): first instruction is NOT an
     automated-dispatch signature (merge-pr / address-pr, review agents, ping tests, bare
     slash commands) AND the session has >= -MinAssistant assistant turns (default 6).
  2. INTERRUPTED sessions (NON-automated only, >= 2 assistant turns): the transcript
     does not end with a completed assistant turn -- it died mid-tool-call / mid-turn
     (or was Esc-interrupted) and may need resuming. Automated dispatches are excluded:
     their transcripts routinely end at a tool_result even when they finished normally.
  3. UNFINISHED merge-pr / address-pr runs (>= 2 turns): no merge-success
     marker in the transcript, so the PR never merged and the session must stay findable.
     (Marker-based: a transcript that merely QUOTES "merged pull request" text can be
     misclassified as finished. ponytail: acceptable ceiling; tighten to tail-only match
     if it ever misfires.)
  Categories 2 and 3 are OFF by default -- pass -KeepResumable to enable them (they're
  still CLI-resumable either way). They only count files untouched for >10 minutes.

  TITLES
  ------
  Records get real titles, tried in order:
    a) if another account's bucket already has a well-titled record for the session
       (e.g. the app's own native record with its AI title), that record is CLONED;
    b) transcript customTitle/aiTitle (written by /rename or the app);
    c) the user's first typed prompt for that session from ~/.claude/history.jsonl;
    d) a summary record in the transcript;
    e) the first user instruction in the transcript (first 200 lines);
    f) 'Session <datestamp>' as last resort.
  Existing records still titled 'Session <datestamp>' are retitled in place when a
  better title can be derived.

  USAGE
    pwsh -File sync-app-history.ps1                 # sync the workspace in ~/.claude/history-sync-workspace.txt
    pwsh -File sync-app-history.ps1 -DryRun         # report what WOULD change (incl., with the app closed, how many sessions it would archive)
    pwsh -File sync-app-history.ps1 -MaxAgeDays 14  # widen/narrow the window (0 = copy all ages, never auto-archive); it is also the archive age:
                                                    # a smaller value archives the sessions older than it on every seat; later runs with the default do not un-archive them (unless its transcript is written again: then it is revived)
    pwsh -File sync-app-history.ps1 -KeepResumable  # also keep interrupted / died-pre-merge runs
    pwsh -File sync-app-history.ps1 -MinAssistant 10
    pwsh -File sync-app-history.ps1 -Cwd 'C:\path\to\project'
    -NoPrune is still accepted and does nothing (records are never removed now)
    pwsh -File sync-app-history.ps1 -Quiet          # for the launcher hook / scheduled task
    pwsh -File sync-app-history.ps1 -AssumeAppRunning   # testing: act as if the app were open (flags not synced)
    pwsh -File sync-app-history.ps1 -AssumeAppClosed    # testing only: skip the app-running check (a sandbox index)

  SCHEDULED: Windows task 'Claude app-history sync' runs this every 30 min when enabled (hidden, via
  sync-app-history-hidden.vbs), so the app history stays fresh without a seat switch.
  Manage:  Disable-ScheduledTask / Enable-ScheduledTask -TaskName 'Claude app-history sync'

  SAFETY
  - No record is moved or deleted (pruning was removed 2026-11-16; older runs moved records to
    ~/.claude-app-seats\.pruned-history-backups\). Transcripts are never touched. Rolling back to an older copy
    prunes (moves out) the records of old sessions again, kept ones included, and forgets autoArchived; redeploying
    this version does not bring them back: restore them from .pruned-history-backups.
  - Only sessions whose transcript we can actually read are auto-archived; records with no local
    transcript are left alone.
  - Archive/pin flags (isArchived, isStarred) are copied across seats only while the app is closed;
    changed records are backed up to ~/.claude-app-seats\.flag-sync-backups\<ts>\ (newest 10 kept).
    Sidebar groups and the pin list are not synced (claude-rotator issue #10).
  - One run at a time (~/.claude-app-seats\.sync-history.lock): an interactive run waits up to 3 min for it;
    -Quiet (the scheduled task) skips at once. The flag step runs only when -Cwd has transcripts.
  - Classification is cached in ~/.claude-app-seats\.sync-classify-cache.json keyed by file
    size+mtime, so repeated runs don't re-read every transcript.
#>
[CmdletBinding()]
param(
  [string]$Cwd,
  [int]$MinAssistant = 6,
  [int]$MaxAgeDays = 7,       # copy only sessions newer than this; archive older ones (0 = no age limit, no auto-archive). A smaller value archives the sessions older than it; later runs with the default do not un-archive them (unless its transcript is written again: then it is revived)
  [switch]$KeepResumable,     # also keep interrupted / died-pre-merge runs (off by default: recent+substantive only)
  [switch]$DryRun,
  [switch]$NoPrune,           # no-op, kept so old invocations still work (records are never removed)
  [switch]$Quiet,
  [switch]$AssumeAppRunning,  # for the test: behave as if the desktop app were running
  [switch]$AssumeAppClosed    # for the test: skip the app-running check (the test's sandbox index); -AssumeAppRunning wins if both are given
)
$ErrorActionPreference = 'Stop'
# Keep configuration and lock setup at Idle too, even when invoked in the caller's shell.
$selfProc = Get-Process -Id $PID
$prevPriority = $selfProc.PriorityClass
$runLock = $null
try { $selfProc.PriorityClass = 'Idle' } catch { }
try {

if (-not $PSBoundParameters.ContainsKey('Cwd')) {
  $workspaceFile = Join-Path $env:USERPROFILE '.claude\history-sync-workspace.txt'
  if (Test-Path -LiteralPath $workspaceFile -PathType Leaf) {
    try {
      $utf8 = [Text.UTF8Encoding]::new($false, $true)
      $Cwd = $utf8.GetString([IO.File]::ReadAllBytes($workspaceFile)).TrimStart([char]0xFEFF).TrimEnd([char[]](13, 10))
    } catch [Text.DecoderFallbackException] {
      throw 'Save ~/.claude/history-sync-workspace.txt as UTF-8.'
    }
  } else {
    throw 'No history sync workspace is configured. Save its absolute path in ~/.claude/history-sync-workspace.txt (README-claude-rotator.md, "Desktop app session history") or pass -Cwd.'
  }
}
# Check syntax without touching the workspace. An offline share can still have local transcripts.
$inputPath = [string]$Cwd
$verbatim = $inputPath.StartsWith('\\?\', [StringComparison]::Ordinal)
$path = if ($verbatim) { $inputPath } else { $inputPath.Replace('/', '\') }
$device = $path -match '^\\\\[?.]\\'
$extendedUnc = $path -match '^\\\\[?.]\\UNC(?:\\|$)'
$unc = $extendedUnc -or (-not $device -and $path.StartsWith('\\', [StringComparison]::Ordinal))
$pathNames = if ($extendedUnc) {
  $path -replace '^\\\\[?.]\\UNC(?:\\|$)', '\\'
} else {
  $path -replace '^\\\\[?.]\\', '' -replace '^[A-Z]:(?=\\)', ''
}
$uncRoot = if ($unc) { [regex]::Match($pathNames, '^\\\\[^\\]*[^\\ ]\\(?!\.{1,2}(?:\\|$))[^\\]+').Value }
$directoryNames = if ($unc) { $pathNames -replace '^\\\\[^\\]+\\', '' } else { $pathNames }
if ([string]::IsNullOrWhiteSpace($Cwd) -or -not [IO.Path]::IsPathFullyQualified($path) -or
    ($unc -and -not $uncRoot) -or
    # \\server\pipe\..., \\server\mailslot\... and \\server\IPC$\... are never a file share
    # (Windows drops trailing dots and spaces).
    ($unc -and $uncRoot -match '^\\\\[^\\]+\\(?:pipe|mailslot|IPC\$)[. ]*$') -or
    # A device path must name a drive or a UNC share (not \\.\pipe\..., a volume GUID or another device).
    ($device -and -not $extendedUnc -and $path -notmatch '^\\\\[?.]\\[A-Z]:\\') -or
    (-not $verbatim -and $directoryNames -match '(^|\\)(?!\.{1,2}(?:\\|$))[^\\]*[. ](?:\\|$)') -or
    ($path.StartsWith('\\?\', [StringComparison]::Ordinal) -and $inputPath.Contains('/')) -or
    ($verbatim -and ($inputPath.Substring(3).Contains('\\') -or $directoryNames -match '(^|\\)\.{1,2}(?:\\|$)')) -or
    (-not $verbatim -and -not $unc -and $directoryNames -match '(^|\\)NUL(?:\\|$)') -or
    -not $pathNames -or $pathNames -match '[\x00-\x1F"<>|:*?]') {
  throw 'Use a valid absolute Windows workspace path with -Cwd or in ~/.claude/history-sync-workspace.txt. Check for quotes, trailing spaces or unsupported characters.'
}
$root = if ($unc) {
  # Keep the original prefix spelling and use the same share boundary as validation.
  $path.Substring(0, $path.Length - $pathNames.Length + $uncRoot.Length)
} else {
  [IO.Path]::GetPathRoot($path)
}
$components = [Collections.Generic.List[string]]::new()
foreach ($component in ($path.Substring($root.Length) -split '\\')) {
  if ([string]::Equals($component, '..', [StringComparison]::Ordinal)) {
    if ($components.Count) { $components.RemoveAt($components.Count - 1) }
  } elseif ($component -and -not [string]::Equals($component, '.', [StringComparison]::Ordinal)) {
    $components.Add($component)
  }
}
$Cwd = [IO.Path]::Combine($root, ($components -join '\'))
# Share roots with a final separator already have a distinct transcript key.
if ($unc -and -not $components.Count -and $path.EndsWith('\', [StringComparison]::Ordinal)) {
  $Cwd = $Cwd.TrimEnd('\') + '\'
}

$ccs = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
if (-not (Test-Path -LiteralPath $ccs)) { throw "App session index not found: $ccs (is the desktop app installed?)" }


$cwdJson = $Cwd -replace '\\', '\\'
# A record belongs to this workspace when its cwd is a string equal to -Cwd ignoring case only. Not -eq: that
# compares by culture, so 'é' and 'e' + combining accent match although they are two NTFS directories.
function Test-IsWorkspace($recCwd) { $recCwd -is [string] -and [string]::Equals($recCwd, $Cwd, [StringComparison]::OrdinalIgnoreCase) }
# One run at a time: two runs share temp-file names and the flag baseline. Held until the script ends.
$lockDir = Join-Path $env:USERPROFILE '.claude-app-seats'
$null = New-Item -ItemType Directory -Path $lockDir -Force
# Interactive runs (a seat switch, claude-sync-history) wait up to 3 min for a run already in progress, so the
# user isn't told to reopen the app while it is still writing; -Quiet (the scheduled task) skips at once.
$lockUntil = [DateTime]::UtcNow.AddMinutes($(if ($Quiet) { 0 } else { 3 })); $lockSaid = $false
while (-not $runLock) {
  try { $runLock = [IO.File]::Open((Join-Path $lockDir '.sync-history.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
  catch [IO.IOException] {
    if (($_.Exception.HResult -band 0xFFFF) -notin 32, 33) { throw }   # only a sharing violation means another run holds it
    if ([DateTime]::UtcNow -ge $lockUntil) { Write-Warning 'another history sync is still running; this one is skipped. That run may still be writing session records: opening the app before it finishes can undo an archive or pin change (an auto-archive undone that way is then read as your un-archive and kept).'; return }
    if (-not $lockSaid) { 'another history sync is running; waiting for it (up to 3 min)...'; $lockSaid = $true }
    Start-Sleep -Seconds 2
  }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'   # after the lock; local time, so the repeated hour at a DST fall-back can reuse a name
# transcripts are listed after the lock, so a run that waited sees what was written meanwhile
# The CLI's project-folder name: every character other than A-Z, a-z, 0-9 becomes '-' (case-sensitive match, as
# the CLI's regex is); a name over 200 characters is cut to 200 plus '-' and a hash, so look that one up by prefix.
$enc = $Cwd -creplace '[^A-Za-z0-9]', '-'
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$projDir = Join-Path $projRoot $enc
if ($enc.Length -gt 200) {
  # The hash can't be recomputed here, so a single folder with that prefix is taken as this one; with
  # more than one the run cannot tell them apart and stops. Case-insensitive, as the filesystem is.
  $cand = @(Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($enc.Substring(0, 200) + '-', [StringComparison]::OrdinalIgnoreCase) })
  if ($cand.Count -eq 1) { $projDir = $cand[0].FullName }
  elseif ($cand.Count -gt 1) { if (-not $Quiet) { "no transcripts for $($Cwd): $($cand.Count) project folders share its 200-character prefix; can't tell which is this one" }; return }
}
if (-not (Test-Path -LiteralPath $projDir)) { if (-not $Quiet) { "no transcripts for $Cwd ($projDir)" }; return }
$transcripts = @(Get-ChildItem -LiteralPath $projDir -File -Filter '*.jsonl')
if ($transcripts.Count -eq 0) { if (-not $Quiet) { "no transcripts for $Cwd" }; return }
# a run killed between writing a .sync-tmp and moving it into place leaves it in the app's index; the suffix is
# only ours and the lock means no other run is mid-write, so any found now is a leftover
if (-not $DryRun -and (Test-Path -LiteralPath $ccs)) {
  Get-ChildItem -LiteralPath $ccs -Recurse -File -Filter '*.sync-tmp' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
$cachePath  = Join-Path $env:USERPROFILE '.claude-app-seats\.sync-classify-cache.json'
$DateTitleRx = '^Session \d{4}-\d{2}-\d{2}'

# First instruction that matches ANY of these = an automated dispatch.
$AutoSignature = '(?i)^\s*/?(merge-pr|address-pr|orch-pass)\b' +
  '|^\s*you are the pr shepherd\b' +
  '|^\s*reply with exactly' + '|^\s*pong\b' +
  '|^\s*review this change for security' +
  '|^\s*scan\b.*\bhardcoded\b' +
  '|^\s*audit\b.*\bmigration' +
  '|^\s*review\b.*\bedge function' +
  '|^\s*/(compact|clear|resume|status|cost|help|context|export|init|review|security-review|code-review)\b'
$MergePrSignature = '(?i)^\s*/?(merge-pr|address-pr)\b'

function Get-FirstInstruction([string]$raw, [int]$maxLines = 40) {
  foreach ($line in (($raw -split "`n") | Select-Object -First $maxLines)) {
    $lt = $line.Trim(); if (-not $lt) { continue }
    try { $o = $lt | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'user' -and $o.message.content) {
      $c = $o.message.content; $t = ''
      if ($c -is [string]) { $t = $c } elseif ($c[0].text) { $t = ($c | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text }
      if (-not $t) { continue }
      if ($t[0] -eq '<') {
        # A slash-command session records the command as a wrapper (<command-name>/merge-pr
        # ... <command-args>554) followed by the expanded skill text as a SECOND user message.
        # Skipping every '<' text made the skill preamble the "first instruction", so
        # /merge-pr sessions matched no signature and 179 of them synced as substantive
        # (2026-07-07). Surface the command itself; skip other wrappers (caveats, reminders).
        if ($t -match '<command-name>\s*(/?[^<\r\n]+?)\s*</command-name>') {
          $cmd = $Matches[1]; if ($cmd[0] -ne '/') { $cmd = "/$cmd" }
          $cargs = if ($t -match '<command-args>([^<]*)</command-args>') { ' ' + $Matches[1].Trim() } else { '' }
          return ($cmd + $cargs).Trim()
        }
        continue
      }
      return ($t -replace '\s+', ' ').Trim()
    }
  }
  return ''
}

# Did the transcript end with a COMPLETED assistant turn? $false = died mid-work
# (unanswered user msg / tool_result, dangling tool_use, max_tokens cutoff, Esc interrupt).
function Test-EndsClean([string]$raw) {
  $lines = $raw -split "`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i]
    if ($l -notmatch '"type":\s*"(user|assistant)"') { continue }
    if ($l -match '"isMeta":\s*true') { continue }
    $o = $null
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'user') {
      $c = $o.message.content
      $t = if ($c -is [string]) { $c } elseif ($c -and $c[0].text) { [string]$c[0].text } else { '' }
      if ($t -and $t[0] -eq '<') { continue }   # command wrappers / caveats, not a real message
      return $false
    }
    if ($o.type -eq 'assistant') {
      $sr = $o.message.stop_reason
      if ($sr -eq 'end_turn' -or $sr -eq 'stop_sequence') { return $true }
      if ($sr) { return $false }                # tool_use / max_tokens: mid-work
      $c = $o.message.content
      if ($c -isnot [string]) { foreach ($b in $c) { if ($b.type -eq 'tool_use') { return $false } } }
      return $true
    }
  }
  return $true   # no real messages at all -> nothing worth resuming
}

# ---- classification cache (size+mtime keyed) --------------------------------
$cache = @{}
if (Test-Path -LiteralPath $cachePath) {
  try {
    foreach ($p in (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).PSObject.Properties) { $cache[$p.Name] = $p.Value }
  } catch {}
}
$script:cacheDirty = $false

function Get-Class($file) {
  # 'v3' (orch-pass / PR-shepherd signature, 2026-11-02) and 'v2' bust entries classified before the 2026-07-07 command-wrapper/interrupted fixes.
  $key = 'v3|{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
  $hit = $cache[$file.BaseName]
  if ($hit -and $hit.k -eq $key) { return $hit }
  $raw = Get-Content -LiteralPath $file.FullName -Raw
  if ($null -eq $raw) { $raw = '' }   # an empty transcript is readable: 0 turns, not kept
  $fi = Get-FirstInstruction $raw 40
  $entry = [pscustomobject]@{
    k      = $key
    asst   = ([regex]::Matches($raw, '"type":"assistant"')).Count
    sig    = [bool]($fi -match $AutoSignature)
    mpr    = [bool]($fi -match $MergePrSignature)
    merged = [bool]($raw -match '(?i)merged pull request|"merged"\s*:\s*true')
    clean  = [bool](Test-EndsClean $raw)
  }
  $script:cache[$file.BaseName] = $entry
  $script:cacheDirty = $true
  return $entry
}

# ---- title sources -----------------------------------------------------------
# The user's first typed prompt per session (from the CLI's global prompt history).
$histTitle = @{}
$hp = Join-Path $env:USERPROFILE '.claude\history.jsonl'
if (Test-Path -LiteralPath $hp) {
  foreach ($line in Get-Content -LiteralPath $hp) {
    if (-not $line) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $sid = [string]$o.sessionId
    if ($sid -and $o.display -and -not $histTitle.ContainsKey($sid)) { $histTitle[$sid] = [string]$o.display }
  }
}

function Get-BestTitle([string]$raw, [string]$cliId) {
  $m = [regex]::Matches($raw, '"(?:customTitle|aiTitle)"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if ($m.Count -gt 0) { try { return (ConvertFrom-Json ('"' + $m[$m.Count - 1].Groups[1].Value + '"')) } catch {} }
  if ($histTitle.ContainsKey($cliId)) { return $histTitle[$cliId] }
  $s = [regex]::Match($raw, '\{"type":"summary","summary":"((?:[^"\\]|\\.)*)"')
  if ($s.Success) { try { return (ConvertFrom-Json ('"' + $s.Groups[1].Value + '"')) } catch {} }
  return (Get-FirstInstruction $raw 200)
}

$tFile = @{}; foreach ($m in $transcripts) { $tFile[$m.BaseName] = $m }
$titleCache = @{}
function Get-TitleFor([string]$cliId) {
  if ($titleCache.ContainsKey($cliId)) { return $titleCache[$cliId] }
  $t = ''
  $tf = $tFile[$cliId]
  if ($tf) {
    try { $t = Get-BestTitle (Get-Content -LiteralPath $tf.FullName -Raw) $cliId } catch { $t = '' }
  }
  if ($t) { $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt 60) { $t = $t.Substring(0, 60) } }
  $titleCache[$cliId] = $t
  return $t
}
function Get-ModelFor($file) {
  foreach ($line in Get-Content -LiteralPath $file.FullName -TotalCount 60) {
    if ($line -match '"model"\s*:\s*"(claude-[^"]+)"') { return $Matches[1] }
  }
  return 'claude-opus-4-8'
}

function Write-Record([string]$subDir, $file) {
  $created = ([DateTimeOffset]$file.CreationTime).ToUnixTimeMilliseconds()
  $act     = ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeMilliseconds()
  $title = Get-TitleFor $file.BaseName
  if (-not $title) { $title = 'Session ' + $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
  $model = Get-ModelFor $file
  $sid = "local_$([guid]::NewGuid().ToString())"
  $tj = $title | ConvertTo-Json -Compress
  # carry the flags pass 1.4 resolved for this session (default: not archived, not starred)
  $fw = $flagWant[$file.BaseName]
  $arch = if ($fw -and $fw.isArchived) { 'true' } else { 'false' }
  $starPart = if ($fw -and $fw.isStarred) { ',"isStarred":true' } else { '' }
  $json = '{"sessionId":"' + $sid + '","cliSessionId":"' + $file.BaseName + '","cwd":"' + $cwdJson + '","originCwd":"' + $cwdJson + '","lastFocusedAt":' + $act + ',"createdAt":' + $created + ',"lastActivityAt":' + $act + ',"model":"' + $model + '","effort":"xhigh","isArchived":' + $arch + $starPart + ',"title":' + $tj + ',"titleSource":"auto","permissionMode":"default","remoteMcpServersConfig":[],"chromePermissionMode":"skip_all_permission_checks","completedTurns":1,"bridgeSessionIds":[],"alwaysAllowedReasons":[],"sessionPermissionUpdates":[],"classifierSummaryEnabled":true,"spawnSeed":{}}'
  try { $null = $json | ConvertFrom-Json } catch { return $false }
  $path = Join-Path $subDir "$sid.json"
  Write-RecordFile $path $json
  $script:madeRecs.Add(@{ cli = $file.BaseName; path = $path; isArchived = [bool]($fw -and $fw.isArchived); isStarred = [bool]($fw -and $fw.isStarred) })
  return $true
}

# ---- classify every transcript once ------------------------------------------
$nowUtc = [DateTime]::UtcNow   # age checks compare UTC, so a DST change can't skew them
$allT = New-Object System.Collections.Generic.HashSet[string]
$keep = New-Object System.Collections.Generic.HashSet[string]
$nInterrupted = 0; $nUnfinishedMpr = 0; $nStale = 0
foreach ($m in $transcripts) {
  # A transcript that can't be read (deleted since it was listed, access denied) is left out entirely: its
  # session is neither copied nor auto-archived this run, and is retried next run.
  try { $c = Get-Class $m }
  catch { Write-Warning "could not read transcript $($m.FullName) ($($_.Exception.Message)); its session is left alone this run"; continue }
  [void]$allT.Add($m.BaseName)
  $settled = ($nowUtc - $m.LastWriteTimeUtc).TotalMinutes -gt 10   # ignore still-running sessions
  # RECENCY: copy only sessions whose last activity is within the window. Older ones are archived
  # instead (pass 1.4, AUTO-ARCHIVE in the header). $MaxAgeDays <= 0 disables the age limit.
  $recent  = ($MaxAgeDays -le 0) -or (($nowUtc - $m.LastWriteTimeUtc).TotalDays -le $MaxAgeDays)
  $substantive   = (-not $c.sig) -and ($c.asst -ge $MinAssistant)
  # Interrupted excludes automated dispatches: a dispatched agent's transcript simply ENDS
  # at its last tool_result (the harness stops it there), so an unclean tail on an automated
  # session usually means "finished normally", not "needs resuming" — 132 completed
  # security-review agents synced as interrupted before this exclusion (2026-07-07).
  # Automated merge-pr runs are covered by the merge-marker rule below instead.
  $interrupted   = $KeepResumable -and $settled -and (-not $c.sig) -and (-not $c.clean) -and ($c.asst -ge 2)
  # DIED-pre-merge, not merely unmerged: many merge-pr runs finish by design without
  # merging (standalone PRs are parked for the owner), ending with a clean assistant
  # summary. "No merge marker" alone kept 165 of them; requiring an unclean tail keeps
  # only runs that actually crashed mid-review and still have no merge.
  $unfinishedMpr = $KeepResumable -and $settled -and $c.mpr -and (-not $c.merged) -and (-not $c.clean) -and ($c.asst -ge 2)
  $qualifies = $substantive -or $interrupted -or $unfinishedMpr
  if ($recent -and $qualifies) {
    [void]$keep.Add($m.BaseName)
    if (-not $substantive) { if ($interrupted) { $nInterrupted++ } else { $nUnfinishedMpr++ } }
  } elseif ($qualifies) {
    $nStale++   # would have been kept, but older than $MaxAgeDays
  }
}
if ($cacheDirty) {
  try { ($cache | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $cachePath -Encoding UTF8 } catch {}
}
if (-not $Quiet) {
  $ageNote = if ($MaxAgeDays -le 0) { 'no age limit' } else { "$nStale over ${MaxAgeDays}d" }
  $resNote = if ($KeepResumable) { "$nInterrupted interrupted + $nUnfinishedMpr unfinished merge-pr" } else { 'resumability off' }
  "classified $($transcripts.Count) transcripts for ${Cwd}: $($keep.Count) to be on every seat ($resNote), $($allT.Count - $keep.Count) not ($ageNote; MinAssistant=$MinAssistant)"
}

# Is the desktop app running? Checked BEFORE any record is read, so a record the app writes as it quits
# can't be read stale and written back by pass 1.4. Always checked; only the test passes -AssumeAppClosed.
function Test-AppUp {
  if ($AssumeAppRunning) { return $true }
  if ($AssumeAppClosed) { return $false }   # only ever passed by the test, for its sandbox; otherwise always check
  # Fail closed: every process named claude counts as the app UNLESS its path is a known Claude Code CLI location.
  # So a new install layout, or a path that can't be read (e.g. an elevated CLI), skips the flag step rather than
  # writing under a running app.
  # Also counted: any process, whatever its name, running from the app's install folders.
  $script:appBlockers = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $pp = $null; try { $pp = $_.Path } catch { }
    $isClaude = $_.ProcessName -eq 'claude'
    $isCli = $pp -and ($pp -like '*\.local\bin\claude.exe' -or $pp -like '*\Claude\claude-code\*\claude.exe')
    # the app's own executables, not the helpers under resources\ (chrome-native-host runs whenever Chrome is open)
    $inApp = $pp -and ($pp -like '*\AnthropicClaude\app-*\*.exe' -or $pp -like '*\WindowsApps\Claude_*\app\*.exe') -and $pp -notlike '*\resources\*'
    if ($inApp -or ($isClaude -and -not $isCli)) {
      "pid $($_.Id) $(if ($pp) { $pp } else { '(path unreadable)' })"
    }
  })
  return $script:appBlockers.Count -gt 0
}
$appUp = Test-AppUp

# ---- pass 1: scan all account buckets once ------------------------------------
$accts = @(Get-ChildItem -LiteralPath $ccs -Directory)
$subCounts = @{}   # acct -> (sub -> this-cwd record count)
$guidVotes = @{}   # sub  -> total count across accounts (workspace guid vote)
$recIndex  = @{}   # cliSessionId -> @{ raw = record json; good = has a real title }
$bucketRecs = @{}  # "acct|sub" -> list of @{ file; j }
$unreadableRecs = 0   # records skipped below because they could not be read or parsed
$cwdSpelling = @{}    # sub and "acct|sub" -> the app's own spelling of this workspace (the match below ignores case)
foreach ($acct in $accts) {
  $subCounts[$acct.Name] = @{}
  foreach ($sub in @(Get-ChildItem -LiteralPath $acct.FullName -Directory)) {
    $cnt = 0
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $sub.FullName -File -Filter '*.json') {
      $rawRec = $null; $j = $null
      try { $rawRec = Get-Content -LiteralPath $f.FullName -Raw; $j = $rawRec | ConvertFrom-Json -DateKind String } catch { $unreadableRecs++; continue }
      if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { $unreadableRecs++; continue }   # empty or "null" (e.g. truncated): unreadable, like a parse error
      $list.Add(@{ file = $f; j = $j })
      if (Test-IsWorkspace $j.cwd) {
        $cnt++
        if (-not $cwdSpelling.ContainsKey($sub.Name)) { $cwdSpelling[$sub.Name] = $j.cwd }
        if (-not $cwdSpelling.ContainsKey("$($acct.Name)|$($sub.Name)")) { $cwdSpelling["$($acct.Name)|$($sub.Name)"] = $j.cwd }
        $cli = [string]$j.cliSessionId
        if ($cli) {
          $good = -not ([string]$j.title -match $DateTitleRx)
          $cur = $recIndex[$cli]
          if (-not $cur -or ($good -and -not $cur.good)) { $recIndex[$cli] = @{ raw = $rawRec; good = $good } }
        }
      }
    }
    $bucketRecs["$($acct.Name)|$($sub.Name)"] = $list
    $subCounts[$acct.Name][$sub.Name] = $cnt
    if ($cnt -gt 0) { $guidVotes[$sub.Name] = [int]$guidVotes[$sub.Name] + $cnt }
  }
}
$wsGuid = ($guidVotes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
# New records carry the app's spelling of the workspace, not the setting's (which may differ in case): the
# destination folder's own spelling when it has one (pass 2), else this shared one.
if ($wsGuid) { $cwdJson = $cwdSpelling[$wsGuid] -replace '\\', '\\' }
$sharedCwdJson = $cwdJson
# Without an app record for this exact workspace there is no workspace ID to file new records under,
# so pass 2 adds no record on any seat (flag sync below still runs). Say so, rather than reporting a plain zero.
if (-not $wsGuid -and -not $Quiet) {
  if ($unreadableRecs) {
    # A locked or half-written record may be the one that matches, so don't blame the path alone.
    "no readable app record on any seat has workspace $($Cwd) ($unreadableRecs record(s) could not be read): retry after the desktop app closes; if it still says this, save one session for it in the desktop app, or check the path matches the app's spelling"
  } else {
    "no app record on any seat has workspace $($Cwd): save one session for it in the desktop app, or check the path matches the app's spelling"
  }
}

# ---- pass 1.4: archive and pin flags follow you across seats -------------------
# isArchived and isStarred (the record's pin flag) live in each seat's own record, with no time of change.
# So we remember every record's flags from the last run (.flag-state.json): a record whose flag
# differs from that is the one you changed, and its value goes to every seat's record of the
# session (true wins if two seats changed opposite ways). A record not seen last run counts as changed
# only if it is on. A session with a record that can't be written or read keeps its last baseline
# (below; with a state file that predates its record->session map, an unreadable record holds every session and nothing is saved). First run, or a session no record was
# seen for before: set on any seat -> set on all. Records are matched across seats by
# cliSessionId, whatever their cwd. Each folder's archived-sessions.idx is kept in step with its records
# (after pass 2). The sidebar pin LIST and groups are NOT synced: the app keeps
# them in each seat's own Local Storage and rewrites claude_desktop_config.json from there.
# Old sessions are archived here too (AUTO-ARCHIVE in the header), so they get the same writes and baseline.
# Runs only while the app is closed: the live app holds its records in memory and rewrites them,
# so a flag we set under it would be lost and then read back as the user's own change ($appUp, above pass 1).
$flagStatePath = Join-Path $env:USERPROFILE '.claude-app-seats\.flag-state.json'
$flagBackupRoot = Join-Path $env:USERPROFILE '.claude-app-seats\.flag-sync-backups'
$flagSkip = $false      # pass 1.4 did not run: leave records AND the state file alone
$flagPrevAll = $null    # $null = first run (no state file yet)
if (-not $appUp) { $appUp = Test-AppUp }   # again, just before the first write (pass 1 took a while)
if ($appUp) {
  $flagSkip = $true
  if (-not $Quiet) {
    $why = if ($AssumeAppRunning) { '-AssumeAppRunning' } else { "$(@($script:appBlockers)[0])$(if (@($script:appBlockers).Count -gt 1) { " and $(@($script:appBlockers).Count - 1) more" })" }
    "archive/pin flags not synced: the desktop app (or a claude process not at a known CLI path) is running ($why; they sync$(if ($MaxAgeDays -gt 0) { ', and old sessions are auto-archived,' }) at the next seat switch)"
  }
} elseif (Test-Path -LiteralPath $flagStatePath) {
  # A present-but-unreadable state file is NOT a first run: a first run unions every flag, which
  # would resurrect everything the user un-archived/unpinned since. Skip and say so.
  try {
    $flagPrevAll = Get-Content -LiteralPath $flagStatePath -Raw | ConvertFrom-Json -AsHashtable
    if ($flagPrevAll -isnot [hashtable]) { throw 'not a JSON object' }
    foreach ($fk in 'isArchived', 'isStarred') { if ($flagPrevAll[$fk] -isnot [hashtable]) { throw "'$fk' is not an object" } }
    foreach ($fk in 'cli', 'autoArchived') { if ($flagPrevAll.ContainsKey($fk) -and $flagPrevAll[$fk] -isnot [hashtable]) { throw "'$fk' is not an object" } }
  } catch {
    $flagSkip = $true
    if ($_.Exception -is [IO.IOException] -and ($_.Exception.HResult -band 0xFFFF) -in 32, 33) {
      Write-Warning "flag state file $flagStatePath is in use ($($_.Exception.Message)); archive/pin flags not synced this run. This clears on its own; do not delete it."
    } else {
      Write-Warning "flag state file $flagStatePath is unreadable ($($_.Exception.Message)); archive/pin flags not synced this run. If it is corrupt, delete it to start again (the next run then counts a flag set on any seat as set on all, and, with the app closed, archives every old unpinned session of this workspace with a local transcript and no autoArchiveExempt record once more, un-archived ones included, because deleting it also forgets which sessions were archived for age)"
    }
  }
}
$flagNextAll = @{}
$flagWant = @{}         # cliSessionId -> @{ isArchived; isStarred }: the resolved values, for records pass 2 creates
$pinResolved = @{}      # cliSessionId -> resolved isStarred, kept even for held sessions (pass 2's pinned-copy rule)
$flagByCli = @{}
# If a session's record can't be written, that SESSION keeps last run's baseline (as if this run never
# happened for it), and its new clones are left out. The next run then compares it with that baseline: the
# records we did write read as changed (where they differ) and the failed one as unchanged, so its stale
# value can't outvote the change. Saving the new values instead would let it vote as "known" and undo it.
# A record known last run that can't be read holds back its session the same way (see below).
$flagFail = $false
$flagFailCli = New-Object 'System.Collections.Generic.HashSet[string]'
# Sessions the age rule has handled (cliSessionId -> value), from .flag-state.json. A session is not archived for
# age while it stays in here. The four value kinds are listed in the header (AUTO-ARCHIVE): a plain ISO date, "kept <iso>",
# "seen <iso>" and "revive <iso>". A state file from before this map simply has none yet.
$autoArch = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
if ($flagPrevAll -and -not $flagSkip -and $flagPrevAll['autoArchived'] -is [hashtable]) { foreach ($k in $flagPrevAll['autoArchived'].Keys) { $autoArch[$k] = $flagPrevAll['autoArchived'][$k] } }
# Returns the date of a plain-date entry (UTC), $null for kept / seen / revive entries.
function Get-AutoArchDate($v) {
  if ($v -is [datetime]) { return $v.ToUniversalTime() }
  if ([string]$v -match '^(kept|seen|revive) ') { return $null }
  $d = [datetime]::MinValue
  if ([datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { return $d }
  return $null
}
$autoDone = 0; $autoFlipped = 0; $autoRevived = 0; $autoKept = 0   # $autoKept: due, but the user had it un-archived: remembered, not archived
# Pass 1 reads every record once; pass 1.4, pass 1.5 and the pass 2 retitle each write a record back from that
# copy. Each checks first that the file is unchanged since pass 1 read it, so none writes an older copy over a
# newer one (the app writing as it starts or quits). A record found changed, or one pass 1.5 could not write, is skipped by the later
# steps. A failed flag write (pass 1.4) is instead rolled back in memory, so a later step that writes the record puts
# back the value on disk, which matches the held baseline.
$changedOnDisk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
# Write a record through a temp file and an atomic replace, so a killed run can't leave it truncated.
function Write-RecordFile([string]$path, [string]$text) {
  $tmp = "$path.sync-tmp"
  try { Set-Content -LiteralPath $tmp -Value $text -Encoding UTF8 -NoNewline; [IO.File]::Move($tmp, $path, $true) }
  catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
}
function Test-ChangedSinceRead($rec) {
  if ($changedOnDisk.Contains($rec.file.FullName)) { return $true }
  $d = Get-Item -LiteralPath $rec.file.FullName -ErrorAction SilentlyContinue
  if ($d -and $d.LastWriteTimeUtc -eq $rec.file.LastWriteTimeUtc -and $d.Length -eq $rec.file.Length) { return $false }
  [void]$changedOnDisk.Add($rec.file.FullName); return $true
}
$flagHeld = New-Object 'System.Collections.Generic.HashSet[string]'   # "flag|cli|key" of unreadable known records
$flagWarned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # warn once per record
$flagPrevCli = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)   # key -> cliSessionId, last run
if ($flagPrevAll -and $flagPrevAll['cli']) { foreach ($k in $flagPrevAll['cli'].Keys) { $flagPrevCli[$k] = [string]$flagPrevAll['cli'][$k] } }
$flagPrevCi = @{}
$seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (-not $flagSkip) {
  foreach ($kv in $bucketRecs.GetEnumerator()) {
    foreach ($r in $kv.Value) {
      $r.key = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
      [void]$seenKeys.Add($r.key)        # read, even without a session id: not "unreadable"
      $cli = [string]$r.j.cliSessionId; if (-not $cli) { continue }
      if (-not $flagByCli.ContainsKey($cli)) { $flagByCli[$cli] = New-Object System.Collections.Generic.List[object] }
      $flagByCli[$cli].Add($r)
    }
  }
  foreach ($flag in 'isStarred', 'isArchived') {   # pins first: auto-archive skips a session pinned as resolved this run
    $prev = $null
    if ($flagPrevAll) {   # keys are paths: compare them case-insensitively, like $seenKeys
      $prev = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
      foreach ($k in $flagPrevAll[$flag].Keys) { $prev[$k] = $flagPrevAll[$flag][$k] }
    }
    # A record known last run that was not read this run but still exists (unreadable): its session keeps
    # last run's baseline, like a failed write. The state file says which session each record belongs to;
    # a state file from before that map can't say, so then NO state is saved this run.
    if ($prev) { foreach ($k in @($prev.Keys)) {
      if (-not $seenKeys.Contains($k) -and (Test-Path -LiteralPath (Join-Path $ccs $k))) {
        $hc = $flagPrevCli[$k]
        if ($hc) {
          [void]$flagFailCli.Add("$flag|$hc"); [void]$flagHeld.Add("$flag|$hc|$k")
          if ($flagWarned.Add($k)) { Write-Warning "could not read $(Join-Path $ccs $k); a change to that session still reaches its other records, but its saved state is held back until this one can be read, so changing it back meanwhile may not stick. If it is corrupt, restore or delete it; if it was only in use, this clears on its own" }
        } else {
          if (-not $flagFail) { Write-Warning "could not read $(Join-Path $ccs $k); the flag state $(if ($DryRun) { 'would not be' } else { 'is not' }) saved this run. If it is corrupt, restore or delete it; if it was only in use, this clears on its own" }
          $flagFail = $true
        }
      }
    } }
    $flagPrevCi[$flag] = $prev           # for the save below
    $next = @{}; $flipped = 0
    foreach ($cli in @($flagByCli.Keys)) {
      $rs = $flagByCli[$cli]
      $known = @(); $changed = @()
      foreach ($r in $rs) {
        $r.v = [bool]$r.j.$flag
        if ($prev -and $prev.ContainsKey($r.key)) { $known += $r; if ([bool]$prev[$r.key] -ne $r.v) { $changed += $r } }
        # A record not seen last run (the app made it since, e.g. on a newly used seat) that is ON counts as
        # a change: it was archived/pinned there after the last sync. One that is OFF does not -- a record the
        # app creates starts off, so counting it would un-archive/unpin the session everywhere.
        elseif ($prev -and $r.v) { $changed += $r }
      }
      $want = if ($changed.Count) { [bool]($changed | Where-Object { $_.v }) }
              elseif ($known.Count) { [bool]($known | Where-Object { $_.v }) }
              else { [bool]($rs | Where-Object { $_.v }) }
      if (-not $flagWant.ContainsKey($cli)) { $flagWant[$cli] = @{ isArchived = $false; isStarred = $false } }
      # AUTO-ARCHIVE (the four entry kinds are in the header): a -Cwd session whose transcript is here and older than
      # $MaxAgeDays, not pinned, not held this run, and with no entry. Setting $want lets the writes and the baseline below do
      # the rest; what is remembered is decided after the writes (below). Decided BEFORE $want is overridden:
      # $autoKeep   an un-archive seen this run (a changed record, and the answer is off), at any age and in any run, when the entry
      #             is absent or a date: remembered ("kept"), never archived for age. A record the app marked autoArchiveExempt
      #             (inferred, issue #16) is handled through $autoUserOff when the session comes due (also "kept").
      # $autoDue    old enough: archive it, or just remember it ("seen") if it was already archived on some seat.
      # $autoRevive a plain-date entry whose transcript was written since and is recent, no change this run, every KNOWN record
      #             archived (a new un-archived copy pass 2 made meanwhile is not a change, so it does not block it): un-archive it everywhere.
      # $autoRevFin a "revive" entry left by a held revive: resolved by $want once the session is not held (see the save below).
      $autoDue = $false; $autoKeep = $false; $autoRevive = $false; $autoRevFin = $false; $sessFlips = 0
      $userOffChange = $flag -eq 'isArchived' -and $changed.Count -and -not $want   # as resolved above, before any override
      $autoUserOff = $flag -eq 'isArchived' -and ($userOffChange -or [bool]($rs | Where-Object { $_.j.autoArchiveExempt -eq $true }))
      # in scope: a session of -Cwd whose transcript is here, with auto-archive on and no flag state in doubt
      $inScope = $flag -eq 'isArchived' -and $MaxAgeDays -gt 0 -and -not $flagFail -and $allT.Contains($cli) -and @($rs | Where-Object { Test-IsWorkspace $_.j.cwd }).Count
      # An un-archive seen this run is remembered at ANY age, and in ANY run (also with -MaxAgeDays 0, another -Cwd, or no
      # transcript here: the baseline is saved for it either way, so a later run could not see it as a change), or the
      # session would be archived once it grows old. (A plain-date entry the user un-archived becomes a kept entry.)
      if ($userOffChange -and -not $flagFail -and -not $flagFailCli.Contains("isArchived|$cli") -and (-not $autoArch.ContainsKey($cli) -or (Get-AutoArchDate $autoArch[$cli]))) { $autoKeep = $true }
      if ($inScope -and -not $autoArch.ContainsKey($cli) -and
          -not $flagWant[$cli]['isStarred'] -and -not $flagFailCli.Contains("isStarred|$cli") -and -not $flagFailCli.Contains("isArchived|$cli")) {
        # re-read the write time: the session may have been resumed since the transcripts were listed
        $tw = $null; try { $tw = (Get-Item -LiteralPath $tFile[$cli].FullName).LastWriteTimeUtc } catch { }
        if ($tw -and ([DateTime]::UtcNow - $tw).TotalDays -gt $MaxAgeDays) { $autoDue = $true; if (-not $autoUserOff) { $autoOff = -not $want; $want = $true } }
      }
      # REVIVE: a session this sync archived for age (a plain date in autoArch) that was written again since and is recent
      # again, with no change this run and every record known from the last run still archived (a new un-archived copy does not
      # block it), is un-archived on every seat; once every record is
      # written the entry is forgotten, so it is archived again when it goes stale. If a write fails the entry becomes
      # "revive <iso>" (below), so the next run does not read the sync's own writes as the user's un-archive.
      if ($inScope -and $autoArch.ContainsKey($cli) -and -not $changed.Count -and -not $flagFailCli.Contains("isArchived|$cli") -and $known.Count -and -not @($known | Where-Object { -not $_.v }).Count) {
        $archD = Get-AutoArchDate $autoArch[$cli]
        if ($archD) {
          $tw = $null; try { $tw = (Get-Item -LiteralPath $tFile[$cli].FullName).LastWriteTimeUtc } catch { }
          if ($tw -and $tw -gt $archD -and ([DateTime]::UtcNow - $tw).TotalDays -le $MaxAgeDays) { $autoRevive = $true; $want = $false }
        }
      }
      if ($flag -eq 'isArchived' -and -not $flagFail -and $autoArch.ContainsKey($cli) -and ([string]$autoArch[$cli]) -like 'revive *') { $autoRevFin = $true }   # in ANY run: $want is whatever the records say
      $flagWant[$cli][$flag] = $want
      foreach ($r in $rs) {
        if ($r.v -eq $want) { $next[$r.key] = $want; continue }
        if ($DryRun) { $flipped++; $next[$r.key] = $want; continue }
        # One unwritable record (locked, read-only, ...) must not abort the whole run ($ErrorActionPreference
        # is Stop). Warn, and keep this session's last baseline, so the next run tries again from it.
        $oldProp = $null
        try {
          # pass 1 read this a while ago; if the file changed since, don't write our older copy over it
          if (Test-ChangedSinceRead $r) { throw 'it changed since it was read' }
          $dest = Join-Path (Join-Path $flagBackupRoot $stamp) $r.key
          if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
          }
          $oldProp = @{ had = ($null -ne $r.j.PSObject.Properties[$flag]); v = $r.j.$flag }
          $r.j | Add-Member -NotePropertyName $flag -NotePropertyValue $want -Force
          # temp file + replace: a run killed mid-write must not leave a truncated (unreadable) record
          ($r.j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath "$($r.file.FullName).sync-tmp" -Encoding UTF8 -NoNewline
          [System.IO.File]::Move("$($r.file.FullName).sync-tmp", $r.file.FullName, $true)
          $r.file = Get-Item -LiteralPath $r.file.FullName   # our own write: the next flag compares with this, not with pass 1
          $flipped++; $sessFlips++; $next[$r.key] = $want
        } catch {
          Remove-Item -LiteralPath "$($r.file.FullName).sync-tmp" -Force -ErrorAction SilentlyContinue   # don't leave it in the app's index
          # undo the in-memory change too: a later write of this record (its other flag, pass 1.5, the retitle) must
          # not put the value that failed here on disk, or the held baseline no longer matches the file
          if ($oldProp) { if ($oldProp.had) { $r.j | Add-Member -NotePropertyName $flag -NotePropertyValue $oldProp.v -Force } else { $r.j.PSObject.Properties.Remove($flag) } }
          Write-Warning "could not set $flag on $($r.file.FullName): $($_.Exception.Message) (the session's other records still get the change; its saved state is held back and this record is retried next run)"
          [void]$flagFailCli.Add("$flag|$cli")
        }
      }
      # not held back this run (no failed write, no record known from the last run that can't be read): resolve fully. A
      # held session stores only what the branch below says (a date or a revive entry), or nothing, and is retried next run
      if (-not $flagFailCli.Contains("isArchived|$cli")) {
        if ($autoDue) { if ($autoUserOff) { $autoArch[$cli] = "kept $($nowUtc.ToString('o'))"; if (-not $want) { $autoKept++ } } else { $autoArch[$cli] = if ($autoOff) { $nowUtc.ToString('o') } else { "seen $($nowUtc.ToString('o'))" }; $autoDone++; if ($autoOff) { $autoFlipped++ } } }
        elseif ($autoKeep) { $autoArch[$cli] = "kept $($nowUtc.ToString('o'))" }
        elseif ($autoRevive) { $autoArch.Remove($cli); $autoRevived++ }
        elseif ($autoRevFin) { if ($want) { $autoArch[$cli] = "seen $($nowUtc.ToString('o'))" } else { $autoArch.Remove($cli); $autoRevived++ } }   # still archived: someone archived it again
      }
      # Held (a write failed) after at least one record was written: the next run reads the sync's own writes as a change, so
      # say what they were. A revive becomes "revive <iso>"; an age archive stores its plain date (the failed record is then
      # written through the normal change path). Nothing written: the baseline is held, nothing to say, store nothing.
      elseif ($flag -eq 'isArchived' -and $sessFlips -gt 0) {
        if ($autoRevive) { $autoArch[$cli] = "revive $($nowUtc.ToString('o'))" }
        elseif ($autoDue -and -not $autoUserOff -and $autoOff) { $autoArch[$cli] = $nowUtc.ToString('o'); $autoDone++; $autoFlipped++ }
      }
    }
    $flagNextAll[$flag] = $next
    if (-not $Quiet -and $flipped -gt 0) { "$(if ($DryRun) { 'WOULD set' } else { 'set' }) $flag on $flipped record(s) to match the other seats$(if ($flag -eq 'isArchived') { ' or for the age rule' })$(if (-not $prev) { ' (first run: set on any seat -> set on all)' })" }
  }
  # A session held back this run (a record failed), or every session when no state is saved, gets no resolved
  # flags for the records pass 2 creates: those are written neutral (off), which the next run doesn't count as
  # a change, and the next good run then sets them like any other record.
  foreach ($kv in $flagWant.GetEnumerator()) { $pinResolved[$kv.Key] = [bool]$kv.Value['isStarred'] }
  if ($flagFail) { $flagWant.Clear() } else { foreach ($fc in $flagFailCli) { [void]$flagWant.Remove(($fc -split '\|', 2)[1]) } }
  if (-not $Quiet -and ($autoDone -gt 0 -or $autoKept -gt 0 -or ($DryRun -and $MaxAgeDays -gt 0))) { "$(if ($DryRun) { 'WOULD auto-archive' } else { 'auto-archived' }) $autoFlipped session(s) last used over ${MaxAgeDays}d ago (+$($autoDone - $autoFlipped) already archived on a seat, $(if ($DryRun) { 'would be remembered' } else { 'now remembered' })$(if ($autoKept) { "; +$autoKept left un-archived as the user chose" })$(if ($autoRevived) { "; +$autoRevived $(if ($DryRun) { 'would be un-archived' } else { 'un-archived' }) because their transcript was written again" }))" }
  elseif (-not $Quiet -and $autoRevived -gt 0) { "$(if ($DryRun) { 'WOULD un-archive' } else { 'un-archived' }) $autoRevived session(s) archived for age, because their transcript was written again" }
  # keep only the newest 10 backup folders (names are yyyyMMdd-HHmmss, so name order = age order)
  if (-not $DryRun -and (Test-Path -LiteralPath $flagBackupRoot)) {
    foreach ($old in @(Get-ChildItem -LiteralPath $flagBackupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -Skip 10)) {
      try { Remove-Item -LiteralPath $old.FullName -Recurse -Force } catch { Write-Warning "could not remove old flag backup $($old.FullName): $($_.Exception.Message)" }
    }
  }
}
$madeRecs = New-Object System.Collections.Generic.List[object]   # records pass 2 creates, for the saved baseline

try {   # the archive list and flag state below are saved even if pass 1.5 or pass 2 stops the run
# ---- pass 1.5: reconcile stale records of the SAME session across buckets -----
# Each account bucket holds its own record per session, cloned/created ONCE and never refreshed.
# The app resumes a session from record.lastAssistantUuid, so a bucket whose record froze at an
# earlier turn (seat A's FABDEM record stopped at 2026-09-29 while the transcript, and seat G's
# record, ran to 2026-10-05) shows only the old part of the work after a seat switch.
# The transcript is the truth: find the record that points at its tip and copy that session
# state into every record that points at an EARLIER assistant turn. Records pointing at a uuid
# not in the transcript (unknown) or at the tip (current) are left alone.
$StateFields = 'lastAssistantUuid','completedTurns','postTurnSummary','postTurnSummaryFor','writtenBranches','titleTurn','latestUserFrameAt','lastFocusedAt','lastActivityAt'
$reconciled = 0
$byCli = @{}
foreach ($kv in $bucketRecs.GetEnumerator()) {
  foreach ($r in $kv.Value) {
    $cli = [string]$r.j.cliSessionId
    if ((Test-IsWorkspace $r.j.cwd) -and $cli -and $r.j.lastAssistantUuid) {
      if (-not $byCli.ContainsKey($cli)) { $byCli[$cli] = New-Object System.Collections.Generic.List[object] }
      $byCli[$cli].Add($r)
    }
  }
}
foreach ($cli in @($byCli.Keys)) {
 try {   # one session's failure (a locked transcript or record) is warned about and skipped, not the whole run
  $rs = $byCli[$cli]
  if (@($rs | ForEach-Object { [string]$_.j.lastAssistantUuid } | Select-Object -Unique).Count -lt 2) { continue }
  $tf = $tFile[$cli]
  if (-not $tf -or ($nowUtc - $tf.LastWriteTimeUtc).TotalMinutes -le 10) { continue }   # no transcript / still running
  $pos = @{}; $tip = $null; $i = 0
  # opened with ReadWrite sharing, so a CLI still appending to it is neither refused nor blocked
  $tfs = [IO.FileStream]::new($tf.FullName, 'Open', 'Read', 'ReadWrite'); $tsr = [IO.StreamReader]::new($tfs)
  try {   # line by line, so a large transcript is never held whole
    while ($null -ne ($line = $tsr.ReadLine())) {
      $i++
      if ($line.Contains(',"type":"assistant","uuid":"') -and $line -match ',"type":"assistant","uuid":"([0-9a-f-]{36})"') { $pos[$Matches[1]] = $i; $tip = $Matches[1] }
    }
  } finally { $tsr.Dispose() }
  if (-not $tip) { continue }
  $srcRec = $rs | Where-Object { [string]$_.j.lastAssistantUuid -eq $tip } | Sort-Object { [double]$_.j.completedTurns } -Descending | Select-Object -First 1
  if (-not $srcRec) { continue }
  foreach ($r in $rs) {
    $u = [string]$r.j.lastAssistantUuid
    if ($u -eq $tip -or -not $pos.ContainsKey($u)) { continue }
    $wasKnown = $changedOnDisk.Contains($r.file.FullName)
    if (Test-ChangedSinceRead $r) { if (-not $wasKnown) { Write-Warning "left $($r.file.FullName) alone: it changed since it was read (reconciled next run)" }; continue }
    if (-not $DryRun) {
      try {
        $rel = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
        $dest = Join-Path (Join-Path $env:USERPROFILE ".claude-app-seats\.reconcile-backups\$stamp") $rel
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
        $upd = $r.j | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String   # copy: a failed write leaves $r.j as on disk
        foreach ($f in $StateFields) {
          if ($null -eq $srcRec.j.PSObject.Properties[$f]) { continue }
          $v = $srcRec.j.$f
          if ($f -eq 'lastActivityAt' -or $f -eq 'lastFocusedAt') { $v = [Math]::Max([double]$v, [double]$r.j.$f) }
          $upd | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
        }
        Write-RecordFile $r.file.FullName ($upd | ConvertTo-Json -Compress -Depth 100)
        $r.j = $upd
        $r.file = Get-Item -LiteralPath $r.file.FullName   # our own write: the retitle compares with this
      } catch {
        Write-Warning "could not reconcile $($r.file.FullName) ($($_.Exception.Message)); retried next run"
        [void]$changedOnDisk.Add($r.file.FullName)   # no later step in this run writes it
        continue
      }
    }
    $reconciled++
  }
  # clones for buckets that lack the session must start from the current state too
  # (from a well-titled record now at the tip: the tip record itself, or one this pass just reconciled)
  $cloneSrc = @($rs | Where-Object { [string]$_.j.lastAssistantUuid -eq $tip -and -not ([string]$_.j.title -match $DateTitleRx) -and -not $changedOnDisk.Contains($_.file.FullName) }) | Select-Object -First 1
  if (-not $DryRun -and $cloneSrc -and $recIndex.ContainsKey($cli) -and $recIndex[$cli].good) {
    try { $recIndex[$cli] = @{ raw = (Get-Content -LiteralPath $cloneSrc.file.FullName -Raw); good = $true } }
    catch { Write-Warning "could not re-read $($cloneSrc.file.FullName) for new copies ($($_.Exception.Message)); they start from the older copy" }
  }
 } catch { Write-Warning "could not reconcile session $cli ($($_.Exception.Message)); retried next run" }
}
if (-not $Quiet -and $reconciled -gt 0) { "$(if ($DryRun) { 'WOULD reconcile' } else { 'reconciled' }) $reconciled stale record(s) to their transcript tip (originals backed up under ~\.claude-app-seats\.reconcile-backups\$stamp)" }

# ---- pass 2: per account -- seed, retitle, add (no record is ever removed) -----
$made = 0; $cloned = 0; $retitled = 0
# A pinned session of -Cwd whose transcript is on this machine is copied to the seats that lack it, like a kept
# one, whatever its age. "Pinned" is the records' isStarred flag as this run resolved it ($pinResolved, set in a
# dry run too and for held sessions), else as read.
$pinnedCli = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($l in $bucketRecs.Values) { foreach ($r in $l) {
  $pc = [string]$r.j.cliSessionId; if (-not $pc) { continue }
  $pin = if ($pinResolved.ContainsKey($pc)) { $pinResolved[$pc] } else { $r.j.isStarred -eq $true }
  if ($pin) { [void]$pinnedCli.Add($pc) }
} }
foreach ($acct in $accts) {
  # primary sub for this workspace = the one holding the most of this cwd's records
  $bestSubName = $null; $bestCount = 0
  foreach ($kv in $subCounts[$acct.Name].GetEnumerator()) {
    if ($kv.Value -gt $bestCount) { $bestCount = $kv.Value; $bestSubName = $kv.Key }
  }
  if (-not $bestSubName) {
    # This account never tracked the workspace: seed it with the shared workspace guid
    # (it used to be silently skipped here, leaving new accounts with an empty history).
    if (-not $wsGuid) { continue }
    $bestSubName = $wsGuid
    $seedDir = Join-Path $acct.FullName $wsGuid
    if (-not (Test-Path -LiteralPath $seedDir)) {
      if ($DryRun) { if (-not $Quiet) { "WOULD seed $($acct.Name)\$wsGuid" } }
      else {
        try { New-Item -ItemType Directory -Path $seedDir -Force | Out-Null }
        catch { Write-Warning "could not create $seedDir ($($_.Exception.Message)); this account is skipped, retried next run"; continue }
      }
    }
  }
  $bestSub = Join-Path $acct.FullName $bestSubName
  $destSpelling = $cwdSpelling["$($acct.Name)|$bestSubName"]
  $cwdJson = if ($destSpelling) { $destSpelling -replace '\\', '\\' } else { $sharedCwdJson }   # read by Write-Record

  # Retitle datestamp-titled records; index what's present.
  # Walks EVERY sub of the account, not just the primary one (records for this cwd can sit in a secondary
  # workspace-guid folder).
  $present = New-Object System.Collections.Generic.HashSet[string]
  $recs = [System.Collections.Generic.List[object]]::new()
  foreach ($subName in @($subCounts[$acct.Name].Keys)) {
    $l = $bucketRecs["$($acct.Name)|$subName"]
    if ($l) { $recs.AddRange($l) }   # note: array + List throws 'Argument types do not match'
  }
  foreach ($r in $recs) {
    $j = $r.j; $f = $r.file
    $cli = [string]$j.cliSessionId
    if (-not $cli) { continue }
    [void]$present.Add($cli)
    if (([string]$j.title -match $DateTitleRx) -and $keep.Contains($cli) -and $allT.Contains($cli) -and -not $changedOnDisk.Contains($f.FullName)) {
      $bt = Get-TitleFor $cli
      # checked right before the write, after the (slow) transcript read
      if ($bt -and -not (Test-ChangedSinceRead $r)) {
        if (-not $DryRun) {
          $old = $j.title; $j.title = $bt
          try { Write-RecordFile $f.FullName ($j | ConvertTo-Json -Compress -Depth 100) }
          catch { $j.title = $old; Write-Warning "could not retitle $($f.FullName) ($($_.Exception.Message)); retried next run"; continue }
        }
        $retitled++
      }
    }
  }

  # Add kept transcripts missing from this sub: clone a well-titled record from another
  # bucket when one exists (preserves the app's own AI titles), else fabricate.
  foreach ($m in $transcripts) {
    if (-not ($keep.Contains($m.BaseName) -or ($allT.Contains($m.BaseName) -and $pinnedCli.Contains($m.BaseName))) -or $present.Contains($m.BaseName)) { continue }
    $src = $recIndex[$m.BaseName]
    if ($src -and $src.good) {
      if ($DryRun) { $cloned++ }
      else {
        try {
          $cj = $src.raw | ConvertFrom-Json -DateKind String
          $cj.sessionId = "local_$([guid]::NewGuid().ToString())"
          # the destination folder's spelling of the workspace (else the shared one), not the source seat's;
          # originCwd only when it names the same workspace, so a different origin path is kept
          $cloneSpelling = if ($destSpelling) { $destSpelling } else { $cwdSpelling[$wsGuid] }
          if ($cloneSpelling) {
            if ($cj.originCwd -is [string] -and [string]::Equals($cj.originCwd, $cj.cwd, [StringComparison]::OrdinalIgnoreCase)) { $cj.originCwd = $cloneSpelling }
            $cj.cwd = $cloneSpelling
          }
          # the resolved flags, not the source's: pass 1.5 may have re-read a source whose flag write failed
          if ($flagWant.ContainsKey($m.BaseName)) { foreach ($fk in 'isArchived', 'isStarred') { $cj | Add-Member -NotePropertyName $fk -NotePropertyValue ([bool]$flagWant[$m.BaseName][$fk]) -Force } }
          else {   # flags not resolved, or not saved, this run: write a neutral (off) record, which the next run
            $cj | Add-Member -NotePropertyName isArchived -NotePropertyValue $false -Force   # doesn't count as a change
            $cj.PSObject.Properties.Remove('isStarred')
          }
          $cpath = Join-Path $bestSub "$($cj.sessionId).json"
          Write-RecordFile $cpath ($cj | ConvertTo-Json -Compress -Depth 100)
          $madeRecs.Add(@{ cli = $m.BaseName; path = $cpath; isArchived = [bool]$cj.isArchived; isStarred = [bool]$cj.isStarred })
          $cloned++
        } catch {
          try { if (Write-Record $bestSub $m) { $made++ } }
          catch { Write-Warning "could not add $($m.BaseName) to $bestSub ($($_.Exception.Message)); retried next run" }
        }
      }
    } else {
      if ($DryRun) { $made++ }
      else {
        try { if (Write-Record $bestSub $m) { $made++ } }
        catch { Write-Warning "could not add $($m.BaseName) to $bestSub ($($_.Exception.Message)); retried next run" }
      }
    }
  }
}
} finally {
# The app also lists each folder's archived records in archived-sessions.idx. Keep it in step with the records'
# isArchived (which pass 1.4 set). The app treats the file as a load-order hint (archived sessions load later)
# and rebuilds it from the records, so the records are the truth; this only keeps a seat's first load right. Entries for records
# that aren't in the folder, or can't be read, are left as they are.
if (-not $DryRun -and -not $flagSkip) {
  $idxChanged = 0
  $idxDirs = @(); try { $idxDirs = @(Get-ChildItem -LiteralPath $ccs -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory }) } catch { Write-Warning "could not list the session folders for archived-sessions.idx: $($_.Exception.Message)" }
  foreach ($dir in $idxDirs) {
    $idxPath = Join-Path $dir.FullName 'archived-sessions.idx'
    try {
      $idx = $null
      if (Test-Path -LiteralPath $idxPath) {
        $idx = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json -DateKind String
        if ($null -eq $idx -or $idx -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $idx.PSObject.Properties['archived']) { Write-Warning "unexpected format in $idxPath; left as it is"; continue }
      }
      $have = New-Object System.Collections.Generic.List[string]
      if ($idx) { foreach ($sid in @($idx.archived)) { if ($sid) { $have.Add([string]$sid) } } }
      $seen = @{}; $on = New-Object System.Collections.Generic.List[string]
      foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'local_*.json') {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject] -or -not $j.sessionId) { continue }
        $seen[[string]$j.sessionId] = $true
        if ([bool]$j.isArchived) { $on.Add([string]$j.sessionId) }
      }
      $want = New-Object System.Collections.Generic.List[string]
      foreach ($sid in $have) { if ((-not $seen.ContainsKey($sid) -or $on.Contains($sid)) -and -not $want.Contains($sid)) { $want.Add($sid) } }
      foreach ($sid in $on) { if (-not $want.Contains($sid)) { $want.Add($sid) } }
      if ($want.Count -eq $have.Count -and @($want | Where-Object { -not $have.Contains($_) }).Count -eq 0) { continue }
      if ($idx) {
        $dest = Join-Path (Join-Path $flagBackupRoot $stamp) $idxPath.Substring($ccs.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $idxPath -Destination $dest -Force
      } else { $idx = [pscustomobject]@{ v = 1 } }
      $idx | Add-Member -NotePropertyName archived -NotePropertyValue ([object[]]$want.ToArray()) -Force
      ($idx | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath "$idxPath.sync-tmp" -Encoding UTF8 -NoNewline
      [System.IO.File]::Move("$idxPath.sync-tmp", $idxPath, $true)
      $idxChanged++
    } catch {
      Remove-Item -LiteralPath "$idxPath.sync-tmp" -Force -ErrorAction SilentlyContinue
      Write-Warning "could not update $($idxPath): $($_.Exception.Message)"
    }
  }
  if (-not $Quiet -and $idxChanged) { "updated the archived list (archived-sessions.idx) in $idxChanged folder(s)" }
}

# Save the flag baseline AFTER pass 2, so the records it created (clone or fabricated) are in it
# with the flags they were written with -- else the next run reads them as brand-new and unions.
# (A session whose write failed keeps last run's values for that flag instead: pass 1.4.)
if (-not $DryRun -and -not $flagSkip -and -not $flagFail) {
  foreach ($mr in $madeRecs) {
    $mk = $mr.path.Substring($ccs.Length).TrimStart('\')
    foreach ($flag in 'isArchived', 'isStarred') {
      if ($flagFailCli.Contains("$flag|$($mr.cli)")) { continue }   # a failed session's clones stay out (pass 1.4)
      $flagNextAll[$flag][$mk] = $mr[$flag]
    }
  }
  # a session whose record could not be written or read keeps last run's baseline for that flag, for all its
  # records (the unreadable ones included, so they are still "known" when they can be read again)
  foreach ($fc in $flagFailCli) {
    $flag, $cli = $fc -split '\|', 2; $p = $flagPrevCi[$flag]
    $ks = @(if ($flagByCli.ContainsKey($cli)) { $flagByCli[$cli] | ForEach-Object { $_.key } })
    $ks += @($flagHeld | Where-Object { $_.StartsWith("$fc|") } | ForEach-Object { ($_ -split '\|', 3)[2] })
    foreach ($k in $ks) {
      if ($p -and $p.ContainsKey($k)) { $flagNextAll[$flag][$k] = [bool]$p[$k] } else { $flagNextAll[$flag].Remove($k) }
    }
  }
  # which session each record belongs to, so a record that later can't be read holds back only its session
  $cliMap = @{}
  foreach ($cli in $flagByCli.Keys) { foreach ($r in $flagByCli[$cli]) { $cliMap[$r.key] = $cli } }
  foreach ($mr in $madeRecs) { $cliMap[$mr.path.Substring($ccs.Length).TrimStart('\')] = $mr.cli }
  foreach ($h in $flagHeld) { $null, $hc, $hk = $h -split '\|', 3; $cliMap[$hk] = $hc }
  $flagNextAll['cli'] = $cliMap
  $flagNextAll['autoArchived'] = $autoArch
  $null = New-Item -ItemType Directory -Path (Split-Path $flagStatePath) -Force
  # Temp file, then an atomic replace: a crash mid-write must not leave a truncated file, and a failed
  # replace must not lose the old one ([IO.File]::Move keeps the destination; Move-Item -Force deletes it first).
  # A failed save warns rather than aborting: pass 2 has already run, and the old state file is still there.
  try {
    ($flagNextAll | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath "$flagStatePath.tmp" -Encoding UTF8
    try { [System.IO.File]::Move("$flagStatePath.tmp", $flagStatePath, $true) }
    catch { Start-Sleep -Milliseconds 500; [System.IO.File]::Move("$flagStatePath.tmp", $flagStatePath, $true) }   # once more: a scanner may hold it briefly
  } catch {
    Remove-Item -LiteralPath "$flagStatePath.tmp" -Force -ErrorAction SilentlyContinue
    Write-Warning "could not save the flag state $flagStatePath ($($_.Exception.Message)); the next run compares with the previous one, so a change you make before the next successful sync may be undone"
  }
}
}

if (-not $Quiet) {
  $verb = if ($DryRun) { 'WOULD: ' } else { '' }
  "${verb}added $made, cloned $cloned, retitled $retitled record(s) for $Cwd"
  if ($DryRun) { "(dry run -- nothing changed. Re-run without -DryRun to apply.)" }
}
} finally {
  try { if ($runLock) { $runLock.Dispose() } }
  finally { try { $selfProc.PriorityClass = $prevPriority } catch { } }
}
