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
  if ($Model -eq 'fable') {
    if ($plan -eq 'fable-disabled') {
      return [pscustomobject]@{ label=$Label; ok=$false; access='disabled'; http=403; code='oauth_org_not_allowed'; note='subscription disabled (403 oauth_org_not_allowed)' }
    }
    return [pscustomobject]@{ label=$Label; ok=$true; access='ok'; http=200; oi7_util=0.1; oi7_stat='allowed'; note='' }
  }
  if ($plan -eq 'disabled') {
    return [pscustomobject]@{
      label=$Label; ok=$false; access='disabled'; http=403; code='oauth_org_not_allowed'
      note='subscription disabled (403 oauth_org_not_allowed)'
    }
  }
  if ($plan -eq 'network') {
    return [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; note='probe failed: network; not marking disabled' }
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
function Probe-Usage { param([string]$Label, [string]$Model) <# MOCK-NO-NETWORK #> [pscustomobject]@{ label=$Label; ok=$false; access='unknown'; http=$null; code=$null; note='probe failed: network (mock)' } }
if ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK') { Write-Host 'ABORT: Probe-Usage is not the mock' -ForegroundColor Red; exit 2 }
$env:CLAUDE_ROTATOR_SELFTEST = '0'
try { Prefetch-Usage @('A','B') $true $true $true } finally { $env:CLAUDE_ROTATOR_SELFTEST = '1'; ${function:Probe-Usage} = $origProbe }
$memoKeys = @($script:UnknownProbeMemo.Keys | Sort-Object)
Check 'parallel probe failures land in the caller memo' (($memoKeys -join ',') -eq 'A|,A|-fable,B|,B|-fable') ($memoKeys -join ',')
Check 'Probe-Usage is the real one again' ((Get-Command Probe-Usage -CommandType Function).Definition -notmatch 'MOCK-NO-NETWORK')

# --- disabled active, everyone else unreachable: one fallback, no extra markers ---
Reset-Case
Clear-AppIdentity
Set-Active 'B'
$script:plan['B'] = 'disabled'
foreach ($l in @('A','C','D','E','F')) { $script:plan[$l] = 'network' }
$rc = Invoke-CheckRotate 0 $false $true 'test'
Check 'fallback picks the first unknown seat in label order (A)' ((Get-ActiveLabel) -eq 'A') (Get-ActiveLabel)
$marked = @(Get-ChildItem $Root -Recurse -Filter 'access-disabled.json' | ForEach-Object { $_.Directory.Name })
Check 'only the refused seat is marked' (($marked.Count -eq 1) -and ($marked[0] -eq 'B')) ($marked -join ',')
Check 'fallback did not hammer B' ($script:probes['B'] -eq 1) ("count=$($script:probes['B'])")

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

# --- the mocks took every machine-wide effect: the rotations above wrote nothing to HKCU and pinged no real session ---
Check 'rotations persisted the token through the mock only' (@($script:envWrites | Where-Object { $_[0] -eq $EnvName }).Count -ge 1) ("writes=$($script:envWrites.Count)")
Check 'access rotation pinged sessions through the mock only' ($script:pings.Count -ge 1) ("pings=$($script:pings.Count)")
$hkcuAfter = (Get-ItemProperty -Path 'HKCU:\Environment' -Name $EnvName -ErrorAction SilentlyContinue).$EnvName
Check 'HKCU:\Environment is untouched' ($hkcuAfter -eq $hkcuBefore)
} finally {
  foreach ($n in $envKeep.Keys) { [Environment]::SetEnvironmentVariable($n, $envKeep[$n], 'Process') }
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "`n$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASSED" -ForegroundColor Green
exit 0
