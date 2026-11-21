(Get-Process -Id $PID).PriorityClass = 'Idle'   # first statement: a long test must not freeze the desktop (children inherit it)
<#
  test-sync-app-history.ps1 -- scenario test for sync-app-history.ps1's pass 1.4: the isArchived / isStarred
  flags follow you across seats. (The sidebar pin LIST and groups are not synced -- see the script header.)
  Covers: first-run union (a planted disagreement, and again after the state folder is deleted); a record
  not seen last run spreads only when it is on; a record whose write fails, or that can't be read, keeps its
  session's last baseline (the rest is saved), so its stale value does not spread next run; a deleted record
  does not stop the save; with the app running (-AssumeAppRunning) nothing is changed or saved and a record
  it creates is neutral; a state file without the record->session map stops the whole save on an unreadable
  record; a held session's new record is neutral and set by the next good run; a record truncated to 0
  bytes counts as unreadable; a leftover .sync-tmp is removed; a flag write in the same run as pass 1.5's reconcile reconciles the records it just wrote, and a record pass 1.5 can't write is skipped without stopping the run;
  archived-sessions.idx follows archive and
  un-archive; idle run changes nothing; pin / unpin and archive / un-archive on one seat reach
  every seat; opposite changes in one run -> "on" wins; a corrupt state file -> warning, nothing changed, file
  left as is; a missing ~\.claude-app-seats directory -> run succeeds and writes the state file; records the
  script creates (cloned from another seat, or fabricated from the transcript) carry the flags and are in the
  saved baseline. Auto-archive: an old session is archived on every seat and no record moves or
  disappears; an un-archive after that is respected on later runs; the app being open defers it; a pinned old session is not
  archived; a held (unreadable record) session is retried and not marked done; a state file without the
  autoArchived map loads, and a malformed one fails like the other maps; an old session the user
  un-archived since the last run, or with autoArchiveExempt on a record, is not archived but is remembered; a young
  session un-archived is remembered too, so it is not archived once old; a session archived for age and then resumed is
  un-archived on every seat and archived again once stale, while a kept entry (user un-archived) and a seen entry (already
  archived when it came due) are never revived; a plain-date session the user un-archived while resuming it becomes a kept entry;
  a revive held by an unwritable record leaves a revive entry that the next run resolves; an age archive held by an unwritable
  record after another record was written keeps its plain date (the failed record is written next run, the entry stays a date,
  and a resume revives it); an un-archive seen in a
  -MaxAgeDays 0 run is remembered too; a session of another cwd is left alone; a state file without the cli map plus an unreadable record auto-archives nothing.
  Builds a synthetic app session index in a fresh sandbox and runs the sync there with
  %APPDATA% / %USERPROFILE% redirected, and -AssumeAppClosed (so the app-running check is skipped for the sandbox).
  The sandbox is deleted on success and kept (path printed) on failure. Exit 1 on any failure.
    pwsh -File test-sync-app-history.ps1 [<path to sync-app-history.ps1>]
#>
$Script = if ($args[0]) { [string]$args[0] } else { Join-Path $PSScriptRoot 'sync-app-history.ps1' }
$sb = Join-Path ([IO.Path]::GetTempPath()) "sync-app-history-test's-[fixture]-$([guid]::NewGuid())"
# This path is only a transcript key. Keep its encoded directory name independent of TEMP.
$workspace = [IO.Path]::Combine([IO.Path]::GetPathRoot($PSHOME), "sync-fixture's-[workspace]-café\NUL.txt\COM1\..$([char]0xAD)")
$encoded = $workspace -creplace '[^A-Za-z0-9]', '-'
$proj = "$sb\home\.claude\projects\$encoded"
$ccs = "$sb\app\Claude\claude-code-sessions"
New-Item -ItemType Directory $proj, "$sb\home\.claude-app-seats", $ccs -Force | Out-Null
$fixtureSessions = @(1..4 | ForEach-Object { [guid]::NewGuid().ToString() })
foreach ($seat in 'A','B','C') {
  $folder = Join-Path (Join-Path $ccs $seat) 'fixture-workspace'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  foreach ($cli in $fixtureSessions) {
    $id = "local_$([guid]::NewGuid())"
    @{ sessionId = $id; cliSessionId = $cli; cwd = $workspace; originCwd = $workspace
       title = 'Synthetic session'; isArchived = $false } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $folder "$id.json") -NoNewline
  }
}
# One synthetic, recent, substantive transcript so the script has a session to create records for (pass 2).
# It is the fixture workspace's only transcript, so nothing else is created or auto-archived.
$X = [guid]::NewGuid().ToString()
$asst = 1..7 | ForEach-Object { '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok ' + $_ + '"}]}}' }
Set-Content -LiteralPath "$proj\$X.jsonl" (@('{"type":"user","message":{"role":"user","content":"please help me with the flag sync test"}}') + $asst)
"sandbox: $sb"
$statePath = "$sb\home\.claude-app-seats\.flag-state.json"
$workspaceFile = "$sb\home\.claude\history-sync-workspace.txt"
$lockPath = "$sb\home\.claude-app-seats\.sync-history.lock"
$fail = 0; $script:out = @(); $script:rc = 0
$runSync = @'
$env:APPDATA, $env:USERPROFILE, $scriptPath, $optionsJson = $args
$options = ConvertFrom-Json -AsHashtable $optionsJson
& $scriptPath -NoPrune -AssumeAppClosed @options *>&1
'@
function run([hashtable]$options = @{}) {
  # -NoPrune is a no-op now; passed so an old invocation is proven to still work
  $json = ConvertTo-Json -InputObject $options -Compress
  $script:out = @(pwsh -NoProfile -CommandWithArgs $runSync "$sb\app" "$sb\home" $Script $json 2>&1 | ForEach-Object { "$_" })
  $script:rc = $LASTEXITCODE
  $script:out | Where-Object { $_ -match '^set |^WOULD |isArchived|isStarred|auto-archiv|not synced|rror|xception|WARNING|added \d' } | ForEach-Object { "    $_" }
}
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function key($f) { $f.Substring($ccs.Length).TrimStart('\') }
function recs { Get-ChildItem -LiteralPath $ccs -Recurse -Filter local_*.json | ForEach-Object { try { $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { return }; [pscustomobject]@{ f = $_.FullName; id = $j.sessionId; cli = [string]$j.cliSessionId; arch = [bool]$j.isArchived; star = [bool]$j.isStarred; title = [string]$j.title } } | Where-Object cli }
function setRec($f, $k, $v) { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; $j | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force; Set-Content -LiteralPath $f ($j | ConvertTo-Json -Compress -Depth 100) -NoNewline }
function recHash { (Get-ChildItem -LiteralPath $ccs -Recurse -Filter local_*.json | Sort-Object FullName | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash)" }) -join '|' }
function state { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable }
function mixed($R, $p) { @($R | Group-Object cli | Where-Object { ($_.Group.$p -contains $true) -and ($_.Group.$p -contains $false) }).Count }
function ofSession($cli) { @(recs | Where-Object { $_.cli -eq $cli }) }
# An old (30-day, or $days) substantive session with an unflagged record next to each of the synthetic session's records.
function mkOld([int]$days = 30) {
  $o = [guid]::NewGuid().ToString()
  Set-Content -LiteralPath "$proj\$o.jsonl" (@('{"type":"user","message":{"role":"user","content":"an old session for the auto-archive test"}}') + $asst)
  (Get-Item -LiteralPath "$proj\$o.jsonl").LastWriteTime = (Get-Date).AddDays(-$days)
  foreach ($r in (ofSession $X)) {
    $j = Get-Content -LiteralPath $r.f -Raw | ConvertFrom-Json
    $j.sessionId = "local_$([guid]::NewGuid())"; $j.cliSessionId = $o
    $j | Add-Member -NotePropertyName isArchived -NotePropertyValue $false -Force; $j.PSObject.Properties.Remove('isStarred')
    Set-Content -LiteralPath (Join-Path (Split-Path -LiteralPath $r.f) "$($j.sessionId).json") ($j | ConvertTo-Json -Compress -Depth 100) -NoNewline
  }
  $o
}
# move a session's transcript write time to $days days ago (0 = now)
function touch($cli, [double]$days) { (Get-Item -LiteralPath "$proj\$cli.jsonl").LastWriteTime = (Get-Date).AddDays(-$days) }
function autoVal($cli) { [string](state)['autoArchived'][$cli] }
function autoDone($cli) { $a = (state)['autoArchived']; [bool]($a -and $a.ContainsKey($cli)) }
# is this record's sessionId in its folder's archived-sessions.idx?
function inIdx($r) { $p = Join-Path (Split-Path -LiteralPath $r.f) 'archived-sessions.idx'; (Test-Path -LiteralPath $p) -and (@((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).archived) -contains $r.id) }

$initialIndex = recHash
run @{ Quiet = $true }
check 'a missing workspace setting fails before writing state' ($rc -ne 0 -and ($out -match 'No history sync workspace is configured') -and -not (Test-Path -LiteralPath $lockPath) -and (recHash) -eq $initialIndex)
[IO.File]::WriteAllBytes($workspaceFile, [byte[]](0x43, 0x3A, 0x5C, 0xE9))
run @{ Quiet = $true }
check 'a non-UTF-8 setting fails before writing state' ($rc -ne 0 -and ($out -match 'as UTF-8') -and -not (Test-Path -LiteralPath $lockPath) -and (recHash) -eq $initialIndex)
$invalidWorkspaces = @(
  'relative-path'
  ($workspace + '"')
  ($workspace + ':archive')
  ($workspace + ' ')
  ($workspace + '.')
  '\\?\UNC\?\C:\x'
  '\\server\share:stream\workspace'
  '\\server\sh*re\workspace'
  '\\server'
  '\\?\C:project'
  '\\?\C:\draft\..\release'
  '\\?\C:\draft\.\release'
  '\\?\C:\work/project'
  '\\?\C:\work\\project'
  '\\?\\UNC\server\share\repo'
  '\\.\C:\work\trailing.'
  '//?/C:/work/project'
  'C:\work\NUL'
  '\\?\'
  '\\.\'
  '\\.\pipe\history'
  '\\localhost\pipe\history'
  '\\localhost\pipe.\history'
  '\\localhost\pipe \history'
  '\\localhost\mailslot\history'
  '\\?\UNC\localhost\MAILSLOT.\history'
  '\\localhost\IPC$\history'
  '\\?\UNC\localhost\PIPE\history'
  '\\?\Volume{00000000-0000-0000-0000-000000000000}\work'
)
foreach ($invalidWorkspace in $invalidWorkspaces) {
  Set-Content -LiteralPath $workspaceFile $invalidWorkspace
  run @{ Quiet = $true }
  check "an invalid workspace setting ($invalidWorkspace) fails before writing state" ($rc -ne 0 -and ($out -match 'Use a valid absolute Windows workspace path') -and -not (Test-Path -LiteralPath $lockPath) -and (recHash) -eq $initialIndex)
}
$overrideWorkspace = $workspace.Replace('\', '/') + '/ignored/.././'
run @{ Cwd = $overrideWorkspace; DryRun = $true }
check 'an explicit workspace overrides an invalid setting and plans additions on all three seats' ($rc -eq 0 -and ($out -match '^WOULD: added 3,') -and (recHash) -eq $initialIndex)
run @{ Cwd = '\\history-sync-fixture.invalid\share\PROJEC~1'; DryRun = $true }
check 'a valid UNC workspace with no local transcripts can be previewed' ($rc -eq 0 -and ($out -match '^no transcripts') -and (recHash) -eq $initialIndex)
# Transcripts but no app record for that exact path: the preview says why nothing is planned.
$unrecorded = $workspace + 'unrecorded'
$unrecordedProj = "$sb\home\.claude\projects\$($unrecorded -creplace '[^A-Za-z0-9]', '-')"
$null = New-Item -ItemType Directory -Path $unrecordedProj -Force
Copy-Item -LiteralPath "$proj\$X.jsonl" -Destination "$unrecordedProj\$([guid]::NewGuid()).jsonl"
run @{ Cwd = $unrecorded; DryRun = $true }
check 'a workspace with transcripts but no app record says so' ($rc -eq 0 -and ($out -match '^no app record on any seat has workspace') -and ($out -match '^WOULD: added 0,') -and (recHash) -eq $initialIndex)
run @{ Cwd = $unrecorded; DryRun = $true; Quiet = $true }
check 'the no-app-record notice stays silent under -Quiet' ($rc -eq 0 -and -not ($out -match 'no app record') -and (recHash) -eq $initialIndex)
# An unreadable record could be the matching one: the notice says so instead of blaming the path.
$brokenRec = Join-Path (Get-ChildItem -LiteralPath (Get-ChildItem -LiteralPath $ccs -Directory | Select-Object -First 1).FullName -Directory | Select-Object -First 1).FullName 'broken-record.json'
Set-Content -LiteralPath $brokenRec '{"cwd":' -NoNewline
run @{ Cwd = $unrecorded; DryRun = $true }
check 'an unreadable record turns the notice into a retry-after-the-app-closes hint' ($rc -eq 0 -and ($out -match '^no readable app record on any seat has workspace .*\(1 record\(s\) could not be read\): retry after the desktop app closes') -and (recHash) -eq $initialIndex)
run @{ Cwd = $unrecorded; DryRun = $true; Quiet = $true }
check 'the unreadable-record notice stays silent under -Quiet' ($rc -eq 0 -and -not ($out -match 'app record') -and (recHash) -eq $initialIndex)
Remove-Item -LiteralPath $brokenRec -Force
Remove-Item -LiteralPath $unrecordedProj -Recurse -Force
Set-Content -LiteralPath $workspaceFile "$workspace\"

# The sandbox index agrees across seats, so plant a disagreement for the first run to resolve.
$U = recs | Where-Object { $_.cli -ne $X } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) -and -not ($_.Group.arch -contains $true) } | Select-Object -First 1
if (-not $U) { "FAIL no unflagged multi-seat session in the index to test with"; exit 1 }
setRec $U.Group[0].f 'isArchived' $true
# Run 1 reads a setting saved the way Windows PowerShell 5.1 saves it (UTF-8 with a BOM, CRLF) and
# spelled in a different case from the app's records: new records must still carry the app's spelling.
[IO.File]::WriteAllBytes($workspaceFile, [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("$($workspace.ToLowerInvariant())\`r`n"))
"--- run 1 (baseline: first run, no state file)"; run; $R = recs
Set-Content -LiteralPath $workspaceFile "$workspace\"
$newCwds = @(Get-ChildItem -LiteralPath $ccs -Recurse -Filter local_*.json | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.cliSessionId -eq $X } | ForEach-Object { $_.cwd; $_.originCwd })
check 'a BOM, CRLF, differently cased setting is read, and new records keep the app''s spelling' ($newCwds.Count -ge 4 -and @($newCwds | Where-Object { -not [string]::Equals($_, $workspace, [StringComparison]::Ordinal) }).Count -eq 0)
check "first run: archived on one seat -> archived on all $($U.Count)" (@(ofSession $U.Name | Where-Object { -not $_.arch }).Count -eq 0)
check 'run 1 exits 0' ($rc -eq 0)
check 'state file written' (Test-Path -LiteralPath $statePath)
check 'every record of a session with any archived record is archived' ((mixed $R 'arch') -eq 0)
check 'every record of a session with any starred record is starred' ((mixed $R 'star') -eq 0)
check "synthetic session got records ($(@($R | Where-Object cli -eq $X).Count))" (@($R | Where-Object cli -eq $X).Count -ge 2)

"--- run 2 (idle)"; $h = recHash; run
check 'idle run changes no record file' ((recHash) -eq $h)
check "idle run prints no 'set ' line, no error" (-not ($out -match '^set |rror|xception') -and $rc -eq 0)
check 'state file has the autoArchived map' ((state).ContainsKey('autoArchived'))

"--- a state file from before auto-archive (no autoArchived map) loads"
$st = state; $st.Remove('autoArchived'); Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5); run
check 'pre-change state: no warning, exits 0' (-not ($out -match 'unreadable') -and $rc -eq 0)
check 'pre-change state: the map is added' ((state).ContainsKey('autoArchived'))
"--- a malformed autoArchived map fails like the other maps: warn, change nothing, leave the file"
$st = state; $st['autoArchived'] = 'x'; Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)
$bad = Get-Content -LiteralPath $statePath -Raw; $h = recHash; run
check 'malformed map: warns' ([bool]($out -match "'autoArchived' is not an object"))
check 'malformed map: no record changed, file left as is' ((recHash) -eq $h -and (Get-Content -LiteralPath $statePath -Raw) -eq $bad)
$st = state; $st['autoArchived'] = @{}; Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)

"--- a .sync-tmp left by a killed run is removed"
$leftover = "$((Get-ChildItem -LiteralPath $ccs -Recurse -Filter local_*.json | Select-Object -First 1).FullName).sync-tmp"; Set-Content -LiteralPath $leftover 'x' -NoNewline; run
check 'leftover .sync-tmp removed' (-not (Test-Path -LiteralPath $leftover))

# An unflagged multi-seat session for the pin / archive tests.
$G = recs | Where-Object { $_.cli -ne $X } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) -and -not ($_.Group.arch -contains $true) } | Sort-Object Count -Descending | Select-Object -First 1
if (-not $G) { "FAIL no unflagged multi-seat session in the index to test with"; exit 1 }
$g0 = $G.Group[0]; $g1 = $G.Group[1]
"--- pin on one seat ($($G.Count) seats)"
setRec $g0.f 'isStarred' $true; run
check 'starred on every seat' (@(ofSession $G.Name | Where-Object { -not $_.star }).Count -eq 0)
"--- unpin on a different seat"
setRec $g1.f 'isStarred' $false; run
check 'unstarred on every seat' (@(ofSession $G.Name | Where-Object star).Count -eq 0)

"--- archive on one seat"
setRec $g0.f 'isArchived' $true; run
check 'archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
check "archived: listed in every folder's archived-sessions.idx" (@(ofSession $G.Name | Where-Object { -not (inIdx $_) }).Count -eq 0)
"--- un-archive on a different seat"
setRec $g1.f 'isArchived' $false; run
check 'un-archived on every seat' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)
check "un-archived: removed from every folder's archived-sessions.idx" (@(ofSession $G.Name | Where-Object { inIdx $_ }).Count -eq 0)

"--- opposite changes on two seats in the same run -> on wins"
# After a run every record of a session agrees, so opposite changes can only come from a state file where two
# seats were recorded differently: seat 0 was 'on' (now off), seat 1 was 'off' (now on).
$st = state
foreach ($fl in 'isArchived', 'isStarred') { $st[$fl][(key $g0.f)] = $true; $st[$fl][(key $g1.f)] = $false; setRec $g0.f $fl $false; setRec $g1.f $fl $true }
Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5); run
$S = ofSession $G.Name
check 'on wins: archived on every seat' (@($S | Where-Object { -not $_.arch }).Count -eq 0)
check 'on wins: starred on every seat' (@($S | Where-Object { -not $_.star }).Count -eq 0)
foreach ($r in $S) { setRec $r.f 'isArchived' $false; setRec $r.f 'isStarred' $false }; run   # reset, and let the state follow
check 'reset: nothing flagged on that session' (@(ofSession $G.Name | Where-Object { $_.arch -or $_.star }).Count -eq 0)

"--- a record not seen last run that is ON spreads (archived on a newly used seat)"
$st = state; $st['isArchived'].Remove((key $g1.f)); Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)
setRec $g1.f 'isArchived' $true; run
check 'unseen archived record -> archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
"--- a record not seen last run that is OFF does not un-archive the others (a new app record starts off)"
$st = state; $st['isArchived'].Remove((key $g0.f)); Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)
setRec $g0.f 'isArchived' $false; run
check 'unseen off record -> still archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $false }; run
check 'reset again: nothing archived on that session' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- a record whose write fails: its session keeps its last baseline, so its stale ON value does not spread next run"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run          # archived everywhere, all known
setRec $g0.f 'isArchived' $false                                                       # un-archive on seat 0
# a second session changed in the same run must still be saved (only the failed session holds back)
$H = recs | Where-Object { $_.cli -ne $X -and $_.cli -ne $G.Name } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) } | Select-Object -First 1
if ($H) { setRec $H.Group[0].f 'isStarred' $true }
Set-ItemProperty -LiteralPath $g1.f -Name IsReadOnly -Value $true; run                 # seat 1's record can't be written
check 'failed write warns' ($out -match 'could not set isArchived')
check 'failed write: the other seats are un-archived' (@(ofSession $G.Name | Where-Object { $_.f -ne $g1.f -and $_.arch }).Count -eq 0)
$st = state; check 'failed write: the session keeps its last baseline' ($st['isArchived'][(key $g0.f)] -eq $true -and $st['isArchived'][(key $g1.f)] -eq $true)
if ($H) {
  check 'failed write: another session changed in the same run is saved' (@(ofSession $H.Name | Where-Object { $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
  foreach ($r in (ofSession $H.Name)) { setRec $r.f 'isStarred' $false }               # put it back (all known -> off)
} else { "(no second unpinned multi-seat session; skipped the other-session check)" }
Set-ItemProperty -LiteralPath $g1.f -Name IsReadOnly -Value $false; run
check 'retried: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)
$st = state; check 'retried: the session baseline moves on' ($st['isArchived'][(key $g0.f)] -eq $false -and $st['isArchived'][(key $g1.f)] -eq $false)

"--- a record that can't be read for a run: its session keeps its last baseline (the rest is saved), so its stale ON value does not spread"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run          # archived everywhere, all known
$keep1 = Get-Content -LiteralPath $g1.f -Raw
if ($H) { setRec $H.Group[0].f 'isStarred' $true }                                     # another session changed in the same run
$x0 = (ofSession $X)[0]; setRec $x0.f 'isStarred' $true                               # a change the save must record
$stHash = (Get-FileHash -LiteralPath $statePath).Hash
setRec $g0.f 'isArchived' $false; Set-Content -LiteralPath $g1.f 'not json' -NoNewline; run   # un-archive on seat 0; seat 1 unreadable
check 'unreadable record warns' ($out -match 'could not read')
$st = state
check 'unreadable record: its session keeps its last baseline' ($st['isArchived'][(key $g0.f)] -eq $true -and $st['isArchived'][(key $g1.f)] -eq $true)
check 'unreadable record: the rest of the state is saved (not the whole-save stop)' ((-not ($out -match 'is not saved this run')) -and ((Get-FileHash -LiteralPath $statePath).Hash -ne $stHash) -and $st['isStarred'][(key $x0.f)] -eq $true -and $st['cli'] -and $st['cli'][(key $g1.f)] -eq $G.Name)
if ($H) {
  check 'unreadable record: another session changed in the same run is saved' (@(ofSession $H.Name | Where-Object { $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
  foreach ($r in (ofSession $H.Name)) { setRec $r.f 'isStarred' $false }
}
foreach ($r in (ofSession $X)) { setRec $r.f 'isStarred' $false }                      # put the synthetic session back (all known -> off)
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run                                # seat 1 readable again, still archived
check 'readable again: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- a flag write in the same run as pass 1.5's reconcile: the records the flag pass just wrote are reconciled too"
# give the transcript real turn ids and an age past pass 1.5's 10-minute window, for this scenario only
$tPath = "$proj\$X.jsonl"; $tOrig = Get-Content -LiteralPath $tPath -Raw
$tu = 1..7 | ForEach-Object { '00000000-0000-0000-0000-00000000000' + $_ }
Set-Content -LiteralPath $tPath (@('{"type":"user","message":{"role":"user","content":"please help me with the flag sync test"}}') + ($tu | ForEach-Object { '{"parentUuid":null,"type":"assistant","uuid":"' + $_ + '","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}}' }))
(Get-Item -LiteralPath $tPath).LastWriteTime = (Get-Date).AddMinutes(-30)
$xs = @(ofSession $X)
setRec $xs[0].f 'lastAssistantUuid' $tu[6]; foreach ($r in ($xs | Select-Object -Skip 1)) { setRec $r.f 'lastAssistantUuid' $tu[2] }
setRec $xs[0].f 'isStarred' $true; run
check 'flag write + pass 1.5: run exits 0' ($rc -eq 0)
check 'flag write + pass 1.5: no error' (-not ($out -match 'Method invocation|op_Subtraction|xception'))
check 'flag write + pass 1.5: pass 2 still ran' ([bool]($out -match '\badded \d+, cloned'))
check 'flag write + pass 1.5: no record mistaken for an outside change' (-not ($out -match 'left .* alone'))
$after = @(ofSession $X | ForEach-Object { Get-Content -LiteralPath $_.f -Raw | ConvertFrom-Json })
check "flag write + pass 1.5: every record reconciled to the last turn ($($after.Count) records)" ($after.Count -ge 2 -and -not ($after | Where-Object { $_.lastAssistantUuid -ne $tu[6] }))
check 'flag write + pass 1.5: every record pinned' (-not ($after | Where-Object { -not $_.isStarred }))
"--- a record pass 1.5 can't write is skipped with a warning; the run still finishes and pass 2 still runs"
$xs = @(ofSession $X)
foreach ($r in ($xs | Select-Object -Skip 1)) { setRec $r.f 'lastAssistantUuid' $tu[2] }
(Get-Item -LiteralPath $tPath).LastWriteTime = (Get-Date).AddMinutes(-30)
(Get-Item -LiteralPath $xs[1].f).IsReadOnly = $true; run
check 'unwritable reconcile: run exits 0' ($rc -eq 0)
check 'unwritable reconcile: warned' ([bool]($out -match 'could not reconcile'))
check 'unwritable reconcile: pass 2 still ran' ([bool]($out -match '\badded \d+, cloned'))
check 'unwritable reconcile: other records reconciled' (-not (@(ofSession $X | Where-Object { $_.f -ne $xs[1].f } | ForEach-Object { Get-Content -LiteralPath $_.f -Raw | ConvertFrom-Json }) | Where-Object { $_.lastAssistantUuid -ne $tu[6] }))
check 'unwritable reconcile: no temp file left' (-not (Get-ChildItem -LiteralPath (Split-Path -LiteralPath $xs[1].f) -Filter '*.sync-tmp'))
(Get-Item -LiteralPath $xs[1].f).IsReadOnly = $false
Set-Content -LiteralPath $tPath $tOrig -NoNewline
foreach ($r in (ofSession $X)) { setRec $r.f 'lastAssistantUuid' ''; setRec $r.f 'isStarred' $false }; run

"--- a held session's new record is neutral (off) and not in the state; the next good run sets it"
foreach ($r in (ofSession $X)) { setRec $r.f 'isArchived' $true }; run              # archived everywhere, all known
$xs = @(ofSession $X); $keepX = Get-Content -LiteralPath $xs[1].f -Raw; $before = @(ofSession $X | ForEach-Object f)
Remove-Item -LiteralPath $xs[0].f; Set-Content -LiteralPath $xs[1].f 'not json' -NoNewline; run   # one seat lacks it, one unreadable
$new = @(ofSession $X | Where-Object { $before -notcontains $_.f })
check "held: a record was recreated ($($new.Count))" ($new.Count -ge 1)
check 'held: the recreated record is neither archived nor pinned' (@($new | Where-Object { $_.arch -or $_.star }).Count -eq 0)
$st = state; check 'held: the recreated record is not in the saved state' (@($new | Where-Object { $st['isArchived'].ContainsKey((key $_.f)) }).Count -eq 0)
Set-Content -LiteralPath $xs[1].f $keepX -NoNewline
$new | Where-Object { (Split-Path -LiteralPath $_.f) -eq (Split-Path -LiteralPath $xs[1].f) } | ForEach-Object { Remove-Item -LiteralPath $_.f }   # the duplicate next to the unreadable record (issue #12)
run
check 'held, next good run: every record of the session is archived' (@(ofSession $X | Where-Object { -not $_.arch }).Count -eq 0)
foreach ($r in (ofSession $X)) { setRec $r.f 'isArchived' $false }; run

"--- a record truncated to 0 bytes counts as unreadable too"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run
$keep1 = Get-Content -LiteralPath $g1.f -Raw
setRec $g0.f 'isArchived' $false; Set-Content -LiteralPath $g1.f '' -NoNewline; run
check 'empty record warns' ($out -match 'could not read')
$st = state; check 'empty record: its session keeps its last baseline' ($st['isArchived'][(key $g1.f)] -eq $true)
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run
check 'empty record, restored: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- the desktop app is running: no record is changed and the state is not saved"
setRec $g0.f 'isArchived' $true
$h = recHash; $stBefore = Get-Content -LiteralPath $statePath -Raw; run @{ AssumeAppRunning = $true }
check 'app running: says flags are not synced' ($out -match 'not synced: the desktop app .*is running')
check 'app running: no record changed' ((recHash) -eq $h)
check 'app running: state file not saved' ((Get-Content -LiteralPath $statePath -Raw) -eq $stBefore)
setRec $g0.f 'isArchived' $false

"--- a record created while the app is running is neutral (off), so it can't count as a change next run"
$xs = @(ofSession $X); foreach ($r in $xs) { setRec $r.f 'isArchived' $true; setRec $r.f 'isStarred' $true }
$before = @($xs.f); Remove-Item -LiteralPath $xs[0].f; run @{ AssumeAppRunning = $true }
$new = @(ofSession $X | Where-Object { $before -notcontains $_.f -or $_.f -eq $xs[0].f })
check "app running: a record was recreated for the synthetic session ($($new.Count))" ($new.Count -ge 1)
check 'app running: the recreated record is neither archived nor pinned' (@($new | Where-Object { $_.arch -or $_.star }).Count -eq 0)
run; foreach ($r in (ofSession $X)) { setRec $r.f 'isArchived' $false; setRec $r.f 'isStarred' $false }; run
check 'reset: synthetic session unflagged' (@(ofSession $X | Where-Object { $_.arch -or $_.star }).Count -eq 0)

"--- a state file from before the record->session map: an unreadable record stops the whole save"
$st = state; $st.Remove('cli'); Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)
$stBefore = Get-Content -LiteralPath $statePath -Raw; $keep1 = Get-Content -LiteralPath $g1.f -Raw
Set-Content -LiteralPath $g1.f 'not json' -NoNewline; run
check 'old state file: says the state is not saved' ($out -match 'is not saved this run')
check 'old state file: state file unchanged' ((Get-Content -LiteralPath $statePath -Raw) -eq $stBefore)
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run
check 'old state file: the next good run adds the map' ([bool](state)['cli'])

"--- a record deleted between runs does not stop the save"
$gd = @(ofSession $G.Name | Where-Object { $_.f -ne $g0.f -and $_.f -ne $g1.f })[0]
if (-not $gd) { $gd = $g1 }
$keepD = Get-Content -LiteralPath $gd.f -Raw; $kd = key $gd.f
Remove-Item -LiteralPath $gd.f; run
check 'deleted record: no read warning' (-not ($out -match 'could not read'))
check 'deleted record: dropped from the saved state' (-not (state)['isArchived'].ContainsKey($kd))
Set-Content -LiteralPath $gd.f $keepD -NoNewline; run

"--- corrupt state file: warn, change nothing, leave the file as is"
$good = Get-Content -LiteralPath $statePath -Raw
setRec $g0.f 'isArchived' $true          # a real change that a healthy run would spread to every seat
Set-Content -LiteralPath $statePath 'not json' -NoNewline
$h = recHash; run
check 'warns about the state file' (($out -match 'WARNING.*unreadable|unreadable.*not synced') -and ($out -match [regex]::Escape('.flag-state.json')))
check 'no record changed' ((recHash) -eq $h)
check 'state file left as is' ((Get-Content -LiteralPath $statePath -Raw) -eq 'not json')
check 'corrupt state does not fail the run' ($rc -eq 0)
Set-Content -LiteralPath $statePath $good -NoNewline; setRec $g0.f 'isArchived' $false

"--- missing ~\.claude-app-seats directory (a first run again: pinned on one seat -> pinned on all)"
setRec $g0.f 'isStarred' $true
Remove-Item -LiteralPath "$sb\home\.claude-app-seats" -Recurse -Force
run
check 'first run again: starred on every seat' (@(ofSession $G.Name | Where-Object { -not $_.star }).Count -eq 0)
check 'run succeeds' ($rc -eq 0 -and -not ($out -match 'rror|xception'))
check 'state file exists again' (Test-Path -LiteralPath $statePath)

"--- a record the script clones from another seat carries the flags"
$RX = ofSession $X
if ($RX.Count -ge 2) {
  $a = $RX[0]; $b = $RX[1]
  Remove-Item -LiteralPath $b.f
  setRec $a.f 'isArchived' $true; setRec $a.f 'isStarred' $true
  run
  $S = ofSession $X
  $new = @($S | Where-Object { $_.f -ne $a.f -and (Split-Path -LiteralPath $_.f) -eq (Split-Path -LiteralPath $b.f) })
  check 'the deleted record was re-created' ($new.Count -eq 1 -and $S.Count -eq $RX.Count)
  check 'every record of the session archived + starred' (@($S | Where-Object { -not ($_.arch -and $_.star) }).Count -eq 0)
  $st = state
  check 'new record is in the saved baseline with its flags' ($new.Count -eq 1 -and $st['isArchived'][(key $new[0].f)] -eq $true -and $st['isStarred'][(key $new[0].f)] -eq $true)
} else { "SKIP clone scenario: fewer than 2 records of the synthetic session" }

"--- a record the script fabricates from the transcript carries the flags"
$RX = ofSession $X
if ($RX.Count -ge 1) {
  $a = $RX[0]
  foreach ($r in ($RX | Select-Object -Skip 1)) { Remove-Item -LiteralPath $r.f }
  setRec $a.f 'title' 'Session 2026-01-01 00:00'    # no well-titled source left -> pass 2 cannot clone, it fabricates
  run
  $S = ofSession $X
  $made = @($S | Where-Object { $_.f -ne $a.f })
  check "records were fabricated ($($made.Count))" ($made.Count -ge 1)
  check 'fabricated records are archived + starred' (@($made | Where-Object { -not ($_.arch -and $_.star) }).Count -eq 0)
  $st = state
  check 'fabricated records are in the saved baseline' (@($made | Where-Object { $st['isArchived'][(key $_.f)] -ne $true -or $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
}

"--- auto-archive: an old session is archived on every seat; no record moves or disappears"
$O1 = mkOld; $paths = @((Get-ChildItem -LiteralPath $ccs -Recurse -Filter local_*.json).FullName); run
$S = ofSession $O1
check "old session: archived on every seat ($($S.Count))" ($S.Count -ge 2 -and @($S | Where-Object { -not $_.arch }).Count -eq 0)
check "old session: in every folder's archived-sessions.idx" (@($S | Where-Object { -not (inIdx $_) }).Count -eq 0)
check 'no record file moved or removed' (@($paths | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0)
check 'old session: remembered as done' (autoDone $O1)
$st = state; check 'old session: baseline records it archived' (@($S | Where-Object { $st['isArchived'][(key $_.f)] -ne $true }).Count -eq 0)
check 'says it auto-archived one session' ([bool]($out -match '^auto-archived 1 session'))
"--- an un-archive after that is respected on later runs"
setRec $S[0].f 'isArchived' $false; run; run
check 'un-archived on every seat and still so two runs later' (@(ofSession $O1 | Where-Object arch).Count -eq 0)

"--- the app being open defers auto-archive to the next run"
$O2 = mkOld; run @{ AssumeAppRunning = $true }
check 'app open: old session not archived' (@(ofSession $O2 | Where-Object arch).Count -eq 0)
check 'app open: not marked done' (-not (autoDone $O2))
run @{ DryRun = $true }
check 'dry run: reports it WOULD auto-archive 1 session' ([bool]($out -match '^WOULD auto-archive 1 session'))
check 'dry run: nothing archived' (@(ofSession $O2 | Where-Object arch).Count -eq 0)
run
check 'app closed: archived on every seat' (@(ofSession $O2 | Where-Object { -not $_.arch }).Count -eq 0)
check 'app closed: marked done' (autoDone $O2)

"--- a pinned old session is not auto-archived"
$O3 = mkOld; setRec (ofSession $O3)[0].f 'isStarred' $true; run
check 'pinned old session: pinned on every seat' (@(ofSession $O3 | Where-Object { -not $_.star }).Count -eq 0)
check 'pinned old session: archived on none, not marked done' (@(ofSession $O3 | Where-Object arch).Count -eq 0 -and -not (autoDone $O3))

"--- a held session (a record it had can't be read) is not auto-archived or marked done, and is retried"
$O4 = mkOld; run @{ MaxAgeDays = 0 }                                      # its records join the baseline; 0 = auto-archive off
check '-MaxAgeDays 0: not archived' (@(ofSession $O4 | Where-Object arch).Count -eq 0 -and -not (autoDone $O4))
$r4 = @(ofSession $O4); $raw4 = Get-Content -LiteralPath $r4[1].f -Raw; Set-Content -LiteralPath $r4[1].f 'not json' -NoNewline; run   # not $o4: PowerShell names ignore case
check 'held: warns' ([bool]($out -match 'could not read'))
check 'held: not archived, not marked done' (@(ofSession $O4 | Where-Object arch).Count -eq 0 -and -not (autoDone $O4))
Set-Content -LiteralPath $r4[1].f $raw4 -NoNewline; run
check 'retried: archived on every seat and marked done' (@(ofSession $O4 | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $O4))
check 'run succeeds' ($rc -eq 0 -and -not ($out -match 'rror|xception'))

"--- an old session the user un-archived since the last run is not archived, and is remembered"
$O5 = mkOld; foreach ($r in (ofSession $O5)) { setRec $r.f 'isArchived' $true }; run @{ MaxAgeDays = 0 }   # archived on every seat, all known, not marked done
check 'user-off: setup: archived everywhere, not marked done' (@(ofSession $O5 | Where-Object { -not $_.arch }).Count -eq 0 -and -not (autoDone $O5))
setRec (ofSession $O5)[0].f 'isArchived' $false; run
check 'user-off: un-archived on every seat' (@(ofSession $O5 | Where-Object arch).Count -eq 0)
check 'user-off: remembered as done' (autoDone $O5)
check 'user-off: not counted as auto-archived' (-not ($out -match '^auto-archived [1-9]') -and [bool]($out -match 'left un-archived as the user chose'))
run
check 'user-off: still un-archived on a further run' (@(ofSession $O5 | Where-Object arch).Count -eq 0)

"--- an old session with autoArchiveExempt on a record is not archived, and is remembered"
$O6 = mkOld; setRec (ofSession $O6)[0].f 'autoArchiveExempt' $true; run
check 'exempt: archived on no seat' (@(ofSession $O6 | Where-Object arch).Count -eq 0)
check 'exempt: remembered as done' (autoDone $O6)
run
check 'exempt: still not archived on a further run' (@(ofSession $O6 | Where-Object arch).Count -eq 0)

"--- the cwd guard: an old session whose records are for another cwd is not archived or remembered"
$O7 = mkOld; foreach ($r in (ofSession $O7)) { setRec $r.f 'cwd' 'C:\Dev\somewhere-else' }; run
check 'other cwd: not archived' (@(ofSession $O7 | Where-Object arch).Count -eq 0)
check 'other cwd: not remembered as done' (-not (autoDone $O7))

"--- a state file without the record->session map plus an unreadable record: nothing is auto-archived, autoArchived is not changed"
$O8 = mkOld; run @{ MaxAgeDays = 0 }                                     # its records join the baseline
$st = state; $st.Remove('cli'); Set-Content -LiteralPath $statePath ($st | ConvertTo-Json -Compress -Depth 5)
$stBefore = Get-Content -LiteralPath $statePath -Raw; $r8 = @(ofSession $O8); $raw8 = Get-Content -LiteralPath $r8[1].f -Raw
Set-Content -LiteralPath $r8[1].f 'not json' -NoNewline; run
check 'no cli map + unreadable record: not archived, not remembered' (@(ofSession $O8 | Where-Object arch).Count -eq 0 -and -not (autoDone $O8))
check 'no cli map + unreadable record: state file (autoArchived) unchanged' ((Get-Content -LiteralPath $statePath -Raw) -eq $stBefore)
Set-Content -LiteralPath $r8[1].f $raw8 -NoNewline; run
check 'no cli map, record readable again: archived on every seat and remembered' (@(ofSession $O8 | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $O8))

"--- an un-archive the sync sees on a YOUNG session is remembered, so it is not archived once the session is old"
$Y = mkOld 1; foreach ($r in (ofSession $Y)) { setRec $r.f 'isArchived' $true }; run   # archived on every seat by hand; young, so not due
check 'young: setup: archived on every seat, not remembered' (@(ofSession $Y | Where-Object { -not $_.arch }).Count -eq 0 -and -not (autoDone $Y))
setRec (ofSession $Y)[0].f 'isArchived' $false; run
check 'young: un-archived on every seat' (@(ofSession $Y | Where-Object arch).Count -eq 0)
check 'young: remembered as a kept entry' ((autoVal $Y) -like 'kept *')
touch $Y 30; run
check 'young, then aged to 30 days: still un-archived on every seat' (@(ofSession $Y | Where-Object arch).Count -eq 0)
check 'young, then aged: still remembered' (autoDone $Y)

"--- an un-archive the sync sees in a run that is out of scope (-MaxAgeDays 0) is remembered too"
$YA = mkOld 1; foreach ($r in (ofSession $YA)) { setRec $r.f 'isArchived' $true }; run   # archived on every seat by hand; young, so not due
setRec (ofSession $YA)[0].f 'isArchived' $false; run @{ MaxAgeDays = 0 }
check 'out of scope: un-archived on every seat' (@(ofSession $YA | Where-Object arch).Count -eq 0)
check 'out of scope: remembered as a kept entry' ((autoVal $YA) -like 'kept *')
touch $YA 30; run
check 'out of scope, then aged to 30 days, default run: still un-archived on every seat' (@(ofSession $YA | Where-Object arch).Count -eq 0)
check 'out of scope, then aged: still a kept entry' ((autoVal $YA) -like 'kept *')

"--- a session that was already archived (by hand) when it came due is remembered as seen, and a resume does not revive it"
$YB = mkOld 1; foreach ($r in (ofSession $YB)) { setRec $r.f 'isArchived' $true }; run   # archived on every seat by hand, saved state; young, so not due
touch $YB 30; run
check 'seen: still archived on every seat after it came due' (@(ofSession $YB | Where-Object { -not $_.arch }).Count -eq 0)
check 'seen: remembered as a seen entry (not a plain date)' ((autoVal $YB) -like 'seen *')
touch $YB 0; run
check 'seen: resumed: stays archived on every seat (a seen entry is never revived)' (@(ofSession $YB | Where-Object { -not $_.arch }).Count -eq 0 -and (autoVal $YB) -like 'seen *')

"--- a session archived for age and then resumed is un-archived on every seat, and archived again once stale"
$RV = mkOld; run
check 'revive: setup: archived on every seat, remembered as a plain date' (@(ofSession $RV | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $RV) -and -not ((autoVal $RV) -like 'kept *'))
touch $RV 0; $AV = mkOld; run @{ DryRun = $true }   # a revive and an age archive due in the same run: the summary line carries both
check 'revive + age archive, dry run: exits 0, no error, says it would un-archive one' ($rc -eq 0 -and -not ($out -match 'rror|xception') -and [bool]($out -match '\+1 would be un-archived because their transcript was written again'))
run
check 'revive + age archive in one run: exits 0, no error' ($rc -eq 0 -and -not ($out -match 'rror|xception'))
check 'revive + age archive in one run: the auto-archived line also reports the revive' ([bool]($out -match '^auto-archived 1 session.*\+1 un-archived because their transcript was written again'))
check 'revive + age archive in one run: the other session is archived for age' (@(ofSession $AV | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $AV))
check 'revive: resumed: un-archived on every seat' (@(ofSession $RV | Where-Object arch).Count -eq 0)
check "revive: resumed: removed from every folder's archived-sessions.idx" (@(ofSession $RV | Where-Object { inIdx $_ }).Count -eq 0)
check 'revive: resumed: no longer remembered' (-not (autoDone $RV))
check 'revive: says it un-archived one because its transcript was written again' ([bool]($out -match '(\+1 un-archived because|un-archived 1 session\(s\) archived for age, because) their transcript was written again'))
run
check 'revive: a further run leaves it un-archived' (@(ofSession $RV | Where-Object arch).Count -eq 0 -and -not (autoDone $RV))
touch $RV 30; run
check 'revive: stale again: archived once more on every seat' (@(ofSession $RV | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $RV))

"--- a new un-archived copy (pass 2 made it while the app was open) does not block a revive"
$NC = mkOld; run
check 'revive with a new copy: setup: archived on every seat, plain date' (@(ofSession $NC | Where-Object { -not $_.arch }).Count -eq 0 -and (autoVal $NC) -notmatch '^(kept|seen|revive) ' -and (autoDone $NC))
$ncSrc = (ofSession $NC)[0]; $ncj = Get-Content -LiteralPath $ncSrc.f -Raw | ConvertFrom-Json; $ncj.sessionId = "local_$([guid]::NewGuid())"; $ncj.isArchived = $false
Set-Content -LiteralPath (Join-Path (Split-Path -LiteralPath $ncSrc.f) "$($ncj.sessionId).json") ($ncj | ConvertTo-Json -Compress -Depth 100) -NoNewline
touch $NC 0; run
check 'revive with a new copy: un-archived on every record, the new copy included' (@(ofSession $NC | Where-Object arch).Count -eq 0)
check 'revive with a new copy: no longer remembered' (-not (autoDone $NC))

"--- a revive that is held (one record can't be written) leaves a revive entry; the next run finishes it"
$HR = mkOld; run
check 'held revive: setup: archived on every seat, remembered as a plain date' (@(ofSession $HR | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $HR) -and (autoVal $HR) -notmatch '^(kept|seen|revive) ')
$rhRec = @(ofSession $HR); touch $HR 0; (Get-Item -LiteralPath $rhRec[1].f).IsReadOnly = $true; run   # the resume revives it; seat 1's record can't be written
check 'held revive: the other records are un-archived, the unwritable one is not' (@(ofSession $HR | Where-Object { $_.f -ne $rhRec[1].f -and $_.arch }).Count -eq 0 -and @(ofSession $HR | Where-Object { $_.f -eq $rhRec[1].f -and $_.arch }).Count -eq 1)
check 'held revive: remembered as a revive entry (not the plain date)' ((autoDone $HR) -and (autoVal $HR) -like 'revive *')
(Get-Item -LiteralPath $rhRec[1].f).IsReadOnly = $false; run
check 'held revive, next run: un-archived on every seat' (@(ofSession $HR | Where-Object arch).Count -eq 0)
check 'held revive, next run: finished (no longer remembered), not a kept entry' (-not (autoDone $HR))
check 'held revive, next run: says it un-archived one because its transcript was written again' ([bool]($out -match '(\+1 un-archived because|un-archived 1 session\(s\) archived for age, because) their transcript was written again'))
run
check 'held revive: a further run leaves it un-archived and forgotten' (@(ofSession $HR | Where-Object arch).Count -eq 0 -and -not (autoDone $HR))

"--- a plain-date session the user un-archives while resuming it becomes a kept entry (no revive is inferred), and stays un-archived once stale"
$UP = mkOld; run
check 'user un-archive on resume: setup: archived on every seat, remembered as a plain date' (@(ofSession $UP | Where-Object { -not $_.arch }).Count -eq 0 -and (autoDone $UP) -and (autoVal $UP) -notmatch '^(kept|seen|revive) ')
touch $UP 0; setRec (ofSession $UP)[0].f 'isArchived' $false; run
check 'user un-archive on resume: un-archived on every seat' (@(ofSession $UP | Where-Object arch).Count -eq 0)
check 'user un-archive on resume: remembered as a kept entry' ((autoVal $UP) -like 'kept *')
touch $UP 30; run
check 'user un-archive on resume, then aged to 30 days: still un-archived on every seat' (@(ofSession $UP | Where-Object arch).Count -eq 0 -and (autoVal $UP) -like 'kept *')

"--- an age archive that is held after one record was written keeps its plain date; the failed record is written next run; a resume revives it"
$HA = mkOld; $haRec = @(ofSession $HA); (Get-Item -LiteralPath $haRec[1].f).IsReadOnly = $true; run   # seat 1's record can't be written
check 'held age archive: warns' ([bool]($out -match 'could not set isArchived'))
check 'held age archive: the other records are archived, the unwritable one is not' (@(ofSession $HA | Where-Object { $_.f -ne $haRec[1].f -and -not $_.arch }).Count -eq 0 -and @(ofSession $HA | Where-Object { $_.f -eq $haRec[1].f -and $_.arch }).Count -eq 0)
check 'held age archive: remembered as a plain date' ((autoDone $HA) -and (autoVal $HA) -notmatch '^(kept|seen|revive) ')
(Get-Item -LiteralPath $haRec[1].f).IsReadOnly = $false; run
check 'held age archive, next run: archived on every seat' (@(ofSession $HA | Where-Object { -not $_.arch }).Count -eq 0)
check 'held age archive, next run: still a plain date (not seen, not kept)' ((autoDone $HA) -and (autoVal $HA) -notmatch '^(kept|seen|revive) ')
touch $HA 0; run
check 'held age archive: resumed: un-archived on every seat (revived)' (@(ofSession $HA | Where-Object arch).Count -eq 0 -and -not (autoDone $HA))

"--- an archive-for-age the user un-archived becomes a kept entry: archived by hand and resumed, it stays archived"
setRec (ofSession $RV)[0].f 'isArchived' $false; run
check 'kept after archive-for-age: un-archived on every seat, now a kept entry' (@(ofSession $RV | Where-Object arch).Count -eq 0 -and (autoVal $RV) -like 'kept *')
foreach ($r in (ofSession $RV)) { setRec $r.f 'isArchived' $true }; run
check 'kept after archive-for-age: archived by hand on every seat' (@(ofSession $RV | Where-Object { -not $_.arch }).Count -eq 0)
touch $RV 0; run
check 'kept after archive-for-age: resumed: stays archived (a kept entry is never revived)' (@(ofSession $RV | Where-Object { -not $_.arch }).Count -eq 0 -and (autoVal $RV) -like 'kept *')

"--- a kept entry (the user un-archived it) that the user later archives by hand and resumes stays archived"
foreach ($r in (ofSession $Y)) { setRec $r.f 'isArchived' $true }; run
check 'kept: archived by hand on every seat' (@(ofSession $Y | Where-Object { -not $_.arch }).Count -eq 0 -and (autoVal $Y) -like 'kept *')
touch $Y 0; run
check 'kept: resumed: stays archived on every seat' (@(ofSession $Y | Where-Object { -not $_.arch }).Count -eq 0 -and (autoVal $Y) -like 'kept *')

# A share root can already have local transcripts and app records keyed with the final separator.
$uncWorkspace = '\\?\unc\history-root-fixture.invalid.\share\'
$uncEncoded = $uncWorkspace -creplace '[^A-Za-z0-9]', '-'
$uncProj = "$sb\home\.claude\projects\$uncEncoded"
$uncBucket = "$ccs\A\unc-share-root-fixture"
New-Item -ItemType Directory $uncProj, $uncBucket -Force | Out-Null
$seedId = "local_$([guid]::NewGuid())"
@{ sessionId = $seedId; cliSessionId = [guid]::NewGuid().ToString(); cwd = $uncWorkspace; originCwd = $uncWorkspace } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $uncBucket "$seedId.json") -NoNewline
$uncSession = [guid]::NewGuid().ToString()
Set-Content -LiteralPath (Join-Path $uncProj "$uncSession.jsonl") (@('{"type":"user","message":{"role":"user","content":"test a share root"}}') + $asst)
run @{ Cwd = $uncWorkspace }
$newUncRecords = @(ofSession $uncSession | ForEach-Object { Get-Content -LiteralPath $_.f -Raw | ConvertFrom-Json })
check 'a trailing UNC share-root separator is preserved in new app pointers' ($rc -eq 0 -and $newUncRecords.Count -gt 0 -and -not ($newUncRecords | Where-Object { $_.cwd -ne $uncWorkspace -or $_.originCwd -ne $uncWorkspace }))
$beforeUnc = recHash
run @{ Cwd = $uncWorkspace.TrimEnd('\'); DryRun = $true }
check 'a UNC root without a separator does not import from a different transcript key' ($rc -eq 0 -and ($out -match '^no transcripts') -and (recHash) -eq $beforeUnc)

# Two seats spell one workspace in different case: each seat's new records take that seat's own spelling,
# and a seat with no record of it takes the shared (first-seen) spelling.
$spellRoot = [IO.Path]::GetPathRoot($PSHOME)
$spellA = $spellRoot + 'Sync-Spelling-Fixture'; $spellB = $spellRoot + 'SYNC-SPELLING-FIXTURE'
$spellProj = "$sb\home\.claude\projects\$($spellA -creplace '[^A-Za-z0-9]', '-')"
New-Item -ItemType Directory $spellProj -Force | Out-Null
foreach ($pair in @(@('A', $spellA), @('B', $spellB))) {
  $dir = Join-Path (Join-Path $ccs $pair[0]) 'spelling-fixture'
  New-Item -ItemType Directory $dir -Force | Out-Null
  $id = "local_$([guid]::NewGuid())"
  @{ sessionId = $id; cliSessionId = [guid]::NewGuid().ToString(); cwd = $pair[1]; originCwd = $pair[1]; title = 'Synthetic session' } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dir "$id.json") -NoNewline
}
$spellSession = [guid]::NewGuid().ToString()
Set-Content -LiteralPath (Join-Path $spellProj "$spellSession.jsonl") (@('{"type":"user","message":{"role":"user","content":"test per-seat workspace spelling"}}') + $asst)
# A titled record on seat A only: seats B and C get clones of it, which must not keep A's spelling on B.
$spellClone = [guid]::NewGuid().ToString()
Set-Content -LiteralPath (Join-Path $spellProj "$spellClone.jsonl") (@('{"type":"user","message":{"role":"user","content":"test a cloned record''s spelling"}}') + $asst)
$id = "local_$([guid]::NewGuid())"
# Its originCwd names another directory, which clones must keep.
$cloneOrigin = $spellRoot + 'Some-Other-Origin'
@{ sessionId = $id; cliSessionId = $spellClone; cwd = $spellA; originCwd = $cloneOrigin; title = 'Titled by the app' } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $ccs 'A') 'spelling-fixture') "$id.json") -NoNewline
run @{ Cwd = $spellA.ToLowerInvariant() }
$spellOf = { param($cli) $m = @{}; foreach ($r in (ofSession $cli)) { $j = Get-Content -LiteralPath $r.f -Raw | ConvertFrom-Json; $m[(key $r.f).Split('\')[0]] = @($j.cwd, $j.originCwd, $j.title) }; $m }
$made = & $spellOf $spellSession; $cloned = & $spellOf $spellClone
$seatOk = { param($m, $s, $want) $m[$s] -and @($m[$s][0, 1] | Where-Object { -not [string]::Equals($_, $want, [StringComparison]::Ordinal) }).Count -eq 0 }
check 'new records take the destination seat''s own spelling of the workspace' ($rc -eq 0 -and (& $seatOk $made 'A' $spellA) -and (& $seatOk $made 'B' $spellB) -and (& $seatOk $made 'C' $spellA))
check 'cloned records take the destination seat''s spelling and keep the app''s title and a different origin' ($cloned['B'] -and $cloned['C'] -and [string]::Equals($cloned['B'][0], $spellB, [StringComparison]::Ordinal) -and [string]::Equals($cloned['C'][0], $spellA, [StringComparison]::Ordinal) -and $cloned['B'][1] -eq $cloneOrigin -and $cloned['C'][1] -eq $cloneOrigin -and $cloned['B'][2] -eq 'Titled by the app')

# A record for 'café' (one character) is a different directory from 'cafe' + combining accent: no match.
$accentRec = $spellRoot + "accent-caf$([char]0xE9)"; $accentCwd = $spellRoot + "accent-cafe$([char]0x301)"
$accentProj = "$sb\home\.claude\projects\$($accentCwd -creplace '[^A-Za-z0-9]', '-')"
$accentDir = Join-Path (Join-Path $ccs 'A') 'accent-fixture'
New-Item -ItemType Directory $accentProj, $accentDir -Force | Out-Null
$id = "local_$([guid]::NewGuid())"
@{ sessionId = $id; cliSessionId = [guid]::NewGuid().ToString(); cwd = $accentRec; originCwd = $accentRec; title = 'Synthetic session' } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $accentDir "$id.json") -NoNewline
Set-Content -LiteralPath (Join-Path $accentProj "$([guid]::NewGuid()).jsonl") (@('{"type":"user","message":{"role":"user","content":"test a combining accent"}}') + $asst)
$beforeAccent = recHash
run @{ Cwd = $accentCwd; DryRun = $true }
check 'a record spelled with a precomposed accent does not match a combining-accent workspace' ($rc -eq 0 -and ($out -match '^no app record on any seat has workspace') -and ($out -match '^WOULD: added 0,') -and (recHash) -eq $beforeAccent)

"$fail failure(s)"
if ($fail -eq 0) { Remove-Item -LiteralPath $sb -Recurse -Force } else { "sandbox kept: $sb" }
exit [int]($fail -gt 0)
