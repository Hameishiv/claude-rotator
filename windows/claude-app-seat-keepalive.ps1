<#
claude-app-seat-keepalive.ps1 — keep every IDLE desktop-app seat's OAuth refresh tokens alive,
so rotating onto a seat never lands on "Sign in again".

ROOT CAUSE (proven 2026-09-22 from %LOCALAPPDATA%\Claude\Logs\main*.log + the app's own code):
  On a seat switch-in the app refreshes its Claude Code token and gets
  400 invalid_grant "Refresh token expired"; its fallback /authorize then gets
  403 session_stale_relogin ("Session is not fresh enough ... Sign in again"). The app asks for a
  30-DAY access token (expires_in=2592000 for user:sessions:claude_code) but only refreshes once
  that access token is expired/near expiry, while the refresh token behind it dies much sooner
  (shortest observed: 14.0 days after issue). Nothing refreshes a seat snapshot in between, live
  or idle, so each seat hits a re-login roughly every 2-4 weeks => "every few days" across 7 seats.
  Full evidence: C:\Dev\hameishiv-wiki\wiki\handoffs\app-seat-relogin-20260922.md

WHAT THIS DOES
  For each captured seat that is NOT the live login (uuid in %APPDATA%\Claude\config.json):
  decrypt config.json's oauth:tokenCacheV2 (Electron safeStorage v10 = AES-256-GCM, key from
  %APPDATA%\Claude\Local State via DPAPI), and refresh every entry that
    - has a refresh token,
    - is not long-lived (access token > LongLivedDays left — refreshing would SHORTEN it), and
    - was not refreshed by us within EveryDays (or its refresh token changed since, e.g. the app
      rotated it while the seat was live).
  The request is byte-for-byte the app's own (POST {apiHost}/v1/oauth/token, see e0t/$1t in
  app.asar). The new blob is re-encrypted with the same key and swapped into config.json.

SAFETY CONTRACT (mirrors codex_failover_review.py -> refresh_auth)
  - Never touches the LIVE seat (the app owns that chain; refreshing it would revoke the app's token).
  - One lock, shared with claude-app-rotator.ps1 (.seat-write.lock, DeleteOnClose so a crash can't
    wedge it): a switch/capture never interleaves with a refresh. Busy => skip this run.
  - Backup of config.json to .keepalive-backups\<stamp>\<seat>\ before every write; the write is a
    same-directory temp + File.Replace (atomic). Only the one encrypted string is replaced in the
    raw text, so nothing else in config.json is re-serialized.
  - invalid_grant => the seat is already dead: reported, file untouched (needs ONE re-login).
  - Never prints, logs or stores a token: only 8-hex SHA-256 prefixes, to prove rotation.
  - Never raises: every seat and entry is try/caught; the script exits 0.

USAGE (pwsh 7)
  claude-app-seat-keepalive.ps1              # refresh what is due (the scheduled task runs this)
  claude-app-seat-keepalive.ps1 -Status      # per seat/entry: access expiry, last refresh, result
  claude-app-seat-keepalive.ps1 -DryRun      # say what would be refreshed, change nothing
  claude-app-seat-keepalive.ps1 -Seat f      # limit to one seat
  claude-app-seat-keepalive.ps1 -Force       # ignore the EveryDays gate (e.g. to rotate a leaked token)
  claude-app-seat-keepalive.ps1 -SelfTest    # crypto round-trip + helper checks, no network
  Log: ~\.claude-app-seats\.keepalive-log.txt   Scheduled task: 'Claude app-seat keepalive'.
#>
param([switch]$Status, [switch]$DryRun, [switch]$SelfTest, [string]$Seat, [switch]$Force,
      [double]$EveryDays = 2, [double]$LongLivedDays = 60, [int]$ExpiresIn = 0)

$ErrorActionPreference = 'Stop'
$AppDir     = "$env:APPDATA\Claude"
$SeatRoot   = "$env:USERPROFILE\.claude-app-seats"
$LockPath   = Join-Path $SeatRoot '.seat-write.lock'
$StatePath  = Join-Path $SeatRoot '.keepalive-state.json'
$LogPath    = Join-Path $SeatRoot '.keepalive-log.txt'
$BackupRoot = Join-Path $SeatRoot '.keepalive-backups'
$Utf8NoBom  = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Security

function Write-Log([string]$m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')  $m"
  Write-Host $line
  if (-not $Status -and -not $SelfTest) { try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {} }
}
function Get-TokId([string]$s) {
  if (-not $s) { return '-' }
  $h = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s))
  ([BitConverter]::ToString($h, 0, 4) -replace '-', '').ToLower()
}
function Get-AppKey {
  $ls = Get-Content (Join-Path $AppDir 'Local State') -Raw | ConvertFrom-Json
  $ek = [Convert]::FromBase64String($ls.os_crypt.encrypted_key)
  [Security.Cryptography.ProtectedData]::Unprotect($ek[5..($ek.Length - 1)], $null, 'CurrentUser')  # strip 'DPAPI'
}
function Unprotect-Blob([byte[]]$key, [string]$b64) {
  $b = [Convert]::FromBase64String($b64)
  if ([Text.Encoding]::ASCII.GetString($b, 0, 3) -ne 'v10') { throw 'not a v10 safeStorage blob' }
  $ct = $b[15..($b.Length - 17)]; $pt = [byte[]]::new($ct.Length)
  $g = [Security.Cryptography.AesGcm]::new($key, 16)
  try { $g.Decrypt($b[3..14], $ct, $b[($b.Length - 16)..($b.Length - 1)], $pt) } finally { $g.Dispose() }
  [Text.Encoding]::UTF8.GetString($pt)
}
function Protect-Blob([byte[]]$key, [string]$plain) {
  $pt = [Text.Encoding]::UTF8.GetBytes($plain)
  $nonce = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
  $ct = [byte[]]::new($pt.Length); $tag = [byte[]]::new(16)
  $g = [Security.Cryptography.AesGcm]::new($key, 16)
  try { $g.Encrypt($nonce, $pt, $ct, $tag) } finally { $g.Dispose() }
  [Convert]::ToBase64String([byte[]]([Text.Encoding]::ASCII.GetBytes('v10') + $nonce + $ct + $tag))
}
function Split-CacheKey([string]$k) {
  # acct:<account>|<clientId>:<orgId>:<apiHost>:<scope>
  if ($k -match '^acct:([^|]+)\|([^:]+):([^:]+):(https?://[^:/]+(?::\d+)?):(.*)$') {
    return @{ account = $Matches[1]; client = $Matches[2]; org = $Matches[3]; api = $Matches[4]; scope = $Matches[5] }
  }
  $null
}
function Get-ExpiresIn([string]$scope) {
  # Mirrors the app's Q1t(): none for org:desktop_config, 1 y for other non-Claude-Code scopes,
  # 30 d for user:sessions:claude_code and bare user:profile.
  if (($scope -split ' ') -contains 'org:desktop_config') { return $null }
  if (-not $scope.Contains('user:sessions:claude_code') -and $scope -ne 'user:profile') { return 31536000 }
  2592000
}
function Get-ErrCode([string]$body) {
  # Server error fields only (e.g. invalid_grant / "Refresh token expired") - never the raw body.
  try { $j = $body | ConvertFrom-Json; $d = "$($j.error_description)"; if (-not $d -and $j.error.type) { return "$($j.error.type)" }
        return ("$($j.error) $d".Trim()).Substring(0, [Math]::Min(80, ("$($j.error) $d".Trim()).Length)) } catch { return '(non-json)' }
}
function Invoke-Refresh($ck, $entry) {
  $body = [ordered]@{ grant_type = 'refresh_token'; client_id = $ck.client; refresh_token = $entry.refreshToken; scope = $ck.scope }
  $exp = if ($ExpiresIn -gt 0) { $ExpiresIn } else { Get-ExpiresIn $ck.scope }
  foreach ($withExp in @($true, $false)) {
    $b = [ordered]@{}; foreach ($kv in $body.GetEnumerator()) { $b[$kv.Key] = $kv.Value }
    if ($withExp -and $exp) { $b.expires_in = $exp }
    $r = Invoke-WebRequest -Method Post -Uri "$($ck.api)/v1/oauth/token" -Headers @{ 'anthropic-version' = '2023-06-01' } `
          -ContentType 'application/json' -Body ($b | ConvertTo-Json -Compress) -SkipHttpErrorCheck -TimeoutSec 30
    # same retry the app does when the server refuses a custom expires_in
    if ($withExp -and $exp -and $r.StatusCode -eq 400 -and $r.Content -match 'expires_in|expiry' -and $r.Content -notmatch 'invalid_grant') { continue }
    return $r
  }
}
function Enter-SeatLock {
  try { [IO.FileStream]::new($LockPath, 'CreateNew', 'Write', 'None', 1, [IO.FileOptions]::DeleteOnClose) } catch { $null }
}
function Read-State { try { Get-Content $StatePath -Raw | ConvertFrom-Json -AsHashtable } catch { @{} } }

if ($SelfTest) {
  $key = Get-AppKey
  $s = '{"acct:x|c:o:https://api.anthropic.com:user:profile":{"token":"t","refreshToken":"r","expiresAt":1790744954090}}'
  $enc = Protect-Blob $key $s
  if ((Unprotect-Blob $key $enc) -ne $s) { throw 'round-trip FAILED' }
  $ck = Split-CacheKey 'acct:a1|9d1c250a-e61b:5dc37287-65bb:https://api.anthropic.com:user:inference user:profile user:sessions:claude_code'
  if ($ck.client -ne '9d1c250a-e61b' -or $ck.api -ne 'https://api.anthropic.com' -or $ck.scope -notmatch 'claude_code$') { throw 'Split-CacheKey FAILED' }
  if ((Get-ExpiresIn 'user:inference user:profile user:sessions:claude_code') -ne 2592000) { throw 'expires_in cc FAILED' }
  if ((Get-ExpiresIn 'user:inference user:file_upload user:profile') -ne 31536000) { throw 'expires_in 1y FAILED' }
  if ((Get-ExpiresIn 'user:profile') -ne 2592000 -or $null -ne (Get-ExpiresIn 'org:desktop_config user:profile')) { throw 'expires_in edge FAILED' }
  # every real seat blob must decrypt with this key (read-only)
  Get-ChildItem $SeatRoot -Directory | Where-Object { $_.Name -notmatch '^\.' -and (Test-Path "$($_.FullName)\config.json") } | ForEach-Object {
    $v = (Get-Content "$($_.FullName)\config.json" -Raw | ConvertFrom-Json).'oauth:tokenCacheV2'
    if ($v) { $n = @((Unprotect-Blob $key $v | ConvertFrom-Json -AsHashtable).Keys).Count; Write-Host "  seat $($_.Name): decrypts, $n entries" }
  }
  Write-Host 'SELFTEST OK'; exit 0
}

try {
  $lock = if ($Status) { $null } else { Enter-SeatLock }
  if (-not $Status -and -not $lock) { Write-Log 'SKIP: seat lock busy (a rotator switch/capture is running)'; exit 0 }
  try {
    $key = Get-AppKey
    $state = Read-State
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $liveUuid = try { (Get-Content (Join-Path $AppDir 'config.json') -Raw | ConvertFrom-Json).lastKnownAccountUuid } catch { '' }
    if (-not $liveUuid) { Write-Log 'SKIP: cannot read the live account uuid - refusing to guess which seat is live'; exit 0 }
    $seats = Get-ChildItem $SeatRoot -Directory | Where-Object { $_.Name -notmatch '^\.' -and (Test-Path "$($_.FullName)\config.json") -and (Test-Path "$($_.FullName)\owner-uuid.txt") }
    if ($Seat) { $seats = $seats | Where-Object { $_.Name -ieq $Seat } }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($s in $seats) {
      $tmp = $null
      try {
        $owner = (Get-Content "$($s.FullName)\owner-uuid.txt" -Raw).Trim()
        if ($owner -eq $liveUuid) { Write-Log "seat $($s.Name): LIVE - skipped (the app owns this chain)"; continue }
        $cfgPath = Join-Path $s.FullName 'config.json'
        $raw = [IO.File]::ReadAllText($cfgPath)
        $cfg = $raw | ConvertFrom-Json
        if ($cfg.lastKnownAccountUuid -and $cfg.lastKnownAccountUuid -ne $owner) { Write-Log "seat $($s.Name): snapshot uuid != owner-uuid - skipped (poisoned snapshot)"; continue }
        $b64 = $cfg.'oauth:tokenCacheV2'
        if (-not $b64) { Write-Log "seat $($s.Name): no tokenCacheV2 - skipped"; continue }
        $cache = Unprotect-Blob $key $b64 | ConvertFrom-Json -AsHashtable
        $changed = $false
        foreach ($k in @($cache.Keys)) {
          $e = $cache[$k]; $ck = Split-CacheKey $k
          if (-not $e -or -not $e.refreshToken -or -not $ck) { continue }
          $tag = "seat $($s.Name) [$($ck.client.Substring(0,8)) $($ck.scope)]"
          $sk = "$($s.Name)|$k"; $st = $state[$sk]
          $leftD = ([double]$e.expiresAt - $nowMs) / 86400000
          $expL = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$e.expiresAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
          $rtId = Get-TokId $e.refreshToken
          $ageD = if ($st -and $st.rtId -eq $rtId) { ($nowMs - [double]$st.lastRefreshMs) / 86400000 } else { $null }
          if ($Status) {
            $lr = if ($st) { "$($st.result) $([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$st.lastRefreshMs).ToLocalTime().ToString('MM-dd HH:mm'))" } else { 'never' }
            Write-Host ("{0,-70} access exp {1}  last keepalive: {2}{3}" -f $tag, $expL, $lr, $(if ($st -and $st.rtId -ne $rtId) { ' (rt changed since - app refreshed it)' } else { '' }))
            continue
          }
          if ($leftD -gt $LongLivedDays) { continue }                       # long-lived: refreshing would shorten it
          if (-not $Force -and $null -ne $ageD -and $ageD -lt $EveryDays) { continue }  # ours, and recent enough
          if ($st -and $st.result -eq 'dead' -and $st.rtId -eq $rtId) { continue }  # already reported dead; needs a login
          if ($DryRun) { Write-Log "DRY-RUN would refresh $tag (access exp $expL)"; continue }
          try {
            $r = Invoke-Refresh $ck $e
            if ($r.StatusCode -eq 200) {
              $j = $r.Content | ConvertFrom-Json
              if (-not $j.access_token) { Write-Log "ERROR $tag : 200 without access_token - left as is"; continue }
              $e.token = $j.access_token
              if ($j.refresh_token) { $e.refreshToken = $j.refresh_token }
              $e.expiresAt = $nowMs + [int64]$j.expires_in * 1000
              $newId = Get-TokId $e.refreshToken
              $state[$sk] = @{ rtId = $newId; lastRefreshMs = $nowMs; result = 'ok' }
              $changed = $true
              Write-Log "refreshed $tag : rt $rtId -> $newId, access now expires $([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$e.expiresAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm'))"
            } elseif ($r.StatusCode -eq 400 -and $r.Content -match 'invalid_grant') {
              $state[$sk] = @{ rtId = $rtId; lastRefreshMs = $nowMs; result = 'dead' }
              Write-Log "DEAD $tag : $(Get-ErrCode $r.Content). Seat needs ONE re-login on its next switch-in; left untouched."
            } else {
              Write-Log "ERROR $tag : HTTP $($r.StatusCode) $(Get-ErrCode $r.Content) - left as is, will retry next run"
            }
          } catch { Write-Log "ERROR $tag : $($_.Exception.GetType().Name) - left as is" }
        }
        if ($changed) {
          $plain = $cache | ConvertTo-Json -Compress -Depth 10
          $nb64 = Protect-Blob $key $plain
          if ((Unprotect-Blob $key $nb64) -ne $plain) { throw 're-encrypt round-trip mismatch' }
          if (@((ConvertFrom-Json $plain -AsHashtable).Keys).Count -ne @($cache.Keys).Count) { throw 'entry count changed' }
          $i = $raw.IndexOf($b64)
          if ($i -lt 0 -or $i -ne $raw.LastIndexOf($b64)) { throw 'tokenCacheV2 not found exactly once in raw config.json' }
          $bk = Join-Path $BackupRoot "$stamp\$($s.Name)"
          New-Item -ItemType Directory -Path $bk -Force | Out-Null
          Copy-Item $cfgPath (Join-Path $bk 'config.json') -Force
          $tmp = "$cfgPath.keepalive-tmp"
          [IO.File]::WriteAllText($tmp, $raw.Substring(0, $i) + $nb64 + $raw.Substring($i + $b64.Length), $Utf8NoBom)
          [IO.File]::Move($tmp, $cfgPath, $true)   # same-volume rename over the old file = atomic
          $check = (Get-Content $cfgPath -Raw | ConvertFrom-Json).'oauth:tokenCacheV2'
          if ((Unprotect-Blob $key $check) -ne $plain) { throw 'post-write verify failed' }
          Write-Log "seat $($s.Name): snapshot updated (backup $bk)"
        }
      } catch {
        # ponytail: if the server already rotated a token and the write then failed, that entry's new
        # refresh token is lost => the seat needs a re-login, i.e. exactly today's failure, never worse.
        if ($tmp -and (Test-Path $tmp)) { Write-Log "RECOVER seat $($s.Name): the refreshed tokens are ONLY in $tmp - move it over config.json" }
        Write-Log "ERROR seat $($s.Name): $($_.Exception.GetType().Name): $($_.Exception.Message -replace 'sk-ant-[A-Za-z0-9_-]+','[REDACTED]') - seat file untouched unless 'snapshot updated' was logged"
      }
    }
    if (-not $Status -and -not $DryRun) { $state | ConvertTo-Json -Depth 5 | Set-Content $StatePath -Encoding UTF8 }
  } finally { if ($lock) { $lock.Dispose() } }
} catch {
  Write-Log "ERROR (run aborted, nothing changed after this point): $($_.Exception.GetType().Name)"
}
exit 0
