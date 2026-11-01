<#
claude-resume-sessions.ps1 — after a seat rotation, nudge every running Claude Code CLI
session to resume on the new account.

Two classes of session, handled differently (see the rotator README / SessionInput.ps1):

  * VS Code integrated-terminal sessions (ConPTY) — a running session is pinned to the
    seat token it launched with, so to pick up the NEW seat it must RESTART. For each:
    capture its session-id + cwd, kill it, then focus VS Code, open a fresh terminal
    (Ctrl+Shift+`, auto-focused), relaunch `claude --resume <id>` (the pwsh profile's
    `claude` function injects the now-active seat token), and type the resume prompt.
    ConPTY can't be driven by WriteConsoleInput (proven), so this path uses real
    keystrokes (SetForegroundWindow + SendInput) — it briefly steals focus; run it while away.

  * Own-window CLI sessions (e.g. merge-pr's `cmd /c start` conhost windows) — these are
    already rotated to an account with available usage by the merge-pr skill, so they do
    NOT restart; they just need a nudge. Classic conhost windows take WriteConsoleInput
    (no focus steal) via Inject-ConsoleInput.ps1.

USAGE
  claude-resume-sessions.ps1              # act on all running sessions
  claude-resume-sessions.ps1 -DryRun      # list what WOULD happen, touch nothing
  claude-resume-sessions.ps1 -VSCodeOnly  # only the VS Code exit+resume sessions
  claude-resume-sessions.ps1 -OwnWindowOnly
  claude-resume-sessions.ps1 -Prompt 'resume'   # text to submit (default: resume)
  claude-resume-sessions.ps1 -All         # also sessions NOT stopped by a limit (old behaviour)
Tuning: -ClaudeStartupMs <ms> wait before typing the prompt into a relaunched session.

ONLY SESSIONS A LIMIT ACTUALLY STOPPED (owner, 2026-10-30). A session that finished (merged),
is waiting on a question, or is still working gets nothing: a nudge there costs a whole turn of
tokens for no reason. Stopped-by-a-limit is read from the session itself: Claude Code's
~/.claude/sessions/<pid>.json gives the session id and its status, and the newest real exchange
in its transcript must be the CLI's own rate_limit / billing_error stop. A busy or waiting session
is never touched. When the session file or transcript can't be read, it is pinged anyway
(fail-open, same as the parked-review check), and the log says so.
#>
[CmdletBinding()]
param(
  [string]$Prompt = 'resume',
  [switch]$DryRun,
  [switch]$VSCodeOnly,
  [switch]$OwnWindowOnly,
  [switch]$All,
  [int]$ClaudeStartupMs = 8000,
  [string]$ClaudeCli = "$env:USERPROFILE\.local\bin\claude.exe"
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'SessionInput.ps1')
. (Join-Path $here 'MergePrParked.ps1')

# ---- cwd of an arbitrary process, read from its PEB (works for ConPTY children, no window needed) ----
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProcCwd {
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int len, out int ret);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr baseAddr, byte[] buf, int size, out int read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_BASIC_INFORMATION { public IntPtr Reserved1, PebBaseAddress, R3, R4; public IntPtr UniqueProcessId, R6; }
  const int PROCESS_QUERY_INFORMATION = 0x0400, PROCESS_VM_READ = 0x0010;

  static IntPtr ReadPtr(IntPtr h, IntPtr addr) {
    var b = new byte[8]; int r; if (!ReadProcessMemory(h, addr, b, 8, out r) || r != 8) return IntPtr.Zero;
    return (IntPtr)BitConverter.ToInt64(b, 0);
  }
  public static string Get(int pid) {
    IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      var pbi = new PROCESS_BASIC_INFORMATION(); int ret;
      if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
      // PEB.ProcessParameters @ 0x20; RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath (UNICODE_STRING) @ 0x38
      IntPtr pp = ReadPtr(h, (IntPtr)((long)pbi.PebBaseAddress + 0x20));
      if (pp == IntPtr.Zero) return null;
      var lenBuf = new byte[2]; int rr;
      if (!ReadProcessMemory(h, (IntPtr)((long)pp + 0x38), lenBuf, 2, out rr)) return null;
      ushort len = BitConverter.ToUInt16(lenBuf, 0);
      if (len == 0 || len > 1040) return null;
      IntPtr buf = ReadPtr(h, (IntPtr)((long)pp + 0x38 + 0x8));
      if (buf == IntPtr.Zero) return null;
      var s = new byte[len]; if (!ReadProcessMemory(h, buf, s, len, out rr) || rr != len) return null;
      return Encoding.Unicode.GetString(s).TrimEnd('\\');
    } finally { CloseHandle(h); }
  }
}
'@

# ---- discover running interactive Claude TUI sessions ----
$procs = Get-CimInstance Win32_Process
$byId  = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }

function Ancestors([int]$pid_) {
  $out = @(); $cur = $pid_; $depth = 0
  while ($cur -and $depth -lt 20) {
    $p = $byId[[int]$cur]; if (-not $p) { break }
    $out += $p; $cur = [int]$p.ParentProcessId; $depth++
  }
  $out
}
# Never touch the session we're launched from (protects the user if they run this from
# inside a Claude terminal, and protects a test run). Two signals: our own ancestor chain,
# and the CLAUDE_CODE_SESSION_ID env of the launching session.
$selfAncestorPids = (Ancestors ([int]$PID) | ForEach-Object { [int]$_.ProcessId })
$selfSessionId = $env:CLAUDE_CODE_SESSION_ID
function Is-Self([int]$pid_, $sid) {
  if ($selfAncestorPids -contains $pid_) { return $true }
  if ($selfSessionId -and $sid -and ($sid -eq $selfSessionId)) { return $true }
  return $false
}
function Is-InVSCode([int]$pid_) {
  foreach ($a in (Ancestors $pid_)) { if ($a.Name -eq 'Code.exe') { return $true } }
  return $false
}
function VSCodeWindowHwnd([int]$pid_) {
  # the ancestor Code.exe that actually owns a window (not the ptyHost helper)
  foreach ($a in (Ancestors $pid_)) {
    if ($a.Name -eq 'Code.exe') {
      $wp = Get-Process -Id $a.ProcessId -EA SilentlyContinue
      if ($wp -and $wp.MainWindowHandle -ne 0) { return $wp.MainWindowHandle }
    }
  }
  # fall back to the largest VS Code window
  $c = Get-Process Code -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } |
       Sort-Object WorkingSet64 -Descending | Select-Object -First 1
  if ($c) { return $c.MainWindowHandle } else { return [IntPtr]::Zero }
}

# interactive TUI = claude.exe, NOT the Electron desktop app, NOT a headless/bridge invocation
$targets = $procs | Where-Object {
  $_.Name -eq 'claude.exe' -and $_.CommandLine -and
  $_.CommandLine -notlike '*--type=*' -and
  $_.CommandLine -notlike '*--output-format*' -and
  $_.CommandLine -notlike '*--print*' -and
  $_.CommandLine -notlike '* -p *' -and
  $_.CommandLine -notlike '*mcp serve*' -and
  $_.CommandLine -notlike '*setup-token*' -and
  # Exclude the Electron desktop app in BOTH install flavours. Its main process carries
  # no --type= switch, so without these it passes every filter above and gets treated as
  # an interactive CLI session to kill and resume. MSIX build removed 2026-08-09; the
  # WindowsApps test alone stopped matching anything.
  $_.CommandLine -notlike '*\WindowsApps\Claude_*' -and
  $_.CommandLine -notlike '*\AnthropicClaude\*'
}

function Get-SessionId($cmd) {
  if ($cmd -match '(?:--resume|-r)\s+([0-9a-fA-F-]{36})') { return $Matches[1] }
  return $null
}

# ---- was this session actually stopped by a usage limit? ----
$SessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
$ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$LimitErrors = @('rate_limit', 'billing_error')   # billing_error is the CLI's "usage limit reached"
function Get-SessionFile([int]$pid_) {
  $f = Join-Path $SessionsDir "$pid_.json"
  if (-not (Test-Path $f)) { return $null }
  try { Get-Content $f -Raw | ConvertFrom-Json } catch { $null }
}
# The newest user/assistant entry in the transcript's tail, skipping meta, sidechain and
# bookkeeping lines. $null when it can't be read.
function Get-LastExchange([string]$sessionId) {
  $t = @(Get-ChildItem $ProjectsDir -Filter "$sessionId.jsonl" -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $t) { return $null }
  try {
    $fs = [IO.File]::Open($t[0].FullName, 'Open', 'Read', 'ReadWrite')
    try {
      $n = [int][math]::Min($fs.Length, 2MB); $whole = ($n -eq $fs.Length); [void]$fs.Seek(-$n, 'End')
      $buf = New-Object byte[] $n; $read = 0
      while ($read -lt $n) { $k = $fs.Read($buf, $read, $n - $read); if ($k -le 0) { break }; $read += $k }
    } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n"
    $first = if ($whole) { 0 } else { 1 }            # a tail read can start mid-line
    for ($i = $lines.Count - 1; $i -ge $first; $i--) {
      $l = $lines[$i].Trim(); if (-not $l) { continue }
      try { $e = $l | ConvertFrom-Json } catch { continue }
      if ($e.type -notin @('user', 'assistant') -or $e.isMeta -or $e.isSidechain) { continue }
      return $e
    }
  } catch {}
  return $null
}
# 'yes' / 'no' / 'unknown', plus why.
function Test-StoppedByLimit([int]$pid_) {
  $s = Get-SessionFile $pid_
  if (-not $s -or -not $s.sessionId) { return @('unknown', 'no session file') }
  if ($s.status -in @('busy', 'waiting', 'shell')) { return @('no', "status $($s.status)$(if ($s.waitingFor) { " ($($s.waitingFor))" })") }
  $e = Get-LastExchange $s.sessionId
  if (-not $e) { return @('unknown', 'transcript unreadable') }
  if ($e.type -eq 'assistant' -and $e.isApiErrorMessage -and ([string]$e.error) -in $LimitErrors) { return @('yes', [string]$e.error) }
  if ($e.type -eq 'assistant') { return @('no', 'its last turn ended normally (finished, or waiting on a question)') }
  return @('no', 'last entry is a user message (already answered or still working)')
}

$vscode = @(); $own = @(); $skippedSelf = 0
foreach ($t in $targets) {
  $sid = Get-SessionId $t.CommandLine
  if (Is-Self ([int]$t.ProcessId) $sid) { $skippedSelf++; continue }
  $rec = [pscustomobject]@{
    Pid = [int]$t.ProcessId; Cmd = $t.CommandLine
    SessionId = $sid
    Cwd = [ProcCwd]::Get([int]$t.ProcessId)
    InVSCode = (Is-InVSCode ([int]$t.ProcessId))
  }
  if ($rec.InVSCode) { $vscode += $rec } else { $own += $rec }
}
if ($skippedSelf) { Write-Host "(skipped $skippedSelf session = the one running this script)" -ForegroundColor DarkGray }

Write-Host ("Found {0} interactive Claude session(s): {1} in VS Code, {2} own-window." -f $targets.Count, $vscode.Count, $own.Count) -ForegroundColor Cyan
foreach ($r in ($vscode + $own)) {
  $kind = if ($r.InVSCode) { 'vscode' } else { 'own' }
  Write-Host ("  [{0}] pid {1}  session {2}  cwd {3}" -f $kind, $r.Pid, ($(if ($r.SessionId) { $r.SessionId } else { '(none-> -c)' })), ($(if ($r.Cwd) { $r.Cwd } else { '?' }))) -ForegroundColor DarkGray
}

# Drop every session a limit did not stop (unless -All). The skip line's wording is what
# Ping-ActiveSessions counts, so keep the two in step.
function Select-Blocked($list) {
  foreach ($r in $list) {
    if ($All) { $r; continue }
    $v = Test-StoppedByLimit $r.Pid
    if ($v[0] -eq 'no') { Write-Host "Skipped idle session pid $($r.Pid): $($v[1])" -ForegroundColor DarkGray; continue }
    if ($v[0] -eq 'unknown') { Write-Host "  pid $($r.Pid): can't tell if a limit stopped it ($($v[1])) - pinging anyway" -ForegroundColor DarkYellow }
    $r
  }
}
$vscode = @(Select-Blocked $vscode); $own = @(Select-Blocked $own)

if ($DryRun) { Write-Host "`n-DryRun: would act on $($vscode.Count) VS Code + $($own.Count) own-window session(s); nothing was killed, relaunched, or typed." -ForegroundColor Yellow; return }

# ---- VS Code: exit + resume ----
if (-not $OwnWindowOnly) {
  foreach ($r in $vscode) {
    Write-Host "`nVS Code session pid $($r.Pid): exit + resume" -ForegroundColor Green
    $hwnd = VSCodeWindowHwnd $r.Pid
    if ($hwnd -eq [IntPtr]::Zero) { Write-Host "  no VS Code window found; skipping" -ForegroundColor Red; continue }
    $cwd = $r.Cwd
    $resumeArg = if ($r.SessionId) { "--resume $($r.SessionId)" } else { "-c" }

    Stop-Process -Id $r.Pid -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (-not [SessionInput]::Focus($hwnd)) { Write-Host "  couldn't focus VS Code; skipping" -ForegroundColor Red; continue }
    Start-Sleep -Milliseconds 400
    [SessionInput]::CtrlShift(0xC0)            # Ctrl+Shift+`  -> new integrated terminal
    Start-Sleep -Milliseconds 2500             # let the shell + profile load
    $launch = if ($cwd) { "Set-Location -LiteralPath '$($cwd.Replace("'","''"))'; claude $resumeArg" } else { "claude $resumeArg" }
    [SessionInput]::TypeText($launch)
    [SessionInput]::Enter()
    Write-Host "  launched: $launch" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds $ClaudeStartupMs # wait for the TUI to be ready
    [SessionInput]::TypeText($Prompt)
    [SessionInput]::Enter()
    Write-Host "  typed prompt: '$Prompt'" -ForegroundColor DarkGray
  }
}

# ---- own-window sessions: nudge in place ----
if (-not $VSCodeOnly) {
  $injector = Join-Path $here 'Inject-ConsoleInput.ps1'
  foreach ($r in $own) {
    # A merge-pr review PARKED on an owner decision must not be woken (owner, 2026-10-20): the
    # nudge costs it a turn and buries the pending question. Fail-open — see MergePrParked.ps1.
    # The line below is what Ping-ActiveSessions counts, so keep its wording in step with it.
    $mp = Get-MergePrTarget -CommandLine $r.Cmd
    if ($mp -and (Test-MergePrParked -Repo $mp.Repo -Pr $mp.Pr)) {
      Write-Host "`nSkipped parked review $($mp.Repo)#$($mp.Pr) (pid $($r.Pid))" -ForegroundColor DarkGray
      continue
    }
    Write-Host "`nOwn-window session pid $($r.Pid): prompt '$Prompt'" -ForegroundColor Green
    $out = & pwsh -NoProfile -File $injector -TargetPid $r.Pid -Text $Prompt 2>&1
    Write-Host "  $out" -ForegroundColor DarkGray
    if ($out -notmatch '^OK') {
      Write-Host "  WriteConsoleInput failed (session may be in Windows Terminal/ConPTY, not conhost)." -ForegroundColor Yellow
      Write-Host "  Focus that window and it will accept the prompt manually, or set the default terminal to Console Host." -ForegroundColor Yellow
    }
  }
}

Write-Host "`nDone." -ForegroundColor Cyan
