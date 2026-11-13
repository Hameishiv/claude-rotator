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
  {"state":"ok","token":"...","expiresAt":<ms>}   the user:profile entry that expires last, unexpired
  {"state":"expired","expiresAt":<ms>}            every user:profile entry has expired (opening the app on that seat refreshes it)
  {"state":"none","why":"..."}                    no saved login, no user:profile entry, or unreadable
  app-login-token.ps1 -Seat A
  app-login-token.ps1 -SelfTest                   no real file is read: a throwaway key and login in a temp folder
#>
param([string]$Seat, [string]$AppDir = (Join-Path $env:APPDATA 'Claude'), [string]$SeatRoot = (Join-Path $env:USERPROFILE '.claude-app-seats'),
      [long]$NowMs = 0, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'Idle'

function Get-AppKey([string]$Dir) {
  Add-Type -AssemblyName System.Security
  $ls = Get-Content -LiteralPath (Join-Path $Dir 'Local State') -Raw | ConvertFrom-Json
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

function Get-AppLogin([string]$Seat, [string]$AppDir, [string]$SeatRoot, [long]$NowMs) {
  if ($Seat -notmatch '^[A-Za-z0-9_-]{1,32}$') { return @{ state = 'none'; why = 'not a seat name' } }
  $snap = Join-Path (Join-Path $SeatRoot $Seat) 'config.json'
  if (-not (Test-Path -LiteralPath $snap)) { return @{ state = 'none'; why = 'no app login saved for this seat' } }
  try {
    $cfg = Get-Content -LiteralPath $snap -Raw | ConvertFrom-Json -AsHashtable
    $live = Join-Path $AppDir 'config.json'
    if (Test-Path -LiteralPath $live) {
      $lc = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json -AsHashtable
      if ($lc['lastKnownAccountUuid'] -and $lc['lastKnownAccountUuid'] -eq $cfg['lastKnownAccountUuid']) { $cfg = $lc }
    }
    if (-not $cfg['oauth:tokenCacheV2']) { return @{ state = 'none'; why = 'no app login token in it' } }
    $cache = Unprotect-Blob (Get-AppKey $AppDir) $cfg['oauth:tokenCacheV2'] | ConvertFrom-Json -AsHashtable
  } catch { return @{ state = 'none'; why = 'app login unreadable' } }
  $now = if ($NowMs) { $NowMs } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  $prof = @($cache.Keys | Where-Object { $_ -match ':https://api\.anthropic\.com:' -and $_ -match '(:| )user:profile( |$)' -and $cache[$_].token } |
            ForEach-Object { $cache[$_] } | Sort-Object { [double]$_.expiresAt } -Descending)
  if (-not $prof) { return @{ state = 'none'; why = 'no user:profile login' } }
  if ([double]$prof[0].expiresAt -le $now) { return @{ state = 'expired'; expiresAt = [long]$prof[0].expiresAt } }
  return @{ state = 'ok'; token = [string]$prof[0].token; expiresAt = [long]$prof[0].expiresAt }
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
    $h = 'acct:x|c1:o1:https://api.anthropic.com:'
    (& $mk 'u-a' @{ ($h + 'user:profile') = @{ token = 'tA-old'; expiresAt = $now + 1000 }; ($h + 'user:inference user:profile user:sessions:claude_code') = @{ token = 'tA-new'; expiresAt = $now + 9000 };
                    ($h + 'user:inference') = @{ token = 'tA-noprofile'; expiresAt = $now + 99999 } }) | Set-Content -LiteralPath (Join-Path $seats 'A\config.json')
    (& $mk 'u-b' @{ ($h + 'user:profile') = @{ token = 'tB'; expiresAt = $now - 5 } }) | Set-Content -LiteralPath (Join-Path $seats 'B\config.json')
    (& $mk 'u-c' @{ ($h + 'user:profile') = @{ token = 'tC-snapshot'; expiresAt = $now - 5 } }) | Set-Content -LiteralPath (Join-Path $seats 'C\config.json')
    (& $mk 'u-c' @{ ($h + 'user:profile') = @{ token = 'tC-live'; expiresAt = $now + 50 } }) | Set-Content -LiteralPath (Join-Path $app 'config.json')
    $hashes = { Get-ChildItem $td -Recurse -File | ForEach-Object { (Get-FileHash $_.FullName).Hash } }
    $before = & $hashes
    $a = Get-AppLogin 'A' $app $seats $now
    T 'the unexpired user:profile entry that expires last' ($a.state -eq 'ok' -and $a.token -eq 'tA-new' -and $a.expiresAt -eq $now + 9000)
    $b = Get-AppLogin 'B' $app $seats $now
    T 'every user:profile entry expired -> expired, no token' ($b.state -eq 'expired' -and -not $b.token)
    $c = Get-AppLogin 'C' $app $seats $now
    T "the live seat reads the app's own, fresher config" ($c.state -eq 'ok' -and $c.token -eq 'tC-live')
    T 'no saved login -> none' ((Get-AppLogin 'Z' $app $seats $now).state -eq 'none')
    T 'a path in the seat name is refused' ((Get-AppLogin '..\A' $app $seats $now).state -eq 'none')
    Set-Content -LiteralPath (Join-Path $seats 'B\config.json') -Value '{"lastKnownAccountUuid":"u-b","oauth:tokenCacheV2":"djEwgarbage"}'
    $before = & $hashes
    T 'an undecryptable login -> none' ((Get-AppLogin 'B' $app $seats $now).state -eq 'none')
    T 'nothing was written' (((& $hashes) -join ',') -eq ($before -join ','))
  } finally { Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail) { Write-Host "app-login-token selftest: $fail FAILED"; exit 1 }
  Write-Host 'app-login-token selftest: ok'
  exit 0
}

Get-AppLogin $Seat $AppDir $SeatRoot $NowMs | ConvertTo-Json -Compress
