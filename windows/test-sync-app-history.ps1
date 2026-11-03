<#
  test-sync-app-history.ps1 -- scenario test for sync-app-history.ps1's archive, pin and sidebar-group sync.
  Copies the LIVE app session index and claude_desktop_config.json into a fresh sandbox under C:\Dev\Temp,
  runs the sync there with %APPDATA% / %USERPROFILE% redirected, and checks each scenario. The real files
  are only read. Exit 1 on any failure. Each sync run takes ~1-2 min on a full index.
    pwsh -File test-sync-app-history.ps1 [-Script <path to sync-app-history.ps1>]
#>
param([string]$Script = (Join-Path $PSScriptRoot 'sync-app-history.ps1'))
$sb = "C:\Dev\Temp\sync-app-history-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory "$sb\app\Claude", "$sb\home\.claude\projects\C--Dev-hameishiv", "$sb\home\.claude-app-seats" -Force | Out-Null
Copy-Item "$env:APPDATA\Claude\claude-code-sessions" "$sb\app\Claude\" -Recurse -Force
Copy-Item "$env:APPDATA\Claude\claude_desktop_config.json" "$sb\app\Claude\" -Force
Set-Content "$sb\home\.claude\projects\C--Dev-hameishiv\dummy.jsonl" '{"type":"user","message":{"content":"hi"}}'
"sandbox: $sb"
$ccs = "$sb\app\Claude\claude-code-sessions"; $cfgP = "$sb\app\Claude\claude_desktop_config.json"
$fail = 0
function run { pwsh -NoProfile -Command "`$env:APPDATA='$sb\app'; `$env:USERPROFILE='$sb\home'; & '$Script' -NoPrune" 2>&1 | Where-Object { "$_" -match 'sidebar|isArchived|isStarred|rror|xception' } | ForEach-Object { "    $_" } }
function cfg { Get-Content $cfgP -Raw | ConvertFrom-Json -AsHashtable }
function savecfg($c) { Set-Content $cfgP ($c | ConvertTo-Json -Depth 100) -NoNewline }
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function recs { Get-ChildItem $ccs -Recurse -Filter local_*.json | ForEach-Object { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; [pscustomobject]@{ f = $_.FullName; id = $j.sessionId; cli = [string]$j.cliSessionId; star = [bool]$j.isStarred; scope = "$($_.Directory.Parent.Name)/$($_.Directory.Name)" } } | Where-Object cli }
function setRec($f, $k, $v) { $j = Get-Content $f -Raw | ConvertFrom-Json; $j | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force; Set-Content $f ($j | ConvertTo-Json -Compress -Depth 100) -NoNewline }
$before = cfg
$scopes = @(Get-ChildItem $ccs -Directory | ForEach-Object { $a = $_; Get-ChildItem $a.FullName -Directory | Where-Object { Get-ChildItem $_.FullName -Filter local_*.json } | ForEach-Object { "$($a.Name)/$($_.Name)" } })

"--- run 1 (baseline)"; run
$c = cfg; $e = $c.preferences.epitaxyPrefs; $R = recs
$gid = 'cg-a35dec0d-f360-498b-b8d2-1be3a703f711'
check 'every seat has the Zmanim group' (@($scopes | Where-Object { @($e['dframe-group-scopes'][$_]['groups'] | Where-Object { $_['id'] -eq $gid }).Count -eq 1 }).Count -eq $scopes.Count)
check 'every seat has a Zmanim section' (@($scopes | Where-Object { @($e['dframe-code-sections'][$_]['sections'] | Where-Object { $_['id'] -eq $gid }).Count -eq 1 }).Count -eq $scopes.Count)
$zCli = @(); foreach ($k in $before.preferences.epitaxyPrefs['dframe-group-scopes'].Values | ForEach-Object { $_['assignments'].Keys }) { $id = $k -replace '^code:', ''; $zCli += ($R | Where-Object id -eq $id).cli }
$zCli = @($zCli | Where-Object { $_ } | Select-Object -Unique)
$expect = @($R | Where-Object { $zCli -contains $_.cli }).Count
$got = @($scopes | ForEach-Object { $e['dframe-group-scopes'][$_]['assignments'].Keys }).Count
check "all seats' records of the $($zCli.Count) Zmanim sessions are assigned ($got of $expect)" ($got -eq $expect)
$starIds = @($R | Where-Object star | ForEach-Object id)
check 'pin list holds every starred record id' (@($starIds | Where-Object { $e['starred-local-code-sessions'] -notcontains $_ }).Count -eq 0)
check 'every record of a starred session is starred' (@($R | Group-Object cli | Where-Object { ($_.Group.star -contains $true) -and ($_.Group.star -contains $false) }).Count -eq 0)
$skip = 'starred-local-code-sessions', 'dframe-local-slice', 'dframe-group-scopes', 'dframe-code-sections'
$o1 = $before.preferences.epitaxyPrefs; $o2 = $e
check 'other epitaxyPrefs keys untouched' (@($o1.Keys | Where-Object { $skip -notcontains $_ -and (($o1[$_] | ConvertTo-Json -Depth 50 -Compress) -ne ($o2[$_] | ConvertTo-Json -Depth 50 -Compress)) }).Count -eq 0)
$b2 = $before.Clone(); $b2.Remove('preferences'); $c2 = $c.Clone(); $c2.Remove('preferences')
check 'rest of config untouched' (($b2 | ConvertTo-Json -Depth 100 -Compress) -eq ($c2 | ConvertTo-Json -Depth 100 -Compress))

"--- run 2 (idle)"; $s = Get-Content $cfgP -Raw; $out = run; $out
check 'idle run changes nothing' ((Get-Content $cfgP -Raw) -eq $s -and -not ($out -match 'updated|set '))

# pick a multi-seat session for pin tests
$G = recs | Group-Object cli | Where-Object { $_.Count -ge 4 -and -not ($_.Group.star -contains $true) } | Select-Object -First 1
"--- pin one session on one seat ($($G.Count) seats)"
$r0 = $G.Group[0]; setRec $r0.f 'isStarred' $true; $c = cfg; $c.preferences.epitaxyPrefs['starred-local-code-sessions'] += $r0.id; savecfg $c
run
$L = (cfg).preferences.epitaxyPrefs['starred-local-code-sessions']
check 'pinned on every seat (records)' (@(recs | Where-Object { $_.cli -eq $G.Name -and -not $_.star }).Count -eq 0)
check 'pin list has every seat''s id' (@($G.Group | Where-Object { $L -notcontains $_.id }).Count -eq 0)

"--- unpin it on a different seat"
$r1 = $G.Group[2]; setRec $r1.f 'isStarred' $false; $c = cfg; $c.preferences.epitaxyPrefs['starred-local-code-sessions'] = @($c.preferences.epitaxyPrefs['starred-local-code-sessions'] | Where-Object { $_ -ne $r1.id }); savecfg $c
run
$L = (cfg).preferences.epitaxyPrefs['starred-local-code-sessions']
check 'unpinned on every seat (records)' (@(recs | Where-Object { $_.cli -eq $G.Name -and $_.star }).Count -eq 0)
check 'no id of it left in pin list' (@($G.Group | Where-Object { $L -contains $_.id }).Count -eq 0)

"--- add it to Zmanim on one seat"
$c = cfg; $a = $c.preferences.epitaxyPrefs['dframe-group-scopes'][$r1.scope]['assignments']; $a["code:$($r1.id)"] = $gid; savecfg $c
run
$gs = (cfg).preferences.epitaxyPrefs['dframe-group-scopes']
check 'in Zmanim on every seat' (@($G.Group | Where-Object { $gs[$_.scope]['assignments']["code:$($_.id)"] -ne $gid }).Count -eq 0)

"--- remove it from Zmanim on another seat"
$c = cfg; $c.preferences.epitaxyPrefs['dframe-group-scopes'][$r0.scope]['assignments'].Remove("code:$($r0.id)"); savecfg $c
run
$gs = (cfg).preferences.epitaxyPrefs['dframe-group-scopes']
check 'out of Zmanim on every seat' (@($G.Group | Where-Object { $gs[$_.scope]['assignments'].Contains("code:$($_.id)") }).Count -eq 0)

"--- rename Zmanim on one seat"
$c = cfg; ($c.preferences.epitaxyPrefs['dframe-group-scopes'][$r0.scope]['groups'] | Where-Object { $_['id'] -eq $gid })['name'] = 'Zmanim2'; savecfg $c
run
$e = (cfg).preferences.epitaxyPrefs
check 'renamed on every seat (groups)' (@($scopes | Where-Object { ($e['dframe-group-scopes'][$_]['groups'] | Where-Object { $_['id'] -eq $gid })['name'] -ne 'Zmanim2' }).Count -eq 0)
check 'renamed on every seat (sections)' (@($scopes | Where-Object { ($e['dframe-code-sections'][$_]['sections'] | Where-Object { $_['id'] -eq $gid })['name'] -ne 'Zmanim2' }).Count -eq 0)

"--- remove the Zmanim section on one seat, add a foreign key to its group entry"
$c = cfg; $sc = $c.preferences.epitaxyPrefs['dframe-code-sections'][$r0.scope]; $sc['sections'] = @($sc['sections'] | Where-Object { $_['id'] -ne $gid }); $c.preferences.epitaxyPrefs['dframe-group-scopes'][$r0.scope]['probeKey'] = 'keep-me'; savecfg $c
run
$e = (cfg).preferences.epitaxyPrefs
check 'section restored on that seat' (@($e['dframe-code-sections'][$r0.scope]['sections'] | Where-Object { $_['id'] -eq $gid }).Count -eq 1)
check 'foreign key kept' ($e['dframe-group-scopes'][$r0.scope]['probeKey'] -eq 'keep-me')
"--- idle again"; $s = Get-Content $cfgP -Raw; $out = run; $out
check 'second idle run changes nothing' ((Get-Content $cfgP -Raw) -eq $s -and -not ($out -match 'updated|set '))

"--- delete Zmanim on one seat"
$c = cfg; $sc = $c.preferences.epitaxyPrefs['dframe-group-scopes'][$r1.scope]; $sc['groups'] = @($sc['groups'] | Where-Object { $_['id'] -ne $gid }); savecfg $c
run
$e = (cfg).preferences.epitaxyPrefs
check 'group gone on every seat' (@($scopes | Where-Object { @($e['dframe-group-scopes'][$_]['groups'] | Where-Object { $_['id'] -eq $gid }).Count }).Count -eq 0)
check 'its section gone on every seat' (@($scopes | Where-Object { @($e['dframe-code-sections'][$_]['sections'] | Where-Object { $_['id'] -eq $gid }).Count }).Count -eq 0)
check 'no assignment to it anywhere' (@($scopes | ForEach-Object { $e['dframe-group-scopes'][$_]['assignments'].Values } | Where-Object { $_ -eq $gid }).Count -eq 0)

"$fail failure(s)"; exit [int]($fail -gt 0)


