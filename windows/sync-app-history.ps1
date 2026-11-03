<#
  sync-app-history.ps1  --  make SUBSTANTIVE or UNFINISHED CLI / cross-account Claude Code
  sessions show up in the Claude Code DESKTOP APP's session history, and prune trivial ones.

  WHY THIS EXISTS
  ---------------
  The CLI writes every session transcript to  ~/.claude/projects/<encoded-cwd>/<id>.jsonl.
  The desktop APP lists only sessions it has a pointer record for, in its own private index:
      %APPDATA%\Claude\claude-code-sessions\<account-uuid>\<workspace-guid>\local_<guid>.json
  This script creates pointer records for transcripts the app never recorded, in EVERY
  account bucket (an account that never tracked the workspace is seeded with the shared
  workspace guid -- it is identical across accounts), and REMOVES records for
  non-substantive sessions.

  WHAT IS KEPT (synced) -- everything else is pruned
  --------------------------------------------------
  A session must be RECENT (last activity within -MaxAgeDays, default 7; 0 = no limit)
  AND match a keep category below. Older sessions are pruned from the app view no matter
  how substantive -- the transcript is never touched and `claude --resume` still lists it.

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
  still CLI-resumable either way). They only apply to files untouched for >10 minutes,
  so live sessions don't churn in and out of the index.

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
    pwsh -File sync-app-history.ps1                 # sync+prune C:\Dev\hameishiv (default: recent 7d + substantive)
    pwsh -File sync-app-history.ps1 -DryRun         # report what WOULD change, change nothing
    pwsh -File sync-app-history.ps1 -MaxAgeDays 14  # widen/narrow the recency window (0 = keep all ages)
    pwsh -File sync-app-history.ps1 -KeepResumable  # also keep interrupted / died-pre-merge runs
    pwsh -File sync-app-history.ps1 -MinAssistant 10
    pwsh -File sync-app-history.ps1 -Cwd 'C:\Dev\other'
    pwsh -File sync-app-history.ps1 -NoPrune        # only add/retitle; never remove
    pwsh -File sync-app-history.ps1 -Quiet          # for the launcher hook / scheduled task

  SCHEDULED: Windows task 'Claude app-history sync' runs this every 30 min (hidden, via
  sync-app-history-hidden.vbs), so the app history stays fresh without a seat switch.
  Manage:  Disable-ScheduledTask / Enable-ScheduledTask -TaskName 'Claude app-history sync'

  SAFETY
  - Pruned records are MOVED (not deleted) to ~/.claude-app-seats\.pruned-history-backups\<ts>\
    preserving their path, so a prune is fully reversible. Transcripts are never touched.
  - Only records whose transcript we can actually read + classify are eligible to prune;
    records with no local transcript are left alone.
  - Classification is cached in ~/.claude-app-seats\.sync-classify-cache.json keyed by file
    size+mtime, so the 30-min scheduled runs don't re-read every transcript.
#>
[CmdletBinding()]
param(
  [string]$Cwd = 'C:\Dev\hameishiv',
  [int]$MinAssistant = 6,
  [int]$MaxAgeDays = 7,       # prune anything whose last activity is older than this (0 = no age limit)
  [switch]$KeepResumable,     # also keep interrupted / died-pre-merge runs (off by default: recent+substantive only)
  [switch]$DryRun,
  [switch]$NoPrune,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$ccs = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
if (-not (Test-Path -LiteralPath $ccs)) { throw "App session index not found: $ccs (is the desktop app installed?)" }

$enc = ($Cwd -replace '[:\\]', '-')
$projDir = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') $enc
if (-not (Test-Path -LiteralPath $projDir)) { if (-not $Quiet) { "no transcripts for $Cwd ($projDir)" }; return }
$transcripts = @(Get-ChildItem -LiteralPath $projDir -File -Filter '*.jsonl')
if ($transcripts.Count -eq 0) { if (-not $Quiet) { "no transcripts for $Cwd" }; return }

$cwdJson = $Cwd -replace '\\', '\\'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:USERPROFILE ".claude-app-seats\.pruned-history-backups\$stamp"
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
  $json = '{"sessionId":"' + $sid + '","cliSessionId":"' + $file.BaseName + '","cwd":"' + $cwdJson + '","originCwd":"' + $cwdJson + '","lastFocusedAt":' + $act + ',"createdAt":' + $created + ',"lastActivityAt":' + $act + ',"model":"' + $model + '","effort":"xhigh","isArchived":false,"title":' + $tj + ',"titleSource":"auto","permissionMode":"default","remoteMcpServersConfig":[],"chromePermissionMode":"skip_all_permission_checks","completedTurns":1,"bridgeSessionIds":[],"alwaysAllowedReasons":[],"sessionPermissionUpdates":[],"classifierSummaryEnabled":true,"spawnSeed":{}}'
  try { $null = $json | ConvertFrom-Json } catch { return $false }
  Set-Content -LiteralPath (Join-Path $subDir "$sid.json") -Value $json -Encoding UTF8 -NoNewline
  return $true
}

# ---- classify every transcript once ------------------------------------------
$now = Get-Date
$allT = New-Object System.Collections.Generic.HashSet[string]
$keep = New-Object System.Collections.Generic.HashSet[string]
$nInterrupted = 0; $nUnfinishedMpr = 0; $nStale = 0
foreach ($m in $transcripts) {
  [void]$allT.Add($m.BaseName)
  $c = Get-Class $m
  $settled = ($now - $m.LastWriteTime).TotalMinutes -gt 10   # ignore still-running sessions
  # RECENCY: keep only sessions whose last activity is within the window. Older ones are
  # pruned from the app view no matter how substantive -- the transcript is untouched and
  # `claude --resume` still lists it. $MaxAgeDays <= 0 disables the age limit.
  $recent  = ($MaxAgeDays -le 0) -or (($now - $m.LastWriteTime).TotalDays -le $MaxAgeDays)
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
  "classified $($transcripts.Count) transcripts for ${Cwd}: $($keep.Count) kept ($resNote), $($allT.Count - $keep.Count) pruned ($ageNote; MinAssistant=$MinAssistant)"
}

# ---- pass 1: scan all account buckets once ------------------------------------
$accts = @(Get-ChildItem -LiteralPath $ccs -Directory)
$subCounts = @{}   # acct -> (sub -> this-cwd record count)
$guidVotes = @{}   # sub  -> total count across accounts (workspace guid vote)
$recIndex  = @{}   # cliSessionId -> @{ raw = record json; good = has a real title }
$bucketRecs = @{}  # "acct|sub" -> list of @{ file; j }
foreach ($acct in $accts) {
  $subCounts[$acct.Name] = @{}
  foreach ($sub in @(Get-ChildItem -LiteralPath $acct.FullName -Directory)) {
    $cnt = 0
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $sub.FullName -File -Filter '*.json') {
      $rawRec = $null; $j = $null
      try { $rawRec = Get-Content -LiteralPath $f.FullName -Raw; $j = $rawRec | ConvertFrom-Json } catch { continue }
      $list.Add(@{ file = $f; j = $j })
      if ($j.cwd -eq $Cwd) {
        $cnt++
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

# ---- pass 1.4: archive and pin flags follow you across seats -------------------
# isArchived and isStarred (a sidebar pin) live in each seat's own record, with no time of change.
# So we remember every record's flags from the last run (.flag-state.json): a record whose flag
# differs from that is the one you changed, and its value goes to every seat's record of the
# session (true wins if two seats changed opposite ways). First run, or a session no record was
# seen for before: set on any seat -> set on all. Records are matched across seats by
# cliSessionId, whatever their cwd. The pin LIST in claude_desktop_config.json is pass 3's job.
$flagStatePath = Join-Path $env:USERPROFILE '.claude-app-seats\.flag-state.json'
$flagPrevAll = $null
if (Test-Path -LiteralPath $flagStatePath) { try { $flagPrevAll = Get-Content -LiteralPath $flagStatePath -Raw | ConvertFrom-Json -AsHashtable } catch { $flagPrevAll = $null } }
$flagNextAll = @{}
$flagByCli = @{}
foreach ($kv in $bucketRecs.GetEnumerator()) {
  foreach ($r in $kv.Value) {
    $cli = [string]$r.j.cliSessionId; if (-not $cli) { continue }
    $r.key = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
    if (-not $flagByCli.ContainsKey($cli)) { $flagByCli[$cli] = New-Object System.Collections.Generic.List[object] }
    $flagByCli[$cli].Add($r)
  }
}
foreach ($flag in 'isArchived', 'isStarred') {
  $prev = if ($flagPrevAll) { $flagPrevAll[$flag] } else { $null }
  $next = @{}; $flipped = 0
  foreach ($cli in @($flagByCli.Keys)) {
    $rs = $flagByCli[$cli]
    $known = @(); $changed = @()
    foreach ($r in $rs) {
      $r.v = [bool]$r.j.$flag
      if ($prev -and $prev.ContainsKey($r.key)) { $known += $r; if ([bool]$prev[$r.key] -ne $r.v) { $changed += $r } }
    }
    $want = if ($changed.Count) { [bool]($changed | Where-Object { $_.v }) }
            elseif ($known.Count) { [bool]($known | Where-Object { $_.v }) }
            else { [bool]($rs | Where-Object { $_.v }) }
    foreach ($r in $rs) {
      $next[$r.key] = $want
      if ($r.v -eq $want) { continue }
      $flipped++
      if ($DryRun) { continue }
      $dest = Join-Path (Join-Path $env:USERPROFILE ".claude-app-seats\.flag-sync-backups\$stamp") $r.key
      if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
      }
      $r.j | Add-Member -NotePropertyName $flag -NotePropertyValue $want -Force
      ($r.j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $r.file.FullName -Encoding UTF8 -NoNewline
    }
    # clones made in pass 2 for seats lacking the session must carry the same flag
    if (-not $DryRun -and $recIndex.ContainsKey($cli)) {
      $o = $recIndex[$cli].raw | ConvertFrom-Json
      if ([bool]$o.$flag -ne $want) { $o | Add-Member -NotePropertyName $flag -NotePropertyValue $want -Force; $recIndex[$cli].raw = $o | ConvertTo-Json -Compress -Depth 100 }
    }
  }
  $flagNextAll[$flag] = $next
  if (-not $Quiet -and $flipped -gt 0) { "$(if ($DryRun) { 'WOULD set' } else { 'set' }) $flag on $flipped record(s) to match the other seats$(if (-not $prev) { ' (first run: set on any seat -> set on all)' })" }
}
if (-not $DryRun) { ($flagNextAll | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath $flagStatePath -Encoding UTF8 }

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
    if ($r.j.cwd -eq $Cwd -and $cli -and $r.j.lastAssistantUuid) {
      if (-not $byCli.ContainsKey($cli)) { $byCli[$cli] = New-Object System.Collections.Generic.List[object] }
      $byCli[$cli].Add($r)
    }
  }
}
foreach ($cli in @($byCli.Keys)) {
  $rs = $byCli[$cli]
  if (@($rs | ForEach-Object { [string]$_.j.lastAssistantUuid } | Select-Object -Unique).Count -lt 2) { continue }
  $tf = $tFile[$cli]
  if (-not $tf -or ($now - $tf.LastWriteTime).TotalMinutes -le 10) { continue }   # no transcript / still running
  $pos = @{}; $tip = $null; $i = 0
  foreach ($line in [IO.File]::ReadLines($tf.FullName)) {
    $i++
    if ($line.Contains(',"type":"assistant","uuid":"') -and $line -match ',"type":"assistant","uuid":"([0-9a-f-]{36})"') { $pos[$Matches[1]] = $i; $tip = $Matches[1] }
  }
  if (-not $tip) { continue }
  $srcRec = $rs | Where-Object { [string]$_.j.lastAssistantUuid -eq $tip } | Sort-Object { [double]$_.j.completedTurns } -Descending | Select-Object -First 1
  if (-not $srcRec) { continue }
  foreach ($r in $rs) {
    $u = [string]$r.j.lastAssistantUuid
    if ($u -eq $tip -or -not $pos.ContainsKey($u)) { continue }
    if (-not $DryRun) {
      $rel = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
      $dest = Join-Path (Join-Path $env:USERPROFILE ".claude-app-seats\.reconcile-backups\$stamp") $rel
      New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
      Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
      foreach ($f in $StateFields) {
        if ($null -eq $srcRec.j.PSObject.Properties[$f]) { continue }
        $v = $srcRec.j.$f
        if ($f -eq 'lastActivityAt' -or $f -eq 'lastFocusedAt') { $v = [Math]::Max([double]$v, [double]$r.j.$f) }
        $r.j | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
      }
      ($r.j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $r.file.FullName -Encoding UTF8 -NoNewline
    }
    $reconciled++
  }
  # clones for buckets that lack the session must start from the current state too
  if (-not $DryRun -and $recIndex.ContainsKey($cli) -and $recIndex[$cli].good -and -not ([string]$srcRec.j.title -match $DateTitleRx)) {
    $recIndex[$cli] = @{ raw = (Get-Content -LiteralPath $srcRec.file.FullName -Raw); good = $true }
  }
}
if (-not $Quiet -and $reconciled -gt 0) { "$(if ($DryRun) { 'WOULD reconcile' } else { 'reconciled' }) $reconciled stale record(s) to their transcript tip (originals backed up under ~\.claude-app-seats\.reconcile-backups\$stamp)" }

# ---- pass 2: per account -- seed, prune, retitle, add -------------------------
$made = 0; $cloned = 0; $pruned = 0; $retitled = 0
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
      else { New-Item -ItemType Directory -Path $seedDir -Force | Out-Null }
    }
  }
  $bestSub = Join-Path $acct.FullName $bestSubName

  # Prune non-kept records; retitle datestamp-titled ones; index what's present.
  # Walks EVERY sub of the account, not just the primary one: records for this cwd
  # stranded in a secondary workspace-guid folder were never pruned (seat A had 35).
  $present = New-Object System.Collections.Generic.HashSet[string]
  $recs = [System.Collections.Generic.List[object]]::new()
  foreach ($subName in @($subCounts[$acct.Name].Keys)) {
    $l = $bucketRecs["$($acct.Name)|$subName"]
    if ($l) { $recs.AddRange($l) }   # note: array + List throws 'Argument types do not match'
  }
  foreach ($r in $recs) {
    $j = $r.j; $f = $r.file
    $cli = [string]$j.cliSessionId
    if ($j.cwd -eq $Cwd -and $cli -and $allT.Contains($cli) -and -not $keep.Contains($cli)) {
      if (-not $NoPrune) {
        if (-not $DryRun) {
          $rel = $f.FullName.Substring($ccs.Length).TrimStart('\')
          $dest = Join-Path $backupRoot $rel
          New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
          Move-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        $pruned++
      }
      continue
    }
    if (-not $cli) { continue }
    [void]$present.Add($cli)
    if (([string]$j.title -match $DateTitleRx) -and $keep.Contains($cli) -and $allT.Contains($cli)) {
      $bt = Get-TitleFor $cli
      if ($bt) {
        if (-not $DryRun) {
          $j.title = $bt
          ($j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $f.FullName -Encoding UTF8 -NoNewline
        }
        $retitled++
      }
    }
  }

  # Add kept transcripts missing from this sub: clone a well-titled record from another
  # bucket when one exists (preserves the app's own AI titles), else fabricate.
  foreach ($m in $transcripts) {
    if (-not $keep.Contains($m.BaseName) -or $present.Contains($m.BaseName)) { continue }
    $src = $recIndex[$m.BaseName]
    if ($src -and $src.good) {
      if ($DryRun) { $cloned++ }
      else {
        try {
          $cj = $src.raw | ConvertFrom-Json
          $cj.sessionId = "local_$([guid]::NewGuid().ToString())"
          ($cj | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath (Join-Path $bestSub "$($cj.sessionId).json") -Encoding UTF8 -NoNewline
          $cloned++
        } catch { if (Write-Record $bestSub $m) { $made++ } }
      }
    } else {
      if ($DryRun) { $made++ } elseif (Write-Record $bestSub $m) { $made++ }
    }
  }
}

if (-not $Quiet) {
  $verb = if ($DryRun) { 'WOULD: ' } else { '' }
  "${verb}added $made, cloned $cloned, retitled $retitled, pruned $pruned record(s) for $Cwd"
  if ($pruned -gt 0 -and -not $DryRun) { "pruned records backed up (reversible) at: $backupRoot" }
  if ($DryRun) { "(dry run -- nothing changed. Re-run without -DryRun to apply.)" }
}

# ---- pass 3: pin list + sidebar groups in claude_desktop_config.json ---------------
# The app keeps the shared pin list and each seat's groups in claude_desktop_config.json, and both
# name a seat's own record ids (local_...), which differ per seat. So: pin list = every seat's id
# of every record pass 1.4 left starred; groups and their sessions are copied to every seat, with
# a group's sessions matched across seats by cliSessionId. Like the flags, a change made on one
# seat since the last run (.sidebar-state.json) wins; first run = union of all seats. The LIVE app
# rewrites this file from memory, so this pass runs only while the app is closed (a seat switch).
$cfgPath = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
# (the guard is for the app's REAL file; a sandbox copy under a redirected %APPDATA% is never live)
$liveCfg = Join-Path (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders').AppData 'Claude\claude_desktop_config.json'
$appUp = ($cfgPath -eq $liveCfg) -and @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like '*\WindowsApps\Claude_*\app\Claude.exe' -or $_.Path -like '*\AnthropicClaude\*\claude.exe' } catch { $false } }).Count -gt 0
if (-not (Test-Path -LiteralPath $cfgPath)) { }
elseif ($appUp) { if (-not $Quiet) { 'sidebar pins/groups not synced: the desktop app is running (they sync at the next seat switch)' } }
else {
  $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json -AsHashtable
  if (-not $cfg['preferences']) { $cfg['preferences'] = [ordered]@{} }
  if (-not $cfg['preferences']['epitaxyPrefs']) { $cfg['preferences']['epitaxyPrefs'] = [ordered]@{} }
  $e = $cfg['preferences']['epitaxyPrefs']
  # rescan after pass 2: it cloned new records with new ids
  $recById = @{}; $idsByCli = @{}; $scopeIds = [ordered]@{}   # scope "acct/sub" -> cli -> id
  foreach ($acct in Get-ChildItem -LiteralPath $ccs -Directory) {
    foreach ($sub in Get-ChildItem -LiteralPath $acct.FullName -Directory) {
      $scope = "$($acct.Name)/$($sub.Name)"; $m = @{}
      foreach ($f in Get-ChildItem -LiteralPath $sub.FullName -File -Filter 'local_*.json') {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        $cli = [string]$j.cliSessionId; $id = [string]$j.sessionId
        if (-not $cli -or -not $id) { continue }
        $recById[$id] = @{ cli = $cli; scope = $scope; star = [bool]$j.isStarred }
        if (-not $idsByCli.ContainsKey($cli)) { $idsByCli[$cli] = New-Object System.Collections.Generic.List[string] }
        $idsByCli[$cli].Add($id); $m[$cli] = $id
      }
      if ($m.Count) { $scopeIds[$scope] = $m }
    }
  }
  $sbStatePath = Join-Path $env:USERPROFILE '.claude-app-seats\.sidebar-state.json'
  $sbPrev = $null
  if (Test-Path -LiteralPath $sbStatePath) { try { $sbPrev = Get-Content -LiteralPath $sbStatePath -Raw | ConvertFrom-Json -AsHashtable } catch { $sbPrev = $null } }

  # pins: keep ids we can't match to a record (not ours to judge), drop unstarred, add every seat's id
  $oldStar = @($e['starred-local-code-sessions'])
  $star = New-Object System.Collections.Generic.List[string]
  foreach ($id in $oldStar) { if ($id -and (-not $recById.ContainsKey($id) -or $recById[$id].star) -and -not $star.Contains($id)) { $star.Add($id) } }
  foreach ($id in @($recById.Keys)) { if ($recById[$id].star -and -not $star.Contains($id)) { $star.Add($id) } }
  $slice = $e['dframe-local-slice']
  $oldOrder = if ($slice) { @($slice['pinnedOrder']) } else { @() }
  $order = New-Object System.Collections.Generic.List[string]
  foreach ($k in $oldOrder) {
    if (-not $k) { continue }
    $id = $k -replace '^code:', ''
    if ($k -notlike 'code:*' -or -not $recById.ContainsKey($id)) { if (-not $order.Contains($k)) { $order.Add($k) }; continue }
    if (-not $recById[$id].star) { continue }
    foreach ($sid in $idsByCli[$recById[$id].cli]) { if (-not $order.Contains("code:$sid")) { $order.Add("code:$sid") } }
  }
  $pinChanged = (($oldStar -join ',') -ne ($star -join ',')) -or (($oldOrder -join ',') -ne ($order -join ','))

  # groups
  $gsAll = $e['dframe-group-scopes']; if (-not $gsAll) { $gsAll = [ordered]@{} }
  $secAll = $e['dframe-code-sections']; if (-not $secAll) { $secAll = [ordered]@{} }
  $prevNames = if ($sbPrev) { $sbPrev['groups'] } else { $null }
  $prevScopeG = if ($sbPrev) { $sbPrev['scopeGroups'] } else { $null }
  $prevAssign = if ($sbPrev) { $sbPrev['assign'] } else { $null }
  $defs = [ordered]@{}; $deleted = New-Object System.Collections.Generic.HashSet[string]
  foreach ($scope in @($gsAll.Keys)) {
    foreach ($g in @($gsAll[$scope]['groups'])) {
      if (-not $g -or -not $g['id']) { continue }
      $gid = $g['id']
      $renamedHere = $prevNames -and $prevNames.ContainsKey($gid) -and $prevNames[$gid] -ne $g['name']
      if (-not $defs.Contains($gid) -or $renamedHere) { $defs[$gid] = $g }
    }
  }
  if ($prevScopeG) {   # a group this seat had last run and no longer has = you deleted it there
    foreach ($scope in @($prevScopeG.Keys)) {
      if (-not $gsAll.Contains($scope)) { continue }
      $now = @($gsAll[$scope]['groups'] | ForEach-Object { $_['id'] })
      foreach ($gid in @($prevScopeG[$scope])) { if ($now -notcontains $gid) { [void]$deleted.Add($gid) } }
    }
  }
  foreach ($gid in @($deleted)) { $defs.Remove($gid) }
  $assignNext = @{}; $want = @{}
  foreach ($cli in @($idsByCli.Keys)) {
    $known = @(); $changed = @(); $cur = @()
    foreach ($scope in @($scopeIds.Keys)) {
      $id = $scopeIds[$scope][$cli]; if (-not $id) { continue }
      $a = if ($gsAll.Contains($scope) -and $gsAll[$scope]['assignments']) { [string]$gsAll[$scope]['assignments']["code:$id"] } else { '' }
      $cur += $a
      $pk = "$scope|$cli"
      if ($prevAssign -and $prevAssign.ContainsKey($pk)) { $known += [string]$prevAssign[$pk]; if ([string]$prevAssign[$pk] -ne $a) { $changed += $a } }
    }
    $w = if ($changed.Count) { ($changed | Where-Object { $_ } | Select-Object -First 1) } elseif ($known.Count) { $known[0] } else { ($cur | Where-Object { $_ } | Select-Object -First 1) }
    if ($w -and -not $defs.Contains($w)) { $w = '' }
    $want[$cli] = [string]$w
  }
  $groupChanges = 0
  if ($defs.Count -or $deleted.Count) {
    foreach ($scope in @($scopeIds.Keys)) {
      $old = if ($gsAll.Contains($scope)) { $gsAll[$scope] } else { $null }
      $asg = [ordered]@{}
      if ($old -and $old['assignments']) {   # keep keys we can't match to a record of this seat
        foreach ($k in @($old['assignments'].Keys)) { $id = $k -replace '^code:', ''; if ((-not $recById.ContainsKey($id) -or $recById[$id].scope -ne $scope) -and $defs.Contains($old['assignments'][$k])) { $asg[$k] = $old['assignments'][$k] } }
      }
      # sorted: a plain hashtable's key order differs between processes, which made idle runs rewrite
      foreach ($cli in @($scopeIds[$scope].Keys | Sort-Object)) { if ($want[$cli]) { $asg["code:$($scopeIds[$scope][$cli])"] = $want[$cli] } }
      $newScope = if ($old) { $old } else { [ordered]@{} }   # keep any other keys the app stores here
      $canon = { param($s) (@($s['groups']) | ConvertTo-Json -Compress -Depth 20) + '|' + ((@($s['assignments'].Keys) | Sort-Object | ForEach-Object { "$_=$($s['assignments'][$_])" }) -join ',') }
      $before = if ($old -and $old['assignments']) { & $canon $old } else { '' }
      $newScope['groups'] = @($defs.Values); $newScope['assignments'] = $asg
      if ($before -ne (& $canon $newScope)) { $groupChanges++ }
      $gsAll[$scope] = $newScope
      # each group also needs a section in this seat's sidebar
      $secBefore = if ($secAll.Contains($scope)) { $secAll[$scope] | ConvertTo-Json -Compress -Depth 20 } else { '' }
      $tmpl = $null
      foreach ($s2 in @($secAll.Keys)) { if ($secAll[$s2]['sections']) { $tmpl = $secAll[$s2]; break } }
      if (-not $secAll.Contains($scope) -and $tmpl) { $secAll[$scope] = ($tmpl | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable) }
      if ($secAll.Contains($scope)) {
        $secs = [System.Collections.Generic.List[object]]::new()
        foreach ($s in @($secAll[$scope]['sections'])) { if ($s['kind'] -eq 'manual' -and -not $defs.Contains($s['id'])) { continue }; if ($s['kind'] -eq 'manual') { $s['name'] = $defs[$s['id']]['name'] }; $secs.Add($s) }
        foreach ($gid in @($defs.Keys)) {
          if (@($secs | Where-Object { $_['id'] -eq $gid }).Count) { continue }
          $src = $null; foreach ($s2 in @($secAll.Keys)) { $src = @($secAll[$s2]['sections']) | Where-Object { $_['id'] -eq $gid } | Select-Object -First 1; if ($src) { break } }
          $s = if ($src) { $src | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable } else { [ordered]@{ id = $gid; kind = 'manual'; v = 2; name = $defs[$gid]['name']; sortBy = 'recency'; ascending = $false; collapsed = $false; shown = $true; members = @() } }
          $s['order'] = (@($secs | ForEach-Object { [double]$_['order'] }) | Measure-Object -Maximum).Maximum + 1
          $secs.Add($s)
        }
        $secAll[$scope]['sections'] = @($secs)
        if ($secBefore -ne ($secAll[$scope] | ConvertTo-Json -Compress -Depth 20) -and $before -eq (& $canon $newScope)) { $groupChanges++ }
      }
    }
  }
  if ($pinChanged -or $groupChanges) {
    if (-not $Quiet) { "$(if ($DryRun) { 'WOULD update' } else { 'updated' }) sidebar: pin list $($oldStar.Count) -> $($star.Count) id(s), groups rewritten for $groupChanges seat(s)$(if ($deleted.Count) { ", $($deleted.Count) deleted group(s) removed everywhere" })" }
    if (-not $DryRun) {
      $bk = Join-Path $env:USERPROFILE ".claude-app-seats\.sidebar-sync-backups\$stamp"
      New-Item -ItemType Directory -Path $bk -Force | Out-Null
      Copy-Item -LiteralPath $cfgPath -Destination $bk -Force
      $e['starred-local-code-sessions'] = @($star)
      if (-not $slice) { $slice = [ordered]@{}; $e['dframe-local-slice'] = $slice }
      $slice['pinnedOrder'] = @($order)
      if ($gsAll.Count) { $e['dframe-group-scopes'] = $gsAll }
      if ($secAll.Count) { $e['dframe-code-sections'] = $secAll }
      $json = $cfg | ConvertTo-Json -Depth 100
      $null = $json | ConvertFrom-Json   # never write a file the app can't parse
      Set-Content -LiteralPath $cfgPath -Value $json -Encoding UTF8 -NoNewline
    }
  }
  if (-not $DryRun) {
    $sg = @{}; foreach ($scope in @($gsAll.Keys)) { $sg[$scope] = @($gsAll[$scope]['groups'] | ForEach-Object { $_['id'] }) }
    $an = @{}; foreach ($scope in @($scopeIds.Keys)) { foreach ($cli in @($scopeIds[$scope].Keys)) { $an["$scope|$cli"] = $want[$cli] } }
    $gn = @{}; foreach ($gid in @($defs.Keys)) { $gn[$gid] = $defs[$gid]['name'] }
    (@{ groups = $gn; scopeGroups = $sg; assign = $an } | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath $sbStatePath -Encoding UTF8
  }
}
