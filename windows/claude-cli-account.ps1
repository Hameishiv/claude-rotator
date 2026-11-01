<#
claude-cli-account.ps1  — switch the Claude CODE CLI between Anthropic accounts using
LONG-LIVED setup-tokens injected via the CLAUDE_CODE_OAUTH_TOKEN env var.

WHY THIS MODEL (and why the old token-file swap is gone)
  Interactive logins (`claude auth login`) revoke each other server-side, so swapping
  stored interactive tokens just yields "logged out". But `claude setup-token` mints a
  LONG-LIVED token that lives in a separate auth class and does NOT get revoked when you
  log into another account. Setting CLAUDE_CODE_OAUTH_TOKEN overrides stored credentials,
  so we just point that env var at whichever account's setup-token we want.

WHAT IT TOUCHES
  - It NEVER writes ~/.claude/.credentials.json, so the Supabase/Vercel MCP OAuth there
    is left intact (the local `supabase` MCP stays connected across switches).
  - It writes: profile token files (~/.claude-cli-accounts/<label>/token.txt), the .active
    pointer, and the USER-level CLAUDE_CODE_OAUTH_TOKEN env var (so VS Code + new terminals
    pick up the active account). The `claude` shell wrapper also injects it per-launch so an
    already-open terminal switches too.
  - Tokens are SECRETS: stored local-only, never printed. Don't push ~/.claude-cli-accounts.

USAGE
  claude-cli-account.ps1 --status
  claude-cli-account.ps1 --switch <label>     (case-insensitive; also: --account / just <label>)
  claude-cli-account.ps1 --rotate [label]     (a.k.a. --toggle: flip to the next account; with a
                                               label it just switches to it, same as --switch)
  claude-cli-account.ps1 --usage [--refresh]  (session 5h + weekly 7d + Fable 5 weekly usage for every account)
  claude-cli-account.ps1 --capture <label>    (paste a setup-token from `claude setup-token`)
  claude-cli-account.ps1 --import <label> <file>   (load a setup-token from a file)
  claude-cli-account.ps1 --clear              (unset the env var -> revert to stored login)
  claude-cli-account.ps1 --list

  To mint a token:  run `claude setup-token` (browser) while logged into that account,
  then `--capture <label>` and paste it.
#>

param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

$ErrorActionPreference = 'Continue'
$Root      = "$env:USERPROFILE\.claude-cli-accounts"
$Active    = Join-Path $Root '.active'
$EnvName   = 'CLAUDE_CODE_OAUTH_TOKEN'

# ---------- helpers ----------
function ShortHash { param([string]$s); if (-not $s) { return '(none)' }
  $h=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s)); (([BitConverter]::ToString($h)) -replace '-','').Substring(0,12).ToLower() }
function Get-Candidates { @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch '^[_.]' -and (Test-Path (Join-Path $_.FullName 'token.txt')) } | ForEach-Object { $_.Name } | Sort-Object) }
function Resolve-Label { param([string]$l); if (-not $l) { return $null }
  $hit = Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $l } | Select-Object -First 1
  if ($hit) { $hit.Name } else { $l } }
function Profile-Email { param([string]$l); $f = Join-Path (Join-Path $Root $l) 'email.txt'; if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '(no email)' } }
function Profile-TokenFile { param([string]$l); Join-Path (Join-Path $Root $l) 'token.txt' }
function Profile-TokenHash { param([string]$l); $f = Profile-TokenFile $l; if (Test-Path $f) { ShortHash (Get-Content $f -Raw).Trim() } else { '(none)' } }
function Get-ActiveLabel { if (Test-Path $Active) { (Get-Content $Active -Raw).Trim() } else { $null } }

# Write the active account's setup-token into ~/.claude/.credentials.json too, so that
# app-spawned / desktop-app-bridged Claude Code sessions follow the switch. Those sessions
# read this file and IGNORE CLAUDE_CODE_OAUTH_TOKEN, so the env var alone never switched them.
# Auth-only: leaves skills, MCP connectors, and session logs untouched. Backs up first.
function Set-DiskCredential {
  param([string]$Token)
  $cred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
  if (-not (Test-Path $cred)) {
    Write-Host "  note: ~/.claude/.credentials.json not found — terminal sessions still switch via the env var," -ForegroundColor DarkYellow
    Write-Host "        but app-spawned sessions need a one-time interactive 'claude' login to create it first." -ForegroundColor DarkYellow
    return
  }
  try {
    $bkDir = Join-Path $Root '.cred-backups'; New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    Copy-Item -LiteralPath $cred -Destination (Join-Path $bkDir ("credentials-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
    Get-ChildItem $bkDir -Filter 'credentials-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 12 | Remove-Item -Force -ErrorAction SilentlyContinue
    $j = Get-Content -LiteralPath $cred -Raw | ConvertFrom-Json
    if (-not $j.claudeAiOauth) { Write-Host "  note: .credentials.json has no claudeAiOauth block — skipped disk-cred swap." -ForegroundColor DarkYellow; return }
    $j.claudeAiOauth.accessToken = $Token
    $j.claudeAiOauth.expiresAt   = [int64][DateTimeOffset]::UtcNow.AddYears(10).ToUnixTimeMilliseconds()
    if ($j.claudeAiOauth.PSObject.Properties.Name -contains 'refreshToken') { $j.claudeAiOauth.refreshToken = '' }
    # Temp file + one replace: a crash mid-write must not truncate the credentials file (Grok review 2026-10-30).
    $tmp = "$cred.tmp-$PID"; [IO.File]::WriteAllText($tmp, ($j | ConvertTo-Json -Depth 20)); [IO.File]::Move($tmp, $cred, $true)
    Write-Host "  + updated ~/.claude/.credentials.json — app-spawned & desktop-bridged sessions follow too (new sessions)." -ForegroundColor DarkGreen
  } catch {
    Write-Host "  WARN: could not update ~/.claude/.credentials.json ($($_.Exception.Message)). Terminal switch still applied." -ForegroundColor DarkYellow
  }
}

# [Environment]::SetEnvironmentVariable(...,'User') took 48 SECONDS on this machine (measured
# 2026-08-13, 27 top-level windows) — that, not the API probes, was the bulk of a switch. The
# registry write is instant; what costs is what .NET does afterwards, broadcasting
# WM_SETTINGCHANGE with SendMessageTimeout and WAITING on every top-level window in turn
# (~1s each for anything busy — Electron apps, VS Code, the Claude app).
# So: write the same registry value, then fire the SAME notification with SendNotifyMessage,
# which is fire-and-forget. Explorer still receives it, so terminals and VS Code launched from
# the taskbar inherit the new token exactly as before — we just don't block on 27 windows.
function Set-UserEnvFast {
  param([string]$Name, [string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { Remove-ItemProperty -Path 'HKCU:\Environment' -Name $Name -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path 'HKCU:\Environment' -Name $Name -Value $Value -Type String }
  try {
    if (-not ('RotatorNative.EnvBcast' -as [type])) {
      Add-Type -Name EnvBcast -Namespace RotatorNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool SendNotifyMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam);
'@
    }
    # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x1A
    [void][RotatorNative.EnvBcast]::SendNotifyMessage([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'Environment')
  } catch {
    # Registry is already written, so the switch holds for anything started after a re-login.
    Write-Host "  note: env-change broadcast failed ($($_.Exception.Message)); already-open Explorer may hand old token to NEW terminals." -ForegroundColor DarkYellow
  }
}

function Apply-Active {
  param([string]$Label)
  $tf = Profile-TokenFile $Label
  if (-not (Test-Path $tf)) { Write-Host "No token for profile '$Label'. Run --capture $Label (or --import $Label <file>) first." -ForegroundColor Red; return 1 }
  $tok = (Get-Content $tf -Raw).Trim()
  if (-not $tok) { Write-Host "Profile '$Label' token.txt is empty." -ForegroundColor Red; return 1 }
  $Label | Set-Content -LiteralPath $Active -Encoding UTF8
  Set-UserEnvFast $EnvName $tok                                   # VS Code + new terminals
  [Environment]::SetEnvironmentVariable($EnvName, $tok, 'Process') # this process too
  Set-DiskCredential $tok   # app-spawned/desktop-bridged sessions read ~/.claude/.credentials.json, not the env var
  Write-Host "Active CLI account -> '$Label' ($(Profile-Email $Label))." -ForegroundColor Green
  Write-Host "  New terminals + VS Code use it immediately; in an already-open terminal, just type `claude` (the wrapper re-reads it)." -ForegroundColor Cyan
  return 0
}

# ---------- usage (server-side per-account rate-limit windows) ----------
# Anthropic returns the live "session" (5h) and "weekly" (7d) utilization as
# anthropic-ratelimit-unified-* headers on a real /v1/messages response. There is no
# free endpoint for it (count_tokens carries no usage headers, and the setup-token
# lacks the user:profile scope the /oauth/usage endpoint needs), so we read it from a
# minimal 1-token haiku call per account. A capped account returns 429 and runs no
# inference, so probing it costs nothing; an allowed account costs ~9 tokens.
# The probe must LOOK like Claude Code (system prompt + claude-code beta + claude-cli UA):
# haiku tolerates a bare OAuth call, but claude-fable-5 rejects one with a headerless
# generic 429 ("rate_limit_error: Error") — that gate, not the rate limiter, is what made
# the fable column read "n/a" until 2026-07-09.
# Cache TTLs — deliberately separate, because the two probes cost wildly different amounts of
# time and report windows that move at wildly different speeds. The haiku probe answers in ~1s
# and reports a 5h rolling window; the fable probe reports a 7-DAY window and spends 6-11s
# queued server-side before it even returns headers (measured 2026-08-13 on all 5 accounts;
# streaming + ResponseHeadersRead does NOT help, so the wait is admission, not generation).
# A shared 60s TTL meant essentially every invocation re-probed all of it.
$UsageTTL = 300    # seconds — session(5h) + weekly(7d), from the haiku probe
# 1800 is doing double duty (owner, 2026-08-16): it is the display cache AND the watcher's fable
# polling interval. Invoke-CheckRotate asks for a CACHED fable reading each tick, so the probe
# only actually fires once this has expired — a 30-min cadence with no counter to keep. It
# self-throttles further: a --best or --usage run refreshes the same file, and the watcher then
# spends nothing. 30 min stale on a 7-DAY bucket is well under 1% drift.
$FableTTL = 1800   # seconds — fable's own 7d window; also the auto-rotate fable poll interval

function Resolve-ProbeCatalogModel {
  param($Catalog, [string]$Family)
  if ($Catalog.has_more -ne $false) { throw 'Incomplete model catalog' }
  $ranked = foreach ($entry in $Catalog.data) {
    if ($entry.id -notmatch "^claude-$Family-(\d+(?:-\d+)*)$") { continue }
    $parts = @($Matches[1].Split('-'))
    if ($parts[-1] -match '^\d{8}$') { $parts = @($parts | Select-Object -SkipLast 1) }
    if ($parts.Count -eq 0 -or $parts.Count -gt 8) { throw 'Invalid model version' }
    $version = (@($parts | ForEach-Object { '{0:D8}' -f [int]$_ }) -join '') + ('00000000' * (8 - $parts.Count))
    [pscustomobject]@{ id=$entry.id; version=$version; created_at=$entry.created_at }
  }
  $current = @($ranked | Sort-Object version,created_at -Descending | Select-Object -First 1)
  if ($current.Count -ne 1) { throw 'No current model for usage probe family' }
  return $current[0].id
}

function Probe-Usage {
  param([string]$Label, [string]$Model = 'haiku')
  $tf = Profile-TokenFile $Label
  if (-not (Test-Path $tf)) { return [pscustomobject]@{ label=$Label; ok=$false; note='no token' } }
  $tok = (Get-Content $tf -Raw).Trim()
  if (-not $tok) { return [pscustomobject]@{ label=$Label; ok=$false; note='empty token' } }
  $hdr  = @{ Authorization = "Bearer $tok"; 'anthropic-version' = '2023-06-01'
             'anthropic-beta' = 'oauth-2025-04-20,claude-code-20250219'
             'User-Agent' = 'claude-cli/2.1.287 (external, cli)' }   # ponytail: hardcoded; the fable gate rejects UAs older than its minimum (2.1.251 on 2026-10-02) -- bump to `claude --version` when fable reads n/a with http 400
  # Live discovery precedes the one-token usage probe; failure spends nothing.
  try {
    if ($Model -notin @('haiku','fable')) { throw 'Usage probes require a family selector' }
    $catalog = Invoke-RestMethod -Method Get -Uri 'https://api.anthropic.com/v1/models?limit=100' -Headers $hdr -TimeoutSec 12
    $Model = Resolve-ProbeCatalogModel $catalog $Model
  } catch {
    return [pscustomobject]@{ label=$Label; ok=$false; note='model discovery failed; no inference' }
  }
  $body = (@{ model=$Model; max_tokens=1
              system=@(@{ type='text'; text="You are Claude Code, Anthropic's official CLI for Claude." })
              messages=@(@{ role='user'; content='.' }) } | ConvertTo-Json -Depth 6 -Compress)
  try {
    $r = Invoke-WebRequest -SkipHttpErrorCheck -Method Post -Uri 'https://api.anthropic.com/v1/messages' `
           -Headers $hdr -Body $body -ContentType 'application/json' -TimeoutSec 12
  } catch {
    return [pscustomobject]@{ label=$Label; ok=$false; note=("probe failed: " + $_.Exception.Message) }
  }
  # $get reads one header value (PS7 returns header values as string arrays). Named to
  # avoid the single-letter `h` -> Get-History alias collision.
  $get = { param($k) $v = $r.Headers[$k]; if ($null -eq $v) { $null } elseif ($v -is [array]) { [string]$v[0] } else { [string]$v } }
  $s5util = (& $get 'anthropic-ratelimit-unified-5h-utilization')
  # A non-2xx (model not on this plan, ZDR-blocked, etc.) still lands here — Invoke-WebRequest
  # with -SkipHttpErrorCheck never throws on it — but carries no ratelimit headers. Surface the
  # API's error message instead of a bare "n/a" so a missing model isn't indistinguishable from
  # a real probe failure.
  $note = ''
  if (-not $s5util) {
    $note = "http $([int]$r.StatusCode)"
    try { $e = ($r.Content | ConvertFrom-Json).error; $note += ": $($e.type): $($e.message)" } catch {}
  }
  [pscustomobject]@{
    label    = $Label; ok = $true; http = [int]$r.StatusCode; model = $Model; note = $note
    org      = (& $get 'anthropic-organization-id')
    status   = (& $get 'anthropic-ratelimit-unified-status')
    s5_util  = $s5util
    s5_stat  = (& $get 'anthropic-ratelimit-unified-5h-status')
    s5_reset = (& $get 'anthropic-ratelimit-unified-5h-reset')
    w7_util  = (& $get 'anthropic-ratelimit-unified-7d-utilization')
    w7_stat  = (& $get 'anthropic-ratelimit-unified-7d-status')
    w7_reset = (& $get 'anthropic-ratelimit-unified-7d-reset')
    # Fable/Mythos-tier weekly window; only present when the probed model is claude-fable-5
    oi7_util  = (& $get 'anthropic-ratelimit-unified-7d_oi-utilization')
    oi7_stat  = (& $get 'anthropic-ratelimit-unified-7d_oi-status')
    oi7_reset = (& $get 'anthropic-ratelimit-unified-7d_oi-reset')
    claim    = (& $get 'anthropic-ratelimit-unified-representative-claim')
  }
}

function Get-UsageCached {
  param([string]$Label, [bool]$Refresh, [string]$Model = 'haiku', [string]$CacheSuffix = '', [bool]$CacheOnly = $false)
  $cf  = Join-Path (Join-Path $Root $Label) "usage-cache$CacheSuffix.json"
  $ttl = if ($Model -like '*fable*') { $FableTTL } else { $UsageTTL }
  $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if (-not $Refresh -and (Test-Path $cf)) {
    try {
      $c = Get-Content $cf -Raw | ConvertFrom-Json
      if ($c.ts -and (($now - [int64]$c.ts) -le $ttl)) {
        $d = $c.data; $d | Add-Member -NotePropertyName ageSec -NotePropertyValue ([int]($now - [int64]$c.ts)) -Force
        return $d
      }
    } catch {}
  }
  # CacheOnly = a switch/rotate readout. It must never pay for a live probe (see Show-Usage).
  if ($CacheOnly) { return [pscustomobject]@{ label=$Label; ok=$false; note='not probed (run claude-usage)' } }
  $d = Probe-Usage $Label $Model
  $d | Add-Member -NotePropertyName ageSec -NotePropertyValue 0 -Force
  if ($d.ok) { try { @{ ts=$now; data=$d } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cf -Encoding UTF8 } catch {} }
  return $d
}

# Fire every probe at once instead of one at a time. Ten serial round-trips (2 per account)
# took ~27s for 5 accounts, dominated by the fable probes' server-side queueing; concurrently
# the wall clock is the slowest SINGLE probe (~8-11s). Each worker writes the very same cache
# file Get-UsageCached would have written, so the ordered print loop below then just reads
# cache hits — no duplicated probe logic, and nothing to keep in sync.
function Prefetch-Usage {
  param([string[]]$Labels, [bool]$Refresh, [bool]$WithFable = $true)
  $fnText = ('Profile-TokenFile','Resolve-ProbeCatalogModel','Probe-Usage','Get-UsageCached' |
    ForEach-Object { "function $_ {" + (Get-Command $_ -CommandType Function).Definition + "}" }) -join "`n"
  $models = @(@{ m='haiku'; s='' })
  if ($WithFable) { $models += @{ m='fable'; s='-fable' } }
  $work = @(foreach ($l in $Labels) { foreach ($mm in $models) { @{ l=$l; m=$mm.m; s=$mm.s } } })
  $work | ForEach-Object -ThrottleLimit 12 -Parallel {
    # Re-create what the probe needs inside the runspace: -Parallel starts a clean session,
    # so script-scope functions and variables are NOT inherited.
    $Root = $using:Root; $UsageTTL = $using:UsageTTL; $FableTTL = $using:FableTTL
    . ([scriptblock]::Create($using:fnText))
    $null = Get-UsageCached $_.l $using:Refresh $_.m $_.s
  } | Out-Null
}

function UsageBar { param([double]$frac, [int]$width=10)
  if ($frac -lt 0) { $frac = 0 }; if ($frac -gt 1) { $frac = 1 }
  $f = [int][math]::Round($frac * $width); ('#' * $f) + ('-' * ($width - $f)) }

function RelReset { param($epoch)
  if (-not $epoch) { return '?' }
  $secs = [int64]$epoch - [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($secs -le 0) { return 'now' }
  $d=[math]::Floor($secs/86400); $h=[math]::Floor(($secs%86400)/3600); $m=[math]::Floor(($secs%3600)/60)
  if ($d -ge 1) { '{0}d{1}h' -f $d,$h } elseif ($h -ge 1) { '{0}h{1}m' -f $h,$m } else { '{0}m' -f $m } }

# Renewal time: countdown + the actual local clock time the window resets at.
function FmtReset { param($epoch)
  if (-not $epoch) { return '(unknown)' }
  $secs = [int64]$epoch - [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($secs -le 0) { return 'available now' }
  $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).LocalDateTime
  $abs = if     ($local.Date -eq (Get-Date).Date)            { $local.ToString('HH:mm') }
         elseif ($local.Date -eq (Get-Date).AddDays(1).Date) { 'tomorrow ' + $local.ToString('HH:mm') }
         else                                                { $local.ToString('ddd MMM d, HH:mm') }
  'in {0} ({1})' -f (RelReset $epoch), $abs }

function StatColor { param([string]$s)
  switch ($s) { 'allowed' { 'Green' } 'allowed_warning' { 'Yellow' } 'rejected' { 'Red' } default { 'Gray' } } }

function Show-Usage {
  # CacheOnly: the readout tacked onto --switch/--rotate. Switching accounts is a 0.1s file
  # write; making it wait on ~10 live API probes is what turned an instant command into a
  # ~27s one. So a switch prints whatever the last `claude-usage` read and never probes.
  # `claude-usage` / --usage / --refresh still do a full live read.
  param([bool]$Refresh = $false, [bool]$CacheOnly = $false)
  $cands = Get-Candidates
  $act   = Get-ActiveLabel
  if (-not $cands) { Write-Host "No profiles with tokens to report usage for (use --capture <label>)." -ForegroundColor Yellow; return }
  if ($CacheOnly) {
    $anyFresh = @($cands | Where-Object { (Get-UsageCached $_ $false 'haiku' '' $true).ok }).Count
    if (-not $anyFresh) { Write-Host "  (usage not shown - nothing cached; run claude-usage for a live read)" -ForegroundColor DarkGray; return }
  } else {
    Prefetch-Usage $cands $Refresh
    # The prefetch just wrote every cache file. Leaving $Refresh set here would make the
    # ordered print loop below ignore those files and probe all ten AGAIN, serially — which
    # is exactly the cost the prefetch exists to remove.
    $Refresh = $false
  }
  Write-Host ""
  Write-Host "CLI usage  (session = 5h rolling window  -  weekly = 7d window  -  fable = Claude Fable 5's own weekly window  -  live from Anthropic)" -ForegroundColor Cyan
  foreach ($l in $cands) {
    $u  = Get-UsageCached $l $Refresh 'haiku' '' $CacheOnly
    $fu = Get-UsageCached $l $Refresh 'fable' '-fable' $CacheOnly
    $marker = if ($l -eq $act) { '>' } else { ' ' }
    Write-Host ("  {0} " -f $marker) -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,-8} " -f $l) -NoNewline
    if (-not $u.ok) { Write-Host $u.note -ForegroundColor DarkYellow; continue }
    $p5 = [int][math]::Round([double]$u.s5_util * 100)
    $p7 = [int][math]::Round([double]$u.w7_util * 100)
    Write-Host ("session [{0}] {1,3}%   " -f (UsageBar ([double]$u.s5_util)), $p5) -NoNewline -ForegroundColor (StatColor $u.s5_stat)
    Write-Host ("weekly [{0}] {1,3}%" -f (UsageBar ([double]$u.w7_util)), $p7) -NoNewline -ForegroundColor (StatColor $u.w7_stat)
    $flag = switch ($u.status) { 'rejected' { ' CAPPED' } 'allowed_warning' { ' !' } default { '' } }
    if ($flag) { Write-Host $flag -NoNewline -ForegroundColor (StatColor $u.status) }
    Write-Host "   " -NoNewline
    # Fable's own weekly window is the 7d_oi bucket on a fable-model probe; the plain 7d
    # headers on that same response are the all-models weekly (already shown) — don't reuse them.
    if ($fu.ok -and $null -ne $fu.oi7_util) {
      $pf = [int][math]::Round([double]$fu.oi7_util * 100)
      Write-Host ("fable [{0}] {1,3}%" -f (UsageBar ([double]$fu.oi7_util)), $pf) -NoNewline -ForegroundColor (StatColor $fu.oi7_stat)
      $fflag = switch ($fu.oi7_stat) { 'rejected' { ' CAPPED' } 'allowed_warning' { ' !' } default { '' } }
      if ($fflag) { Write-Host $fflag -NoNewline -ForegroundColor (StatColor $fu.oi7_stat) }
    } else {
      Write-Host ("fable n/a" + $(if ($fu.note) { " ($($fu.note))" } else { '' })) -NoNewline -ForegroundColor DarkGray
    }
    # >=30s only: after a parallel prefetch every line is a few seconds old by definition,
    # and "(cached 3s)" on a freshly-probed row reads like it didn't refresh.
    if ($u.ageSec -ge 30) { Write-Host ("  (cached {0}s)" -f [int]$u.ageSec) -NoNewline -ForegroundColor DarkGray }
    Write-Host ""
    $renew = "             renews  session {0}    weekly {1}" -f (FmtReset $u.s5_reset), (FmtReset $u.w7_reset)
    if ($fu.ok -and $fu.oi7_reset) { $renew += "    fable {0}" -f (FmtReset $fu.oi7_reset) }
    Write-Host $renew -ForegroundColor DarkGray
  }
  if ($CacheOnly) { Write-Host ("  (cached read - --status / claude-usage probe live; cache holds {0}s session/weekly, {1}s fable)" -f $UsageTTL, $FableTTL) -ForegroundColor DarkGray }
  else            { Write-Host  "  (live read - MEASURED 23 haiku + 32 fable tokens per allowed account)" -ForegroundColor DarkGray }
}

# ---------- pick the account with the most headroom ----------
# What interrupts work is whichever window is nearest its wall, so an account scores by the
# WORSE of its two: max(session, weekly). That ranks the weekly window correctly (it costs you
# DAYS, not hours) without inventing a weighting knob to tune. An account the server is already
# rejecting is excluded outright, not merely ranked last.
# Fable's own weekly window is deliberately NOT in the score — it only matters if the work is
# going to use Fable — but it is displayed, and a winner with a capped fable is called out.
# Mirrors codex_failover_review.py's pick_account in spirit; the Claude side had no equivalent,
# which is why bare --rotate happily cycles you onto a capped seat.
# Which seat is the DESKTOP APP logged into? That seat is never a CLI rotation target (owner,
# 2026-08-16): the app and the CLI would draw on ONE account's quota, so rotating onto it burns
# that seat twice as fast and takes the app down together with the CLI.
# Ground truth is the app's live account uuid in %APPDATA%\Claude\config.json.
# claude-app-rotator.ps1 is emphatic that its own .active pointer DRIFTS whenever you log in or
# out inside the app by hand, so .active is only the fallback for a uuid matching no captured seat.
function Get-AppSeatLabel {
  $appRoot = Join-Path $env:USERPROFILE '.claude-app-seats'
  $cfg     = Join-Path $env:APPDATA 'Claude\config.json'
  $uuid    = ''
  if (Test-Path $cfg) {
    try { $j = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
          if ($j.ContainsKey('lastKnownAccountUuid')) { $uuid = [string]$j['lastKnownAccountUuid'] } } catch {}
  }
  if ($uuid) {
    foreach ($p in (Get-ChildItem $appRoot -Directory -EA SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' })) {
      $f = Join-Path $p.FullName 'owner-uuid.txt'
      if ((Test-Path $f) -and ((Get-Content $f -Raw).Trim() -eq $uuid)) { return $p.Name }
      $m = Join-Path $p.FullName 'meta.txt'      # seats captured before owner-uuid.txt existed
      if ((Test-Path $m) -and ((Get-Content $m -Raw) -match [regex]::Escape("uuid=$uuid"))) { return $p.Name }
    }
  }
  $act = Join-Path $appRoot '.active'
  if (Test-Path $act) { return (Get-Content $act -Raw).Trim() }
  return ''
}

function Rank-Accounts {
  param([bool]$Refresh = $true, [bool]$WithFable = $true)
  $cands = Get-Candidates
  if (-not $cands) { return @() }
  $appSeat = Get-AppSeatLabel
  Prefetch-Usage $cands $Refresh $WithFable
  $rows = foreach ($l in $cands) {
    $u  = Get-UsageCached $l $false
    $fu = if ($WithFable) { Get-UsageCached $l $false 'fable' '-fable' }
          else { [pscustomobject]@{ ok = $false; note = 'not probed' } }
    if (-not $u.ok) { [pscustomobject]@{ label=$l; usable=$false; why=$u.note; score=9 }; continue }
    $s5 = [double]$u.s5_util; $w7 = [double]$u.w7_util
    $capped = ($u.s5_stat -eq 'rejected') -or ($u.w7_stat -eq 'rejected') -or ($u.status -eq 'rejected')
    # A fable-capped account is NOT a rotation target (owner, 2026-08-16): Fable is what runs
    # merge-pr's Gate C, so landing on a seat that cannot run Fable trades one blocked pipeline
    # for another. An UNKNOWN fable reading is deliberately treated as not-capped — excluding on
    # a probe hiccup would wedge rotation entirely, which is the worse failure.
    $fCapped = ($fu.ok -and $fu.oi7_stat -eq 'rejected')
    $isApp   = ($appSeat -and ($l -ieq $appSeat))
    $why = if ($isApp) { 'claude-account (desktop app) is on this seat' }
           elseif ($capped -and $fCapped) { 'capped + fable capped' }
           elseif ($capped) { 'capped' }
           elseif ($fCapped) { 'fable capped (needed for Gate C)' } else { '' }
    [pscustomobject]@{
      label = $l; usable = (-not $capped -and -not $fCapped -and -not $isApp); why = $why
      w7reset = $(if ($u.w7_reset) { [int64]$u.w7_reset } else { [int64]::MaxValue })
      score = [math]::Max($s5, $w7); s5 = $s5; w7 = $w7
      fable = $(if ($fu.ok -and $null -ne $fu.oi7_util) { [double]$fu.oi7_util } else { $null })
      fableCapped = $fCapped
    }
  }
  # Rank on the SESSION window alone. Weekly is no longer a reason to avoid an account (it is
  # cap-only now), and sorting by max(session,weekly) actively penalised a high-weekly account —
  # exactly backwards from "burn weekly through to 100%".
  @($rows | Sort-Object @{ e = { -not $_.usable } }, s5)
}

# ---------- automatic rotation (--check-rotate, driven by a scheduled task) ----------
# One SHOT per tick, not a resident loop: a loop dies at reboot, orphans, and needs supervising.
# Steady-state cost is ONE haiku probe of the ACTIVE account (~1s, ~9 tokens). The full
# all-accounts rank — which needs a fable probe each, and fable tokens are the scarce ones — runs
# only when the threshold has actually tripped, which should be a few times a week, not 288 times
# a day. Probing every account every tick would have burned ~46k fable tokens/day against the
# very windows this is meant to protect.
$RotateLog       = Join-Path $Root '.rotate-log.txt'
$RotateLastCheck = Join-Path $Root '.rotate-last-check'
$RotateState     = Join-Path $Root '.rotate-state.json'

# POLICY (owner, 2026-08-16). Three windows, three completely different treatments:
#
#   session (5h)  PROACTIVE. Rotate at $SessionAt, before the wall. Unused session quota is not
#                 really lost - the window refills in hours and you come back to it - so rotating
#                 early is close to free, which is what buys the margin below.
#   weekly (7d)   CAP-ONLY. Burn it to 100% and rotate only once the server rejects. Rotating a
#                 weekly window early WASTES it: it does not refill for days.
#   fable (7d)    CAP-ONLY, same reasoning.
#
# Flat intervals, no ramping as the wall approaches. That ramping existed to protect a bar set
# close to 100%; with a bar at $SessionAt there is a large margin of error and nothing to protect
# against, so the extra probes bought nothing. Deleted rather than tuned.
#
# ⚠ "large margin of error" held at the burn rates of 2026-08. It does not hold at ~1-3 points per
# minute, where one probe interval burns MORE than the whole 10-point margin and the seat is at
# 104% the first time anyone looks. The answer is NOT to reinstate ramping (probe frequency is
# still flat, still one haiku per tick): Invoke-CheckRotate now reads the SLOPE between the two
# samples it already has and trips the same $SessionAt bar on the projected value. Zero extra
# probes, zero extra tokens, and it self-tunes — idle days still rotate at 90%.
# 75, LOWERED from 90 by the owner 2026-09-23 ("I guess we have to lower the floor"), which is the
# remedy his original 90 reserved for itself — it was explicitly provisional, "if it fails, we'll
# lower", with the named trigger being a session capping before a rotation lands. It has now done
# that three times: 2026-09-20 05:06, 2026-09-22 10:06, and 2026-09-23 16:29 on seat C.
#
# Why a bar at all, and why this number. The projection below already handles FAST burn —
# 2026-09-22/23 logged clean rotations at 85%, 87%, 88% and 89% off burn rates of 0.7-2.3 %/min, so
# the bar is no longer what catches a spike. What the bar absorbs is a BLIND SPELL: the probe itself
# failing, which a projection cannot see through. Seat C burned a slow, steady ~0.34 %/min from 0%
# at 11:36 and capped at 16:29, with four logged `HttpClient.Timeout of 12 seconds` failures on the
# way (13:40, 13:47, 14:51, 16:00). At 90 the seat became trip-eligible at ~15:55 and the probe in
# that window — 16:00:41 — was one of the failures. The margin from bar to wall at that burn rate:
#
#     bar 90 -> 29 min      bar 85 -> 44 min      bar 75 -> 74 min      (worst blind spell: 29 min)
#
# 90 gave exactly the width of the spell, which is to say none. 85 clears it by a quarter of an
# hour. The owner picked 85 over the agent's first choice of 75 on 2026-09-23, on churn: 75 rotates
# every seat roughly 75 minutes earlier than 90 does and he judged that too many switches a day.
# That is a live trade, not a settled one — 85 is ~1.5x the worst observed spell where 75 was ~2.5x,
# so the retry above is now carrying more of the load than the bar is.
#
# The cost he accepted: an idle seat rotates with 15% of its session window unspent. It refills in
# ~5h and you come back to it, which is his own stated reason that rotating early "costs us nothing".
$SessionAt       = 85    # % - proactive bar, SESSION window only
# 240, NOT 300, and the 60s of slack is the whole point. The scheduled task fires every 300s, and
# $now is captured AFTER pwsh startup, which measured anywhere from 1s to 25s depending on machine
# load. With this at 300 the deadline lands within a second of the next tick, so whenever a tick
# starts faster than the one before it, $now < nextHaiku and the probe is SKIPPED for a further
# five minutes. Measured in .rotate-log.txt over 549 triggers: 321 correct 5-min gaps against 39
# of 10 min and 9 of 15-30 min — ~13% of probes silently lost, worst exactly when the machine is
# busy, i.e. when burn is fastest. The gate exists to stop over-probing if the task cadence ever
# changes; 240 still does that and no longer races the scheduler.
$SessionProbeSec = 240   # 4 min - one probe per 5-min task tick, with slack for startup jitter
$MinHeadroom     = 10    # points below the bar a seat needs before weekly-reset order applies
#
# FABLE — risk-armed, escalating, and never polled on a clock (owner, 2026-08-16).
# The baseline is always acquired FREE: Select-RotationTarget probes the candidate's Fable window
# on the way in, and --usage/--status/--best all write usage-cache-fable.json. The watcher reads
# that file; it never pays to discover where Fable stands, only to watch it once it matters.
#   distance = 100 - fable%.
#   distance > 20  -> DISARMED. No probe at all.
#   distance <= 20 -> ARMED, interval = 3 min per remaining point, floored at 15 min, ceiling 1h.
#                     80% -> 1h,  90% -> 30 min,  95% -> 15 min,  and NEVER more often than that.
#
# The slope is the owner's, and the reasoning is the point (2026-08-16): **we are not going to
# rotate out before Fable burns out anyway, so there is nothing to play safe against.** Detecting
# the cap up to 15 minutes late costs nothing real — a session waiting on Gate C simply waits.
# So the interval tracks the measured burn rate 1:1 (peak ~5 points per 15 min = ~0.33/min, i.e.
# ~3 min per point) instead of halving it for margin, which is what an earlier revision did.
# A capped account 429s INSTANTLY and spends nothing, so the only state that costs anything is
# "high but not yet capped".
$FableArmAt      = 20    # points from the cap at which periodic probing arms
$FableSecPerPt   = 180   # 3 min of interval per remaining point — tracks the burn rate 1:1
$FableMinSec     = 900   # never more often than every 15 min
$FableMaxSec     = 3600  # 1h at the arming line
#
# ⚠ NO safety net, by explicit choice (owner). While disarmed nothing re-reads Fable, so a seat
# that climbs past the arming line with no rotation and no manual --usage/--status/--best in
# between stays dark until one of those happens.

# The Fable baseline someone else already paid for: Select-RotationTarget on the way in, or any
# --usage/--status/--best. Reading it costs nothing, which is the whole point.
function Read-FableCache {
  param([string]$Label)
  $cf = Join-Path (Join-Path $Root $Label) 'usage-cache-fable.json'
  if (-not (Test-Path $cf)) { return $null }
  try {
    $c = Get-Content $cf -Raw | ConvertFrom-Json
    if ($c.data -and $null -ne $c.data.oi7_util) {
      return [pscustomobject]@{ pct = [int][math]::Round([double]$c.data.oi7_util * 100)
                                ts  = [int64]$c.ts
                                capped = ($c.data.oi7_stat -eq 'rejected') }
    }
  } catch {}
  return $null
}

function Save-RotateState { param($s)
  try { $s | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $RotateState -Encoding UTF8 } catch {} }

function Write-RotateLog {
  param([string]$Message, [string]$Colour = 'Gray')
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  try { Add-Content -LiteralPath $RotateLog -Value $line -Encoding UTF8 } catch {}
  Write-Host $line -ForegroundColor $Colour
}

# Three things can now ask for a check: the 5-minute task, the StopFailure hook (a session just
# hit a rate limit) and the local proxy (a request just got a quota 429). One at a time, or two
# of them rotate twice off the same reading.
function Invoke-CheckRotate {
  param([int]$Threshold = 0, [bool]$DryRun = $false, [bool]$ForceNow = $false, [string]$Source = '')
  $mx = New-Object System.Threading.Mutex($false, 'Global\claude-rotator-check')
  $got = $false
  try { $got = $mx.WaitOne(90000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { Write-RotateLog "another rotation check held the lock for 90s - skipped$(if ($Source) { " ($Source)" })" DarkYellow; $mx.Dispose(); return 0 }
  try { return (Invoke-CheckRotateCore $Threshold $DryRun $ForceNow $Source) }
  finally { $mx.ReleaseMutex(); $mx.Dispose() }
}

# Rotations allowed per window before the watcher stops and asks for a human (headroom's
# supervisor cap). Three in ten minutes means every seat is failing, not that one more will help.
$RotateCapCount  = 3
$RotateCapWindow = 600
# A usage reading the local proxy took off a real response, younger than this, replaces the probe.
$ProxyFreshSec   = 120

# The proxy writes the same usage-cache.json a probe does, tagged src=proxy. Fresh -> use it.
# -RejectedOnly (a --now check): something just hit a limit, possibly a session that does not go
# through the proxy, so a HEALTHY reading up to 2 min old must not overrule a live probe. Only a
# reading that already shows the rejection is good enough then (Grok review 2026-10-30, P1).
function Get-ProxySample {
  param([string]$Label, [bool]$RejectedOnly = $false)
  $cf = Join-Path (Join-Path $Root $Label) 'usage-cache.json'
  if (-not (Test-Path $cf)) { return $null }
  try {
    $c = Get-Content $cf -Raw | ConvertFrom-Json
    $age = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$c.ts
    $d = $c.data
    $rejected = ($d.status -eq 'rejected' -or $d.s5_stat -eq 'rejected' -or $d.w7_stat -eq 'rejected')
    if ($d.src -eq 'proxy' -and $d.ok -and ($d.s5_util -or $rejected) -and $age -le $ProxyFreshSec -and
        ($rejected -or -not $RejectedOnly)) { return $d }
  } catch {}
  return $null
}

function Invoke-CheckRotateCore {
  param([int]$Threshold = 0, [bool]$DryRun = $false, [bool]$ForceNow = $false, [string]$Source = '')
  $sessBar = if ($Threshold -gt 0) { $Threshold } else { $SessionAt }   # --threshold forces a trigger, for testing
  try { (Get-Date -Format 'o') | Set-Content -LiteralPath $RotateLastCheck -Encoding UTF8 } catch {}
  $act = Get-ActiveLabel
  if (-not $act) { Write-RotateLog "no active account set - nothing to monitor" DarkYellow; return 0 }
  $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

  $st = [ordered]@{ acct=''; nextHaiku=0; lastWorst=0; lastTs=0; fableBase=0; fableTs=0; nextFable=0; rotations=@() }
  if (Test-Path $RotateState) {
    try { $j = Get-Content $RotateState -Raw | ConvertFrom-Json
          foreach ($k in @($st.Keys)) { if ($null -ne $j.$k) { $st[$k] = $j.$k } } } catch {}
  }
  # A switch invalidates the schedule outright — the new account's numbers say nothing about the
  # old one's, so never inherit a "next probe in 30 min" earned by the account we just left.
  # A switch invalidates everything; the new seat's Fable baseline then re-seeds itself for free on
  # this very tick, because Select-RotationTarget wrote its usage-cache-fable.json on the way in.
  if ($st.acct -ne $act) { $st.acct = $act; $st.nextHaiku = 0; $st.lastWorst = 0; $st.lastTs = 0
                           $st.fableBase = 0; $st.fableTs = 0; $st.nextFable = 0 }
  # --now (StopFailure hook, proxy): something just hit a limit, so look immediately.
  if ($ForceNow) { $st.nextHaiku = 0 }

  $trigger = $null; $capped = $null
  if ($now -ge [int64]$st.nextHaiku) {
    # A reading the proxy took off real traffic in the last 2 min is as good as a probe, and free.
    $u = Get-ProxySample $act $ForceNow
    if (-not $u) { $u = Get-UsageCached $act $true }          # live, haiku only: ~1s, ~9 tokens
    # Retry ONCE before going blind. A failed probe is not a neutral event: it is the watcher losing
    # sight of the only window it rotates on, and the projection below cannot see through a sample
    # that never arrived. Seat C capped at 100% on 2026-09-23 with four logged 12-second
    # `HttpClient.Timeout` failures during the climb. The failures are transient — a retry costs at
    # most one more 12s timeout against a 5-minute tick, and ~9 tokens when it succeeds.
    if (-not $u.ok) { $u = Get-UsageCached $act $true }
    if (-not $u.ok) {
      Write-RotateLog "probe of '$act' failed twice ($($u.note)) - NOT rotating, blind until the next tick" DarkYellow
      # $SessionProbeSec, never a bare 300: the task ticks every 300s and $now is read after pwsh
      # startup, so a 300 here re-creates in the failure path exactly the race that was taken out of
      # the success path — the next tick lands a second short of the deadline and skips, turning one
      # failed probe into TEN minutes of blindness instead of five.
      $st.nextHaiku = $now + $SessionProbeSec; Save-RotateState $st; return 0
    }
    $s5 = [int][math]::Round([double]$u.s5_util * 100); $w7 = [int][math]::Round([double]$u.w7_util * 100)
    # Project the session window forward one probe interval before testing the bar. A bare level
    # test is a test on a sample that is already up to $SessionProbeSec stale, and the margin
    # between the bar and the wall is only (100 - $SessionAt) = 10 points. Measured burn on
    # 2026-09-20 was ~1 point/min (96->101 across one interval) and the 2026-09-22 10:06 event
    # needed >=14 points inside one interval: more than the entire margin. That is why the log
    # reads "session at 104% >= 90%" — the bar was not crossed late, it was jumped clean over,
    # and the seat was already 429ing by the time anything fired.
    # This buys the lookahead from the two samples we already pay for, so it adds no probe and no
    # tokens, and it does NOT reinstate the ramping the owner deleted — that ramped the probe
    # FREQUENCY; this leaves the cadence flat and only reads the slope. Rising samples only, so a
    # window reset (s5 drops) can never manufacture a rate.
    $rate = 0.0   # points per second
    # Need >= 2 min between samples: readings are whole percents, so a --now check 20s after a
    # tick turns a 1-point step into +12 projected and trips the bar on a healthy seat (Grok review 2026-10-30).
    if ([int64]$st.lastTs -gt 0 -and ($now - [int64]$st.lastTs) -ge 120 -and $s5 -gt [int]$st.lastWorst) {
      $rate = ($s5 - [int]$st.lastWorst) / [double]($now - [int64]$st.lastTs)
    }
    $proj = $s5 + [int][math]::Ceiling($rate * $SessionProbeSec)
    $st.lastWorst = $s5; $st.lastTs = $now
    $st.nextHaiku = $now + $SessionProbeSec
    # Weekly is CAP-ONLY and rides this same probe for free — no percentage bar, because rotating
    # off an uncapped weekly window throws the rest of it away.
    if ($u.w7_stat -eq 'rejected') { $trigger = "WEEKLY window CAPPED at $w7% (session $s5%)"; $capped = 'weekly' }
    # A SESSION cap is a cap. It was missing here, so the one window that actually stalls running
    # sessions rotated with $capped unset and Ping-ActiveSessions was never called — see the
    # 2026-09-22 10:06 rotation at 104%, which woke nobody, against 2026-09-20 02:56 (fable) which
    # did. Rank-Accounts has tested s5_stat all along; only this branch did not.
    elseif ($u.s5_stat -eq 'rejected') { $trigger = "SESSION window CAPPED at $s5% (weekly $w7%)"; $capped = 'session' }
    # The server's overall verdict. Rank-Accounts already treats it as a cap and the proxy rotates
    # on it; without this branch a rejection carried by another claim was invisible here, so the
    # proxy re-asked every 20s and nothing moved (Fable review 2026-10-30, P2-4).
    elseif ($u.status -eq 'rejected') { $trigger = "account REJECTED by the server (claim $($u.claim); session $s5%, weekly $w7%)"; $capped = 'session' }
    elseif ($s5 -ge $sessBar)      { $trigger = "session at $s5% >= $sessBar% (weekly $w7%, left to burn)" }
    elseif ($proj -ge $sessBar)    { $trigger = "session at $s5% burning {0:n1}%/min -> {1}% by the next probe, bar $sessBar% (weekly $w7%, left to burn)" -f ($rate * 60), $proj }
  }

  # ---- Fable: free baseline, then armed-and-escalating only once it is genuinely at risk ----
  if (-not $trigger) {
    $fc = Read-FableCache $act
    if ($fc -and $fc.ts -gt [int64]$st.fableTs) {   # someone else already paid for a newer reading
      # Count that reading AS the probe: schedule the next one from its timestamp. Zeroing
      # nextFable here re-probed live on every tick once the proxy began writing Fable readings
      # every few seconds (Fable review 2026-10-30, P2-3).
      $st.fableBase = $fc.pct; $st.fableTs = $fc.ts
      $st.nextFable = $fc.ts + [math]::Min($FableMaxSec, [math]::Max($FableMinSec, (100 - $fc.pct) * $FableSecPerPt))
      if ($fc.capped) { $trigger = "FABLE window CAPPED at $($fc.pct)% (Gate C cannot run)"; $capped = 'fable' }
    }
    $dist = 100 - [int]$st.fableBase
    if (-not $trigger -and [int64]$st.fableTs -gt 0 -and $dist -le $FableArmAt) {
      if ($now -ge [int64]$st.nextFable) {
        $fu = Get-UsageCached $act $true 'fable' '-fable'
        if ($fu.ok -and $null -ne $fu.oi7_util) {
          $st.fableBase = [int][math]::Round([double]$fu.oi7_util * 100)
          # Record the CACHE's timestamp, not $now. Get-UsageCached stamps the file a second or
          # two later than this function's $now, so storing $now leaves our own write looking
          # "newer than the baseline" on the very next tick — which re-seeded, zeroed nextFable,
          # and probed again every single tick. That silently turns the escalating ladder back
          # into flat 5-minute polling, the exact thing it replaced.
          $back = Read-FableCache $act
          $st.fableTs = if ($back) { $back.ts } else { $now }
          $dist = 100 - [int]$st.fableBase
          if ($fu.oi7_stat -eq 'rejected') { $trigger = "FABLE window CAPPED at $($st.fableBase)% (Gate C cannot run)"; $capped = 'fable' }
        }
        $st.nextFable = $now + [math]::Min($FableMaxSec, [math]::Max($FableMinSec, $dist * $FableSecPerPt))
      }
    } elseif ($dist -gt $FableArmAt) { $st.nextFable = 0 }   # disarmed
  }

  Save-RotateState $st
  if (-not $trigger) { return 0 }            # healthy: stay silent, the log is for events only
  Write-RotateLog "TRIGGER: active account '$act' $trigger$(if ($Source) { " [via $Source]" })" Yellow
  $recent = @(@($st.rotations) | Where-Object { $_ -and ($now - [int64]$_) -lt $RotateCapWindow })
  if ($recent.Count -ge $RotateCapCount -and -not $DryRun) {
    Write-RotateLog "RATE CAP: $($recent.Count) rotations in the last $([int]($RotateCapWindow/60)) min - NOT rotating again. Every seat may be failing; owner action needed (claude-rotator --best)." Red
    return 3
  }
  $win = Select-RotationTarget $sessBar
  if (-not $win) {
    # Never rotate onto a fable-capped seat to escape this, and never onto one that would
    # re-trigger next tick. Surface loudly and leave it to the owner — the same boundary
    # codex_failover_review.py draws around redeeming a reset.
    $detail = (Rank-Accounts $false $false | ForEach-Object {
                 "{0}=s{1}%/w{2}%{3}" -f $_.label, [int][math]::Round($_.s5*100), [int][math]::Round($_.w7*100),
                 $(if ($_.why) { "($($_.why))" } else { '' }) }) -join ' '
    Write-RotateLog "NO USABLE TARGET - staying on '$act'. $detail" Red
    Write-RotateLog "  every alternative is capped, fable-capped, or already >= $sessBar% session. Owner action needed." Red
    return 3
  }
  if ($win.label -eq $act) { Write-RotateLog "'$act' is still the best available - staying put" Yellow; return 0 }

  $target = "{0} ({1}) session {2}%, weekly {3}%, fable {4}" -f $win.label, (Profile-Email $win.label),
            [int][math]::Round($win.s5 * 100), [int][math]::Round($win.w7 * 100),
            $(if ($null -eq $win.fable) { 'unknown' } else { "$([int][math]::Round($win.fable*100))%" })
  if ($DryRun) { Write-RotateLog "DRY RUN: would rotate '$act' -> $target" Cyan; return 0 }
  $rc = Apply-Active $win.label
  if ($rc -ne 0) { Write-RotateLog "rotation to '$($win.label)' FAILED" Red; return $rc }
  Write-RotateLog "ROTATED '$act' -> $target" Green
  $st.rotations = @($recent + $now); Save-RotateState $st
  # Only after a CAP (owner, 2026-08-16). A proactive session rotation happens BEFORE anything is
  # blocked, so there is nothing to tell a session it can now resume — pinging then would just
  # interrupt working sessions for no reason.
  if ($capped) {
    Ping-ActiveSessions ("Usage reset: the {0} limit capped, so the CLI account was rotated to {1}. Fresh {0} quota is available now - continue where you left off." -f $capped, $win.label)
  }
  return 0
}

# Rank on the HAIKU probe only — ~1s for every account at once. Probing fable for all five up
# front is what put 2m14s between "TRIGGER" and "ROTATED" in the 2026-08-16 03:06 log entry: long
# enough to look broken, and long enough to burn several more points at ~2%/min. Fable is only
# needed to REJECT a capped target, so buy it one candidate at a time — normally exactly one.
function Select-RotationTarget {
  param([int]$Bar)
  $viable = @(Rank-Accounts $true $false | Where-Object {
                $_.usable -and ([int][math]::Round($_.s5 * 100)) -lt $Bar })
  if (-not $viable) { return $null }
  # Among viable seats, prefer the one whose WEEKLY window renews SOONEST (owner, 2026-08-16):
  # that quota is use-it-or-lose-it, so burn the most perishable first. It costs nothing to know —
  # the reset epoch rides along on the session probe we already paid for. Same reasoning as
  # codex_failover_review.py's weekly-regime tiebreak.
  # Guard: only among seats with real session headroom. Without it, a seat at 89% against a 90%
  # bar would win purely on renewal date and re-trigger a rotation minutes later.
  $roomy   = @($viable | Where-Object { ([int][math]::Round($_.s5 * 100)) -le ($Bar - $MinHeadroom) })
  $ordered = if ($roomy) { @($roomy | Sort-Object { [int64]$_.w7reset }) } else { @($viable | Sort-Object s5) }
  foreach ($c in $ordered) {
    $fu = Get-UsageCached $c.label $true 'fable' '-fable'
    if ($fu.ok -and $fu.oi7_stat -eq 'rejected') { continue }         # Gate C needs Fable
    $c | Add-Member -NotePropertyName fable -NotePropertyValue $(if ($fu.ok -and $null -ne $fu.oi7_util) { [double]$fu.oi7_util } else { $null }) -Force
    return $c
  }
  return $null
}

# Tell running sessions their quota is back (owner, 2026-08-16). Own-window only, deliberately:
# the VS Code path in claude-resume-sessions.ps1 KILLS and relaunches a session and steals focus,
# which is not something an unattended watcher may do to someone who is working. Own-window
# conhost sessions take WriteConsoleInput with no focus steal.
function Ping-ActiveSessions {
  param([string]$Message)
  $script = Join-Path (Split-Path -Parent $PSCommandPath) 'claude-resume-sessions.ps1'
  if (-not (Test-Path $script)) { Write-RotateLog "  (cannot ping sessions: $script missing)" DarkYellow; return }
  try {
    $out = & pwsh -NoProfile -File $script -OwnWindowOnly -Prompt $Message 2>&1
    # Count what the INJECTOR confirmed, not the header line the caller prints before trying.
    # 'Own-window session pid' is written ahead of the WriteConsoleInput attempt, so counting it
    # reported every failed inject as a successful ping — in a log whose whole job is to tell you
    # whether the sessions were woken.
    $tried = @($out | Select-String -Pattern 'Own-window session pid').Count
    $n     = @($out | Select-String -Pattern 'OK injected into PID').Count
    $miss  = if ($tried -gt $n) { " ($($tried - $n) of $tried FAILED to take input)" } else { '' }
    # Parked merge-pr reviews are skipped by the resume script (owner, 2026-10-20) and counted
    # separately: they are neither pinged nor failed. Each is logged by name.
    $skipLines = @($out | Where-Object { "$_" -match '^Skipped parked review (\S+#\d+)' } | ForEach-Object { $Matches[1] })
    foreach ($sk in $skipLines) { Write-RotateLog "  skipped parked review $sk" DarkGray }
    $skip  = if ($skipLines.Count) { ", skipped $($skipLines.Count) parked review(s)" } else { '' }
    # Sessions a limit did not stop (finished, waiting on a question, still working) are skipped
    # by the resume script itself (owner, 2026-10-30) and counted here, never pinged.
    $idle  = @($out | Where-Object { "$_" -match '^Skipped idle session pid' }).Count
    if ($idle) { $skip += ", skipped $idle not stopped by a limit" }
    Write-RotateLog "  pinged $n running own-window session(s)$($skip)$($miss): $Message" $(if ($miss) { 'DarkYellow' } else { 'Gray' })
  } catch { Write-RotateLog "  (ping failed: $($_.Exception.Message))" DarkYellow }
}

# Capture guards (headroom's connect.py idea). A token already stored under another label would
# make two seats that are secretly one account, so rotating between them rotates nowhere; a label
# that already holds a different token would be silently overwritten. --replace overrides the
# second, after backing the old token up. Setup-tokens are opaque, so the account behind one
# cannot be checked here - only the token itself.
function Save-ProfileToken {
  param([string]$Label, [string]$Tok, [bool]$Replace = $false)
  foreach ($l in Get-Candidates) {
    if ($l -ne $Label -and ((Get-Content (Profile-TokenFile $l) -Raw).Trim()) -eq $Tok) {
      Write-Host "Refusing: that token is already stored as '$l'. Two labels for one account would make rotating between them a no-op." -ForegroundColor Red; exit 1
    }
  }
  $dst = Join-Path $Root $Label; $tf = Join-Path $dst 'token.txt'
  if ((Test-Path $tf) -and ((Get-Content $tf -Raw).Trim()) -ne $Tok) {
    if (-not $Replace) { Write-Host "Refusing: '$Label' already holds a different token (fingerprint $(Profile-TokenHash $Label)). Pass --replace to overwrite it (the old one is backed up)." -ForegroundColor Red; exit 1 }
    Copy-Item $tf (Join-Path $dst ("token.txt.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
  }
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  $tmp = "$tf.tmp-$PID"; Set-Content -LiteralPath $tmp -Value $Tok -Encoding UTF8 -NoNewline; [IO.File]::Move($tmp, $tf, $true)
}

function Resolve-Target {
  # 'best' is a KEYWORD, not a seat: --switch best / --rotate best pick the most headroom.
  # A real seat literally named 'best' still wins — it is checked first.
  param([string]$l)
  if ($l -and $l -ieq 'best' -and -not (Test-Path (Join-Path $Root $l))) {
    $w = @(Rank-Accounts $true | Where-Object usable)[0]
    if (-not $w) { Write-Host "Every account is capped - nothing to switch to." -ForegroundColor Red; exit 1 }
    Write-Host ("Best headroom: {0} ({1}) - session {2}%" -f $w.label, (Profile-Email $w.label), [int][math]::Round($w.s5 * 100)) -ForegroundColor Cyan
    if ($w.fableCapped) { Write-Host "  NOTE: its FABLE window is capped - fine for Opus/Sonnet work, not for a Fable review." -ForegroundColor DarkYellow }
    return $w.label
  }
  return (Resolve-Label $l)
}

# ---------- flag parse ----------
$mode=$null; $label=$null; $extra=$null; $unknown=@(); $Refresh=$false; $NoUsage=$false
$Threshold=0;  $DryRun=$false   # 0 = unset; the real bar is $SessionAt
$NowCheck=$false; $Source=''; $Replace=$false
$a = @($Args | Where-Object { $_ })
for ($i=0; $i -lt $a.Count; $i++) {
  switch -regex ($a[$i]) {
    '^--?now$'                         { $NowCheck = $true }
    '^--?source$'                      { if ($i+1 -lt $a.Count) { $Source=$a[$i+1]; $i++ } }
    '^--?replace$'                     { $Replace = $true }
    '^--?(status|st)$'                  { $mode='status' }
    '^--?(list|ls)$'                   { $mode='list' }
    # --rotate <label> is an explicit target, not a cycle - same as --switch <label>, which is
    # what you mean when you type one. Before this it swallowed the label into $unknown and
    # cycled to the NEXT account instead, silently landing you on the wrong one.
    '^--?(rotate|toggle|swap|next)$'   { $mode='rotate'; if ($i+1 -lt $a.Count -and $a[$i+1] -notmatch '^-') { $label=$a[$i+1]; $i++ } }
    '^--?(usage|u)$'                   { $mode='usage' }
    '^--?(best|headroom)$'             { $mode='best' }
    '^--?(check-?rotate|auto-?rotate|monitor)$' { $mode='checkrotate' }
    '^--?(dry-?run|whatif)$'           { $DryRun = $true }
    '^--?(threshold|at)$'              { if ($i+1 -lt $a.Count -and $a[$i+1] -match '^\d+$') { $Threshold=[int]$a[$i+1]; $i++ } }
    '^--?(refresh|fresh)$'             { $Refresh = $true }
    '^--?(no-?usage|quiet)$'           { $NoUsage = $true }
    '^--?(clear|none|logout-local)$'   { $mode='clear' }
    '^--?(help|h|\?)$'                 { $mode='help' }
    '^--?(switch|account|acct|use|to)$' { $mode='switch'; if ($i+1 -lt $a.Count -and $a[$i+1] -notmatch '^-') { $label=$a[$i+1]; $i++ } }
    '^--?(capture|save|add)$'          { $mode='capture'; if ($i+1 -lt $a.Count -and $a[$i+1] -notmatch '^-') { $label=$a[$i+1]; $i++ } }
    '^--?(import)$'                    { $mode='import'; if ($i+1 -lt $a.Count -and $a[$i+1] -notmatch '^-') { $label=$a[$i+1]; $i++ }; if ($i+1 -lt $a.Count) { $extra=$a[$i+1]; $i++ } }
    default {
      if (-not $mode -and (Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $a[$i] })) { $mode='switch'; $label=$a[$i] }
      else { $unknown += $a[$i] }
    }
  }
}
if (-not $mode) { $mode = if ($unknown.Count) { 'unknown' } else { 'status' } }
New-Item -ItemType Directory -Path $Root -Force | Out-Null

# ---------- modes ----------
switch ($mode) {
  'help' {
    Write-Host "claude-rotator — switch the CLI between accounts via long-lived setup-tokens."
    Write-Host ""
    Write-Host "  --status                 active account + profiles"
    Write-Host "  --switch <l> (--account) make <l> active   (or just: claude-cli-account <l>)"
    Write-Host "  --rotate  (--toggle)     flip to the next account   (--rotate <l> = --switch <l>)"
    Write-Host "  --usage   (--refresh)    session(5h)+weekly(7d)+fable(weekly) usage for every account (also: claude-usage)"
    Write-Host "  --best    (--headroom)   rank accounts by headroom; 'best' is also a switch target:"
    Write-Host "                           claude-rotator --switch best   (skips capped + fable-capped)"
    Write-Host "  --check-rotate           rotate when the ACTIVE account passes the session bar (80%), or"
    Write-Host "                           when its weekly/fable window CAPS. Add --dry-run to preview."
    Write-Host "                           Runs every 5 min as the 'Claude usage auto-rotate' task."
    Write-Host "                           After a CAP rotation it pings running sessions that quota is back."
    Write-Host "  --capture <l>            paste a setup-token (from `claude setup-token`) into profile <l>"
    Write-Host "  --import <l> <file>      load a setup-token from a file"
    Write-Host "  --clear                  unset the token env var (revert to stored interactive login)"
    Write-Host "  --list"
    Write-Host ""
    Write-Host "  --status and --usage always read usage LIVE (~5s; every probe fires concurrently)."
    Write-Host "  The readout tacked onto --switch/--rotate prints the last cached read instead, so"
    Write-Host "  switching stays ~2s -- a fable probe alone queues 6-11s server-side. --no-usage"
    Write-Host "  omits the readout entirely; --refresh is now the default for --status/--usage."
    break
  }
  'unknown' {
    Write-Host "Unknown command: $($unknown -join ' ')" -ForegroundColor Red
    Write-Host "Try: --status | --switch <label> (or just <label>) | --rotate | --usage | --capture <label> | --import <label> <file> | --clear | --help" -ForegroundColor Yellow
    exit 1
  }
  'list' {
    Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^[_.]' } | ForEach-Object {
      "{0,-10} email={1,-28} token={2} {3}" -f $_.Name, (Profile-Email $_.Name), (Profile-TokenHash $_.Name), $(if ((Test-Path (Join-Path $_.FullName 'token.txt'))) { '' } else { '(NO TOKEN)' })
    }
    break
  }
  'status' {
    $act = Get-ActiveLabel
    $envSet = [bool][Environment]::GetEnvironmentVariable($EnvName,'User')
    Write-Host "Active CLI account: $(if($act){"$act ($(Profile-Email $act))"}else{'(none set — using stored interactive login)'})"
    Write-Host "User CLAUDE_CODE_OAUTH_TOKEN set: $envSet"
    # Is the auto-rotate watcher actually alive? A monitor nobody can see the heartbeat of is a
    # monitor you find out has been dead for a week at exactly the wrong moment.
    if (Test-Path $RotateLastCheck) {
      $ago = [int]((Get-Date) - [datetime]::Parse((Get-Content $RotateLastCheck -Raw).Trim())).TotalMinutes
      $last = if (Test-Path $RotateLog) { (Get-Content $RotateLog -Tail 1 -EA SilentlyContinue) } else { $null }
      Write-Host ("Auto-rotate watcher: last checked {0} min ago (session bar {1}%; weekly/fable rotate on CAP only)" -f $ago, $SessionAt) -ForegroundColor $(if ($ago -le 15) { 'DarkGray' } else { 'DarkYellow' })
      if ($last) { Write-Host "  last event: $last" -ForegroundColor DarkGray }
    } else {
      Write-Host "Auto-rotate watcher: never run (see --check-rotate / the 'Claude usage auto-rotate' task)" -ForegroundColor DarkYellow
    }
    Write-Host "Profiles:"
    $p = Get-Candidates
    if ($p) { $p | ForEach-Object { Write-Host "  - $_  ($(Profile-Email $_))  token=$(Profile-TokenHash $_)$(if($_ -eq $act){'   <== ACTIVE'})" } }
    else { Write-Host "  (none with tokens — use --capture <label> or --import <label> <file>)" }
    # --status is a LIVE read by design (owner, 2026-08-13): it exists to tell you the current
    # numbers, so it always probes and never trusts the cache. It still WRITES the cache on the
    # way out, which is what a --switch/--rotate readout prints a moment later.
    if ($p -and -not $NoUsage) { Show-Usage $true $false }
    break
  }
  # Live too, for the same reason as --status: a command whose whole job is to report usage
  # must not hand back an hour-old fable number. --refresh is now a no-op here (kept working).
  'usage' { Show-Usage $true $false; break }
  'checkrotate' { exit (Invoke-CheckRotate $Threshold $DryRun $NowCheck $Source) }
  'best' {
    $r = Rank-Accounts $true
    # Same order the watcher rotates in, so what you read is what it would do.
    $r = @(@($r | Where-Object usable | Sort-Object { [int64]$_.w7reset }) + @($r | Where-Object { -not $_.usable } | Sort-Object s5))
    if (-not $r) { Write-Host "No profiles with tokens." -ForegroundColor Yellow; exit 1 }
    $act = Get-ActiveLabel
    Write-Host ""
    Write-Host "Usable seats in ROTATION ORDER (soonest weekly renewal first - most perishable quota); rest by session:" -ForegroundColor Cyan
    foreach ($x in $r) {
      $mark = if ($x.label -eq $act) { '>' } else { ' ' }
      if (-not $x.usable) { Write-Host ("  {0} {1,-8} UNUSABLE ({2})" -f $mark, $x.label, $x.why) -ForegroundColor Red; continue }
      $fs = if ($null -eq $x.fable) { 'fable  n/a' }
            else { "fable {0,3}%{1}" -f [int][math]::Round($x.fable * 100), $(if ($x.fableCapped) { ' CAPPED' } else { '' }) }
      Write-Host ("  {0} {1,-8} session {2,3}%   weekly {3,3}% (renews {4,-6})   {5}   {6}" -f `
        $mark, $x.label, [int][math]::Round($x.s5 * 100), [int][math]::Round($x.w7 * 100),
        (RelReset $x.w7reset), $fs, (Profile-Email $x.label))
    }
    $win = @($r | Where-Object usable)[0]
    Write-Host ""
    if (-not $win) { Write-Host "Every account is capped. Nothing to switch to." -ForegroundColor Red; exit 1 }
    if ($win.label -eq $act) { Write-Host "You are already on the account with the most headroom ($act)." -ForegroundColor Green }
    else { Write-Host ("Switch with:  claude-rotator --switch {0}      (or: --switch best)" -f $win.label) -ForegroundColor Green }
    break
  }
  'capture' {
    if (-not $label) { Write-Host "Usage: --capture <label>   (run `claude setup-token` first, then paste here)" -ForegroundColor Red; exit 1 }
    Write-Host "Paste the setup-token from `claude setup-token` (input hidden):" -ForegroundColor Cyan
    $sec = Read-Host -AsSecureString
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $tok) { Write-Host "Nothing pasted; aborted." -ForegroundColor Red; exit 1 }
    $tok = $tok.Trim()
    # Setup-tokens look like sk-ant-oat01-... Hidden input can't be Ctrl+V-pasted in some
    # consoles (it records a literal ^V control char); catch that instead of storing junk.
    if ($tok -notmatch '^sk-ant-[A-Za-z0-9_\-]{20,}$') {
      Write-Host "That doesn't look like a setup-token (got $($tok.Length) char(s); expected sk-ant-...)." -ForegroundColor Red
      Write-Host "Ctrl+V doesn't paste into hidden input in some consoles - use RIGHT-CLICK to paste," -ForegroundColor Yellow
      Write-Host "or save the token to a file and run:  claude-rotator --import $label <file>" -ForegroundColor Yellow
      exit 1
    }
    Save-ProfileToken $label $tok.Trim() $Replace
    Write-Host "Stored setup-token for '$label' (fingerprint $(ShortHash $tok.Trim())). Set its email with: notepad $(Join-Path $Root $label)\email.txt" -ForegroundColor Green
    break
  }
  'import' {
    if (-not $label -or -not $extra) { Write-Host "Usage: --import <label> <file>" -ForegroundColor Red; exit 1 }
    if (-not (Test-Path -LiteralPath $extra)) { Write-Host "File not found: $extra" -ForegroundColor Red; exit 1 }
    $tok = (Get-Content -LiteralPath $extra -Raw).Trim()
    if (-not $tok) { Write-Host "File is empty: $extra" -ForegroundColor Red; exit 1 }
    if ($tok -notmatch '^sk-ant-[A-Za-z0-9_\-]{20,}$') { Write-Host "File doesn't contain a setup-token (expected sk-ant-...)." -ForegroundColor Red; exit 1 }
    Save-ProfileToken $label $tok $Replace
    Write-Host "Imported setup-token for '$label' (fingerprint $(ShortHash $tok))." -ForegroundColor Green
    break
  }
  'clear' {
    Set-UserEnvFast $EnvName $null
    [Environment]::SetEnvironmentVariable($EnvName, $null, 'Process')
    if (Test-Path $Active) { Remove-Item -LiteralPath $Active -ErrorAction SilentlyContinue }
    Write-Host "Cleared CLAUDE_CODE_OAUTH_TOKEN (User + process). The CLI reverts to its stored interactive login." -ForegroundColor Green
    break
  }
  'switch' {
    if (-not $label -and $unknown.Count) { $label = $unknown[0] }
    if (-not $label) { Write-Host "Usage: --switch <label>" -ForegroundColor Red; exit 1 }
    $rc = Apply-Active (Resolve-Target $label)
    # Cache-only unless you asked for live (--refresh): see Show-Usage.
    if ($rc -eq 0 -and -not $NoUsage) { Show-Usage $Refresh (-not $Refresh) }
    exit $rc
  }
  'rotate' {
    if ($label) {   # --rotate <label> == --switch <label>
      $rc = Apply-Active (Resolve-Target $label)
      if ($rc -eq 0 -and -not $NoUsage) { Show-Usage $Refresh (-not $Refresh) }
      exit $rc
    }
    $cands = Get-Candidates
    if ($cands.Count -lt 2) { Write-Host "Need >=2 profiles with tokens to rotate (have $($cands.Count))." -ForegroundColor Red; exit 1 }
    $cur = Get-ActiveLabel
    $next = if ($cur -and ($cands -contains $cur)) { $cands[(([array]::IndexOf($cands,$cur))+1) % $cands.Count] } else { $cands[0] }
    Write-Host "Rotating: $(if($cur){$cur}else{'?'}) -> $next ($(Profile-Email $next))"
    $rc = Apply-Active $next
    if ($rc -eq 0 -and -not $NoUsage) { Show-Usage $Refresh (-not $Refresh) }
    exit $rc
  }
}
