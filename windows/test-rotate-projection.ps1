<#
test-rotate-projection.ps1 — self-check for the two 2026-09-22 rotator fixes.

  pwsh -NoProfile -File C:\Dev\Rotators\test-rotate-projection.ps1

Covers the logic that actually decides a rotation, not the network calls:
  1. the session-window projection (rotate BEFORE the wall at a real burn rate),
  2. the probe deadline vs the 5-minute task tick (no silently skipped probes),
  3. the $capped classification that gates Ping-ActiveSessions.
#>
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

# Mirrors the live constants + branch order in Invoke-CheckRotate. Kept in step by test 0.
$SessionAt = 85; $SessionProbeSec = 240; $TaskTickSec = 300

function Decide {
  param([int]$s5, [int]$w7, [int]$prev, [int]$elapsed, [string]$s5stat = 'allowed', [string]$w7stat = 'allowed')
  $rate = 0.0
  if ($elapsed -gt 0 -and $s5 -gt $prev) { $rate = ($s5 - $prev) / [double]$elapsed }
  $proj = $s5 + [int][math]::Ceiling($rate * $SessionProbeSec)
  $trigger = $null; $capped = $null
  if ($w7stat -eq 'rejected')     { $trigger = 'weekly cap';  $capped = 'weekly' }
  elseif ($s5stat -eq 'rejected') { $trigger = 'session cap'; $capped = 'session' }
  elseif ($s5 -ge $SessionAt)     { $trigger = 'level' }
  elseif ($proj -ge $SessionAt)   { $trigger = 'projected' }
  [pscustomobject]@{ trigger = $trigger; capped = $capped; proj = $proj; rate = $rate }
}

Write-Host "`nrotator projection + cap-classification self-check" -ForegroundColor Cyan

# 0. the constants above still match the script under test
$src = Get-Content (Join-Path (Split-Path -Parent $PSCommandPath) 'claude-cli-account.ps1') -Raw
Check 'constants in step with claude-cli-account.ps1' `
  (($src -match '\$SessionAt\s*=\s*85\b') -and ($src -match '\$SessionProbeSec\s*=\s*240\b')) `
  'update this test and the script together'

# 0b. The failure path must not re-introduce the tick race with a bare 300 (2026-09-23).
Check 'probe-failure back-off uses $SessionProbeSec, not a bare 300' `
  ($src -notmatch '\$st\.nextHaiku\s*=\s*\$now\s*\+\s*300\b') `
  'a bare 300 in the failure path turns one failed probe into 10 minutes blind'

# 0c. A failed probe retries once before the watcher goes blind (2026-09-23).
Check 'probe retries once on failure' `
  ($src -match 'if \(-not \$u\.ok\) \{ \$u = Get-UsageCached') `
  'without the retry, one transient 12s timeout costs a whole interval of sight'

# 1. The contract is NOT "rotate as soon as it is burning" — that would throw away headroom the
#    bar deliberately keeps. It is "rotate at the last probe before the seat is projected to cross
#    the bar", so the crossing happens with the rotation, at any burn rate.
#    1 pt/min (measured 2026-09-20): 4 points per interval, so it trips at 81 and holds at 80.
$r = Decide -s5 80 -w7 30 -prev 76 -elapsed 240
Check '1%/min at 80% holds (headroom not wasted)' ($null -eq $r.trigger) "got '$($r.trigger)' proj=$($r.proj)"
$r = Decide -s5 81 -w7 30 -prev 77 -elapsed 240
Check '1%/min trips at 81%, one interval short of the bar' ($r.trigger -eq 'projected') "got '$($r.trigger)' proj=$($r.proj)"
#    3 pt/min (the 2026-09-22/23 regime): 12 points per interval, so the same rule trips at 73.
$r = Decide -s5 73 -w7 17 -prev 61 -elapsed 240
Check '3%/min trips at 73% on the same rule' ($r.trigger -eq 'projected') "got '$($r.trigger)' proj=$($r.proj)"
$r = Decide -s5 72 -w7 17 -prev 60 -elapsed 240
Check '3%/min still holds at 72%' ($null -eq $r.trigger) "got '$($r.trigger)' proj=$($r.proj)"

# 2. THE 2026-09-23 CASE the lowered floor exists for — and be exact about it, because the obvious
#    reading is wrong. Seat C burned a slow steady ~0.34 %/min from 0% at 11:36 and capped at 16:29,
#    with four logged 12-second probe timeouts on the way. At a 90 bar the projection trips at 88%,
#    which that seat reached at ~15:55 — and the 16:00 probe, the one in that window, FAILED. So 90
#    did not miss the seat by being too high; it left a trigger window ~35 minutes wide and a ~29
#    minute blind spell swallowed it whole. The probe retry is the real fix; the floor is the margin
#    that stops a single blind spell spanning the window at all.
$r = Decide -s5 85 -w7 27 -prev 84 -elapsed 180
Check 'slow 0.34%/min burn trips at the 85 bar' ($r.trigger -eq 'level') "got '$($r.trigger)' proj=$($r.proj)"
#    The invariant that justifies the number: at the slowest burn that still caps inside a session
#    window, the time from first trip-eligible probe to the 100% wall must exceed the longest blind
#    spell observed (29 min on 2026-09-23) with real room to spare.
#      bar 90 -> 29 min (exactly the spell: no margin at all, which is how C capped)
#      bar 85 -> 44 min (the owner's number, 2026-09-23 — 75 was rejected as too much churn)
#      bar 75 -> 74 min
#    40 is the floor under the floor: it passes 85 and fails 90, so raising the bar back toward 90
#    fails a test rather than a seat. It is NOT a claim that 85 is comfortable — it is 1.5x the
#    worst spell where 75 was 2.5x, so the probe retry now carries more of this than the bar does.
$slowRate = 0.34                                   # %/min, measured on seat C 2026-09-23
$marginMin = (100 - $SessionAt) / $slowRate
Check 'bar leaves >40 min before the wall at the slowest capping burn' `
  ($marginMin -gt 40) ("margin is {0:n0} min at {1}%/min; a 90 bar gives only {2:n0}, the width of the spell that capped C" -f `
                        $marginMin, $slowRate, ((100 - 90) / $slowRate))

# 3. an idle seat must NOT rotate early — the projection may not cost headroom on a quiet day.
$r = Decide -s5 40 -w7 10 -prev 39 -elapsed 240
Check 'idle seat does not rotate early' ($null -eq $r.trigger) "got '$($r.trigger)' proj=$($r.proj)"

# 4. a window RESET (s5 drops) must never manufacture a rate.
$r = Decide -s5 5 -w7 10 -prev 104 -elapsed 240
Check 'window reset yields no rate' (($null -eq $r.trigger) -and $r.rate -eq 0.0) "rate=$($r.rate)"

# 5. first sample after a switch: no prior timestamp, so no projection, no spurious rotate.
$r = Decide -s5 22 -w7 33 -prev 0 -elapsed 0
Check 'first sample after a switch is inert' ($null -eq $r.trigger) "got '$($r.trigger)'"

# 6. THE ping bug: a session-window rejection must classify as a cap, or nothing is woken.
$r = Decide -s5 104 -w7 17 -prev 89 -elapsed 240 -s5stat 'rejected'
Check 'session cap sets $capped (drives Ping-ActiveSessions)' ($r.capped -eq 'session') "capped='$($r.capped)'"

# 7. weekly still wins the classification when both are rejected (pre-existing behaviour).
$r = Decide -s5 104 -w7 100 -prev 89 -elapsed 240 -s5stat 'rejected' -w7stat 'rejected'
Check 'weekly cap still classifies first' ($r.capped -eq 'weekly') "capped='$($r.capped)'"

# 8. a proactive (uncapped) rotation must NOT ping — owner, 2026-08-16.
$r = Decide -s5 91 -w7 30 -prev 88 -elapsed 240
Check 'proactive rotation leaves $capped unset' (($r.trigger -eq 'level') -and ($null -eq $r.capped)) "capped='$($r.capped)'"

# 9. the skipped-probe bug: the deadline must clear the next task tick even with startup jitter.
#    Worst case is a slow tick (late $now) followed by a fast one (early $now).
$jitterSec = 25   # measured range of pwsh startup on this box: ~1s to ~25s
Check 'probe deadline clears the next 5-min tick under worst-case jitter' `
  (($SessionProbeSec + $jitterSec) -lt ($TaskTickSec + $jitterSec) -and $SessionProbeSec -le ($TaskTickSec - $jitterSec)) `
  "SessionProbeSec=$SessionProbeSec needs <= $($TaskTickSec - $jitterSec)"

# 10. Parked merge-pr reviews are skipped, everything else is nudged (owner, 2026-10-20, option A).
#     Fail-open: the ONLY thing that skips an inject is a clean exit-0 JSON status of exactly "parked".
. (Join-Path (Split-Path -Parent $PSCommandPath) 'MergePrParked.ps1')
function FakeStatus([string]$json, [int]$code = 0) { $r = @{ ExitCode = $code; Stdout = $json }; { $r }.GetNewClosure() }
$repo = 'Your-Org/Your-Repo'
Check 'lock-status "parked" => skipped'  (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus '{"status": "parked", "lock": "x"}'))
Check 'lock-status "active" => pinged'   (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus '{"status": "active"}')))
foreach ($st in 'free','stale','Parked','parked ','PARKED','') {
  Check "lock-status '$st' => pinged" (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus ('{"status": "' + $st + '"}'))))
}
Check 'lock-status non-zero exit (even printing parked) => pinged' (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus '{"status": "parked"}' 1)))
Check 'lock-status unparseable output => pinged' (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus 'Traceback (most recent call last)')))
Check 'lock-status empty output => pinged'       (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus '')))
Check 'lock-status non-string status => pinged'  (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke (FakeStatus '{"status": ["parked"]}')))
Check 'lock-status invoker throws => pinged'     (-not (Test-MergePrParked -Repo $repo -Pr 1 -Invoke { throw 'boom' }))
Check 'launcher missing => pinged' (-not (Test-MergePrParked -Repo $repo -Pr 1 -Launcher (Join-Path ([IO.Path]::GetTempPath()) 'no-such-launcher.py')))

# 10b. window -> PR mapping (separate from the decision). Throwaway state dir, not the real one.
$sd = Join-Path ([IO.Path]::GetTempPath()) ("rot-parked-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $sd 'locks') -Force | Out-Null
try {
  '{"repo": "Your-Org/Your-Repo", "pr": 77, "state": "parked", "ts": 1}' | Set-Content (Join-Path $sd 'locks/your-org__your-repo__pr77.lock')
  '{"pid": 1, "ts": 1, "token": "x"}' | Set-Content (Join-Path $sd 'locks/your-org__your-repo__pr77.lock.watch')   # real .watch files carry no repo
  ('{"repo": "Your-Org/Your-Repo", "pr": 78, "ts": ' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '}') | Set-Content (Join-Path $sd 'locks/your-org__your-repo__pr78.lock')
  'not json' | Set-Content (Join-Path $sd 'locks/your-org__your-repo__pr79.lock')
  $cl = 'C:\Users\User\.local\bin\claude.EXE  --model opus --effort medium  --name merge-pr-{0} "/merge-pr {0}"'
  $t = Get-MergePrTarget -CommandLine ($cl -f 77) -StateDir $sd
  Check 'review window maps to repo#PR via name + lock file' ($t -and $t.Pr -eq 77 -and $t.Repo -eq 'Your-Org/Your-Repo') "got $($t | Out-String)"
  Check 'non-review claude window is not a target' ($null -eq (Get-MergePrTarget -CommandLine 'claude.exe --model opus' -StateDir $sd))
  Check 'prompt text alone (no --name) is not a target' ($null -eq (Get-MergePrTarget -CommandLine 'claude.exe "/merge-pr 77"' -StateDir $sd))
  Check '--name merge-pr-770 does not match the pr77 lock' ($null -eq (Get-MergePrTarget -CommandLine ($cl -f 770) -StateDir $sd))
  Check 'named window with no lock file => unidentified (inject)' ($null -eq (Get-MergePrTarget -CommandLine ($cl -f 5) -StateDir $sd))
  Check 'named window with unreadable lock => unidentified (inject)' ($null -eq (Get-MergePrTarget -CommandLine ($cl -f 79) -StateDir $sd))
  Check 'NUL-delimited (Linux /proc) command line maps' ((Get-MergePrTarget -CommandLine (($cl -f 77) -replace ' ', "`0") -StateDir $sd).Pr -eq 77)
  Check 'oversized PR number => unidentified, no throw' ($null -eq (Get-MergePrTarget -CommandLine ($cl -f '999999999999999999') -StateDir $sd))
  '{"repo": "Other-Org/Your-Repo", "pr": 77, "state": "parked", "ts": 1}' | Set-Content (Join-Path $sd 'locks/other-org__your-repo__pr77.lock')
  Check 'same PR number under two repos => unidentified (inject)' ($null -eq (Get-MergePrTarget -CommandLine ($cl -f 77) -StateDir $sd))
  Remove-Item (Join-Path $sd 'locks/other-org__your-repo__pr77.lock')
  '{"repo": "your-org/your-repo", "pr": 77, "state": "parked", "ts": 1}' | Set-Content (Join-Path $sd 'locks/your-repo__your-repo__pr77.lock')
  Check 'same repo under two lock spellings is still one repo' ((Get-MergePrTarget -CommandLine ($cl -f 77) -StateDir $sd).Pr -eq 77)
  Remove-Item (Join-Path $sd 'locks/your-repo__your-repo__pr77.lock')
  Check 'null/empty command line => unidentified' (($null -eq (Get-MergePrTarget -CommandLine $null -StateDir $sd)) -and ($null -eq (Get-MergePrTarget -CommandLine '' -StateDir $sd)))

  # 10c. end-to-end against the REAL launcher, on the throwaway state dir (read-only call).
  $realLauncher = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude/skills/merge-pr/scripts/merge_pr_launcher.py'
  if ((Test-Path $realLauncher) -and $PSVersionTable.PSVersion.Major -ge 7) {
    $env:MERGE_PR_STATE_DIR = $sd
    try {
      # -TimeoutSec 30: the real launcher takes ~3 s; the default 10 s cap raced it on a busy machine.
      Check 'real launcher: parked lock => skipped' (Test-MergePrParked -Repo $repo -Pr 77 -TimeoutSec 30)
      Check 'real launcher: active lock => pinged'  (-not (Test-MergePrParked -Repo $repo -Pr 78 -TimeoutSec 30))
      Check 'real launcher: no lock => pinged'      (-not (Test-MergePrParked -Repo $repo -Pr 5 -TimeoutSec 30))
    } finally { Remove-Item Env:\MERGE_PR_STATE_DIR -ErrorAction SilentlyContinue }
  } else { Write-Host "  SKIP  real-launcher checks (launcher not found, or not PowerShell 7)" -ForegroundColor DarkYellow }

  # 10e. answered-but-still-parked (owner, 2026-10-20): a parked lock is woken only when its
  #      transcript holds an owner answer from after it parked (for a queued message: read after it): typed (or resubmitted for him by
  #      cache-keeper), an AskUserQuestion pick, or a relayed "Owner ruling for #N". Anything else
  #      written while parked (task notifications, other cross-session messages, compactions,
  #      plugin prompts, the rotator's own ping, limit errors) is not an answer.
  $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $tr = Join-Path $sd 'session.jsonl'
  function Stamp([int]$secAfterTs, [double]$ts) { [DateTimeOffset]::FromUnixTimeSeconds([long]($ts + $secAfterTs)).ToString('o') }
  function UserLine($content, [int]$sec, [double]$ts, [hashtable]$extra = @{}) {
    $o = [ordered]@{ type = 'user'; timestamp = (Stamp $sec $ts); message = @{ role = 'user'; content = $content } }
    foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
    $o | ConvertTo-Json -Compress -Depth 6
  }
  function WriteTranscript([string[]]$lines) { Set-Content -LiteralPath $tr -Value $lines -Encoding UTF8 }
  function WriteLock([string]$path, $ts, $session) {
    $o = [ordered]@{ repo = $repo; pr = 90; state = 'parked'; ts = $ts }; if ($null -ne $session) { $o.session = $session }
    ($o | ConvertTo-Json -Compress) | Set-Content $path
  }
  $lk = Join-Path $sd 'locks/your-org__your-repo__pr90.lock'
  $parkedJson = '{"status": "parked", "lock": ' + (ConvertTo-Json $lk) + '}'
  $ts0 = $nowS - 86400
  WriteLock $lk $ts0 $tr
  $noise = @(
    (UserLine '<task-notification><task-id>x</task-id><status>completed</status></task-notification>' 900 $ts0),
    (UserLine 'Another Claude session sent a message: <cross-session-message>status?</cross-session-message>' 1200 $ts0 @{ isMeta = $true }),
    (UserLine '<command-name>/compact</command-name>' 1500 $ts0),
    (UserLine 'This session is being continued from a previous conversation.' 1501 $ts0 @{ isCompactSummary = $true }),
    (UserLine @(@{ type = 'tool_result'; tool_use_id = 't'; content = 'ok' }) 1600 $ts0),
    (UserLine 'Usage reset: the session limit capped, so the CLI account was rotated to D.' 1700 $ts0),
    # Real plugin-written lines (cache-keeper / compact-early): origin says plugin, the text looks typed.
    (UserLine 'Resume' 1710 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true }; turnOrigin = 'system' }),
    (UserLine 'Try again' 1720 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true }; turnOrigin = 'system' }),
    (UserLine '/compact' 1730 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper' } }),
    (UserLine '/compact' 1735 $ts0),
    (UserLine '[Request interrupted by user for tool use]' 1740 $ts0),
    (UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: "Ship it?"="[User dismissed the question]"' }) 1750 $ts0),
    # The rotator's own ping is typed into the window, so the CLI stamps it human/typed.
    (UserLine 'Usage reset: the session limit capped, so the CLI account was rotated to D.' 1770 $ts0 @{ origin = @{ kind = 'human' }; promptSource = 'typed' }),
    (UserLine 'resume' 1775 $ts0 @{ origin = @{ kind = 'human' }; promptSource = 'typed' }),
    ('{"type":"attachment","attachment":{"type":"queued_command","prompt":"Usage reset: rotated to D.","origin":{"kind":"human"}},"timestamp":"' + (Stamp 1776 $ts0) + '"}'),
    # A plugin re-emitting an OLD AskUserQuestion answer with a fresh stamp; and a peer message that is not a ruling.
    (UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'Your questions have been answered: "Ship it?"="Yes".' }) 1780 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper' } }),
    (UserLine 'Another Claude session sent a message: <cross-session-message>Owner ruling for #91: a.</cross-session-message>' 1785 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = 'Owner ruling for #91 (given in: x): a.' } }),
    (UserLine 'I hit my usage limit while you were working, but it has reset now. Please continue.' 1786 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } }),
    (UserLine '<task-notification><task-id>y</task-id></task-notification>' 1788 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } }),
    (UserLine 'keep going' 1789 $ts0 @{ origin = @{ kind = 'auto-continuation' } }),
    (UserLine 'observer report: tests green' 1792 $ts0 @{ origin = @{ kind = 'observer' } }),
    ('{"type":"attachment","attachment":{"type":"queued_command","prompt":"observer activity","origin":{"kind":"observer-activity"}},"timestamp":"' + (Stamp 1793 $ts0) + '"}'),
    (UserLine '<command-name>/usage</command-name>' 1791 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } }),
    (UserLine 'Handoff from my previous session:

stuff' 1787 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } }),
    (UserLine 'Another Claude session sent a message: <cross-session-message>status?</cross-session-message>' 1790 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = 'status?' } }),
    ('{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>x</task-notification>","origin":{"kind":"task-notification"},"timestamp":"' + (Stamp 1760 $ts0) + '"},"timestamp":"' + (Stamp 1761 $ts0) + '"}'),
    ('{"type":"assistant","timestamp":"' + (Stamp 1800 $ts0) + '","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"limit"}]}}')
  )
  WriteTranscript $noise
  Check 'notifications, meta, compaction, tool results, rotator pings after park => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  Check 'parked + only noise since => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus $parkedJson))
  WriteTranscript (@((UserLine 'a' -60 $ts0)) + $noise)
  Check 'owner message typed BEFORE the park => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine 'a' 30 $ts0)))
  Check 'owner message typed after the park => answered' (Test-ParkedLockAnswered -LockPath $lk)
  Check 'answered parked lock => pinged' (-not (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus $parkedJson)))
  WriteTranscript ($noise + @((UserLine @(@{ type = 'text'; text = 'go with B' }) 4000 $ts0)))
  Check 'owner answer as a text block => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'Your questions have been answered: "Ship it?"="Yes". You can now continue with these answers in mind.' }) 4000 $ts0)))
  Check 'owner answer picked in AskUserQuestion => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = @(@{ type = 'text'; text = 'Your questions have been answered: "Ship it?"="No".' }) }) 4000 $ts0)))
  Check 'AskUserQuestion pick as a text-block tool_result => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<pasted_content id="c1">go with B</pasted_content>' 4000 $ts0 @{ origin = @{ kind = 'human' }; turnOrigin = 'human' })))
  Check 'owner answer pasted (opens with a tag, origin human) => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'go with B' 4000 $ts0 @{ origin = @{ kind = 'human' }; promptSource = 'typed' })))
  Check 'owner answer typed, origin human => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: "Ship it?"="Yes"' }) 4000 $ts0)))
  Check 'AskUserQuestion pick phrased "The user answered:" => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: "Ship it?"="Yes", "Also?"="[User dismissed the question]"' }) 4000 $ts0)))
  Check 'AskUserQuestion with one pick and one dismissal => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: <cross-session-message>Owner ruling for #90: a.</cross-session-message>' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = 'Owner ruling for #90 (given in: orchestrator): a.' } })))
  Check 'owner ruling relayed by deliver_ruling (meta peer line) => answered' (Test-ParkedLockAnswered -LockPath $lk)
  # cache-keeper resubmitting his held text after a /compact: often the only copy of the answer.
  WriteTranscript ($noise + @((UserLine '6529 A, router A - unpark and carry on' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true }; turnOrigin = 'system' })))
  Check 'owner answer resubmitted by cache-keeper (plugin, asUser) => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript (@((UserLine 'A' -600 $ts0 @{ origin = @{ kind = 'human' } })) + $noise + @((UserLine 'A' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'resubmitted answer repeating an earlier short answer => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<pasted_content id="2f">go with B</pasted_content>' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'pasted answer resubmitted by cache-keeper => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<cross-session-message from="x" from-name="ORCH">Owner ruling for #90 (given in: y): a.</cross-session-message>' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'relayed ruling resubmitted by cache-keeper after a compact => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine "<system-reminder>`nLinked sessions now: x`n</system-reminder>`n`n<cross-session-message from=`"x`">Owner ruling for #90: a.</cross-session-message>" 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'resubmitted ruling behind a system-reminder block => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine "<system-reminder>`nx`n</system-reminder>`n`ngo with B" 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'resubmitted owner text behind a system-reminder block => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/png'; data = 'AA==' } }) 4000 $ts0 @{ origin = @{ kind = 'human' } })))
  Check 'image-only owner answer => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<cross-session-message from="x">Owner ruling for #91: a.</cross-session-message>' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'resubmitted ruling for ANOTHER PR => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: <cross-session-message>From the orchestrator: Owner ruling for #90, his words: a.</cross-session-message>' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer' } })))
  Check 'wrapped ruling, peer origin without body => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"x","origin":{"kind":"peer","body":"Owner ruling for #90 (given in: y): a."}},"timestamp":"' + (Stamp 4000 $ts0) + '"}'))
  Check 'relayed ruling queued mid-turn (attachment line) => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"go with B","origin":{"kind":"human"},"timestamp":"' + (Stamp -5 $ts0) + '"},"timestamp":"' + (Stamp -5 $ts0) + '"}'))
  Check 'owner text stamped 5 s before the park, written after post-park lines => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"go with B","origin":{"kind":"human"},"timestamp":"' + (Stamp -600 $ts0) + '"},"timestamp":"' + (Stamp -600 $ts0) + '"}'))
  Check 'owner text stamped 10 min before the park but read after it (file order) => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"/usage","origin":{"kind":"human"},"timestamp":"' + (Stamp 4000 $ts0) + '"},"timestamp":"' + (Stamp 4000 $ts0) + '"}'))
  Check 'bare /usage typed mid-turn (queued) => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  # Read BEFORE the park (no post-park line precedes it), e.g. "park it, I'll decide tonight": not an answer.
  WriteTranscript (@('{"type":"attachment","attachment":{"type":"queued_command","prompt":"park it, I will decide tonight","origin":{"kind":"human"},"timestamp":"' + (Stamp -30 $ts0) + '"},"timestamp":"' + (Stamp -30 $ts0) + '"}') + $noise)
  Check 'owner text queued and read before the park => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"go with B","origin":{"kind":"plugin","name":"cache-keeper","asUser":true}},"timestamp":"' + (Stamp 4000 $ts0) + '"}'))
  Check 'cache-keeper resubmission queued as an attachment => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<- this one' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'resubmitted owner text that happens to start with < => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'go with B' 4000 $ts0 @{ origin = @{ kind = 'bridge' } })))
  Check 'owner text with an unknown origin kind (e.g. remote) => answered (fail-open)' (Test-ParkedLockAnswered -LockPath $lk)
  # Typed while a turn ran: stored only as a queued_command attachment. Its stamps are typing time
  # and are not compared; it counts because the user/assistant line written most recently before it
  # is post-park.
  WriteTranscript ($noise + @('{"type":"attachment","attachment":{"type":"queued_command","prompt":"go with B","origin":{"kind":"human"},"timestamp":"' + (Stamp -30 $ts0) + '"},"timestamp":"' + (Stamp 4000 $ts0) + '"}'))
  Check 'owner text queued mid-turn, after post-park lines => answered' (Test-ParkedLockAnswered -LockPath $lk)
  # A compaction after the park writes a boundary stamped now, then re-writes the retained history
  # with ORIGINAL stamps -- including a queued message read before the park. Not an answer.
  $q = '{"type":"attachment","attachment":{"type":"queued_command","prompt":"park it, I will decide tonight","origin":{"kind":"human"},"timestamp":"' + (Stamp -40 $ts0) + '"},"timestamp":"' + (Stamp -40 $ts0) + '"}'
  $pre = (UserLine @(@{ type = 'tool_result'; tool_use_id = 't0'; content = 'ok' }) -45 $ts0)
  $boundary = '{"type":"system","subtype":"compact_boundary","timestamp":"' + (Stamp 5000 $ts0) + '"}'
  WriteTranscript (@($pre, $q) + $noise + @($boundary, $q))
  Check 'pre-park queued message re-written by a later compaction => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript (@($pre, $q) + $noise + @($boundary, $pre, $q))
  Check 'same, with older history copied ahead of it => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  $summary = (UserLine 'This session is being continued from a previous conversation.' 5001 $ts0 @{ isCompactSummary = $true })
  WriteTranscript (@($pre, $q) + $noise + @($boundary, $summary, $q))
  Check 'compaction summary between the boundary and a copied queued message => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  # A PreToolUse hook line lands after the tool_result but carries the hook's earlier time; it must
  # not hide an answer queued during the park call. Same for a snapshot update's nested older stamp.
  $parkUse = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p","name":"Bash"}]},"timestamp":"' + (Stamp -5 $ts0) + '"}'
  $parkRes = (UserLine @(@{ type = 'tool_result'; tool_use_id = 'p'; content = 'parked' }) 2 $ts0)
  $hook = '{"type":"attachment","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash"},"timestamp":"' + (Stamp -4 $ts0) + '"}'
  $snap = '{"type":"file-history-snapshot","isSnapshotUpdate":true,"snapshot":{"trackedFileBackups":{},"timestamp":"' + (Stamp -60 $ts0) + '"}}'
  $ans = '{"type":"attachment","attachment":{"type":"queued_command","prompt":"go with B","origin":{"kind":"human"},"timestamp":"' + (Stamp -1 $ts0) + '"},"timestamp":"' + (Stamp -1 $ts0) + '"}'
  WriteTranscript @($parkUse, $parkRes, $hook, $ans)
  Check 'answer queued during the park call, behind a PreToolUse hook line => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript @($parkUse, $parkRes, $snap, $ans)
  Check 'same, behind a file-history snapshot update => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: <cross-session-message>Owner ruling for #6413 is merged; Owner ruling for #90: a.</cross-session-message>' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer' } })))
  Check 'relay naming another PR first, then this one => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: Owner ruling for #99999999999999999999: x' 3990 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer' } }), (UserLine 'go with B' 4000 $ts0 @{ origin = @{ kind = 'human' } })))
  Check 'an oversized ruling number for another PR is not this one, and the scan carries on => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'Your claude.ai usage limit has reset. Continue the task you were working on when the limit was reached.' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'CLI usage-reset continuation resubmitted by cache-keeper => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: "Ship it?"="Usage reset: the 5-hour limit capped this window"' }) 4000 $ts0)))
  Check 'rotator ping typed into an open AskUserQuestion => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'Your questions have been answered: "Ship it?"="[User dismissed the question]"' }) 4000 $ts0)))
  Check 'every question dismissed => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'Your questions have been answered: "Ship it?"="resume", "Also?"="Yes"' }) 4000 $ts0)))
  Check 'a ping beside a real pick => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: "Ship it?"="[User did not answer this question - they sent a message instead. Treat that message as their response; do not re-ask.]"' }) 4000 $ts0)))
  Check 'a message sent instead of a pick => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine @(@{ type = 'tool_result'; tool_use_id = 'q'; content = 'The user answered: [fast-jev-compaction truncated 1641 chars of this tool result]' }) 4000 $ts0)))
  Check 'a truncated result with no parsable pick => answered (fail-open)' (Test-ParkedLockAnswered -LockPath $lk)
  # Real relays reword the phrase itself.
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: <cross-session-message>Flight coordinator here, with an owner ruling for #90, his words: a.</cross-session-message>' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer' } })))
  Check 'relay worded "an owner ruling for #N" => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine 'Another Claude session sent a message: <cross-session-message>Flight coordinator: OWNER RULING on #90, his words exactly: a.</cross-session-message>' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer' } })))
  Check 'relay worded "OWNER RULING on #N" => answered' (Test-ParkedLockAnswered -LockPath $lk)
  # The desktop app's own continuation lands with no origin at all.
  WriteTranscript ($noise + @((UserLine 'I hit my usage limit while you were working, but it has reset now. Please continue.' 4000 $ts0 @{ promptSource = 'sdk' })))
  Check 'app usage-limit continuation with no origin => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  WriteTranscript ($noise + @((UserLine "<command-message>usage</command-message>`n<command-name>/usage</command-name>`n<command-args></command-args>" 4000 $ts0)))
  Check 'a slash command he typed to check quota (CLI: no origin) => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  # The desktop app stamps cache-keeper's immediate commands human (seen: /keepwarm while a question waited).
  foreach ($c in 'keepwarm', 'board', 'cache-keeper:keepwarm') {
    WriteTranscript ($noise + @((UserLine "<command-message>$c</command-message>`n<command-name>/$c</command-name>`n<command-args></command-args>" 4000 $ts0 @{ origin = @{ kind = 'human' } })))
    Check "cache-keeper housekeeping command /$c stamped human => still parked" (-not (Test-ParkedLockAnswered -LockPath $lk))
  }
  # Real free-text relays of his answer (no "owner ruling" phrase).
  foreach ($body in @(
      'The owner answered your parked question on PR #90. His words, verbatim: "90 A".',
      '#90 has the owner''s answers to your parked question, so you can resume now.',
      '#90 has the owner''s approval ("A", in the orchestrator session just now).',
      'PR #90: the owner OKed the look. His words: "looks good".',
      # Real shapes (#4682, #6609, #5988, #6534) that a whole-message veto threw away.
      '#90: the owner said "90 yes". I''ll relay anything further he adds.',
      'Owner ruling on the disc rule for #90. His words, verbatim: "Drop 175 as recommended." The other question is still open.',
      'A further owner ruling for the #90 question: a.',
      ('#90 decision. His words (2026-11-03): "re open 90".' + "`n" + 'The other item waits until he answers.'),
      # #5985 / #5397 shape: the PR is named in the sentence before his words, and another PR is named too.
      '#90 is pushed. The owner waives your Gate E for #90. His words, verbatim: "A. Create the marker." #91 is unaffected.',
      'Owner instruction for #90 (you now own it). His words: "keep 90 but cherry pick from 91."',
      # Punctuation inside the closing quote/bracket still ends the sentence, so the next one's veto stays there.
      'For #90, his words, verbatim: "A." The other question is still open.',
      '#90: he answered "A." I will relay anything further.',
      'The owner answered #90 (verbatim: "A, keep it.") Q2 stays parked.',
      # One PR named: the answer may sit several sentences after it (pins the single-PR rule).
      'Review of #90 resumed. Head is abc123. CI is green. His words, verbatim: "A".',
      # Only the "owner ruling for the #N" form can carry this one (the free-text sentence is vetoed).
      'Owner ruling for the #90 question, and I''ll relay anything further.',
      # The PR named without "#": in a link, or as the first word of his quoted reply.
      'Relayed from the orchestrator about #91''s sibling. He answered "90 copy: A".',
      'Answers are at https://github.com/o/r/pull/90#issuecomment-1. His words: "A".',
      # e.g. and a blank line after a heading do not cut the PR off from the answer.
      ('Re #91: merged. For #90, e.g. the v2 question. His answer: A.'),
      # A bold label line between the PR heading and the answer (#6481's real shape).
      ("**#90**`n- **Design approval.** The owner gave it today, in his words: `"Design approved`".`n**#91** is unaffected."),
      # A bold line that is itself the answer still counts.
      ("Re #90.`n**The owner approved.**`nProceed to merge."),
      # His quoted reply names the PR after each lead-in the relays use.
      'Relayed about #91''s sibling. The owner said "90 copy: A".',
      'Relayed about #91''s sibling. His answer, verbatim: "90 approve".',
      'Relayed about #91''s sibling. The owner typed "90 B".',
      'Relayed about #91''s sibling. He replied "90 A".',
      'Relayed about #91''s sibling. He chose "90 B".',
      '#90: he chose option B.',
      '#90: he chose option b.',
      # A release with no disclaimer and no PR, and #6468's real "release the park" wording.
      'resume (second notice). Your disk-space park is cleared. Continue the review.',
      'From the orchestrator (not an owner ruling): your parked question isn''t an owner question, so fix both gaps and carry on. Release the park through your own lock as usual.',
      # Other numbers in the answer sentence are not other PRs: options, #1, an issue, a PR in his quote.
      'Relay for #90. His words: "1 B, 2 replace".',
      '#90: two questions. On question #1 he answered A.',
      'Relay for your parked question on #90. His words, verbatim: "approve", recorded on issue #5079.',
      'Gate E for #90. His words: "approve, and fold #6400 in too".',
      # Real park releases (#6091/#6093): named by --pr N, or by nothing at all.
      'resume. From the orchestrator: C: now has about 39 GB free (it was 0 when you parked), so the blocker you parked on is cleared. This isn''t an owner ruling, because a disk-space block is agent work. Unpark your own lock with `--unpark --pr 90` and carry on with the review.',
      'resume (second notice from the orchestrator). C: has about 39 GB free now, so your disk-space park is cleared. Unpark your own lock with `--unpark --pr 90` and continue the review.',
      'Status note from the succah close-out orchestrator (not an owner ruling): your park condition has cleared. C: now has 39 GB free. Your question asked for disk to be freed and then "resume", so resume the review.',
      'Re #91. He answered with the words "90 approve".',
      'Relayed about #91''s sibling. For #90 he chose "+1".',
      '#90: his answer is A; approval no longer pending.',
      '#90: his answer is A; no more decision needed.',
      # Any quoted reply after typed/replied counts, word character or not.
      'Relayed about #91''s sibling. He replied "+1" to #90.',
      'Relayed about #91''s sibling. For #90 he typed "**A**".',
      # Saying nothing more is pending is not a hold.
      '#90: his answer is A, so no further decision needed.',
      '#90 is not awaiting the owner any more: his answer is "approve".',
      # A curly-quoted option list about ANOTHER PR does not un-name this one.
      ('#90: the owner answered A. #91: he has not chosen between ' + [char]0x201C + 'keep' + [char]0x201D + ' or ' + [char]0x201C + 'drop' + [char]0x201D + ' yet.'),
      'Relayed about #91''s sibling. He typed "90 approve".',
      'Relayed about #91''s sibling. The owner replied "90: yes".',
      # Every closer after the terminator ends the sentence: bold, curly quote, single quote.
      '#90: he answered **"A."** The other question is still open.',
      ('#90: he answered ' + [char]0x201C + 'A.' + [char]0x201D + ' The other question is still open.'),
      "#90: he answered 'A.' The other question is still open.",
      # "#090" is this PR, not another one.
      'Review of #90 resumed (also written #090). CI green. Head ok. His words: "A".',
      # Curly quotes, as the desktop app types them.
      ("Relayed about #91's sibling too. His words: " + [char]0x201C + '90 copy: A' + [char]0x201D + '.'),
      ("Re #91: merged.`nFor #90:`n`nHis words: A."),
      # An orchestrator releasing the park counts on purpose: waking the window is what it asks for.
      'Status note (not an owner ruling): your park condition has cleared. Resume the review of #90.')) {
    WriteTranscript ($noise + @((UserLine "Another Claude session sent a message: <cross-session-message>$body</cross-session-message>" 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = $body } })))
    Check "free-text relay of his answer => answered: $body" (Test-ParkedLockAnswered -LockPath $lk)
  }
  WriteTranscript ($noise + @((UserLine 'x' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = 'The owner answered on PR #901: go.' } })))
  Check 'free-text relay naming another PR (#901, not #90) => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  # Real orchestrator acknowledgements of a park (#5992, #5978, #4381): not answers.
  foreach ($body in @(
      'Agreed, #90 stays parked. I''m putting your exact question to the owner now and will relay his words and the time the moment he answers. Nothing else needed from you meanwhile.',
      'One owner question on #90 is still open. Please don''t merge past it without his answer.',
      'Stay parked on #90 1-4 until then; I''ll relay his answer to you verbatim.',
      'Keep #90 in draft. I''ll send you his answer word for word when he gives it. You can go idle.',
      '#90 is waiting on the owner''s approval.',
      'Give me #90''s question so I can put it to the owner. If the owner has already answered it in your window, say so and give his words.',
      # Real broadcast shapes: another PR's answer, a request, a hold (#4904, #6468, #6585, #5986).
      '#91 has the owner''s approval ("A"). Once it''s on main, re-run #90''s halacha-check.',
      'Here is the #90 question. Please carry it to him; his answer must be given in session.',
      'Do NOT merge #90 until I tell you. The fix is waiting on the owner''s approval.',
      'Brief for the #90 review. Cherry-pick the fix and push only when no Test run is going. Owner ruling D (undo) is #92 and stays out.',
      # Reject twin of the single-PR test: another PR named, answer far from #90.
      'Review of #90 resumed. #91 is merged. CI is green. His words, verbatim: "A".',
      # The other PR named only by its link still makes this a multi-PR message.
      'Review of #90 resumed. See https://github.com/o/r/pull/91 for CI. Head is green. His words, verbatim: "A".',
      # #6481/#6471's real shape, seen from #6471 (#90): the answer sits under another PR's bold heading.
      ("Reply from the #91/#90 session: #91 needs nothing, and #90 waits for #91.`n`n**#91**`n- **Design approval.** The owner gave it today, in his words: `"Design approved`".`n`n**#90**`n- I'm holding it."),
      # A quoted list of reply options is not his reply, verbatim or not.
      'Re #91. Ask him to reply verbatim "90 A" or "90 B". His answer comes through me.',
      'Re #91. I put your question to him verbatim: "90: keep the guard?" His answer is pending.',
      # "typed"/"replied" with no quoted reply is narrative, not an answer.
      '#90: the owner typed nothing yet.',
      '#90: he replied that he needs more time.',
      '#90 review. He chose this because the last brief misread the work.',
      '#90 brief: last round he chose a narrower fix, so keep the scope tight.',
      # Another PR's release is not this one's.
      'From the orchestrator: your disk-space park is cleared. Unpark your own lock with `--unpark --pr 91`.',
      # An answer quoted for another PR does not make this a one-PR message.
      '#90 is pushed. His words "91 A".',
      # Third-person and plain-English holds.
      '#90 awaits the owner''s decision.',
      'No owner answer yet on #90.',
      'Hold #90: the owner''s approval has not come through.',
      '#90 is blocked on the owner''s decision.',
      'I will forward his answer on #90 once he gives it.',
      '#90: his decision is due tonight.',
      '#90: I will pass it on.',
      # Release wording negated, asked, or conditional; and a no-PR message judged only on its release.
      'Do NOT unpark your own lock yet: the owner has not answered.',
      'Is your park condition cleared? Reply with one line.',
      'Waiting on his answer. Unpark your own lock after he answers.',
      # Each prompt guard on its own: an option list after a lead-in, and a bare "verbatim"/"words".
      'Re #91. Offer him two replies, in his words "90 A" or "90 B". His answer comes through me.',
      'Re #91. Tell him to reply verbatim "90 approve". His answer comes through me.',
      'Re #91. Ask him for the exact words "90 approve". His answer comes through me.',
      # Awaiting / pending / needed (#5375's real wording), bold or not.
      '#90 copy is still awaiting the owner''s approval, so please don''t treat a push as the trigger.',
      ("**#90**`n- **Awaiting owner approval.**"),
      ("#90 status:`n**Owner decision needed.**"),
      ("#90 status:`n**His answer: pending.**"),
      # A prompt quoting the reply format is not his reply.
      'Re #91. To answer, he types "90 A" or "90 B". His answer comes through me.',
      # The sender's name holding the ruling phrase is not a ruling.
      '<cross-session-message from="x" from-name="Owner ruling for #90 relay">Status: CI green on #91.',
      # The sender's name mentioning the PR is not a mention.
      '<cross-session-message from="x" from-name="Answer page PRs #90/#91">Status: CI green on #91. His words: "A".')) {
    WriteTranscript ($noise + @((UserLine 'x' 4000 $ts0 @{ isMeta = $true; origin = @{ kind = 'peer'; body = $body } })))
    Check "orchestrator park acknowledgement => still parked: $body" (-not (Test-ParkedLockAnswered -LockPath $lk))
  }
  WriteTranscript ($noise + @((UserLine "<command-message>merge-pr</command-message>`n<command-name>/merge-pr</command-name>`n<command-args>90 resume</command-args>" 4000 $ts0 @{ origin = @{ kind = 'human' } })))
  Check 'owner typed /merge-pr 90 resume => answered' (Test-ParkedLockAnswered -LockPath $lk)
  WriteTranscript ($noise + @((UserLine '<ci-monitor-event>"Auto-fix pushed"</ci-monitor-event>' 4000 $ts0 @{ origin = @{ kind = 'plugin'; name = 'cache-keeper'; asUser = $true } })))
  Check 'ci-monitor-event resubmitted by cache-keeper => still parked' (-not (Test-ParkedLockAnswered -LockPath $lk))
  # The timestamp must not round-trip through the current culture: on en-GB a day-first re-parse
  # swapped month and day (or threw on a day above 12, abandoning the scan).
  $cult = [cultureinfo]::CurrentCulture
  foreach ($cn in 'en-GB', 'he-IL', 'de-DE') {
    try {
      [cultureinfo]::CurrentCulture = [cultureinfo]::new($cn)
      WriteTranscript ($noise + @((UserLine 'a' 30 $ts0)))
      $ok1 = Test-ParkedLockAnswered -LockPath $lk
      WriteTranscript (@((UserLine 'a' -30 $ts0)) + $noise)
      $ok2 = -not (Test-ParkedLockAnswered -LockPath $lk)
    } finally { [cultureinfo]::CurrentCulture = $cult }
    Check "culture ${cn}: answer after the park found, answer before it not" ($ok1 -and $ok2)
  }
  WriteTranscript ($noise + @((UserLine 'a' 30 $ts0)))
  ([ordered]@{ repo = $repo; pr = 90; state = 'parked'; ts = $ts0 + 3600; parked_at = $ts0; session = $tr } | ConvertTo-Json -Compress) | Set-Content $lk
  Check 'heartbeat re-stamped ts after the answer => parked_at still finds it' (Test-ParkedLockAnswered -LockPath $lk)
  WriteLock $lk $ts0 $null
  Check 'lock without session => no evidence => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus $parkedJson))
  WriteLock $lk $ts0 (Join-Path $sd 'gone.jsonl')
  Check 'transcript missing => no evidence => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus $parkedJson))
  'not json' | Set-Content $lk
  Check 'unreadable lock => no evidence => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus $parkedJson))
  Check 'no lock path in status JSON => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -Invoke (FakeStatus '{"status": "parked"}'))
  # end to end through the REAL launcher (it reports the lock path itself)
  if ((Test-Path $realLauncher) -and $PSVersionTable.PSVersion.Major -ge 7) {
    WriteLock $lk $ts0 $tr; WriteTranscript ($noise + @((UserLine 'a' 30 $ts0)))
    $env:MERGE_PR_STATE_DIR = $sd
    try {
      Check 'real launcher: parked + answered => pinged' (-not (Test-MergePrParked -Repo $repo -Pr 90 -TimeoutSec 30))
      WriteTranscript $noise
      Check 'real launcher: parked + not answered => skipped' (Test-MergePrParked -Repo $repo -Pr 90 -TimeoutSec 30)
    } finally { Remove-Item Env:\MERGE_PR_STATE_DIR -ErrorAction SilentlyContinue }
  }

  # 10d. timeout: a launcher that hangs must fail open within the cap, not hang the ping.
  $slow = Join-Path $sd 'slow.py'; "import time; time.sleep(30)" | Set-Content $slow
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Test-MergePrParked -Repo $repo -Pr 1 -Launcher $slow -TimeoutSec 2
  $sw.Stop()
  Check 'hung launcher => pinged, within the timeout cap' ((-not $r) -and $sw.Elapsed.TotalSeconds -lt 8) "took $([int]$sw.Elapsed.TotalSeconds)s"
} finally { Remove-Item -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue }

# 11. the summary counts skipped separately from pinged/failed (wiring present in both scripts).
$resSrc = Get-Content (Join-Path (Split-Path -Parent $PSCommandPath) 'claude-resume-sessions.ps1') -Raw
Check 'resume script emits the line Ping-ActiveSessions counts' ($resSrc -match 'Skipped parked review \$\(\$mp\.Repo\)#') 'wording drifted between the two scripts'
Check 'Ping-ActiveSessions counts skipped separately' (($src -match 'Skipped parked review') -and ($src -match 'skipped \$\(\$skipLines\.Count\) parked')) 'summary does not report skipped'

Write-Host ""
if ($fail) { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "all checks passed" -ForegroundColor Green
