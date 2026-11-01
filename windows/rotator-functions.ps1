# Claude rotator shell functions — SINGLE SOURCE OF TRUTH.
# Dot-sourced from BOTH the PowerShell 7 profile and the Windows PowerShell 5.1
# profile so `claude-rotator`, `claude-account`, claude1/2/3, etc. behave
# identically in either shell (no drift). Edit here, not in the profiles.

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
    $__act = "C:\Users\User\.claude-cli-accounts\.active"; $__prev = $env:CLAUDE_CODE_OAUTH_TOKEN
    if (Test-Path $__act) {
        $__tf = "C:\Users\User\.claude-cli-accounts\$((Get-Content $__act -Raw).Trim())\token.txt"
        if (Test-Path $__tf) { $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content $__tf -Raw).Trim() }
    }
    # Route through the local rotate proxy (claude-rotate-proxy.py) when it is up: it follows
    # rotations mid-session and retries a quota 429 on the next seat. Checked at launch, so a
    # stopped proxy means a direct session, never a broken one. CLAUDE_ROTATOR_PROXY=0 opts out.
    $__prevBase = $env:ANTHROPIC_BASE_URL
    if ($env:CLAUDE_ROTATOR_PROXY -ne '0' -and (Test-RotateProxy)) { $env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:18484' }
    try { & "C:\Users\User\.local\bin\claude.exe" @args }
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
function claude-account { pwsh -NoProfile -File "C:\Dev\Rotators\claude-app-rotator.ps1" @args }

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
function claude-rotator    { pwsh -NoProfile -File "C:\Dev\Rotators\claude-cli-account.ps1" @args }
function claude-cli-account { claude-rotator @args }   # old name kept as an alias

# Session(5h) + weekly(7d) usage for every CLI account (server-authoritative, read live from
# Anthropic rate-limit headers). Also printed automatically after each --rotate / --switch.
function claude-usage      { claude-rotator --usage @args }   # add --refresh to bypass the cache

# Backfill the desktop APP's session history with CLI / other-account sessions the app never
# recorded. The app lists only sessions it has a pointer record for; this creates the missing
# pointers (idempotent). Run after CLI work, then refresh the app's sessions panel.
function claude-sync-history { pwsh -NoProfile -File "C:\Users\User\.grok\bin\sync-app-history.ps1" @args }

# After rotating seats: resume every running Claude session on the new account. VS Code
# sessions are exited + relaunched (they're pinned to the seat they started on) and prompted
# 'resume'; own-window CLI sessions (merge-pr etc.) are just prompted 'resume'. -DryRun to preview.
function claude-resume { pwsh -NoProfile -File "C:\Dev\Rotators\claude-resume-sessions.ps1" @args }

