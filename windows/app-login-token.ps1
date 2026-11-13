<#
app-login-token.ps1 - READ-ONLY: print one Claude seat's full desktop-app login token (scope user:profile) as JSON, for
usage-history.py's reset-credit read and consume. A setup-token cannot read reset credits (403 "scope requirement
user:profile"); the desktop app's own login for the same account can.

Where it reads (the same places claude-app-rotator.ps1 and claude-app-seat-keepalive.ps1 use):
  ~/.claude-app-seats/<seat>/config.json   the seat's saved app login (the live seat: %APPDATA%\Claude\config.json,
                                            the app's own and fresher copy, chosen when its lastKnownAccountUuid matches)
  oauth:tokenCacheV2                        Electron safeStorage v10 = AES-256-GCM, key DPAPI-wrapped in
                                            %APPDATA%\Claude\Local State
It never refreshes a token and never writes any file. Output, one line of JSON on stdout:
  {"state":"ok","token":"...","expiresAt":<ms>,"accountUuid":"...","orgUuid":"..."}
                                                  the seat's own account's user:profile entry that expires last, unexpired
                                                  (with -Org: of that organization only)
  {"state":"expired","expiresAt":<ms>}            every user:profile entry has expired (opening the app on that seat refreshes it)
  {"state":"org","why":"..."}                     with -Org: the account has user:profile entries, but none for that organization
  {"state":"none","why":"..."}                    no usable app login: none saved, no owner-uuid.txt, a snapshot of another
                                                  account (its lastKnownAccountUuid is not the seat's owner: a poisoned snapshot,
                                                  the rule claude-app-seat-keepalive.ps1 applies), or no user:profile entry of that
                                                  account
  {"state":"busy","why":"..."}                    the login files could not be read just now (a lock, the app rewriting config.json): a
                                                  passing failure, not "no login"
  {"state":"unreadable","why":"..."}              a login is saved and was read but could not be decrypted (not the same as none: the
                                                  caller must not treat it as "no login")
  app-login-token.ps1 -Seat A [-Org <organization uuid>]
  app-login-token.ps1 -SelfTest                   no real file is read: a throwaway key and login in a temp folder
#>
param([string]$Seat, [string]$AppDir = (Join-Path $env:APPDATA 'Claude'), [string]$SeatRoot = (Join-Path $env:USERPROFILE '.claude-app-seats'),
      [long]$NowMs = 0, [string]$Org = '', [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'Idle'

function Get-AppKey($ls) {           # $ls: Local State, already read and checked by the caller
  Add-Type -AssemblyName System.Security
  $ek = [Convert]::FromBase64String($ls.os_crypt.encrypted_key)
  [Security.Cryptography.ProtectedData]::Unprotect($ek[5..($ek.Length - 1)], $null, 'CurrentUser')     # strip 'DPAPI'
}
function Unprotect-Blob([byte[]]$Key, [string]$B64) {
  $b = [Convert]::FromBase64String($B64)
  if ([Text.Encoding]::ASCII.GetString($b, 0, 3) -ne 'v10') { throw 'not a v10 safeStorage blob' }
  $ct = $b[15..($b.Length - 17)]; $pt = [byte[]]::new($ct.Length)
  $g = [Security.Cryptography.AesGcm]::new($Key, 16)
  try { $g.Decrypt($b[3..14], $ct, $b[($b.Length - 16)..($b.Length - 1)], $pt) } finally { $g.Dispose() }
  [Text.Encoding]::UTF8.GetString($pt)
}

function Get-AppLogin([string]$Seat, [string]$AppDir, [string]$SeatRoot, [long]$NowMs, [string]$Org = '') {
  if ($Seat -notmatch '^[A-Za-z0-9_-]{1,32}$') { return @{ state = 'none'; why = 'not a seat name' } }
  $dir = Join-Path $SeatRoot $Seat
  $snap = Join-Path $dir 'config.json'
  if (-not (Test-Path -LiteralPath $snap)) { return @{ state = 'none'; why = 'no app login saved for this seat' } }
  $ownerFile = Join-Path $dir 'owner-uuid.txt'       # which account this seat IS, written at --capture (claude-app-rotator.ps1)
  $owner = if (Test-Path -LiteralPath $ownerFile) { (Get-Content -LiteralPath $ownerFile -Raw).Trim() } else { '' }
  if (-not $owner) { return @{ state = 'none'; why = 'no usable app login: the seat has no owner-uuid.txt' } }
  # Reading the files can fail for a moment (the app rewriting its config.json, a lock): "busy", which the caller treats as a passing failure.
  # Only the decryption failing, with the files read, is "unreadable": that does not change until the app signs in again.
  try {
    $cfg = Get-Content -LiteralPath $snap -Raw | ConvertFrom-Json -AsHashtable
    if ($cfg['lastKnownAccountUuid'] -and $cfg['lastKnownAccountUuid'] -ne $owner) { return @{ state = 'none'; why = 'no usable app login: the snapshot is another account' } }
    $live = Join-Path $AppDir 'config.json'
    if (Test-Path -LiteralPath $live) {
      $lc = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json -AsHashtable
      if ($lc['lastKnownAccountUuid'] -eq $owner -and $lc['oauth:tokenCacheV2']) { $cfg = $lc }        # the live seat: the app's own, fresher copy (not a signed-out one with no login in it)
    }
    if (-not $cfg['oauth:tokenCacheV2']) { return @{ state = 'none'; why = 'no app login token in it' } }
    $ls = Get-Content -LiteralPath (Join-Path $AppDir 'Local State') -Raw | ConvertFrom-Json
    if (-not $ls -or -not $ls.os_crypt.encrypted_key) { throw 'Local State has no key yet' }     # empty / truncated: ConvertFrom-Json gives $null without throwing
  } catch { return @{ state = 'busy'; why = 'app login files could not be read just now' } }
  try {
    $cache = Unprotect-Blob (Get-AppKey $ls) $cfg['oauth:tokenCacheV2'] | ConvertFrom-Json -AsHashtable
  } catch { return @{ state = 'unreadable'; why = 'app login could not be decrypted' } }
  $now = if ($NowMs) { $NowMs } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  # entry keys: acct:<account>|<client>:<organization>:https://api.anthropic.com:<scopes>; only this seat's own account counts
  $prof = @(foreach ($k in $cache.Keys) {
      if ($k -notmatch '^acct:([^|]+)\|[^:]+:([^:]+):https://api\.anthropic\.com:(.+)$') { continue }
      $acct, $eorg, $scopes = $Matches[1], $Matches[2], " $($Matches[3]) "
      if ($acct -eq $owner -and $scopes.Contains(' user:profile ') -and $cache[$k].token) {
        [pscustomobject]@{ token = [string]$cache[$k].token; expiresAt = [double]$cache[$k].expiresAt; org = $eorg }
      }
    })
  if (-not $prof) { return @{ state = 'none'; why = 'no user:profile login for this account' } }
  if ($Org) {         # the seat's organization: the latest entry of ANOTHER organization must not hide this one's, or stand in for it
    $prof = @($prof | Where-Object { $_.org -eq $Org })
    if (-not $prof) { return @{ state = 'org'; why = 'no user:profile login for this seat''s organization' } }
  }
  $prof = @($prof | Sort-Object expiresAt -Descending)
  if ($prof[0].expiresAt -le $now) { return @{ state = 'expired'; expiresAt = [long]$prof[0].expiresAt } }
  return @{ state = 'ok'; token = $prof[0].token; expiresAt = [long]$prof[0].expiresAt; accountUuid = $owner; orgUuid = $prof[0].org }
}

if ($SelfTest) {
  $fail = 0
  function T([string]$n, [bool]$ok) { if ($ok) { Write-Host "  ok    $n" } else { $script:fail++; Write-Host "  FAIL  $n" } }
  $td = Join-Path ([IO.Path]::GetTempPath()) ('app-login-selftest-' + [guid]::NewGuid().ToString('N'))
  try {
    Add-Type -AssemblyName System.Security
    $app = Join-Path $td 'Claude'; $seats = Join-Path $td 'seats'
    New-Item -ItemType Directory -Force -Path $app, (Join-Path $seats 'A'), (Join-Path $seats 'B'), (Join-Path $seats 'C') | Out-Null
    $key = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $wrapped = [byte[]]([Text.Encoding]::ASCII.GetBytes('DPAPI') + [Security.Cryptography.ProtectedData]::Protect($key, $null, 'CurrentUser'))
    @{ os_crypt = @{ encrypted_key = [Convert]::ToBase64String($wrapped) } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'Local State')
    $enc = {
      param([string]$plain)
      $nonce = [byte[]]::new(12); [Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
      $pt = [Text.Encoding]::UTF8.GetBytes($plain); $ct = [byte[]]::new($pt.Length); $tag = [byte[]]::new(16)
      $g = [Security.Cryptography.AesGcm]::new($key, 16); try { $g.Encrypt($nonce, $pt, $ct, $tag) } finally { $g.Dispose() }
      [Convert]::ToBase64String([byte[]]([Text.Encoding]::ASCII.GetBytes('v10') + $nonce + $ct + $tag))
    }
    $now = 1800000000000
    $mk = { param($uuid, $entries) @{ lastKnownAccountUuid = $uuid; 'oauth:tokenCacheV2' = (& $enc ($entries | ConvertTo-Json -Compress)) } | ConvertTo-Json -Compress }
    $h = 'acct:u-a|c1:o1:https://api.anthropic.com:'
    (& $mk 'u-a' @{ ($h + 'user:profile') = @{ token = 'tA-old'; expiresAt = $now + 1000 }; ($h + 'user:inference user:profile user:sessions:claude_code') = @{ token = 'tA-new'; expiresAt = $now + 9000 };
                    ($h + 'user:inference') = @{ token = 'tA-noprofile'; expiresAt = $now + 99999 };
                    ('acct:u-other|c1:o1:https://api.anthropic.com:user:profile') = @{ token = 'tOTHER'; expiresAt = $now + 99999 } }) | Set-Content -LiteralPath (Join-Path $seats 'A\config.json')
    (& $mk 'u-b' @{ ('acct:u-b|c1:o1:https://api.anthropic.com:user:profile') = @{ token = 'tB'; expiresAt = $now - 5 } }) | Set-Content -LiteralPath (Join-Path $seats 'B\config.json')
    (& $mk 'u-c' @{ ('acct:u-c|c1:o1:https://api.anthropic.com:user:profile') = @{ token = 'tC-snapshot'; expiresAt = $now - 5 } }) | Set-Content -LiteralPath (Join-Path $seats 'C\config.json')
    (& $mk 'u-c' @{ ('acct:u-c|c1:o9:https://api.anthropic.com:user:profile') = @{ token = 'tC-live'; expiresAt = $now + 50 } }) | Set-Content -LiteralPath (Join-Path $app 'config.json')
    foreach ($o in @('A:u-a', 'B:u-b', 'C:u-c')) { $n, $u = $o -split ':'; Set-Content -LiteralPath (Join-Path $seats "$n\owner-uuid.txt") -Value $u -NoNewline }
    New-Item -ItemType Directory -Force -Path (Join-Path $seats 'P'), (Join-Path $seats 'N') | Out-Null
    (& $mk 'u-a' @{ ($h + 'user:profile') = @{ token = 'tA-in-P'; expiresAt = $now + 9000 }; ('acct:u-p|c1:o1:https://api.anthropic.com:user:profile') = @{ token = 'tP'; expiresAt = $now + 9000 } }) |
      Set-Content -LiteralPath (Join-Path $seats 'P\config.json')
    Set-Content -LiteralPath (Join-Path $seats 'P\owner-uuid.txt') -Value 'u-p' -NoNewline      # P's snapshot is A's account: poisoned
    Copy-Item (Join-Path $seats 'A\config.json') (Join-Path $seats 'N\config.json')                 # N has no owner-uuid.txt
    New-Item -ItemType Directory -Force -Path (Join-Path $seats 'M') | Out-Null                      # M: one account, two organizations, the other one's login expires later
    (& $mk 'u-m' @{ 'acct:u-m|c1:o1:https://api.anthropic.com:user:profile' = @{ token = 'tM-o1'; expiresAt = $now + 1000 }; 'acct:u-m|c1:o2:https://api.anthropic.com:user:profile' = @{ token = 'tM-o2'; expiresAt = $now + 9000 } }) |
      Set-Content -LiteralPath (Join-Path $seats 'M\config.json')
    Set-Content -LiteralPath (Join-Path $seats 'M\owner-uuid.txt') -Value 'u-m' -NoNewline
    $hashes = { Get-ChildItem $td -Recurse -File | ForEach-Object { (Get-FileHash $_.FullName).Hash } }
    $before = & $hashes
    $a = Get-AppLogin 'A' $app $seats $now
    T "the seat's own unexpired user:profile entry that expires last, never another account's" ($a.state -eq 'ok' -and $a.token -eq 'tA-new' -and $a.expiresAt -eq $now + 9000 -and $a.accountUuid -eq 'u-a' -and $a.orgUuid -eq 'o1')
    T 'a snapshot of another account (poisoned) -> none' ((Get-AppLogin 'P' $app $seats $now).state -eq 'none')
    T 'no owner-uuid.txt -> none' ((Get-AppLogin 'N' $app $seats $now).state -eq 'none')
    T 'with -Org, only that organization is considered' ((Get-AppLogin 'A' $app $seats $now 'o1').token -eq 'tA-new')
    $ao = Get-AppLogin 'A' $app $seats $now 'o2'
    T 'with -Org, an account with entries only for other organizations -> org, no token' ($ao.state -eq 'org' -and -not $ao.token)
    $co = Get-AppLogin 'C' $app $seats $now 'o9'
    T 'with -Org, the live config of that organization is used; another organization -> org' ($co.token -eq 'tC-live' -and (Get-AppLogin 'C' $app $seats $now 'o1').state -eq 'org')
    T 'without -Org the latest-expiring entry of any organization wins; with -Org the seat organization does' ((Get-AppLogin 'M' $app $seats $now).token -eq 'tM-o2' -and (Get-AppLogin 'M' $app $seats $now 'o1').token -eq 'tM-o1' -and (Get-AppLogin 'M' $app $seats $now 'o1').orgUuid -eq 'o1')
    $b = Get-AppLogin 'B' $app $seats $now
    T 'every user:profile entry expired -> expired, no token' ($b.state -eq 'expired' -and -not $b.token)
    $c = Get-AppLogin 'C' $app $seats $now
    T "the live seat reads the app's own, fresher config" ($c.state -eq 'ok' -and $c.token -eq 'tC-live' -and $c.orgUuid -eq 'o9')
    $liveKeep = Get-Content -LiteralPath (Join-Path $app 'config.json') -Raw
    Set-Content -LiteralPath (Join-Path $app 'config.json') -Value '{"lastKnownAccountUuid":"u-c"}'
    T 'a signed-out live config (no login in it) does not hide the seat snapshot' ((Get-AppLogin 'C' $app $seats $now).state -eq 'expired')
    Set-Content -LiteralPath (Join-Path $app 'config.json') -Value $liveKeep -NoNewline
    T 'no saved login -> none' ((Get-AppLogin 'Z' $app $seats $now).state -eq 'none')
    T 'a path in the seat name is refused' ((Get-AppLogin '..\A' $app $seats $now).state -eq 'none')
    Set-Content -LiteralPath (Join-Path $seats 'B\config.json') -Value '{"lastKnownAccountUuid":"u-b", half-written'
    T 'a config.json that cannot be parsed just now -> busy, not unreadable' ((Get-AppLogin 'B' $app $seats $now).state -eq 'busy')
    $lsPath = Join-Path $app 'Local State'; $lsKeep = Get-Content -LiteralPath $lsPath -Raw
    Set-Content -LiteralPath (Join-Path $seats 'B\config.json') -Value '{"lastKnownAccountUuid":"u-b","oauth:tokenCacheV2":"djEwgarbage"}'
    Set-Content -LiteralPath $lsPath -Value ''
    T 'an empty Local State (mid-rewrite) -> busy, not unreadable' ((Get-AppLogin 'B' $app $seats $now).state -eq 'busy')
    Set-Content -LiteralPath $lsPath -Value $lsKeep -NoNewline
    Set-Content -LiteralPath (Join-Path $seats 'B\config.json') -Value '{"lastKnownAccountUuid":"u-b","oauth:tokenCacheV2":"djEwgarbage"}'
    $before = & $hashes
    T 'an undecryptable login -> unreadable, not none' ((Get-AppLogin 'B' $app $seats $now).state -eq 'unreadable')
    T 'nothing was written' (((& $hashes) -join ',') -eq ($before -join ','))
  } finally { Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail) { Write-Host "app-login-token selftest: $fail FAILED"; exit 1 }
  Write-Host 'app-login-token selftest: ok'
  exit 0
}

Get-AppLogin $Seat $AppDir $SeatRoot $NowMs $Org | ConvertTo-Json -Compress
