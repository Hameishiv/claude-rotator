<#
claude-app-rotator.ps1  — switch the Claude DESKTOP app between Anthropic accounts,
by swapping the app's login state. (Separate from the CLI rotator,
claude-cli-account.ps1, which swaps the token CLI *sessions* use.)

WHY THIS EXISTS
  On this machine the app login is owned by the desktop app: the OAuth token
  lives in %APPDATA%\Claude\config.json (oauth:tokenCacheV2) plus the Electron web
  session (Local Storage / Session Storage / Network / Partitions / IndexedDB).
  CLAUDE_CONFIG_DIR (the CLI rotator) CANNOT switch the app account — only this can.

SAFETY CONTRACT
  - Copy-only. The ONLY "removal" on switch is a MOVE-ASIDE of the current login
    dirs into a timestamped backup (fully reversible) before the new ones are copied
    in. Nothing is ever deleted. Caches / vm_bundles are never touched.
  - REQUIRES the desktop app fully quit (capture + switch/rotate). Quitting the app
    also ends any CLI session bridged through it, so RUN THIS FROM A PLAIN TERMINAL,
    NOT from inside a Claude session.

USAGE  (run in normal PowerShell, app CLOSED for capture/switch/rotate)
  claude-app-rotator.ps1 --status            # app state, live account + UUID, profiles
  claude-app-rotator.ps1 --list              # list captured account profiles
  claude-app-rotator.ps1 --switch <label>    # back up current login, load profile <label>
  claude-app-rotator.ps1 --switch <label> --relaunch
                                             # close the running app first (gracefully; aborts if it
                                             # is still running after 30 s), switch, reopen the app
  claude-app-rotator.ps1 --rotate [label]    # cycle to the next profile (or switch to <label>)
  claude-app-rotator.ps1 --capture <label>   # save the CURRENT login as profile <label>
  claude-app-rotator.ps1 --usage [--refresh]  # per-account usage incl. Fable (app seats = the
                                              # same Anthropic accounts; delegates to the CLI rotator)
  aliases: --toggle/--swap/--next = --rotate ; --use/--to = --switch ; --save/--add = --capture

  After a successful --switch/--rotate this also runs sync-app-history.ps1, so the
  account you land on shows your CLI sessions in its history. Then reopen the app.

TYPICAL SETUP
  1) Log into account A in the app. Quit app. Run: --capture A
  2) Log into account B in the app (Settings > Log out > log in as B). Quit. --capture B
  3) Thereafter: quit app, run --switch A / --switch B / --rotate, reopen app.
#>

param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

$ErrorActionPreference = 'Continue'
$AppDir    = "$env:APPDATA\Claude"
$SeatRoot  = "$env:USERPROFILE\.claude-app-seats"
$HomeState = "$env:USERPROFILE\.claude.json"
$LoginFiles = @('config.json')
$LoginDirs  = @('Local Storage','Session Storage','Network','Partitions','IndexedDB')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-AppProcs {
  # Match BOTH desktop-app install flavours. The MSIX (WindowsApps) build was removed
  # on 2026-08-09 after Windows flagged it Modified/NeedsRemediation and refused to
  # activate it; the app now ships as a Squirrel install under %LOCALAPPDATA%.
  # Matching only the MSIX path made this return nothing, so Assert-Closed silently
  # passed and a switch would have swapped Local Storage / Network / IndexedDB out
  # from under a RUNNING app. Keep both patterns so either install is detected.
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try {
      $_.Path -like '*\WindowsApps\Claude_*\app\Claude.exe' -or
      $_.Path -like '*\AnthropicClaude\*\claude.exe'
    } catch { $false }
  }
}
function Get-LiveAccountEmail {
  if (Test-Path $HomeState) {
    try { $j = Get-Content $HomeState -Raw | ConvertFrom-Json -AsHashtable
      if ($j.ContainsKey('oauthAccount')) { return $j['oauthAccount']['emailAddress'] } } catch {}
  }
  return '(unknown)'
}
function Get-AppAccountUuid {
  $cfg = Join-Path $AppDir 'config.json'
  if (Test-Path $cfg) {
    try { $j = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
      if ($j.ContainsKey('lastKnownAccountUuid')) { return $j['lastKnownAccountUuid'] } } catch {}
  }
  return '(unknown)'
}
function Get-SeatOwnerUuid([string]$name) {
  # owner-uuid.txt = which account this seat IS, written at --capture and never touched
  # by re-capture. The permanent anchor every integrity check compares against.
  $f = Join-Path (Join-Path $SeatRoot $name) 'owner-uuid.txt'
  if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '' }
}
function Find-SeatByUuid([string]$uuid) {
  # Which captured seat is this account? The uuid in the live config.json is the ONLY
  # ground truth for what's logged in; .active and ~/.claude.json both drift when the
  # user logs in/out manually inside the app.
  if (-not $uuid -or $uuid -eq '(unknown)') { return '' }
  foreach ($p in Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' }) {
    if ((Get-SeatOwnerUuid $p.Name) -eq $uuid) { return $p.Name }
    $m = Join-Path $p.FullName 'meta.txt'   # fallback for seats captured before owner files
    if ((Test-Path $m) -and ((Get-Content $m -Raw) -match [regex]::Escape("uuid=$uuid"))) { return $p.Name }
  }
  return ''
}
function Get-ProfileEmail([string]$name) {
  # Prefer the correct email from the CLI account of the same label; fall back to meta.
  $cli = Join-Path (Join-Path (Join-Path $env:USERPROFILE '.claude-cli-accounts') $name) 'email.txt'
  if (Test-Path $cli) { return (Get-Content $cli -Raw).Trim() }
  $meta = Join-Path (Join-Path $SeatRoot $name) 'meta.txt'
  if (Test-Path $meta) { return ((Get-Content $meta -Raw) -replace '.*account=([^ ]+).*', '$1').Trim() }
  return '(no email)'
}
function Resolve-Label([string]$l) {
  # Canonicalize to the seat dir's real name: NTFS is case-insensitive, so '--rotate a'
  # switches into the A dir but would record 'a' -- which the case-SENSITIVE IndexOf in
  # rotate then can't find, breaking the cycle. Resolve once at every entry point.
  if (-not $l) { return $l }
  $hit = Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ieq $l } | Select-Object -First 1
  if ($hit) { $hit.Name } else { $l }
}
function Assert-Closed {
  $p = @(Get-AppProcs)
  if ($p.Count -gt 0) {
    Write-Host "BLOCKED: the Claude desktop app is RUNNING (PIDs: $($p.Id -join ', '))." -ForegroundColor Red
    Write-Host "Fully quit it first (tray icon > Quit, or close every window), then re-run." -ForegroundColor Yellow
    Write-Host "Note: quitting the app also ends any CLI session bridged through it." -ForegroundColor DarkGray
    exit 1
  }
}
function Enter-SeatLock {
  # Shared with claude-app-seat-keepalive.ps1: it refreshes IDLE seats' tokens in place, so a
  # switch/capture must never interleave with it (a refresh rotates the server-side token; losing
  # the race would copy a just-revoked token into the app). DeleteOnClose = a crash can't wedge it.
  $p = Join-Path $SeatRoot '.seat-write.lock'
  for ($i = 0; $i -lt 90; $i++) {
    try { return [IO.FileStream]::new($p, 'CreateNew', 'Write', 'None', 1, [IO.FileOptions]::DeleteOnClose) } catch { Start-Sleep 1 }
  }
  Write-Host "BLOCKED: $p is held (the seat keep-alive is refreshing a seat). Re-run in a minute." -ForegroundColor Red
  exit 1
}
$script:CloseWaitSec = 30
function Close-AppGracefully {
  # --relaunch: ask every app window to close, then wait. Never force-kills: a kill mid-write can tear
  # the login storage this script is about to move aside. Returns $true once no app process is left.
  $p = @(Get-AppProcs)
  if ($p.Count -eq 0) { return $true }
  Write-Host "Closing the Claude app (PIDs $($p.Id -join ', '))..." -ForegroundColor DarkGray
  foreach ($w in @($p | Where-Object { $_.MainWindowHandle -ne 0 })) { [void]$w.CloseMainWindow() }
  $deadline = (Get-Date).AddSeconds($script:CloseWaitSec)
  while ((Get-Date) -lt $deadline -and @(Get-AppProcs).Count) { Start-Sleep -Milliseconds 500 }
  return (@(Get-AppProcs).Count -eq 0)
}
function Find-AppLauncher {
  # The installed app's launcher, as {file; args}: the Squirrel stub the Start-menu shortcut runs (it starts the newest
  # app-* build), else Squirrel's Update.exe --processStart, else the MSIX package by its AUMID. $null when none is found.
  $sq = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
  if (Test-Path (Join-Path $sq 'claude.exe')) { return @{ file = (Join-Path $sq 'claude.exe'); args = @() } }
  if (Test-Path (Join-Path $sq 'Update.exe')) { return @{ file = (Join-Path $sq 'Update.exe'); args = @('--processStart', 'claude.exe') } }
  try {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Select-Object -First 1
    if ($pkg) {
      $id = @((Get-AppxPackageManifest $pkg).Package.Applications.Application)[0].Id
      if ($id) { return @{ file = "shell:AppsFolder\$($pkg.PackageFamilyName)!$id"; args = @() } }
    }
  } catch {}
  return $null
}
function Start-ClaudeApp {
  $l = Find-AppLauncher
  if (-not $l) { Write-Host "Could not find the installed Claude app to reopen; open it from the Start menu." -ForegroundColor DarkYellow; return $false }
  try {
    # The app is a user-facing program: it must not inherit this shell's class. The dashboard server runs this script at Idle (or BelowNormal), and a
    # child starts at its parent's class, so the shell goes to Normal for the launch and back after: the reverse of Get-CliVersion (claude-cli-account.ps1).
    $me = Get-Process -Id $PID; $was = $me.PriorityClass
    try {
      if ("$was" -eq 'Idle' -or "$was" -eq 'BelowNormal') { try { $me.PriorityClass = 'Normal' } catch {} }
      if ($l.args.Count) { Start-Process -FilePath $l.file -ArgumentList $l.args } else { Start-Process -FilePath $l.file }
    } finally { try { $me.PriorityClass = $was } catch {} }
    return $true
  } catch { Write-Host "Could not reopen the Claude app: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}
function Invoke-SwitchRelaunch([string]$label) {
  # --switch <label> --relaunch. Closing first, then the ordinary switch with every one of its gates; the app is reopened
  # afterwards, on the new login, or on the old one when the switch refused (Invoke-Switch exits, so this runs in finally).
  $wasRunning = @(Get-AppProcs).Count -gt 0
  if (-not (Close-AppGracefully)) {
    Write-Host "ABORTED: the Claude app was still running $($script:CloseWaitSec) s after it was asked to close (if it lives in the system tray, quit it from the tray icon and run this again). Nothing was switched; it was not force-closed (that can tear the login storage)." -ForegroundColor Red
    exit 1
  }
  $script:SwitchDone = $false
  try { Invoke-Switch $label }
  finally {
    if ($script:SwitchDone) {
      if (Start-ClaudeApp) { Write-Host "Relaunched the Claude app on seat $(Resolve-Label $label)." -ForegroundColor Green }
    } elseif ($wasRunning) {
      if (Start-ClaudeApp) { Write-Host "Switch failed; relaunched the Claude app on its old login." -ForegroundColor Red }
    }
  }
}
function Copy-Dir($src,$dst){ robocopy $src $dst /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null }
function Mirror-Dir($src,$dst){ robocopy $src $dst /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null }

function Invoke-Switch([string]$label) {
  if (-not $label) { Write-Host "Usage: --switch <label>" -ForegroundColor Red; exit 1 }
  $label = Resolve-Label $label
  $src = Join-Path $SeatRoot $label
  if (-not (Test-Path $src)) { Write-Host "No captured profile '$label'. Run --capture $label while logged into that account first." -ForegroundColor Red; exit 1 }
  # Integrity gate: never apply a seat whose snapshot holds a different account than the
  # seat was captured as. Catches any poisoned snapshot LOUDLY instead of logging you
  # into the wrong account.
  $owner = Get-SeatOwnerUuid $label
  if ($owner) {
    $snapUuid = try { (Get-Content (Join-Path $src 'config.json') -Raw | ConvertFrom-Json -AsHashtable)['lastKnownAccountUuid'] } catch { '' }
    if ($snapUuid -and $snapUuid -ne $owner) {
      Write-Host "REFUSED: seat '$label' snapshot holds account uuid $snapUuid, but the seat belongs to $owner." -ForegroundColor Red
      Write-Host "The snapshot is corrupted/poisoned. Log into the right account in the app, quit, then re-run --capture $label." -ForegroundColor Yellow
      exit 1
    }
  }
  Assert-Closed
  $seatLock = Enter-SeatLock
  # Re-capture the login we're LEAVING into its own profile FIRST, so returning to it later
  # doesn't force a re-sign-in. The seat to re-capture into is identified by the LIVE
  # login's account uuid, never by .active: a manual in-app log-in/out desyncs .active,
  # and a blind re-capture then writes the wrong account into a seat (that's exactly how
  # seat A once ended up holding the Noshim login).
  $liveUuid = Get-AppAccountUuid
  $prev = Find-SeatByUuid $liveUuid
  if ($prev -and $prev -ne $label) {
    $pdst = Join-Path $SeatRoot $prev
    foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$pdst\$f" -Force } }
    foreach ($d in $LoginDirs)  { if (Test-Path "$AppDir\$d") { Mirror-Dir "$AppDir\$d" "$pdst\$d" } }
    "captured=$stamp account=$(Get-ProfileEmail $prev) uuid=$liveUuid label=$prev" | Set-Content "$pdst\meta.txt" -Encoding UTF8
    Write-Host "Re-captured '$prev' (kept its login fresh -- no re-sign-in when you switch back)." -ForegroundColor DarkGray
  } elseif (-not $prev) {
    Write-Host "Live login (uuid $liveUuid) doesn't match any captured seat -- NOT re-capturing." -ForegroundColor DarkYellow
    Write-Host "If you logged in manually and want this login saved, quit and run --capture <label> first." -ForegroundColor DarkYellow
  }
  $bk = Join-Path $SeatRoot ".swap-backups\$stamp"
  New-Item -ItemType Directory -Path $bk -Force | Out-Null
  # 1) back up current login (files copied, dirs MOVED aside = reversible, nothing deleted)
  foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$bk\$f" -Force } }
  foreach ($d in $LoginDirs)  { if (Test-Path "$AppDir\$d") { Move-Item "$AppDir\$d" "$bk\$d" -Force } }
  # 2) apply the chosen profile
  foreach ($f in $LoginFiles) { if (Test-Path "$src\$f") { Copy-Item "$src\$f" "$AppDir\$f" -Force } }
  foreach ($d in $LoginDirs)  { if (Test-Path "$src\$d") { Copy-Dir "$src\$d" "$AppDir\$d" } }
  $label | Set-Content "$SeatRoot\.active" -Encoding UTF8
  Write-Host "Switched the Claude app login to profile '$label' ($(Get-ProfileEmail $label))." -ForegroundColor Green
  $seatLock.Dispose()
  Write-Host "Previous login backed up at: $bk" -ForegroundColor DarkGray
  # Retention (owner-approved 2026-10-20): keep the newest 10 swap backups. With no limit this folder
  # reached 181 copies / 63 GB and filled C:. Only stamp-named dirs are touched, newest first, so the
  # backup just written above is always kept; a failed delete is reported, never fatal to the switch.
  $SwapKeep = 10
  $swaps = Get-ChildItem -LiteralPath (Join-Path $SeatRoot '.swap-backups') -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending
  foreach ($old in ($swaps | Select-Object -Skip $SwapKeep)) {
    try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop }
    catch { Write-Host "Could not prune old swap backup $($old.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  # 3) make this account's app history show your CLI sessions
  $sync = "$env:USERPROFILE\.grok\bin\sync-app-history.ps1"   # stays in .grok\bin (scheduled task points there)
  if (Test-Path $sync) {
    Write-Host "Syncing session history into the app index..." -ForegroundColor DarkGray
    try { & $sync } catch { Write-Host "  (history sync skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
  }
  # 4) tell the box which seat the app is on now (heartbeat issue); never fatal to the switch
  $pub = Join-Path $PSScriptRoot 'app-seat-publish.ps1'
  if (Test-Path $pub) {
    try { & $pub | Out-Null } catch { Write-Host "  (app-seat publish skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
  }
  Write-Host "To undo: --switch <previous-label>, or restore that backup folder into $AppDir." -ForegroundColor DarkGray
  $script:SwitchDone = $true
  if (-not $Relaunch) { Write-Host "Now reopen the Claude desktop app." -ForegroundColor Cyan }
}

# ---- flag parse ----
$mode = $null; $label = $null; $Relaunch = $false
$a = @($Args | Where-Object { $_ })
for ($i=0; $i -lt $a.Count; $i++) {
  switch -regex ($a[$i]) {
    '^--?(status|st)$'        { $mode='status' }
    '^--?(usage|u)$'          { $mode='usage' }
    '^--?refresh$'            { $usageRefresh = $true }
    '^--?relaunch$'           { $Relaunch = $true }
    '^--?(list|ls)$'          { $mode='list' }
    '^--?(help|h|\?)$'        { $mode='help' }
    '^--?(capture|save|add)$' { $mode='capture'; if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(switch|use|to)$'    { $mode='switch';  if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(rotate|toggle|swap|next)$' { $mode='rotate'; if (($i+1 -lt $a.Count) -and ($a[$i+1] -notmatch '^-')){ $label=$a[$i+1]; $i++ } }
    default {
      Write-Host "Unknown command: $($a[$i])" -ForegroundColor Red
      Write-Host "Valid: --status | --list | --switch <label> | --rotate [label] | --capture <label> | --help" -ForegroundColor Yellow
      exit 2
    }
  }
}
if (-not $mode) { $mode='status' }
if ($Relaunch -and $mode -ne 'switch') { Write-Host "--relaunch works with --switch <label> only." -ForegroundColor Red; exit 2 }
# Dot-sourcing imports the functions for test-app-relaunch.ps1 (same pattern as claude-cli-account.ps1).
if ($MyInvocation.InvocationName -eq '.') { return }

New-Item -ItemType Directory -Path $SeatRoot -Force | Out-Null

switch ($mode) {
  'help' { Get-Content $PSCommandPath -TotalCount 46 | Select-Object -Skip 1; break }

  'status' {
    $procs = @(Get-AppProcs)
    Write-Host "Claude desktop app: " -NoNewline
    if ($procs.Count) { Write-Host "RUNNING (PIDs $($procs.Id -join ', '))" -ForegroundColor Yellow } else { Write-Host "not running" -ForegroundColor Green }
    $liveUuid = Get-AppAccountUuid
    $liveSeat = Find-SeatByUuid $liveUuid
    Write-Host "App account UUID (config.json)     : $liveUuid"
    if ($liveSeat) { Write-Host "Live login = seat                  : $liveSeat ($(Get-ProfileEmail $liveSeat))" }
    else { Write-Host "Live login = seat                  : (matches no captured seat)" -ForegroundColor DarkYellow }
    $active = if (Test-Path "$SeatRoot\.active") { Resolve-Label ((Get-Content "$SeatRoot\.active" -Raw).Trim()) } else { '(never switched via this tool)' }
    Write-Host "Last switched-to profile: $active"
    if ($liveSeat -and $active -and $liveSeat -ne $active) {
      Write-Host "NOTE: live login ($liveSeat) != last switch ($active) -- someone logged in/out manually in the app." -ForegroundColor Yellow
    }
    Write-Host "Captured profiles:"
    $profs = Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' }
    if ($profs) {
      $profs | ForEach-Object {
        $ts = if (Test-Path "$($_.FullName)\meta.txt") { ((Get-Content "$($_.FullName)\meta.txt" -Raw) -replace '.*captured=([0-9\-]+).*', '$1').Trim() } else { '?' }
        Write-Host "  - $($_.Name)  [$(Get-ProfileEmail $_.Name)]  captured $ts"
      }
    } else { Write-Host "  (none yet - use --capture <label>)" }
    break
  }

  'usage' {
    # App seats are the same Anthropic accounts as the CLI profiles (matched by label), so the
    # per-account windows — session, weekly, and Fable — come from the CLI rotator's probe.
    $cliArgs = @('--usage'); if ($usageRefresh) { $cliArgs += '--refresh' }
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'claude-cli-account.ps1') @cliArgs
    break
  }

  'list' {
    # Mark STAGED seats (dir exists, no captured login) the way claude-cli-account.ps1 marks
    # "(NO TOKEN)". A staged seat gets its email from the synced .claude-cli-accounts entry, so
    # without this marker it looks identical to a real one -- which is the whole failure it exists
    # to prevent: knowing the seat is there AND that you still have to log into it.
    Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' } | ForEach-Object {
      $staged = -not (Test-Path (Join-Path $_.FullName 'config.json'))
      "{0,-20} {1}{2}" -f $_.Name, (Get-ProfileEmail $_.Name), $(if ($staged) { '   (NOT CAPTURED -- run: --switch ' + $_.Name + '  to log in)' } else { '' })
    }
    break
  }

  'capture' {
    if (-not $label) { Write-Host "Usage: --capture <label>" -ForegroundColor Red; exit 1 }
    Assert-Closed
    # Duplicate-owner gate: capturing a login already pinned to ANOTHER seat just clones
    # that seat under a new name — then "switching" to the new label silently lands on the
    # old account (how seat E got captured as a copy of c, 2026-07-07). The uuid must be
    # unique across seats; log into the target account first.
    $curUuid = Get-AppAccountUuid
    $dupe = Find-SeatByUuid $curUuid
    if ($dupe -and ($dupe -ne (Resolve-Label $label))) {
      Write-Host "REFUSED: the app's current login (uuid $curUuid) is already captured as seat '$dupe' ($(Get-ProfileEmail $dupe))." -ForegroundColor Red
      Write-Host "Capturing it as '$label' would make '$label' a duplicate of '$dupe' -- switching to it would land on the same account." -ForegroundColor Yellow
      Write-Host "Open the app, log in as the '$label' account (Settings > Log out > log in), quit fully, then re-run --capture $label." -ForegroundColor Yellow
      exit 1
    }
    $seatLock = Enter-SeatLock
    $dst = Join-Path $SeatRoot $label
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$dst\$f" -Force } }
    foreach ($d in $LoginDirs)  { if (Test-Path "$AppDir\$d") { Copy-Dir "$AppDir\$d" "$dst\$d" } }
    "captured=$stamp account=$(Get-ProfileEmail $label) uuid=$(Get-AppAccountUuid) label=$label" | Set-Content "$dst\meta.txt" -Encoding UTF8
    (Get-AppAccountUuid) | Set-Content "$dst\owner-uuid.txt" -Encoding UTF8   # pins this seat to this account
    Write-Host "Captured current login as profile '$label' (uuid $(Get-AppAccountUuid)) -> $dst" -ForegroundColor Green
    $seatLock.Dispose()
    break
  }

  'switch' { if ($Relaunch) { Invoke-SwitchRelaunch $label } else { Invoke-Switch $label }; break }

  'rotate' {
    if ($label) { Invoke-Switch $label; break }
    # config.json = "this seat actually holds a captured login". Mirrors claude-cli-account.ps1's
    # Get-Candidates, which requires token.txt for exactly the same reason. Without this, an EMPTY
    # seat dir (the way you stage a seat you have not logged into yet, e.g. one that exists on the
    # other machine) joins the cycle, and --rotate silently lands on it: Invoke-Switch moves the
    # current login aside, copies nothing in, and you are logged out mid-session with no warning.
    # --switch <label> still targets an empty seat deliberately, which is how you get the login prompt.
    $names = @(Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' -and (Test-Path (Join-Path $_.FullName 'config.json')) } | Select-Object -ExpandProperty Name | Sort-Object)
    if ($names.Count -lt 2) { Write-Host "Need at least 2 CAPTURED profiles to rotate (have $($names.Count)). Seats with no config.json are staged but not captured -- use --switch <label> to log into one." -ForegroundColor Red; exit 1 }
    $cur = if (Test-Path "$SeatRoot\.active") { Resolve-Label ((Get-Content "$SeatRoot\.active" -Raw).Trim()) } else { '' }
    $idx = [array]::IndexOf($names, $cur)
    $next = if ($idx -lt 0) { $names[0] } else { $names[($idx + 1) % $names.Count] }
    Write-Host "Rotating app login: $cur -> $next" -ForegroundColor Cyan
    Invoke-Switch $next
    break
  }
}
