# Claude rotator shell functions — SINGLE SOURCE OF TRUTH.
# Dot-sourced from BOTH the PowerShell 7 profile and the Windows PowerShell 5.1
# profile so `claude-rotator`, `claude-account`, claude1/2/3, etc. behave
# identically in either shell (no drift). Edit here, not in the profiles.

# This file lives in the rotator folder. $PSScriptRoot is that folder when the profile dot-sources it
# (`. <rotator folder>\rotator-functions.ps1`), so the same file runs wherever the folder is.
$RotatorDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ProfileHome = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
function Test-AccessCooldownActive([string]$Label) {
    if (-not $Label) { return $false }
    $f = Join-Path (Join-Path (Join-Path $ProfileHome '.claude-cli-accounts') $Label) 'access-disabled.json'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    try {
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        return ([int64]$j.until -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    } catch { return $false }
}

# ---- Claude CLI ----------------------------------------------------------
# The CLI's Anthropic account comes from the Claude desktop-app bridge, NOT from
# CLAUDE_CONFIG_DIR. Launching claude.exe through a child `pwsh -File` lost the
# interactive TTY, so it fell back to --print ("Input must be provided...").
# Fix: run the real claude.exe DIRECTLY in this console. CLAUDE_CONFIG_DIR only
# isolates settings/skills/MCP (same account); to switch ACCOUNTS use `claude-account`.
function claude {
    Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue   # default (app-logged-in) account
    # Strip Claude-Code "I'm nested" markers so claude.exe starts a REAL interactive REPL
    # instead of seeing CLAUDECODE=1 and falling back to --print ("Input must be provided...").
    # These get inherited when the terminal was itself spawned under a Claude session.
    foreach ($v in 'CLAUDECODE','CLAUDE_CODE_CHILD_SESSION','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_SESSION_ID','CLAUDE_CODE_SSE_PORT','CLAUDE_CODE_USE_POWERSHELL_TOOL','CLAUDE_CODE_DISABLE_AUTO_MEMORY','AI_AGENT') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    # Inject the active CLI account's long-lived setup-token (managed by claude-cli-account).
    # No seat letter is reserved. If the active seat is already known subscription-disabled,
    # move off it before this process's first request. A healthy seat, including A, is used as-is.
    $__root = Join-Path $ProfileHome '.claude-cli-accounts'
    $__act = Join-Path $__root '.active'; $__prev = $env:CLAUDE_CODE_OAUTH_TOKEN
    # A credential command (claude setup-token / login / /login, as the FIRST argument) must run even when every seat is refused: no gate,
    # and no seat token handed to it (it makes its own credential), not even an inherited one.
    $__cred = @($args).Count -gt 0 -and "$(@($args)[0])" -in 'setup-token', 'login', '/login'
    if ($__cred) { Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue }
    if (Test-Path $__act) {
        $__label = (Get-Content $__act -Raw).Trim()
        if (-not $__cred -and $__label -and (Test-AccessCooldownActive $__label)) {
            & pwsh -NoProfile -File (Join-Path $RotatorDir 'claude-cli-account.ps1') --ensure-cli-seat
            $__label = if (Test-Path $__act) { (Get-Content $__act -Raw).Trim() } else { '' }
            if ($__label -and (Test-AccessCooldownActive $__label)) {
                Write-Host "Active seat '$__label' is subscription-disabled and no other eligible seat is available. Not starting Claude Code." -ForegroundColor Red
                $global:LASTEXITCODE = 1      # a refusal is a failed start: callers that test $LASTEXITCODE must not see the 0 of the --ensure-cli-seat probe above
                return
            }
        }
        if ($__label -and -not $__cred) {
            $__tf = Join-Path (Join-Path $__root $__label) 'token.txt'
            if (Test-Path $__tf) { $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content $__tf -Raw).Trim() }
        }
    }
    # Route through the local rotate proxy (claude-rotate-proxy.py) when it is up: it follows
    # rotations mid-session and retries a quota 429 or a subscription-disabled 403 on the next seat.
    # Checked at launch, so a stopped proxy means a direct session, never a broken one. CLAUDE_ROTATOR_PROXY=0 opts out.
    $__prevBase = $env:ANTHROPIC_BASE_URL
    if ($env:CLAUDE_ROTATOR_PROXY -ne '0' -and (Test-RotateProxy)) { $env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:18484' }
    try { & (Join-Path (Join-Path (Join-Path $ProfileHome '.local') 'bin') 'claude.exe') @args }
    finally {
        if ($null -eq $__prev) { Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_OAUTH_TOKEN = $__prev }
        if ($null -eq $__prevBase) { Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue } else { $env:ANTHROPIC_BASE_URL = $__prevBase }
    }
}
function Test-RotateProxy {
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync('127.0.0.1', 18484).Wait(300) -and $c.Connected; $c.Dispose(); $ok } catch { $false }
}
# claude1 / claude2 / claude3 = switch the active CLI account to A / B / C, then launch in the
# SHARED ~/.claude config. All accounts share ONE config -- same skills, MCP connectors,
# and session history -- and only the auth token changes. The switch goes through claude-rotator,
# which updates .active, the env var, AND ~/.claude/.credentials.json (so app-spawned sessions follow
# too). No more separate seat config dirs: pointing claude3 at the (empty/missing) ~/.claude-seat3 was
# exactly what made account C open with no skills and no session history.
# Plain `claude` (above) launches the CURRENT active account WITHOUT switching.
function claude1 { claude-rotator --switch A; claude @args }
function claude2 { claude-rotator --switch B; claude @args }
function claude3 { claude-rotator --switch C; claude @args }
function claude4 { claude-rotator --switch D; claude @args }
function claude6 { claude-rotator --switch F; claude @args }
function claude7 { claude-rotator --switch G; claude @args }
function claude-both {
    Start-Process pwsh -ArgumentList '-NoExit', '-Command', 'claude'    # 2nd shared-config window (same active account)
    claude                                                              # and one in this window
}

# Switch the Claude DESKTOP APP account (swaps %APPDATA%\Claude login state). Does NOT
# touch the CLI — the CLI has its own login in ~/.claude/.credentials.json. App closed.
function claude-account { pwsh -NoProfile -File (Join-Path $RotatorDir 'claude-app-rotator.ps1') @args }

# Kill background CLI processes (NOT the desktop app). Safe to run any time.
# Spares the desktop app in BOTH install flavours -- WindowsApps\Claude (MSIX) and
# AnthropicClaude (Squirrel, %LOCALAPPDATA%) -- plus chrome-native-host (app extension).
# The MSIX build was removed 2026-08-09; without the AnthropicClaude exclusion this
# function would have killed the desktop app it is supposed to leave alone.
function claude-kill {
    $killed = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -like '*claude*' -and
            $_.Path -notlike '*WindowsApps*' -and
            $_.Path -notlike '*AnthropicClaude*' -and
            $_.Path -notlike '*chrome-native-host*'
        } catch { $false }
    }
    if (-not $killed) { Write-Host "No background CLI claude processes found." -ForegroundColor Green; return }
    $killed | ForEach-Object { Write-Host "Killing PID $($_.Id): $($_.Path)" -ForegroundColor Yellow; Stop-Process -Id $_.Id -Force }
    Write-Host "Done." -ForegroundColor Green
}

# Switch the Claude CODE CLI (terminal + VS Code) between Anthropic accounts via long-lived
# setup-tokens (CLAUDE_CODE_OAUTH_TOKEN). Commands: --status / --switch <l> / --rotate / --usage.
function claude-rotator    { pwsh -NoProfile -File (Join-Path $RotatorDir 'claude-cli-account.ps1') @args }
function claude-cli-account { claude-rotator @args }   # old name kept as an alias

# Session(5h) + weekly(7d) usage for every CLI account (server-authoritative, read live from
# Anthropic rate-limit headers). Also printed automatically after each --rotate / --switch.
function claude-usage      { claude-rotator --usage @args }   # add --refresh to bypass the cache

# Backfill the desktop APP's session history with CLI / other-account sessions the app never
# recorded. The app lists only sessions it has a pointer record for; this creates the missing
# pointers (idempotent). Run after CLI work, then refresh the app's sessions panel.
function claude-sync-history { pwsh -NoProfile -File (Join-Path (Join-Path (Join-Path $ProfileHome '.grok') 'bin') 'sync-app-history.ps1') @args }

# After rotating seats: resume every running Claude session on the new account. VS Code
# sessions are exited + relaunched (they're pinned to the seat they started on) and prompted
# 'resume'; own-window CLI sessions (merge-pr etc.) are just prompted 'resume'. -DryRun to preview.
function claude-resume { pwsh -NoProfile -File (Join-Path $RotatorDir 'claude-resume-sessions.ps1') @args }


# rotator-sync: keep this folder identical to the repo (see README-claude-rotator.md, "Keeping the install in sync").
# It runs at Idle CPU priority from its first instruction: this shell drops to Idle while starting it (a child inherits an Idle
# parent's class) and goes back to its own priority afterwards.
function rotator-sync {
    $me = Get-Process -Id $PID; $was = $me.PriorityClass
    try { $me.PriorityClass = 'Idle'; py -3 (Join-Path $RotatorDir 'rotator-sync.py') @args } finally { $me.PriorityClass = $was }
}

# Machine-local functions (e.g. other tools' wrappers) live in a git-ignored file so this one can match the repo.
$RotatorLocalFunctions = Join-Path $RotatorDir 'rotator-functions.local.ps1'
if (Test-Path -LiteralPath $RotatorLocalFunctions) { . $RotatorLocalFunctions }
