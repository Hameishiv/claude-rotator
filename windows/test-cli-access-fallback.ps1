<#
test-cli-access-fallback.ps1 — mocked regression tests for subscription-disabled 403.

No live API calls. Seat letters are not reserved: A is eligible unless the desktop app's
current identity is A, or A's own probe was an explicit 403. .inactive is not a candidate.
No real machine state either: Set-UserEnvFast (HKCU:\Environment + the WM_SETTINGCHANGE broadcast)
and Ping-ActiveSessions (prompt injection into running sessions) are mocked, the run aborts before
any rotation if either mock is not the live definition, and the process environment is restored.

  pwsh -NoProfile -File windows/test-cli-access-fallback.ps1
#>
$ErrorActionPreference = 'Stop'
try { (Get-Process -Id $PID).PriorityClass = 'Idle' } catch {}      # first: every child below inherits Idle
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

$envKeep = @{}
foreach ($n in 'USERPROFILE','APPDATA','CLAUDE_ROTATOR_SELFTEST','CLAUDE_ROTATOR_SKIP_APP_SYNC','CLAUDE_CODE_OAUTH_TOKEN') {
  $envKeep[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
}
$root = Join-Path ([IO.Path]::GetTempPath()) ("cli-access-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
$env:USERPROFILE = $root
$env:APPDATA = Join-Path $root 'AppData'
$env:CLAUDE_ROTATOR_SELFTEST = '1'
$env:CLAUDE_ROTATOR_SKIP_APP_SYNC = '1'
New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
$script:probes = @{}
$global:ClaudeRotatorProbeOverride = {
  param($Label, $Model)
  if (-not $script:probes.ContainsKey($Label)) { $script:probes[$Label] = 0 }
  if ($Model -eq 'haiku') { $script:probes[$Label]++ }
  $plan = $script:plan[$Label]
  if (-not $plan) { $plan = 'ok' }
  if ($Model -eq 'fable' -and $plan -notin @('network','http401')) {     # a seat the network or its token fails fails both probes, as Probe-Usage does
    if ($plan -in @('fable-500','both-500','live-default+fable-500')) {     # Probe-Usage's ok=$true for a non-2xx with no usage headers
      return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=500; note='http 500: api_error: Overloaded' }
    }
    if ($plan -eq 'fable-2xx-bare') {     # a 2xx that carries the session headers but no 7d_oi window
      return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=200; status='allowed'; s5_util=0.1; note='' }
    }
    if ($plan -eq 'default-500+live-fable') {     # a live Fable rejection beside a headerless default probe
      return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; oi7_util=1.0; oi7_stat='rejected'; note='' }
    }
    if ($plan -like 'fable-only:*') {     # a non-2xx carrying exactly one oi7 field
      $r = [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; note='' }
      $f = $plan.Split(':')[1]; $r | Add-Member -NotePropertyName $f -NotePropertyValue $(if ($f -eq 'oi7_util') { 0.1 } else { 'allowed' })
      return $r
    }
    if ($plan -eq 'fable-429-fields') {     # a non-2xx that still carries the oi7 window
      return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; oi7_util=0.1; oi7_stat='allowed'; note='' }
    }
    if ($plan -eq 'fable-net') {     # the Fable probe alone fails on the network; the haiku one reads normally
      return [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; net=$true; note='probe failed: network; not marking disabled' }
    }
    if ($plan -eq 'fable-disabled') {
      return [pscustomobject]@{ label=$Label; ok=$false; access='disabled'; http=403; code='oauth_org_not_allowed'; note='subscription disabled (403 oauth_org_not_allowed)' }
    }
    if ($plan -eq 'fable-overlap') {
      Start-Sleep -Milliseconds 1100   # give the proxy write a later epoch second than the start of this probe
      $proxyAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      @{ ts = $proxyAt; data = @{ ok = $true; src = 'proxy'; oi7_stat = 'rejected'; oi7_reset = $proxyAt + 3600 } } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root $Label) 'usage-cache.json') -Encoding UTF8
    }
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=200; oi7_util=0.1; oi7_stat='allowed'; note='' }
  }
  if ($plan -eq 'disabled') {
    return [pscustomobject]@{
      label=$Label; ok=$false; access='disabled'; http=403; code='oauth_org_not_allowed'
      note='subscription disabled (403 oauth_org_not_allowed)'; tokfp=(Get-TokenFingerprint (TokenOf $Label))     # as Probe-Usage: the token it sent
    }
  }
  if ($plan -eq 'network') {
    return [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; net=$true; note='probe failed: network; not marking disabled' }
  }
  if ($plan -eq 'http401') {     # Probe-Usage's result for a dead token: an HTTP failure, not a network one
    return [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; net=$false; note='probe failed: http 401: authentication_error: invalid token; not marking disabled' }
  }
  if ($plan -like 'default-only:*') {     # a non-2xx carrying exactly one session/weekly field
    $r = [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; note='' }
    $f = $plan.Split(':')[1]; $r | Add-Member -NotePropertyName $f -NotePropertyValue $(if ($f -like '*_util') { 0.1 } else { 'allowed' })
    return $r
  }
  if ($plan -in @('default-rejected-bare','live-default+fable-500')) {     # a live cap whose reading carries no utilisation
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; status='rejected'; note='' }
  }
  if ($plan -eq 'default-2xx-bare') {     # a 2xx that carries no usage headers at all
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=200; note='' }
  }
  if ($plan -eq 'default-429-fields') {     # a non-2xx that still carries the session/weekly window
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=429; status='allowed'; s5_util=0.1; w7_util=0.2; s5_stat='allowed'; w7_stat='allowed'; note='' }
  }
  if ($plan -in @('default-500','both-500','default-500+live-fable')) {     # Probe-Usage's ok=$true for a non-2xx default-model probe with no usage headers
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=500; note='http 500: api_error: Overloaded' }
  }
  if ($plan -eq 'quota') {
    return [pscustomobject]@{
      label=$Label; ok=$true; access='ok'; http=429; note=''
      s5_util=1.0; w7_util=0.2; s5_stat='rejected'; w7_stat='allowed'; status='rejected'; w7_reset=100
    }
  }
  $s5 = [double]$script:head[$Label]
  [pscustomobject]@{
    label=$Label; ok=$true; access='ok'; http=200; note=''
    s5_util=$s5; w7_util=0.2; s5_stat='allowed'; w7_stat='allowed'; status='allowed'; w7_reset=(1000 + [int][char]$Label)
  }
}

. (Join-Path $PSScriptRoot 'claude-cli-account.ps1')

# The rotation under test would write fake tokens into HKCU:\Environment, broadcast them, and type a
# continuation prompt into running sessions. These two replace the functions that do it.
$script:envWrites = @(); $script:pings = @()
function Set-UserEnvFast { param([string]$Name, [string]$Value) <# MOCK-NO-MACHINE-STATE #> $script:envWrites += ,@($Name, $Value) }
function Ping-ActiveSessions { param([string]$Message) <# MOCK-NO-MACHINE-STATE #> $script:pings += $Message }
foreach ($fn in 'Set-UserEnvFast','Ping-ActiveSessions') {
  if ((Get-Command $fn -CommandType Function).Definition -notmatch 'MOCK-NO-MACHINE-STATE') {
    Write-Host "ABORT: $fn is not the mock; refusing to run rotations that would touch HKCU or running sessions" -ForegroundColor Red
    exit 2
  }
}
$hkcuBefore = (Get-ItemProperty -Path 'HKCU:\Environment' -Name $EnvName -ErrorAction SilentlyContinue).$EnvName

function Reset-Case {
  $script:probes = @{}
  $script:plan = @{}
  $script:head = @{}
  $script:UnknownProbeMemo = @{}
  Get-ChildItem $Root -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($label in @('A','B','C','D','E','F')) {
    $dir = Join-Path $Root $label
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tok = "sk-ant-oat01-SEAT$label-TOKENVALUE"
    Set-Content -LiteralPath (Join-Path $dir 'token.txt') -Value $tok -Encoding UTF8 -NoNewline
    $script:plan[$label] = 'ok'
    $script:head[$label] = 0.10
  }
  $old = Join-Path $Root '.inactive/L'
  New-Item -ItemType Directory -Path $old -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $old 'token.txt') -Value 'sk-ant-oat01-SEATINACTIVE-TOKENVALUE' -Encoding UTF8 -NoNewline
  $under = Join-Path $Root '_old'
  New-Item -ItemType Directory -Path $under -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $under 'token.txt') -Value 'sk-ant-oat01-SEATOLD-TOKENVALUE' -Encoding UTF8 -NoNewline
}

function Set-Active([string]$Label) {
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $Root '.active') -Value $Label -Encoding UTF8 -NoNewline
}
function Set-AppIdentity([string]$Label) {
  $app = Join-Path $env:USERPROFILE '.claude-app-seats'
  if (Test-Path $app) { Remove-Item $app -Recurse -Force }
  $seat = Join-Path $app $Label
  New-Item -ItemType Directory -Path $seat -Force | Out-Null
  $uuid = "uuid-$Label"
  Set-Content -LiteralPath (Join-Path $seat 'owner-uuid.txt') -Value $uuid -Encoding UTF8 -NoNewline
  $cfgDir = Join-Path $env:APPDATA 'Claude'
  New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
  @{ lastKnownAccountUuid = $uuid } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cfgDir 'config.json') -Encoding UTF8
}
function Clear-AppIdentity {
  $app = Join-Path $env:USERPROFILE '.claude-app-seats'
  if (Test-Path $app) { Remove-Item $app -Recurse -Force }
  $cfg = Join-Path (Join-Path $env:APPDATA 'Claude') 'config.json'
  if (Test-Path $cfg) { Remove-Item $cfg -Force }
}
function TokenOf([string]$Label) { (Get-Content -LiteralPath (Join-Path (Join-Path $Root $Label) 'token.txt') -Raw).Trim() }
function NoSecrets([string]$where) {
  $blob = if (Test-Path -LiteralPath $where) { Get-Content -LiteralPath $where -Raw } else { '' }
  return ($blob -notmatch 'sk-ant-')
}

Write-Host "`ncli access fallback" -ForegroundColor Cyan
Reset-Case

# --- discovery: every live token dir, nothing inside .inactive, no letter filter ---
$names = @(Get-Candidates)
Check 'live candidates are A through F' ((@($names) -join ',') -eq 'A,B,C,D,E,F') ("got $($names -join ',')")
Check '.inactive and _old are not candidates' (($names -notcontains 'L') -and ($names -notcontains '_old') -and ($names -notcontains '.inactive'))

# --- classifier fixtures, shared with the Python tests ---
$fix = Get-Content (Join-Path $PSScriptRoot 'fixtures/access-responses.json') -Raw | ConvertFrom-Json
foreach ($case in $fix) {
  $got = Test-SubscriptionDisabled ([int]$case.status) ([string]$case.body)
  Check ("fixture http $($case.status) disabled=$($case.disabled)") ($got -eq [bool]$case.disabled) "got $got"
}
# every refusal fixture (the proxy's own reply included), recorded as an API-error turn, is an access stop for the session resumer
$resAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'claude-resume-sessions.ps1'), [ref]$null, [ref]$null)
$tsl = $resAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-StoppedByLimit' }, $true)
. ([scriptblock]::Create($tsl.Extent.Text))
$LimitErrors = @('rate_limit', 'billing_error')
function Get-SessionFile([int]$p) { [pscustomobject]@{ sessionId = 's'; status = 'idle' } }
foreach ($case in @($fix | Where-Object { $_.disabled })) {
  $script:lastTurn = [pscustomobject]@{ type = 'assistant'; isApiErrorMessage = $true; error = 'unknown'; message = [pscustomobject]@{ content = @([pscustomobject]@{ text = "API Error: 403 $($case.body)" }) } }
  function Get-LastExchange([string]$sid) { $script:lastTurn }
  $v = Test-StoppedByLimit 1
  Check ("resumer sees fixture as a limit stop: $($case.body.Substring(0, [math]::Min(60, $case.body.Length)))") ($v[0] -eq 'yes') ($v -join ' ')
}

$dirty = '403 oauth_org_not_allowed sk-ant-oat01-SEATA-TOKENVALUE Bearer sk-ant-oat01-SEATA-TOKENVALUE'
$clean = ConvertTo-SanitizedNote $dirty
Check 'notes redact tokens' (($clean -notmatch 'sk-ant-') -and ($clean -match 'oauth_org_not_allowed')) $clean

# --- app identity is dynamic. A is eligible when the app is on someone else. ---
Set-AppIdentity 'B'
Check 'app identity resolves to B' ((Get-AppSeatLabel) -eq 'B') (Get-AppSeatLabel)
Set-AppIdentity 'A'
Check 'app identity resolves to A when that account is the app' ((Get-AppSeatLabel) -eq 'A') (Get-AppSeatLabel)
Clear-AppIdentity
$actFile = Join-Path (Join-Path $env:USERPROFILE '.claude-app-seats') '.active'
New-Item -ItemType Directory -Path (Split-Path $actFile) -Force | Out-Null
Set-Content -LiteralPath $actFile -Value 'F' -Encoding UTF8 -NoNewline
Check 'fallback .active is F, not a hardcoded letter' ((Get-AppSeatLabel) -eq 'F') (Get-AppSeatLabel)

# --- a fresh install (no ~/.claude-app-seats yet) still records the laptop's app seat from the heartbeat ---
# `timeout` wraps every gh call in Sync-AppSeatFromLaptop; this function shadows it, so nothing reaches GitHub.
Clear-AppIdentity
$appRoot = Join-Path $env:USERPROFILE '.claude-app-seats'
function timeout { <# MOCK-NO-NETWORK #> $global:LASTEXITCODE = 0; if ("$($args[3])" -like '*state=open*') { '7' } else { ConvertTo-Json -Compress @([DateTimeOffset]::UtcNow.ToString('o'), 'app-seat: C') } }
if ((Get-Command timeout).CommandType -ne 'Function' -or (Get-Command timeout).Definition -notmatch 'MOCK-NO-NETWORK') { Write-Host 'ABORT: timeout is not the mock' -ForegroundColor Red; exit 2 }
$env:CLAUDE_ROTATOR_SKIP_APP_SYNC = '0'; $script:AppSeatSynced = $false
try { Sync-AppSeatFromLaptop } finally { $env:CLAUDE_ROTATOR_SKIP_APP_SYNC = '1'; Remove-Item function:timeout }
Check 'fresh install: the heartbeat seat is written to .active' ((Test-Path (Join-Path $appRoot '.active')) -and ((Get-Content (Join-Path $appRoot '.active') -Raw).Trim() -eq 'C'))
Check 'fresh install: the app seat resolves to C' ((Get-AppSeatLabel) -eq 'C') (Get-AppSeatLabel)
Clear-AppIdentity

# --- the configured heartbeat repo wins over a cached .laptop-sync.json that names another repo: its issue number and logged-once flags do not carry over ---
$localCfg = try { Get-Content (Join-Path $PSScriptRoot 'rotator.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
$hbWant = if ($localCfg -and $localCfg.heartbeatRepo) { [string]$localCfg.heartbeatRepo } else { 'your-org/claude-config-backup' }
$syncConf = Join-Path $appRoot '.laptop-sync.json'
$script:ghPaths = @()
function timeout { <# MOCK-NO-NETWORK #> $global:LASTEXITCODE = 0; $script:ghPaths += "$($args[3])"; if ("$($args[3])" -like '*state=open*') { '7' } else { ConvertTo-Json -Compress @([DateTimeOffset]::UtcNow.ToString('o'), 'app-seat: D') } }
if ((Get-Command timeout).CommandType -ne 'Function' -or (Get-Command timeout).Definition -notmatch 'MOCK-NO-NETWORK') { Write-Host 'ABORT: timeout is not the mock' -ForegroundColor Red; exit 2 }
try {
  New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
  ConvertTo-Json ([ordered]@{ repo = 'someone-else/other-repo'; issue = 99; staleMin = 15; lastSeen = 'B'; lastUpdated = '2020-01-01T00:00:00.0000000+00:00'; staleLogged = $true; unconfLogged = $true }) | Set-Content -LiteralPath $syncConf -Encoding UTF8
  $env:CLAUDE_ROTATOR_SKIP_APP_SYNC = '0'; $script:AppSeatSynced = $false
  Sync-AppSeatFromLaptop
  $cache = Get-Content -LiteralPath $syncConf -Raw | ConvertFrom-Json
  Check 'cached heartbeat repo differs: the configured repo is the one read' (($script:ghPaths.Count -gt 0) -and (@($script:ghPaths | Where-Object { $_ -notlike "repos/$hbWant/*" }).Count -eq 0)) ($script:ghPaths -join ' | ')
  Check 'cached heartbeat repo differs: the other repo issue number is dropped and the issue is looked up again' (($script:ghPaths[0] -like '*state=open*') -and ($script:ghPaths -notcontains 'repos/someone-else/other-repo/issues/99') -and ([int]$cache.issue -eq 7)) ($script:ghPaths -join ' | ')
  Check 'cached heartbeat repo differs: the cache now names the configured repo and the logged-once flags are reset' (($cache.repo -eq $hbWant) -and ($cache.staleLogged -eq $false) -and ($cache.unconfLogged -eq $false) -and ($cache.lastSeen -eq 'D')) ($cache | ConvertTo-Json -Compress)
  # a cache that already names the configured repo is trusted as before: its issue number is used with no lookup
  ConvertTo-Json ([ordered]@{ repo = $hbWant; issue = 55; staleMin = 15; lastSeen = ''; lastUpdated = ''; staleLogged = $false; unconfLogged = $false }) | Set-Content -LiteralPath $syncConf -Encoding UTF8
  $script:ghPaths = @(); $script:AppSeatSynced = $false
  Sync-AppSeatFromLaptop
  Check 'cached heartbeat repo matches: its issue number is kept, with no issue lookup' (($script:ghPaths.Count -eq 1) -and ($script:ghPaths[0] -eq "repos/$hbWant/issues/55")) ($script:ghPaths -join ' | ')
} finally { $env:CLAUDE_ROTATOR_SKIP_APP_SYNC = '1'; Remove-Item function:timeout }
Clear-AppIdentity

# --- the CLI version is read once per run, with a timeout, from the `claude` on PATH; unreadable -> the fallback ---
$stubDir = Join-Path $root 'stub-claude'
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
$pathKeep = $env:PATH
try {
  $env:PATH = $stubDir + [IO.Path]::PathSeparator + $env:PATH
  Set-Content -LiteralPath (Join-Path $stubDir 'claude.cmd') -Value "@echo off`r`necho 9.8.7 (Claude Code)" -Encoding ASCII
  $script:CliVersion = $null
  $noPref = Join-Path $stubDir 'no-such-claude.exe'      # the real ~/.local/bin/claude.exe, when this PC has one, must not decide the stub's test
  Check 'the CLI version is the one `claude --version` prints' ((Get-CliVersion -Preferred $noPref) -eq '9.8.7') (Get-CliVersion -Preferred $noPref)
  Remove-Item (Join-Path $stubDir 'claude.cmd') -Force
  Check 'it is cached: a second call spawns nothing' ((Get-CliVersion) -eq '9.8.7')
  Set-Content -LiteralPath (Join-Path $stubDir 'claude.cmd') -Value "@echo off`r`necho not a version" -Encoding ASCII
  $script:CliVersion = $null
  Check 'an unreadable version falls back to 2.1.322' ((Get-CliVersion -Preferred $noPref) -eq '2.1.322') (Get-CliVersion -Preferred $noPref)
  # ~/.local/bin/claude.exe (the `claude` wrapper's binary) is used in preference to the `claude` on PATH when it exists
  $prefStub = Join-Path $stubDir 'claude-preferred.cmd'
  Set-Content -LiteralPath $prefStub -Value "@echo off`r`necho 1.2.3 (Claude Code)" -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $stubDir 'claude.cmd') -Value "@echo off`r`necho 9.8.7 (Claude Code)" -Encoding ASCII
  $script:CliVersion = $null
  Check 'the preferred binary wins over the one on PATH' ((Get-CliVersion -Preferred $prefStub) -eq '1.2.3') (Get-CliVersion -Preferred $prefStub)
  # a hung `claude --version` is killed at the timeout and the fallback used (a short timeout here; production waits 15 s)
  Set-Content -LiteralPath $prefStub -Value "@echo off`r`nping -n 20 127.0.0.1 >nul`r`necho 1.2.3" -Encoding ASCII
  $script:CliVersion = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $hung = Get-CliVersion -Preferred $prefStub -TimeoutMs 1500
  Check 'a hung claude --version times out to the fallback, quickly' ($hung -eq '2.1.322' -and $sw.Elapsed.TotalSeconds -lt 12) ('{0} after {1:n1}s' -f $hung, $sw.Elapsed.TotalSeconds)
  # a child that exits at once but leaves a grandchild holding the stdout pipe open (ping runs ~12 s): the read of its output is bounded by the same timeout
  Set-Content -LiteralPath $prefStub -Value "@echo off`r`nstart /b ping -n 13 127.0.0.1`r`nexit /b 0" -Encoding ASCII
  $script:CliVersion = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $held = Get-CliVersion -Preferred $prefStub -TimeoutMs 3000
  Check 'an output pipe held open after the child exits times out to the fallback, quickly' ($held -eq '2.1.322' -and $sw.Elapsed.TotalSeconds -lt 8) ('{0} after {1:n1}s' -f $held, $sw.Elapsed.TotalSeconds)
} finally { $env:PATH = $pathKeep; $script:CliVersion = '2.1.322' }      # the rest of the run never spawns the real CLI

# --- active B is subscription-disabled; A is the best eligible seat and must be selected ---
Reset-Case
Clear-AppIdentity
Set-AppIdentity 'F'
Set-Active 'B'
$script:plan['B'] = 'disabled'
$script:head['A'] = 0.05
$script:head['C'] = 0.40
$before = @{}
foreach ($l in @('A','B','C','D','E','F')) { $before[$l] = TokenOf $l }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'disabled B rotates (exit 0)' ($rc -eq 0) "rc=$rc"
Check 'rotated to A, which was eligible' ((Get-ActiveLabel) -eq 'A') (Get-ActiveLabel)
Check 'B was probed once, not hammered' ($script:probes['B'] -eq 1) ("count=$($script:probes['B'])")
Check 'A was probed (not skipped for being A)' ($script:probes['A'] -ge 1) ("count=$($script:probes['A'])")
$marker = Get-Content (Join-Path (Join-Path $Root 'B') 'access-disabled.json') -Raw | ConvertFrom-Json
Check 'B marker is the 403 code' ($marker.code -eq 'oauth_org_not_allowed' -and $marker.kind -eq 'subscription_disabled') $marker.code
Check 'no marker on A' (-not (Test-Path (Join-Path (Join-Path $Root 'A') 'access-disabled.json')))
foreach ($l in @('A','B','C','D','E','F')) { Check "token $l unchanged" ((TokenOf $l) -eq $before[$l]) }
Check 'rotate log has no token' (NoSecrets (Join-Path $Root '.rotate-log.txt'))
Check 'marker has no token' (NoSecrets (Join-Path (Join-Path $Root 'B') 'access-disabled.json'))
Check 'health is ready on the new seat' ((Get-Content (Join-Path $Root '.seat-health.json') -Raw | ConvertFrom-Json).ok -eq $true)

# --- the same 403 while the app identity IS A: A is excluded, C is the target ---
Reset-Case
Set-AppIdentity 'A'
Set-Active 'B'
$script:plan['B'] = 'disabled'
$script:head['A'] = 0.01
$script:head['C'] = 0.20
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'app-identity A is not the automatic target' ((Get-ActiveLabel) -eq 'C') (Get-ActiveLabel)
Check 'that exclusion is the identity rule' ((Get-AppSeatLabel) -eq 'A')

# --- the best seat's Fable probe is an explicit 403: that seat is rejected, the next one is the target ---
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
$script:plan['A'] = 'fable-disabled'
$script:head['A'] = 0.05
$script:head['C'] = 0.40
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'a Fable access refusal disqualifies A; C is the target' (($rc -eq 0) -and ((Get-ActiveLabel) -eq 'C')) "rc=$rc active=$(Get-ActiveLabel)"
Check 'A got the access marker' (Test-Path (Join-Path (Join-Path $Root 'A') 'access-disabled.json'))

# --- the ACTIVE seat's armed Fable probe is an explicit 403: rotate now, never declare the seat ready ---
Reset-Case
Clear-AppIdentity
Set-Active 'A'
$script:plan['A'] = 'fable-disabled'
$script:head['C'] = 0.30
$nowTs = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
# Haiku not due for hours (so only the Fable ladder runs); Fable armed (10 points from the cap) and due.
@{ acct='A'; nextHaiku=($nowTs + 36000); lastWorst=0; lastTs=0; fableBase=90; fableTs=($nowTs - 60); nextFable=0; rotations=@() } | ConvertTo-Json | Set-Content -LiteralPath $RotateState -Encoding UTF8
$rc = Invoke-CheckRotate 0 $false $false 'test'
Check 'an armed Fable refusal on the active seat rotates off it' (($rc -eq 0) -and ((Get-ActiveLabel) -ne 'A')) "rc=$rc active=$(Get-ActiveLabel)"
Check '... through the access path (marker on A), not declared ready' ((Test-Path (Join-Path (Join-Path $Root 'A') 'access-disabled.json')) -and
  ((Get-Content (Join-Path $Root '.rotate-log.txt') -Raw) -match 'subscription access disabled \(403 oauth_org_not_allowed\)')) (Get-Content (Join-Path $Root '.rotate-log.txt') -Raw -ErrorAction SilentlyContinue)

# --- only a successful Fable probe clears the shared refusal marker: a Haiku success beside a refused Fable probe does not ---
Reset-Case
Clear-AppIdentity
$markerA = Join-Path (Join-Path $Root 'A') 'access-disabled.json'
Write-AccessDisabled 'A' 403 'oauth_org_not_allowed'
$null = Get-UsageCached 'A' $true 'haiku' '' $false $false
Check 'a Haiku success leaves the refusal marker' (Test-Path $markerA)
$script:plan['A'] = 'fable-500'
$null = Get-UsageCached 'A' $true 'fable' '-fable' $false $false
Check 'a Fable ok=true that proves nothing (500, no usage headers) leaves it' (Test-Path $markerA)
$script:plan['A'] = 'ok'
$null = Get-UsageCached 'A' $true 'fable' '-fable' $false $false
Check 'a Fable 2xx with usage headers clears it' (-not (Test-Path $markerA))

# --- ranking rejects a Fable refusal by itself, even with no marker on disk (so --switch best skips the seat) ---
Reset-Case
Clear-AppIdentity
$script:plan['A'] = 'fable-disabled'
$script:head['A'] = 0.01
$origWrite = ${function:Write-AccessDisabled}
function Write-AccessDisabled { param([string]$Label, [int]$Http = 403, [string]$Code = '', [string]$TokFp = '') }    # the marker write is lost
try { $rows = @(Rank-Accounts $true $true) } finally { ${function:Write-AccessDisabled} = $origWrite }
$rowA = $rows | Where-Object label -eq 'A'
Check 'ranking: a Fable 403 makes A unusable' ((-not $rowA.usable) -and $rowA.access -eq 'disabled') "usable=$($rowA.usable) access=$($rowA.access)"
Check 'ranking: the best usable seat is not A' ((@($rows | Where-Object usable)[0]).label -ne 'A')

# --- ensure leaves a cooled-down seat and does not touch a healthy one ---
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
$null = Get-UsageCached 'B' $true
Check 'manual probe wrote the marker' (Test-Path (Join-Path (Join-Path $Root 'B') 'access-disabled.json'))
$script:probes = @{}
$rc = Invoke-EnsureCliSeat
Check 'ensure rotates off the disabled seat' (($rc -eq 0) -and ((Get-ActiveLabel) -ne 'B')) "rc=$rc active=$(Get-ActiveLabel)"
Check 'ensure did not probe the cooled-down seat' (-not $script:probes.ContainsKey('B') -or $script:probes['B'] -eq 0) ("count=$($script:probes['B'])")
$script:probes = @{}
Set-Active 'A'
$rc = Invoke-EnsureCliSeat
Check 'ensure leaves healthy A in place' (($rc -eq 0) -and ((Get-ActiveLabel) -eq 'A')) "rc=$rc active=$(Get-ActiveLabel)"
Check 'ensure did not probe healthy A' (-not $script:probes.ContainsKey('A') -or $script:probes['A'] -eq 0) ("count=$($script:probes['A'])")

# --- network failure does not mark every seat disabled, and does not rotate ---
Reset-Case
Clear-AppIdentity
Set-Active 'A'
$script:plan['A'] = 'network'
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'network failure stays on A' ((Get-ActiveLabel) -eq 'A') (Get-ActiveLabel)
Check 'network failure probed twice then stopped' ($script:probes['A'] -eq 2) ("count=$($script:probes['A'])")
$marked = @(Get-ChildItem $Root -Recurse -Filter 'access-disabled.json' -ErrorAction SilentlyContinue)
Check 'network failure wrote no disabled markers' ($marked.Count -eq 0) ("count=$($marked.Count)")
$health = Get-Content (Join-Path $Root '.seat-health.json') -Raw | ConvertFrom-Json
Check 'network failure is not reported as an access refusal' ($health.ok -eq $true -and $health.reason -eq 'probe_transient') "$($health.ok) $($health.reason)"

# --- the real parallel prefetch: failures in the workers reach this process's memo, so they are not probed again ---
# Probe-Usage itself is replaced (the workers copy its definition), so nothing can reach the network.
Reset-Case
$origProbe = ${function:Probe-Usage}
function Probe-Usage { param([string]$Label, [string]$Model) <# MOCK-NO-NETWORK #> [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; net=$true; note='probe failed: network (mock)' } }
if ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK') { Write-Host 'ABORT: Probe-Usage is not the mock' -ForegroundColor Red; exit 2 }
$env:CLAUDE_ROTATOR_SELFTEST = '0'
try { Prefetch-Usage @('A','B') $true $true $true } finally { $env:CLAUDE_ROTATOR_SELFTEST = '1'; ${function:Probe-Usage} = $origProbe }
$memoKeys = @($script:UnknownProbeMemo.Keys | Sort-Object)
Check 'parallel probe failures land in the caller memo' (($memoKeys -join ',') -eq 'A|,A|-fable,B|,B|-fable') ($memoKeys -join ',')
Check 'Probe-Usage is the real one again' ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK')

# --- a pair the caller's memo already holds a failure for is not sent to a worker again (unless the cooldown is not honoured) ---
$allModels = @(@{ m='haiku'; s='' }, @{ m='fable'; s='-fable' })
$script:UnknownProbeMemo = @{ 'A|-fable' = [pscustomobject]@{ label='A'; ok=$false; access='unknown' } }
$wk = @(Get-PrefetchWork @('A','B') $allModels $true | ForEach-Object { "$($_.l)|$($_.s)" })
Check 'work list drops a memoized pair when the cooldown is honoured' (($wk -join ',') -eq 'A|,B|,B|-fable') ($wk -join ',')
$wk = @(Get-PrefetchWork @('A','B') $allModels $false | ForEach-Object { "$($_.l)|$($_.s)" })
Check 'work list keeps every pair when the cooldown is not honoured' (($wk -join ',') -eq 'A|,A|-fable,B|,B|-fable') ($wk -join ',')
# and for real: the workers must not probe the memoized pair (the mock records each call as its own file in a folder, since parallel appends to one file can
# lose a line to a sharing violation; environment variables reach the runspaces)
Reset-Case
$script:UnknownProbeMemo = @{ 'A|-fable' = [pscustomobject]@{ label='A'; ok=$false; access='unknown' } }
$probeLog = Join-Path $root 'prefetch-probes'
$null = New-Item -ItemType Directory -Force -Path $probeLog
$env:CLAUDE_ROTATOR_TEST_PROBE_LOG = $probeLog
$origProbe = ${function:Probe-Usage}
function Probe-Usage { param([string]$Label, [string]$Model) <# MOCK-NO-NETWORK #> Set-Content -LiteralPath (Join-Path $env:CLAUDE_ROTATOR_TEST_PROBE_LOG "$Label`_$Model") -Value ''; [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; net=$true; note='probe failed: network (mock)' } }
if ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK') { Write-Host 'ABORT: Probe-Usage is not the mock' -ForegroundColor Red; exit 2 }
$env:CLAUDE_ROTATOR_SELFTEST = '0'
try { Prefetch-Usage @('A','B') $false $true $true } finally { $env:CLAUDE_ROTATOR_SELFTEST = '1'; ${function:Probe-Usage} = $origProbe; $env:CLAUDE_ROTATOR_TEST_PROBE_LOG = $null }
$probed = @(Get-ChildItem -LiteralPath $probeLog -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '_', '|' } | Sort-Object)
Check 'the real prefetch does not probe a memoized pair again' (($probed -join ',') -eq 'A|haiku,B|fable,B|haiku') ($probed -join ',')
Check 'Probe-Usage is the real one again (after the memo case)' ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK')

# --- disabled active, everyone else unreachable: one fallback, no extra markers ---
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'network' }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'fallback picks the first network-unknown seat in label order (A)' ((Get-ActiveLabel) -eq 'A') (Get-ActiveLabel)
$marked = @(Get-ChildItem $Root -Recurse -Filter 'access-disabled.json' | ForEach-Object { $_.Directory.Name })
Check 'only the refused seat is marked' (($marked.Count -eq 1) -and ($marked[0] -eq 'B')) ($marked -join ',')
Check 'fallback did not hammer B' ($script:probes['B'] -eq 1) ("count=$($script:probes['B'])")

# --- the fallback never steps onto a seat whose probe failed with an HTTP status (a dead token's 401) ---
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
$script:plan['A'] = 'http401'
foreach ($l in @('C','D','E','F')) { $script:plan[$l] = 'network' }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'fallback passes over a 401 seat to the first network-unknown one (C)' ((Get-ActiveLabel) -eq 'C') (Get-ActiveLabel)
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'http401' }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'every other seat a 401: no fallback, stays on B' ((Get-ActiveLabel) -eq 'B') (Get-ActiveLabel)
Check 'every other seat a 401: not exit 0' ($rc -eq 3) "rc=$rc"

# --- a cached Fable cap outlives the cache TTL: the fallback honours it until the cap's own reset ---
function Write-FableCache([string]$l, [int64]$age, $reset) {
  $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  @{ ts = $now - $age; data = @{ label = $l; ok = $true; access = 'ok'; http = 200; oi7_util = 1.0; oi7_stat = 'rejected'; oi7_reset = $reset } } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root $l) 'usage-cache-fable.json') -Encoding UTF8
}
$nowS = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Reset-Case
Write-FableCache 'A' (8 * 86400) ([string]($nowS + 3 * 86400))
Check 'a Fable cap older than a week still counts when its reset is in the future' (Test-FableCapCached 'A')
Write-FableCache 'A' ($FableTTL + 3600) ([string]($nowS - 60))
Check 'a Fable cap whose reset has passed no longer counts' (-not (Test-FableCapCached 'A'))
Write-FableCache 'A' 10 $null
Check 'a Fable cap with no reset counts' (Test-FableCapCached 'A')
Check 'no Fable cache: no cap' (-not (Test-FableCapCached 'C'))
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'network' }
Write-FableCache 'A' ($FableTTL + 3600) ([string]($nowS + 3 * 86400))
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'fallback passes over a seat whose stale Fable cap is still in force (C)' ((Get-ActiveLabel) -eq 'C') (Get-ActiveLabel)
# a headerless Fable probe (ok, http 500, no Fable window) must not overwrite a cap still in force; a real reading does
Reset-Case
Write-FableCache 'A' ($FableTTL + 3600) ([string]($nowS + 3 * 86400))
$script:plan['A'] = 'fable-500'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a headerless Fable probe leaves a cap in force on disk' (Test-FableCapCached 'A')
$script:plan['A'] = 'ok'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a Fable probe that reads the window replaces the cap' (-not (Test-FableCapCached 'A'))
Write-FableCache 'A' ($FableTTL + 3600) ([string]($nowS - 60))
$script:plan['A'] = 'fable-500'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a headerless Fable probe still replaces a cap that has reset' ((Get-Content (Join-Path (Join-Path $Root 'A') 'usage-cache-fable.json') -Raw | ConvertFrom-Json).data.http -eq 500)
Write-FableCache 'A' ($FableTTL + 3600) $null
$script:plan['A'] = 'fable-2xx-bare'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a 2xx Fable probe without the Fable window replaces a cap with no reset' (-not (Test-FableCapCached 'A'))

# --- a cached SESSION or WEEKLY cap (the default-model reading) is honoured the same way ---
function Write-DefaultCache([string]$l, [int64]$age, [hashtable]$fields) {
  $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $d = @{ label = $l; ok = $true; access = 'ok'; http = 200; s5_util = 0.2; w7_util = 0.2; s5_stat = 'allowed'; w7_stat = 'allowed'; status = 'allowed' }
  foreach ($k in $fields.Keys) { $d[$k] = $fields[$k] }
  @{ ts = $now - $age; data = $d } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root $l) 'usage-cache.json') -Encoding UTF8
}
$stale = $UsageTTL + 3600
foreach ($which in 's5','w7') {
  $word = if ($which -eq 's5') { 'session' } else { 'weekly' }
  Reset-Case
  Clear-AppIdentity
  Set-Active 'B'
  $script:plan['B'] = 'disabled'
  foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'network' }
  Write-DefaultCache 'A' $stale @{ "${which}_stat" = 'rejected'; "${which}_reset" = ($nowS + 3600); status = 'rejected' }
  Check "a $word cap read past the TTL still counts until its reset" (Test-CapCached 'A' 'default')
  $rc = Invoke-CheckRotate 0 $false $true 'test'
  Check "fallback passes over a seat whose stale $word cap is still in force (C)" ((Get-ActiveLabel) -eq 'C') (Get-ActiveLabel)
  Reset-Case
  Clear-AppIdentity
  Set-Active 'B'
  $script:plan['B'] = 'disabled'
  foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'network' }
  Write-DefaultCache 'A' $stale @{ "${which}_stat" = 'rejected'; "${which}_reset" = ($nowS - 60); status = 'rejected' }
  Check "a $word cap whose reset has passed no longer counts" (-not (Test-CapCached 'A' 'default'))
  $rc = Invoke-CheckRotate 0 $false $true 'test'
  Check "fallback does not exclude a seat whose $word cap has reset (A)" ((Get-ActiveLabel) -eq 'A') (Get-ActiveLabel)
}
Reset-Case
Write-DefaultCache 'A' 10 @{ status = 'rejected' }
Check 'an overall rejection naming no window, no reset, counts' (Test-CapCached 'A' 'default')
Write-DefaultCache 'A' 10 @{}
Check 'an allowed default reading is no cap' (-not (Test-CapCached 'A' 'default'))
Check 'no default cache: no cap' (-not (Test-CapCached 'C' 'default'))
# a headerless non-2xx default-model probe must not overwrite a cap still in force; a real 2xx reading does
Reset-Case
Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = ($nowS + 3600); status = 'rejected' }
$script:plan['A'] = 'default-500'
$null = Get-UsageCached 'A' $true 'haiku' ''
Check 'a headerless default probe leaves a session cap in force on disk' (Test-CapCached 'A' 'default')
$script:plan['A'] = 'ok'
$null = Get-UsageCached 'A' $true 'haiku' ''
Check 'a 2xx default probe replaces the cap' (-not (Test-CapCached 'A' 'default'))
Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = ($nowS - 60); status = 'rejected' }
$script:plan['A'] = 'default-500'
$null = Get-UsageCached 'A' $true 'haiku' ''
Check 'a headerless default probe still replaces a cap that has reset' ((Get-Content (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Raw | ConvertFrom-Json).data.http -eq 500)

# A proxy response can name only the Fable window, without measuring its utilization.
Reset-Case
Clear-AppIdentity
foreach ($l in 'A','C') { $script:plan[$l] = 'network' }
$seatA = Join-Path $Root 'A'
$statusOnly = @{ ts = $nowS - $stale; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429
                 status = 'rejected'; oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 3600); oi7_util = $null } }
$cacheNames = 'usage-cache.json','usage-cache-fable.json'
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a Fable-only rejection is no default cap' (-not (Test-CapCached 'A' 'default'))
Check 'the network fallback honors a legacy rejection stored only in the default cache' ((Select-RotationTarget 90 'B').label -eq 'C')
$measured = @{ ts = $nowS - $stale; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'
               oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 3600); oi7_util = '1.0' } }
$measured | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'the network fallback honors a measured Fable rejection whose Fable cache write was skipped' ((Select-RotationTarget 90 'B').label -eq 'C')
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$allowedFable = @{ ts = $statusOnly.ts + 60; data = @{ ok = $true; oi7_stat = 'allowed'; oi7_util = 0.1 } }
$fablePath = Join-Path $seatA 'usage-cache-fable.json'
@{ ts = $statusOnly.ts + 60; data = @{ ok = $true; http = 500 } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'an older rotator unable to read Fable cannot mask a legacy rejection' ((Select-RotationTarget 90 'B').label -eq 'C')
$allowedFable | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a newer Fable reading supersedes the legacy rejection' ((Select-RotationTarget 90 'B').label -eq 'A')
$allowedFable.ts = $statusOnly.ts - 60
$allowedFable | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a legacy rejection supersedes an older Fable reading' ((Select-RotationTarget 90 'B').label -eq 'C')
$allowedFable.ts = $nowS + 86400
$allowedFable | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a future-dated Fable reading does not outrank a default-cache rejection' ((Select-RotationTarget 90 'B').label -eq 'C')
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
@{ ts = $statusOnly.ts + 60; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; s5_util = 0.1; oi7_stat = 'allowed' } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a newer Fable allowance in the default cache supersedes the Fable cache rejection' ((Select-RotationTarget 90 'B').label -eq 'A')
@{ ts = $statusOnly.ts + 60; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; s5_util = 0.1; oi7_util = 0.2 } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a newer Fable utilization reading in the default cache supersedes the Fable cache rejection' ((Select-RotationTarget 90 'B').label -eq 'A')
$measuredCap = @{ ts = $statusOnly.ts; data = @{ ok = $true; http = 429; oi7_stat = 'rejected'; oi7_util = 1.0; oi7_reset = [string]($nowS + 3600) } }
$measuredCap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache.json')
Check 'the watcher baseline reports a measured Fable cap' ((Read-FableCache 'A').capped)
$sameResponse = @{ ts = $nowS; observed_ms = $nowS * 1000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'
                   oi7_stat = 'rejected'; oi7_util = 1.0; oi7_reset = [string]($nowS + 3600) } }
foreach ($name in $cacheNames) { $sameResponse | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA $name) -Encoding UTF8 }
Check 'the watcher baseline reports a cap the proxy saved in both caches at once' ((Read-FableCache 'A').capped)
@{ ts = $statusOnly.ts + 60; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; s5_util = 0.1; oi7_stat = 'allowed' } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$measuredCap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'the watcher baseline agrees: a newer default-cache allowance clears a measured Fable cap' (-not (Read-FableCache 'A').capped)
function Set-NestedRej($TopTs, $TopSrc, $NestTs, $NestData) {
  $top = @{ label = 'A'; ok = $true; http = 200; status = 'allowed'; s5_util = 0.2; w7_util = 0.3 }
  if ($TopSrc) { $top.src = $TopSrc }
  @{ ts = $TopTs; observed_ms = $TopTs * 1000; data = $top
     fable_cap = @{ ts = $NestTs; observed_ms = $NestTs * 1000; data = $NestData } } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
}
$rej429 = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day_oi'; oi7_stat = 'rejected' }
$oiOnly = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 3600) }
Set-NestedRej ($nowS - 900) 'proxy' $nowS $rej429
$sample = Get-ProxySample 'A' $true
Check 'a --now check sees a fresh nested Fable-only rejection under a stale default reading' ($sample.fable_only_rejection -and $sample.status -eq 'rejected' -and $sample.claim -eq 'seven_day_oi')
Check 'a nested Fable-only rejection sample carries no session value for the projection' ($null -eq $sample.s5_util)
Set-NestedRej $nowS $null $nowS $rej429
Check 'a --now check sees a fresh nested Fable-only rejection under a rotator probe reading' ((Get-ProxySample 'A' $true).fable_only_rejection)
Set-NestedRej ($nowS - 900) 'proxy' $nowS $oiOnly
Check 'a nested rejection carried only by 7d_oi-status is seen' ((Get-ProxySample 'A' $true).fable_only_rejection)
Set-NestedRej ($nowS - 900) 'proxy' ($nowS + 3600) $rej429
Check 'a future-dated nested rejection is not a fresh rejection' ($null -eq (Get-ProxySample 'A' $true))
Set-NestedRej ($nowS - 900) 'proxy' ($nowS - 600) $rej429
Check 'a stale nested rejection does not satisfy a --now check' ($null -eq (Get-ProxySample 'A' $true))
$renewedRej = $rej429.Clone(); $renewedRej.oi7_reset = [string]($nowS - 60)
Set-NestedRej ($nowS - 900) 'proxy' $nowS $renewedRej
Check 'a nested rejection whose Fable window already renewed does not trigger' ($null -eq (Get-ProxySample 'A' $true))
$weeklyCarried = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day'; w7_util = 1.0; oi7_stat = 'allowed'; oi7_util = 0.2 }
Set-NestedRej $nowS 'proxy' $nowS $weeklyCarried
Check 'a carried reading naming only weekly utilization is not a Fable-only rejection' ($null -eq (Get-ProxySample 'A' $true))
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $oiOnly } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a top-level Fable-only rejection (no default reading to nest under) is seen as a Fable rejection' ((Get-ProxySample 'A' $true).fable_only_rejection)
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $rej429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a top-level Fable-only rejection with an overall status is a Fable rejection, not a session cap' ((Get-ProxySample 'A' $true).fable_only_rejection)
# $rej429 carries the overall status too, as a real Fable 429 does: a renewed, future-dated or superseded one must not
# fall through to a session cap (a stale one is also stopped by the freshness test that sample needs).
$topRenewed = $rej429.Clone(); $topRenewed.oi7_reset = [string]($nowS - 60)
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $topRenewed } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a top-level Fable rejection whose window already renewed does not trigger' ($null -eq (Get-ProxySample 'A' $true))
@{ ts = $nowS - 600; observed_ms = ($nowS - 600) * 1000; data = $rej429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a stale top-level Fable rejection does not satisfy a --now check' ($null -eq (Get-ProxySample 'A' $true))
@{ ts = $nowS + 3600; observed_ms = ($nowS + 3600) * 1000; data = $rej429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a future-dated top-level Fable rejection is not a fresh rejection' ($null -eq (Get-ProxySample 'A' $true))
@{ ts = $nowS - 30; observed_ms = ($nowS - 30) * 1000; data = $rej429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
@{ ts = $nowS; observed_ms = $nowS * 1000; data = @{ label = 'A'; ok = $true; http = 200; oi7_stat = 'allowed'; oi7_util = 0.4 } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -Encoding UTF8
Check 'a newer Fable cache allowance supersedes a top-level Fable rejection' ($null -eq (Get-ProxySample 'A' $true))
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -ErrorAction SilentlyContinue
$plain429 = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'five_hour' }
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $plain429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$sample = Get-ProxySample 'A' $true
Check 'a top-level 429 whose Fable window is not rejected stays an overall rejection, not a Fable cap' ($sample.status -eq 'rejected' -and -not $sample.fable_only_rejection)
# The shape the proxy now stores at the top level: another limit's sparse 429 that carries a Fable status.
$other429 = $plain429.Clone(); $other429.oi7_stat = 'allowed'
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $other429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$sample = Get-ProxySample 'A' $true
Check "a top-level five_hour 429 whose Fable window says allowed is an overall rejection the watcher sees" ($sample.status -eq 'rejected' -and -not $sample.fable_only_rejection)
# The production Fable 429 shape: 7d window allowed with utilization, overall and Fable windows rejected.
$prod429 = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day_oi'
              w7_util = 0.62; w7_stat = 'allowed'; oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 3600) }
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $prod429 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a full Fable 429 with an allowed 7d window is a Fable rejection, not a session cap' ((Get-ProxySample 'A' $true).fable_only_rejection)
$prodRenewed = $prod429.Clone(); $prodRenewed.oi7_reset = [string]($nowS - 60); $prodRenewed.s5_util = 0.3; $prodRenewed.s5_stat = 'allowed'
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $prodRenewed } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a renewed full Fable 429 is not reported as a rejection' ($null -eq (Get-ProxySample 'A' $true))
$sample = Get-ProxySample 'A' $false
Check '... but its session value still feeds the projection, without the overall rejection' ($sample -and [double]$sample.s5_util -eq 0.3 -and $sample.status -ne 'rejected' -and -not $sample.fable_only_rejection)
@{ ts = $nowS - 600; observed_ms = ($nowS - 600) * 1000; data = $prodRenewed } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a stale renewed full Fable 429 does not feed the projection' ($null -eq (Get-ProxySample 'A' $false))
$prodNoSession = $prod429.Clone(); $prodNoSession.oi7_reset = [string]($nowS - 60)
@{ ts = $nowS; observed_ms = $nowS * 1000; data = $prodNoSession } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
Check 'a renewed full Fable 429 with no session value does not feed the projection' ($null -eq (Get-ProxySample 'A' $false))
$carried = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'five_hour'; s5_util = 1.0; s5_stat = 'rejected'; oi7_stat = 'allowed'; oi7_util = 0.2 }
Set-NestedRej $nowS 'proxy' $nowS $carried
Check 'a carried full reading rejected on a default window is not a Fable-only rejection' ($null -eq (Get-ProxySample 'A' $true))
@{ ts = $nowS; observed_ms = $nowS * 1000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day'; s5_util = 0.2; w7_util = 1.0; s5_stat = 'allowed'; w7_stat = 'rejected' }
   fable_cap = @{ ts = $nowS; observed_ms = $nowS * 1000; data = $rej429 } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$sample = Get-ProxySample 'A' $true
Check 'a fresh weekly cap above a nested Fable rejection is the sample reported' ($sample.w7_stat -eq 'rejected' -and -not $sample.fable_only_rejection)
Set-NestedRej ($nowS - 900) 'proxy' ($nowS - 30) $rej429
@{ ts = $nowS; observed_ms = $nowS * 1000; data = @{ label = 'A'; ok = $true; http = 200; oi7_stat = 'allowed'; oi7_util = 0.4 } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -Encoding UTF8
Check 'a newer Fable cache allowance supersedes a nested Fable rejection' ($null -eq (Get-ProxySample 'A' $true))
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -ErrorAction SilentlyContinue
Set-NestedRej ($nowS - 900) 'proxy' ($nowS - 30) $rej429
@{ ts = $nowS - 600; observed_ms = ($nowS - 600) * 1000; data = @{ label = 'A'; ok = $true; http = 200; oi7_stat = 'allowed'; oi7_util = 0.85 }
   fable_cap = @{ ts = $nowS; observed_ms = $nowS * 1000; data = @{ label = 'A'; ok = $true; http = 429; oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 3600) } } } |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -Encoding UTF8
Check 'a newer status-only Fable cache rejection keeps the nested Fable rejection' ((Get-ProxySample 'A' $true).fable_only_rejection)
@{ ts = $nowS + 3600; observed_ms = ($nowS + 3600) * 1000; data = @{ label = 'A'; ok = $true; http = 200; oi7_stat = 'allowed'; oi7_util = 0.4 } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -Encoding UTF8
Check 'a future-dated Fable cache allowance does not hide a fresh nested rejection' ((Get-ProxySample 'A' $true).fable_only_rejection)
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache.json') -ErrorAction SilentlyContinue
@{ ts = $nowS + 3600; observed_ms = ($nowS + 3600) * 1000; data = @{ label = 'A'; ok = $true; http = 429; oi7_stat = 'rejected'; oi7_reset = [string]($nowS + 7200) } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -Encoding UTF8
Check 'a future-dated Fable cache rejection is not a cap in force' (-not (Test-FableCapCached 'A'))
Remove-Item -LiteralPath (Join-Path $seatA 'usage-cache-fable.json') -ErrorAction SilentlyContinue
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA 'usage-cache.json') -Encoding UTF8
$allowedFable.ts = $statusOnly.ts - 60
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a status-only Fable rejection is a cap in the Fable cache' (Test-FableCapCached 'A')
Check 'a status-only Fable rejection supplies no utilization baseline' ($null -eq (Read-FableCache 'A'))
Check 'the network fallback skips the Fable-capped seat' ((Select-RotationTarget 90 'B').label -eq 'C')
$statusOnly.data.oi7_reset = [string]($nowS - 60)
foreach ($name in $cacheNames) {
  $statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $seatA $name) -Encoding UTF8
}
Check 'the network fallback can use the seat after its Fable reset' ((Select-RotationTarget 90 'B').label -eq 'A')

Reset-Case
foreach ($l in 'B','C','D','E','F') { $script:plan[$l] = 'http401' }
$script:plan['A'] = 'fable-500'
$statusOnly.data.oi7_reset = [string]($nowS + 3600)
$defaultPath = Join-Path $seatA 'usage-cache.json'
$statusOnly | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $defaultPath -Encoding UTF8
Check 'normal selection honors the legacy Fable cap after a healthy default refresh and a headerless Fable probe' ($null -eq (Select-RotationTarget 90))
$refreshed = Read-UsageCacheFile $defaultPath
Check 'the default refresh saves its new reading and retains the original Fable cap timestamp' ($refreshed.data.http -eq 200 -and $refreshed.fable_cap.ts -eq $statusOnly.ts)
$future = $statusOnly | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$future.ts = $nowS + 86400; $future | Add-Member -NotePropertyName observed_ms -NotePropertyValue (($nowS + 86400) * 1000) -Force
$future | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $defaultPath -Encoding UTF8
Write-UsageCacheFile $defaultPath 'A' @{ ts = $nowS; observed_ms = $nowS * 1000 + 1; data = @{ ok = $true; http = 200; s5_util = 0.1 } } $false
Check 'a default refresh drops a future-dated legacy Fable cap' (-not (Read-UsageCacheFile $defaultPath).fable_cap)
$nowMsT = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
@{ ts = [int64](($nowMsT - 5000) / 1000); observed_ms = $nowMsT - 5000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; s5_util = 0.1 }
   fable_cap = @{ ts = [int64](($nowMsT - 10) / 1000); observed_ms = $nowMsT - 10; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; oi7_stat = 'rejected' } } } |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $defaultPath -Encoding UTF8
Write-UsageCacheFile $defaultPath 'A' @{ ts = [int64](($nowMsT - 2000) / 1000); observed_ms = $nowMsT - 2000; data = @{ ok = $true; http = 200; s5_util = 0.2 } } $false
Check 'a default refresh that finishes late keeps a newer Fable cap' ((Read-UsageCacheFile $defaultPath).fable_cap.data.oi7_stat -eq 'rejected')

Reset-Case
$allowedFable.fable_cap = $statusOnly
$allowedFable | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fablePath -Encoding UTF8
$baseline = Read-FableCache 'A'
Check 'a status-only cap preserves the older measured baseline' ($baseline.pct -eq 10 -and $baseline.ts -eq $allowedFable.ts -and -not $baseline.capped)
Check 'cap checks use the status-only rejection alongside the measured baseline' (Test-FableCapCached 'A')
$allowedFable.data.oi7_stat = 'rejected'
$statusOnly.data.oi7_reset = $nowS - 60
$allowedFable | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a preserved rejected measurement does not supply a watcher cap once the newer rejection resets' (-not (Read-FableCache 'A').capped)

Reset-Case
$statusOnly.ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$statusOnly | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $defaultPath -Encoding UTF8
$statusOnly | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fablePath -Encoding UTF8
$a = Rank-Accounts $false $false | Where-Object label -eq 'A'
Check 'fresh default cache does not classify a Fable-only rejection as a default cap' $a.usable
$fableFromCache = Get-UsageCached 'A' $false 'fable' '-fable' $true
Check 'a fresh cached Fable rejection is no longer returned after its reset' (-not $fableFromCache.ok)
Check 'a malformed reset formats as unknown' ((FmtReset 'invalid reset') -eq '(unknown)')

Reset-Case
$script:plan['A'] = 'fable-overlap'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a successful Fable response supersedes a proxy rejection received during the probe' (-not (Test-FableCapCached 'A'))
$script:plan['A'] = 'fable-500'
$null = Get-UsageCached 'A' $true 'fable' '-fable'
Check 'a subsequent headerless Fable probe does not revive the superseded cap' (-not (Test-FableCapCached 'A'))

Reset-Case
$second = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
$observed = $second * 1000
Write-UsageCacheFile $fablePath 'A' @{ ts = $second; observed_ms = $observed + 200; data = @{ ok = $true; http = 200; oi7_stat = 'allowed' } } $true
Write-UsageCacheFile $fablePath 'A' @{ ts = $second; observed_ms = $observed + 100; data = @{ ok = $true; http = 429; oi7_stat = 'rejected' } } $true
Check 'a delayed cache write cannot reinstate a rejection from earlier in the same second' ((Read-FableUsageCache $seatA).data.oi7_stat -eq 'allowed')

$repair = @{ ts = $second; observed_ms = $observed + 300; data = @{ ok = $true; http = 429; oi7_stat = 'rejected' } }
Set-Content -LiteralPath $fablePath -Value '{"data":' -Encoding UTF8
Write-UsageCacheFile $fablePath 'A' $repair $true
Check 'a persistently invalid Fable cache is repaired by the next observation' (Test-FableCapCached 'A')
@{ ts = $second + 86400; observed_ms = $observed + 86400000; data = @{ok=$true; http=200; oi7_stat='allowed'} } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Check 'a future-dated reading is not served as fresh' (-not (Get-UsageCached 'A' $false 'fable' '-fable' $true).ok)
Write-UsageCacheFile $fablePath 'A' $repair $true
Check 'a future cache timestamp does not block the next Fable observation' (Test-FableCapCached 'A')
@{ ts = $second + 86400; observed_ms = $observed + 86400000; data = @{ok=$true; http=200; oi7_util=0.4} } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fablePath -Encoding UTF8
Write-UsageCacheFile $fablePath 'A' $repair $true
$saved = Read-UsageCacheFile $fablePath
Check 'a status-only write does not carry a future-dated measurement forward' (-not $saved.fable_cap -and [long]$saved.observed_ms -eq $repair.observed_ms)

# With no usable reset, a headerless probe preserves both the cap and its original timestamp for up to a week.
$week = 7 * 86400
foreach ($case in @(
    @{ window = 'session'; fields = @{ s5_stat = 'rejected'; status = 'rejected' } },
    @{ window = 'weekly'; fields = @{ w7_stat = 'rejected'; w7_reset = 'unreadable'; status = 'rejected' } },
    @{ window = 'overall'; fields = @{ status = 'rejected' } },
    @{ window = 'Fable'; fable = $true })) {
  Reset-Case
  $which, $model, $suffix = if ($case.fable) { 'fable', 'fable', '-fable' } else { 'default', 'haiku', '' }
  $script:plan['A'] = "$which-500"
  $cf = Join-Path $seatA "usage-cache$suffix.json"
  foreach ($age in ($week - 60), ($week + 60)) {
    if ($case.fable) { Write-FableCache 'A' $age $null }
    else { Write-DefaultCache 'A' $age $case.fields }
    $before = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json
    $inForce = $age -lt $week
    Check "the $($case.window) cap without a reset at age ${age}s counts only within a week" ((Test-CapCached 'A' $which) -eq $inForce)
    $null = Get-UsageCached 'A' $true $model $suffix
    $after = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json
    if ($inForce) {
      Check "a headerless probe retains the $($case.window) cap without renewing its timestamp" ($after.ts -eq $before.ts -and (Test-CapCached 'A' $which))
    } else {
      Check "a headerless probe replaces the expired $($case.window) cap" ($after.data.http -eq 500 -and -not (Test-CapCached 'A' $which))
    }
  }
}

# --- issue #11: the normal ranking and selection path honours a cached cap when the live probe is headerless ---
# A is the only seat the other probes leave usable (401s), so selecting it can only be the cap being ignored.
foreach ($case in @(
    @{ word = 'session'; plan = 'default-500'; fable = $false; key = 's5' },
    @{ word = 'weekly';  plan = 'default-500'; fable = $false; key = 'w7' },
    @{ word = 'Fable';   plan = 'fable-500';   fable = $true;  key = 'oi7' })) {
  foreach ($future in $true, $false) {
    Reset-Case
    Clear-AppIdentity
    foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
    $script:plan['A'] = $case.plan
    $reset = if ($future) { $nowS + 3600 } else { $nowS - 60 }
    if ($case.fable) { Write-FableCache 'A' $stale ([string]$reset) }
    else { Write-DefaultCache 'A' $stale @{ "$($case.key)_stat" = 'rejected'; "$($case.key)_reset" = $reset; status = 'rejected' } }
    $rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
    $script:UnknownProbeMemo = @{}
    $pick = Select-RotationTarget -Bar 90
    $pickL = if ($pick) { $pick.label } else { '(none)' }
    if ($future) {
      Check "a headerless 500 over a cached $($case.word) cap in force: not ranked usable" ($rowA -and -not $rowA.usable) "usable=$($rowA.usable) why=$($rowA.why)"
      Check "a headerless 500 over a cached $($case.word) cap in force: not selected" ($pickL -eq '(none)') $pickL
      if (-not $case.fable) {
        Check "a headerless 500 over a cached $($case.word) cap in force: its unread usage is reported as unknown, not 0%" ($null -eq $rowA.s5 -and $null -eq $rowA.w7) "s5=$($rowA.s5) w7=$($rowA.w7)"
        Check "a headerless 500 over a cached $($case.word) cap in force: labelled as a cached cap" ($rowA.why -eq 'capped (cached cap in force)') $rowA.why
      } else {
        Check "a headerless 500 over a cached Fable cap in force: labelled as a cached Fable cap" ($rowA.why -eq 'fable capped (cached cap in force, needed for Gate C)') $rowA.why
        Check "a headerless 500 over a cached Fable cap in force: the skip is logged" ((Test-Path -LiteralPath $RotateLog) -and ((Get-Content -LiteralPath $RotateLog -Raw) -match "skipped 'A' as a target: its Fable probe \(http 500\)"))
      }
    } else {
      Check "a headerless 500 over an expired cached $($case.word) cap: still ranked usable" ([bool]$rowA.usable) "why=$($rowA.why)"
      Check "a headerless 500 over an expired cached $($case.word) cap: still selected" ($pickL -eq 'A') $pickL
    }
  }
}

# Blanking reports only what the reading lacks: a reading that carries w7_util alone keeps it next to a cache-only cap, and a live
# cap keeps its numbers even when the reading carried no utilisation.
Reset-Case
Clear-AppIdentity
foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
$script:plan['A'] = 'default-only:w7_util'
Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = $nowS + 3600; status = 'rejected' }
$rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
Check 'a 429 carrying only w7_util over a cached cap in force: excluded as a cached cap' ($rowA -and -not $rowA.usable -and $rowA.why -eq 'capped (cached cap in force)') "usable=$($rowA.usable) why=$($rowA.why)"
Check 'a 429 carrying only w7_util over a cached cap in force: s5 unknown, w7 kept' ($null -eq $rowA.s5 -and $rowA.w7 -eq 0.1) "s5=$($rowA.s5) w7=$($rowA.w7)"
Reset-Case
Clear-AppIdentity
foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
$script:plan['A'] = 'default-rejected-bare'
$rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
Check 'a live cap with no utilisation: labelled capped, numbers kept' ($rowA -and -not $rowA.usable -and $rowA.why -eq 'capped' -and $null -ne $rowA.s5 -and $null -ne $rowA.w7) "why=$($rowA.why) s5=$($rowA.s5) w7=$($rowA.w7)"

# Both caps at once: the combined label says cached when either one came from the cache.
Reset-Case
Clear-AppIdentity
foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
$script:plan['A'] = 'both-500'
Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = $nowS + 3600; status = 'rejected' }
Write-FableCache 'A' $stale ([string]($nowS + 3600))
$rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
Check 'cached session and Fable caps together: labelled as cached' ($rowA -and $rowA.why -eq 'capped + fable capped (cached cap in force)') $rowA.why
foreach ($mix in @(
    @{ word = 'a live session cap beside a cached Fable cap'; plan = 'live-default+fable-500'; dc = $false; fc = $true },
    @{ word = 'a cached session cap beside a live Fable cap'; plan = 'default-500+live-fable'; dc = $true; fc = $false })) {
  Reset-Case
  Clear-AppIdentity
  foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
  $script:plan['A'] = $mix.plan
  if ($mix.dc) { Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = $nowS + 3600; status = 'rejected' } }
  if ($mix.fc) { Write-FableCache 'A' $stale ([string]($nowS + 3600)) }
  $rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
  Check "$($mix.word): labelled as cached" ($rowA -and $rowA.why -eq 'capped + fable capped (cached cap in force)') $rowA.why
}

# A cached Fable cap (in force, or with no reset) is replaced by a fresh 2xx reading, and a failed Fable probe over it stays
# not-capped: either way A is the target. This is what keeps a cap with no reset from excluding a seat for good.
foreach ($case in @(
    @{ word = 'a fresh 2xx Fable reading'; plan = 'ok' },
    @{ word = 'a Fable probe that fails on the network'; plan = 'fable-net' })) {
  foreach ($reset in @([string]($nowS + 3600), $null)) {
    $rw = if ($reset) { 'in force' } else { 'with no reset' }
    Reset-Case
    Clear-AppIdentity
    foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
    $script:plan['A'] = $case.plan
    Write-FableCache 'A' $stale $reset
    $rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
    $script:UnknownProbeMemo = @{}
    $pick = Select-RotationTarget -Bar 90
    $pickL = if ($pick) { $pick.label } else { '(none)' }
    Check "$($case.word) over a cached Fable cap $($rw): still ranked usable" ($rowA -and [bool]$rowA.usable) "why=$($rowA.why)"
    Check "$($case.word) over a cached Fable cap $($rw): still selected" ($pickL -eq 'A') $pickL
  }
}

# Only the reading Write-UsageCacheFile keeps a cached cap through (an ok non-2xx with none of the window's fields) is checked against the cache: a 2xx
# (with or without the window) or a non-2xx carrying the window decides, even when its cache write failed and the old cap is still
# on disk. The old cache is past its TTL here, so the live reading is the one ranked.
foreach ($case in @(
    @{ word = '2xx session'; fable = $false; plan = 'ok' },
    @{ word = 'bare 2xx session (no usage headers)'; fable = $false; plan = 'default-2xx-bare' },
    @{ word = '429 session carrying the window'; fable = $false; plan = 'default-429-fields' },
    @{ word = '2xx Fable'; fable = $true; plan = 'ok' },
    @{ word = 'bare 2xx Fable (no oi7 window)'; fable = $true; plan = 'fable-2xx-bare' },
    @{ word = '429 Fable carrying the oi7 window'; fable = $true; plan = 'fable-429-fields' },
    @{ word = '429 session carrying only status'; fable = $false; plan = 'default-only:status' },
    @{ word = '429 session carrying only s5_stat'; fable = $false; plan = 'default-only:s5_stat' },
    @{ word = '429 session carrying only w7_stat'; fable = $false; plan = 'default-only:w7_stat' },
    @{ word = '429 session carrying only s5_util'; fable = $false; plan = 'default-only:s5_util' },
    @{ word = '429 Fable carrying only oi7_stat'; fable = $true; plan = 'fable-only:oi7_stat' },
    @{ word = '429 Fable carrying only oi7_util'; fable = $true; plan = 'fable-only:oi7_util' })) {
  Reset-Case
  Clear-AppIdentity
  foreach ($l in @('B','C','D','E','F')) { $script:plan[$l] = 'http401' }
  $script:plan['A'] = $case.plan
  if ($case.fable) { Write-FableCache 'A' $stale ([string]($nowS + 3600)); $cf = 'usage-cache-fable.json' }
  else { Write-DefaultCache 'A' $stale @{ s5_stat = 'rejected'; s5_reset = $nowS + 3600; status = 'rejected' }; $cf = 'usage-cache.json' }
  $cfp = Join-Path (Join-Path $Root 'A') $cf
  Set-ItemProperty -LiteralPath $cfp -Name IsReadOnly -Value $true
  $rowA = @(Rank-Accounts $true $true) | Where-Object label -eq 'A'
  $script:UnknownProbeMemo = @{}
  $pick = Select-RotationTarget -Bar 90
  $pickL = if ($pick) { $pick.label } else { '(none)' }
  Set-ItemProperty -LiteralPath $cfp -Name IsReadOnly -Value $false
  Check "a $($case.word) reading over a cached cap it could not overwrite: the old cap really is still on disk" (Test-CapCached 'A' $(if ($case.fable) { 'fable' } else { 'default' }))
  Check "a $($case.word) reading over a cached cap it could not overwrite: still ranked usable" ($rowA -and [bool]$rowA.usable) "why=$($rowA.why)"
  Check "a $($case.word) reading over a cached cap it could not overwrite: still selected" ($pickL -eq 'A') $pickL
}

# --- quota 429 is not an access refusal ---
Reset-Case
Clear-AppIdentity
Set-Active 'A'
$script:plan['A'] = 'quota'
$script:head['B'] = 0.05
$null = Invoke-CheckRotate 0 $false $true 'test'
Check 'quota 429 did not write an access marker on A' (-not (Test-Path (Join-Path (Join-Path $Root 'A') 'access-disabled.json')))
Check 'quota still rotates off the capped seat' ((Get-ActiveLabel) -ne 'A') (Get-ActiveLabel)

# --- exhaustion: the only other seat is the app identity, so we stay and say so ---
Reset-Case
# drop C-F so the only other seat is the app identity? Keep them but mark them disabled via plan
# and make A the app identity with a disabled active B. If A is app and the rest are disabled
# (not network), there is no unknown fallback and no usable target.
Set-AppIdentity 'A'
Set-Active 'B'
foreach ($l in @('A','B','C','D','E','F')) { $script:plan[$l] = 'disabled' }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'exhaustion stays put' ((Get-ActiveLabel) -eq 'B') (Get-ActiveLabel)
Check 'exhaustion is not exit 0' ($rc -eq 3) "rc=$rc"
$health = Get-Content (Join-Path $Root '.seat-health.json') -Raw | ConvertFrom-Json
Check 'exhaustion is not healthy' ($health.ok -eq $false -and $health.reason -eq 'exhausted') "$($health.ok) $($health.reason)"

# --- source does not special-case a letter ---
$src = Get-Content (Join-Path $PSScriptRoot 'claude-cli-account.ps1') -Raw
$py = (Get-Content (Join-Path $PSScriptRoot 'claude-rotate-proxy.py') -Raw) + (Get-Content (Join-Path $PSScriptRoot 'stopfailure-rotate.py') -Raw)
Check 'rotator has no hardcoded app-only seat' ($src -notmatch 'AppOnly|reserved app-only')
Check 'proxy and hook do not exclude label A' ($py -notmatch '== ["'']A["'']|label == "A"')

# --- a secret's temp file is created owner-only before the secret is written (UnixCreateMode on Linux), never chmod-ed after ---
$woFn = Get-Command Write-OwnerOnly -CommandType Function -ErrorAction SilentlyContinue
Check 'Write-OwnerOnly exists' ([bool]$woFn)
if ($woFn) {
  $wo = Join-Path $root 'wo.tmp'; Set-Content -LiteralPath $wo -Value 'stale'
  Write-OwnerOnly $wo 'sk-ant-oat01-SEATX-TOKENVALUE'
  Check 'Write-OwnerOnly writes the exact text, no BOM, over a stale file' ([IO.File]::ReadAllText($wo) -ceq 'sk-ant-oat01-SEATX-TOKENVALUE' -and [IO.File]::ReadAllBytes($wo)[0] -eq [byte][char]'s')
  Check 'Write-OwnerOnly sets the owner-only mode at creation' ($woFn.Definition -match "UnixCreateMode = \[IO.UnixFileMode\]'UserRead, UserWrite'" -and $woFn.Definition -match "Mode = 'CreateNew'")
}
foreach ($fn in 'Set-DiskCredential', 'Save-ProfileToken') {
  $d = (Get-Command $fn -CommandType Function).Definition
  Check "$fn writes its temp secret through Write-OwnerOnly, no write-then-chmod" ($d -match 'Write-OwnerOnly \$tmp' -and $d -notmatch 'chmod')
}

# --- a replaced token drops the seat's refusal marker; storing the same token again keeps it ---
Reset-Case
Write-AccessDisabled -Label 'B'
Save-ProfileToken 'B' (TokenOf 'B') $false
Check 'storing the same token keeps the refusal marker' ($null -ne (Read-AccessDisabled 'B'))
foreach ($c in 'usage-cache.json', 'usage-cache-fable.json') { Set-Content -LiteralPath (Join-Path (Join-Path $Root 'B') $c) -Value '{"ts":1,"data":{"ok":true,"status":"rejected"}}' }
Save-ProfileToken 'B' (TokenOf 'B') $false
Check 'storing the same token keeps the cached readings' ((Test-Path (Join-Path (Join-Path $Root 'B') 'usage-cache.json')) -and (Test-Path (Join-Path (Join-Path $Root 'B') 'usage-cache-fable.json')))
Save-ProfileToken 'B' 'sk-ant-oat01-SEATB-REPLACEDVALUE' $true
Check 'a replaced token clears the refusal marker' (($null -eq (Read-AccessDisabled 'B')) -and (TokenOf 'B') -eq 'sk-ant-oat01-SEATB-REPLACEDVALUE')
Check 'a replaced token drops the old token''s cached readings (a cap among them)' (-not (Test-Path (Join-Path (Join-Path $Root 'B') 'usage-cache.json')) -and -not (Test-Path (Join-Path (Join-Path $Root 'B') 'usage-cache-fable.json')))
Write-AccessDisabled -Label 'G'
Save-ProfileToken 'G' 'sk-ant-oat01-SEATG-NEWVALUE' $false
Check 'a first token on a seat with a stale marker clears it' ($null -eq (Read-AccessDisabled 'G'))
Reset-Case

# --- a refusal marker names the refused token by fingerprint and is ignored once the seat holds a different token ---
Check 'the fingerprint of "abc" is the literal the Python side asserts (SHA-256 first 16 hex)' ((Get-TokenFingerprint 'abc') -ceq 'ba7816bf8f01cfea')
$pyExe = (Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ($pyExe) {     # the two languages hash the same bytes: ASCII, and a non-ASCII string (UTF-8), computed by rotator_access.token_fingerprint
  $sandboxProfile = $env:USERPROFILE; $env:USERPROFILE = $envKeep['USERPROFILE']      # (PowerShell variables are case-insensitive: $root is $Root here, so keep the sandbox profile under its own name)
  # the py shim finds Python through the real profile
  try { $pyOut = & $pyExe -3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); from rotator_access import token_fingerprint as f; print(f('abc')); print(f('t\u00e9st-fake')); print(f('fake-' + 'x' * 40))" $PSScriptRoot } finally { $env:USERPROFILE = $sandboxProfile }
  $psOut = @((Get-TokenFingerprint 'abc'), (Get-TokenFingerprint ("t$([char]0xE9)st-fake")), (Get-TokenFingerprint ('fake-' + ('x' * 40))))
  Check 'PowerShell and Python fingerprint the same strings identically' ((@($pyOut) -join ',') -ceq ($psOut -join ',')) "py=$(@($pyOut) -join ',') ps=$($psOut -join ',')"
}
$fpOld = Get-TokenFingerprint (TokenOf 'B')
Write-AccessDisabled -Label 'B' -TokFp $fpOld
$mj = Get-Content (Join-Path (Join-Path $Root 'B') 'access-disabled.json') -Raw | ConvertFrom-Json
Check 'the marker records the refused token''s fingerprint, and no token' (($mj.tok -ceq $fpOld) -and $mj.tok.Length -eq 16 -and (NoSecrets (Join-Path (Join-Path $Root 'B') 'access-disabled.json')))
Check 'a marker is honoured while token.txt holds the refused token' ($null -ne (Read-AccessDisabled 'B'))
Set-Content -LiteralPath (Join-Path (Join-Path $Root 'B') 'token.txt') -Value 'sk-ant-oat01-SEATB-OTHERVALUE' -Encoding UTF8 -NoNewline
Check 'the same marker is ignored once token.txt holds another token' ($null -eq (Read-AccessDisabled 'B'))
Write-AccessDisabled -Label 'C'
Set-Content -LiteralPath (Join-Path (Join-Path $Root 'C') 'token.txt') -Value 'sk-ant-oat01-SEATC-OTHERVALUE' -Encoding UTF8 -NoNewline
Check 'a marker without tok (older code) is honoured whatever token.txt holds' (($null -eq (Get-Content (Join-Path (Join-Path $Root 'C') 'access-disabled.json') -Raw | ConvertFrom-Json).tok) -and ($null -ne (Read-AccessDisabled 'C')))
Write-AccessDisabled -Label 'E' -TokFp $fpOld
Remove-Item -LiteralPath (Join-Path (Join-Path $Root 'E') 'token.txt')
Check 'an unreadable (missing) token.txt keeps today''s behaviour: the marker is honoured' ($null -ne (Read-AccessDisabled 'E'))
$acr = ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'rotator-functions.ps1'), [ref]$null, [ref]$null)).Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-AccessCooldownActive' }, $true)
. ([scriptblock]::Create($acr.Extent.Text)); $ProfileHome = $env:USERPROFILE
Check 'the shell wrapper''s cooldown test follows the same rules (stale tok ignored, no tok honoured, missing token.txt honoured)' ((-not (Test-AccessCooldownActive 'B')) -and (Test-AccessCooldownActive 'C') -and (Test-AccessCooldownActive 'E'))
Write-AccessDisabled -Label 'F' -TokFp (Get-TokenFingerprint (TokenOf 'F'))
Check 'the shell wrapper''s cooldown test honours a marker for the token the seat holds' (Test-AccessCooldownActive 'F')
Reset-Case

# --- the race: --replace stores a healthy token (clearing the marker), then the OLD token's refusal lands late (the proxy's 15 s token cache, or a request in flight) ---
$fpX = Get-TokenFingerprint (TokenOf 'D')
Write-AccessDisabled -Label 'D' -TokFp $fpX
Save-ProfileToken 'D' 'sk-ant-oat01-SEATD-REPLACEDVALUE' $true
Check 'storing the replacement cleared the marker' ($null -eq (Read-AccessDisabled 'D'))
Write-AccessDisabled -Label 'D' -TokFp $fpX                      # the late write for the replaced token X recreates the file ...
Check '... the file is back' (Test-Path (Join-Path (Join-Path $Root 'D') 'access-disabled.json'))
Check '... but the seat holding the replacement is not treated as disabled' ($null -eq (Read-AccessDisabled 'D'))
$script:plan['D'] = 'ok'; $script:head['D'] = 0.10
$rd = Get-UsageCached 'D' $false 'haiku' '' $false $true
Check '... and its usage read is a real probe, not the cooldown answer' ($rd.access -eq 'ok' -and $rd.note -notmatch 'cooldown')
Write-AccessDisabled -Label 'D' -TokFp (Get-TokenFingerprint (TokenOf 'D'))
Check 'a refusal of the replacement itself still counts' ($null -ne (Read-AccessDisabled 'D'))
Reset-Case

# --- the watcher rotates on a fresh nested Fable-only proxy rejection, as a Fable cap, and leaves the session projection alone ---
$pingsBefore = $script:pings; $probeBefore = $global:ClaudeRotatorProbeOverride
# A's live Fable probe agrees with the rejection, as on a real capped seat.
$global:ClaudeRotatorProbeOverride = { param($Label, $Model)
  if ($Label -eq 'A' -and $Model -eq 'fable') {
    return [pscustomobject]@{ label = 'A'; ok = $true; access = 'ok'; http = 429; oi7_util = 1.0; oi7_stat = 'rejected'; status = 'rejected'; note = '' } }
  & $probeBefore $Label $Model }.GetNewClosure()
$tn = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$nestedFableRej = @{ ts = $tn - 900; observed_ms = ($tn - 900) * 1000
  data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; status = 'allowed'; s5_util = 0.2; w7_util = 0.3 }
  fable_cap = @{ ts = $tn; observed_ms = $tn * 1000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day_oi'; oi7_stat = 'rejected' } } }
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
$nestedFableRej | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
Check 'a fresh nested Fable-only rejection rotates the watcher off the seat' ((Get-ActiveLabel) -ne 'A') ("active=$(Get-ActiveLabel)")
Check '... and the ping names the fable limit' (($script:pings -join ' ') -match 'fable') ("pings=$($script:pings -join ' | ')")
$rlN = Join-Path $Root '.rotate-log.txt'
$logN = if (Test-Path -LiteralPath $rlN) { Get-Content -LiteralPath $rlN -Raw } else { '' }
Check '... and its trigger line leaves out the weekly % of a default reading older than the proxy freshness window' ($logN -match 'FABLE window REJECTED by the server \(claim seven_day_oi; Gate C cannot run\)') ("log=$logN")
$nestedFresh = $nestedFableRej.Clone(); $nestedFresh.ts = $tn; $nestedFresh.observed_ms = $tn * 1000
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
$nestedFresh | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$logN = if (Test-Path -LiteralPath $rlN) { Get-Content -LiteralPath $rlN -Raw } else { '' }
Check '... and with a fresh default reading the nested trigger line carries its weekly %' ($logN -match 'claim seven_day_oi; weekly 30%; ') ("log=$logN")
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
foreach ($l in 'B','C','D','E','F') { $script:plan[$l] = 'quota' }
@{ acct = 'A'; nextHaiku = 0; lastWorst = 55; lastTs = $tn - 300; fableBase = 0; fableTs = 0; nextFable = 0; rotations = @() } |
  ConvertTo-Json | Set-Content -LiteralPath $RotateState -Encoding UTF8
$nestedFableRej | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$stAfter = Get-Content $RotateState -Raw | ConvertFrom-Json
Check 'with no free seat the Fable-only rejection leaves the session projection state alone' ([int]$stAfter.lastWorst -eq 55 -and [int64]$stAfter.lastTs -eq ($tn - 300)) ("lastWorst=$($stAfter.lastWorst) lastTs=$($stAfter.lastTs)")
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
@{ ts = $tn; observed_ms = $tn * 1000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; oi7_stat = 'rejected'; oi7_reset = [string]($tn + 3600) } } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
Check 'a fresh top-level Fable-only rejection (no default reading) rotates the watcher off the seat' ((Get-ActiveLabel) -ne 'A') ("active=$(Get-ActiveLabel)")
Check '... and the ping names the fable limit' (($script:pings -join ' ') -match 'fable') ("pings=$($script:pings -join ' | ')")
# The production Fable 429 shape: 7d window allowed with utilization, overall and Fable windows rejected.
$wProd = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'seven_day_oi'
            w7_util = 0.62; w7_stat = 'allowed'; oi7_stat = 'rejected'; oi7_reset = [string]($tn + 3600) }
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
@{ ts = $tn; observed_ms = $tn * 1000; data = $wProd } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
Check 'a fresh production-shape Fable 429 rotates the watcher off the seat' ((Get-ActiveLabel) -ne 'A') ("active=$(Get-ActiveLabel)")
Check '... and the ping names the fable limit, not the session' (($script:pings -join ' ') -match 'fable' -and ($script:pings -join ' ') -notmatch 'session limit') ("pings=$($script:pings -join ' | ')")
$rlP = Join-Path $Root '.rotate-log.txt'
$logP = if (Test-Path -LiteralPath $rlP) { Get-Content -LiteralPath $rlP -Raw } else { '' }
Check '... and its trigger line keeps the weekly reading, and invents no Fable %, for usage history' ($logP -match 'FABLE window REJECTED by the server \(claim seven_day_oi; weekly 62%; ') ("log=$logP")
$wMeas = $wProd.Clone(); $wMeas.oi7_util = 0.2
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
@{ ts = $tn; observed_ms = $tn * 1000; data = $wMeas } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$logM = if (Test-Path -LiteralPath $rlP) { Get-Content -LiteralPath $rlP -Raw } else { '' }
Check '... and a measured Fable % rides the trigger line' ($logM -match 'claim seven_day_oi; fable 20%; weekly 62%; ') ("log=$logM")
$wBad = $wProd.Clone(); $wBad.w7_util = 'abc'; $wBad.oi7_util = 'NaN'
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
@{ ts = $tn; observed_ms = $tn * 1000; data = $wBad } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$logB = if (Test-Path -LiteralPath $rlP) { Get-Content -LiteralPath $rlP -Raw } else { '' }
Check 'malformed utilization headers on a Fable 429 still rotate, and stay out of the trigger line' ((Get-ActiveLabel) -ne 'A' -and $logB -match 'claim seven_day_oi; Gate C cannot run') ("active=$(Get-ActiveLabel) log=$logB")
# A sparse nested 429 whose Fable window says allowed (another limit rejected it) is not a Fable cap.
$sparse = @{ ts = $tn - 900; observed_ms = ($tn - 900) * 1000
  data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 200; status = 'allowed'; s5_util = 0.2; w7_util = 0.3 }
  fable_cap = @{ ts = $tn; observed_ms = $tn * 1000; data = @{ label = 'A'; ok = $true; src = 'proxy'; http = 429; status = 'rejected'; claim = 'five_hour'; oi7_stat = 'allowed' } } }
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
$sparse | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$logS = if (Test-Path -LiteralPath $rlP) { Get-Content -LiteralPath $rlP -Raw } else { '' }
Check 'a nested 429 whose Fable window says allowed is not reported as a Fable cap' ($logS -notmatch 'FABLE window REJECTED' -and ($script:pings -join ' ') -notmatch 'fable') ("log=$logS pings=$($script:pings -join ' | ')")
$sparse.fable_cap.data.oi7_stat = 'allowed_warning'
Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
$sparse | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
$null = Invoke-CheckRotate 0 $false $true 'test'
$logS = if (Test-Path -LiteralPath $rlP) { Get-Content -LiteralPath $rlP -Raw } else { '' }
Check '... nor one whose Fable window says allowed_warning' ($logS -notmatch 'FABLE window REJECTED' -and ($script:pings -join ' ') -notmatch 'fable') ("log=$logS pings=$($script:pings -join ' | ')")
# Renewed, on a healthy seat: no trigger at all, on a --now check and on a scheduled one (which reads the
# status-rewritten copy). Every seat is equally healthy here, so a wrong trigger would only 'stay put':
# assert on the trigger log line, not on which seat ends up active.
$global:ClaudeRotatorProbeOverride = $probeBefore
$wRenewed = $wProd.Clone(); $wRenewed.oi7_reset = [string]($tn - 60); $wRenewed.s5_util = 0.1; $wRenewed.s5_stat = 'allowed'
foreach ($forceNow in $true, $false) {
  Reset-Case; Clear-AppIdentity; Set-Active 'A'; $script:pings = @()
  $tr = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  @{ ts = $tr; observed_ms = $tr * 1000; data = $wRenewed } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Join-Path $Root 'A') 'usage-cache.json') -Encoding UTF8
  $null = Invoke-CheckRotate 0 $false $forceNow 'test'
  $rl = Join-Path $Root '.rotate-log.txt'
  $logText = if (Test-Path -LiteralPath $rl) { Get-Content -LiteralPath $rl -Raw } else { '' }
  Check "a renewed production-shape Fable 429 fires no trigger (forceNow=$forceNow)" ($logText -notmatch 'TRIGGER:' -and $script:pings.Count -eq 0 -and (Get-ActiveLabel) -eq 'A') ("active=$(Get-ActiveLabel) pings=$($script:pings -join ' | ') log=$logText")
  # --now probes live; a scheduled tick uses the rewritten copy and does not probe.
  $aProbes = if ($script:probes.ContainsKey('A')) { [int]$script:probes['A'] } else { 0 }
  if ($forceNow) { Check '... and --now probed A live instead of reading the rewritten copy' ($aProbes -ge 1) ("probes=$aProbes") }
  else { Check '... and the scheduled tick used the rewritten copy, with no live probe of A' ($aProbes -eq 0) ("probes=$aProbes") }
}
Reset-Case
$global:ClaudeRotatorProbeOverride = $probeBefore; $script:pings = $pingsBefore

# --- the claude wrapper's seat gate never blocks a credential command (every seat refused, the user adds a token) ---
$gd = Join-Path $root 'gate'; $gh = Join-Path $gd 'home'; $ga = Join-Path $gh '.claude-cli-accounts'
New-Item -ItemType Directory -Force -Path (Join-Path $ga 'B') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'rotator-functions.ps1') $gd
Set-Content -LiteralPath (Join-Path $gd 'claude-cli-account.ps1') -Value '# stand-in: --ensure-cli-seat finds nothing'
Set-Content -LiteralPath (Join-Path $ga '.active') -Value 'B' -NoNewline
@{ until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ga 'B\access-disabled.json')
# the stand-in claude.exe is a copy of the py launcher: `claude <name>` runs the script <name> here, which prints the token it was handed
$gb = Join-Path $gh '.local\bin'; New-Item -ItemType Directory -Force -Path $gb | Out-Null
$pyl = (Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ($pyl) { Copy-Item $pyl (Join-Path $gb 'claude.exe') }
foreach ($n in 'setup-token', 'auth', 'run') { Set-Content -LiteralPath (Join-Path $gd $n) -Value 'import os; print("TOKEN=" + os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "-"))' }
Set-Content -LiteralPath (Join-Path $ga 'B\token.txt') -Value 'sk-ant-oat01-SEATB-TOKENVALUE' -NoNewline
# (the wrapper's paths come from USERPROFILE at dot-source time; the py shim then needs the real one back to find Python)
$gate = { param($a) & pwsh -NoProfile -NonInteractive -Command "Set-Location '$gd'; `$env:USERPROFILE = '$gh'; `$env:CLAUDE_ROTATOR_PROXY = '0'; `$env:CLAUDE_CODE_OAUTH_TOKEN = 'inherited'; . '$gd\rotator-functions.ps1'; `$env:USERPROFILE = '$($envKeep['USERPROFILE'])'; claude $a" 2>&1 | Out-String }
Check 'a refused seat still stops a normal start' ((& $gate '--version') -match 'Not starting Claude Code')
$gateRc = { param($a) & pwsh -NoProfile -NonInteractive -Command "Set-Location '$gd'; `$env:USERPROFILE = '$gh'; `$env:CLAUDE_ROTATOR_PROXY = '0'; . '$gd\rotator-functions.ps1'; `$env:USERPROFILE = '$($envKeep['USERPROFILE'])'; `$global:LASTEXITCODE = 0; claude $a; 'LEC=' + `$LASTEXITCODE" 2>&1 | Out-String }
Check 'a refused seat leaves LASTEXITCODE at 1 (not the 0 of the seat probe)' ((& $gateRc '--version') -match 'LEC=1')
Check 'a credential word that is not the first argument is still gated' ((& $gate '-p login') -match 'Not starting Claude Code')
Check '/login is never gated' ((& $gate '/login') -notmatch 'Not starting Claude Code')
$st_ = & $gate 'setup-token'
Check 'setup-token is never gated, and is handed no token at all' ($st_ -notmatch 'Not starting Claude Code' -and (-not $pyl -or $st_ -match 'TOKEN=-')) $st_
$al_ = & $gate 'auth login'
Check 'auth login is never gated, and is handed no token at all' ($al_ -notmatch 'Not starting Claude Code' -and (-not $pyl -or $al_ -match 'TOKEN=-')) $al_
Check 'auth status is still gated' ((& $gate 'auth status') -match 'Not starting Claude Code')
@{ until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600; tok = (Get-TokenFingerprint 'sk-ant-oat01-SEATB-REPLACED') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ga 'B\access-disabled.json')
Check 'a marker for a replaced token does not stop a start' ((& $gate '--version') -notmatch 'Not starting Claude Code')
@{ until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600; tok = (Get-TokenFingerprint 'sk-ant-oat01-SEATB-TOKENVALUE') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ga 'B\access-disabled.json')
Check 'a marker for the token the seat holds still stops a start' ((& $gate '--version') -match 'Not starting Claude Code')
Remove-Item -LiteralPath (Join-Path $ga 'B\access-disabled.json')
Check 'a normal start on a healthy seat gets that seat token' (-not $pyl -or (& $gate 'run') -match 'TOKEN=sk-ant-oat01-SEATB-TOKENVALUE')

# --- the mocks took every machine-wide effect: the rotations above wrote nothing to HKCU and pinged no real session ---
Check 'rotations persisted the token through the mock only' (@($script:envWrites | Where-Object { $_[0] -eq $EnvName }).Count -ge 1) ("writes=$($script:envWrites.Count)")
Check 'access rotation pinged sessions through the mock only' ($script:pings.Count -ge 1) ("pings=$($script:pings.Count)")
$hkcuAfter = (Get-ItemProperty -Path 'HKCU:\Environment' -Name $EnvName -ErrorAction SilentlyContinue).$EnvName
Check 'HKCU:\Environment is untouched' ($hkcuAfter -eq $hkcuBefore)
} catch {
  # A throw skips every check after it: it is a failure, never a silent ALL PASSED.
  $fail++; Write-Host "  FAIL  the run threw, so the checks after it never ran: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
} finally {
  foreach ($n in $envKeep.Keys) { [Environment]::SetEnvironmentVariable($n, $envKeep[$n], 'Process') }
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "`n$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASSED" -ForegroundColor Green
exit 0
