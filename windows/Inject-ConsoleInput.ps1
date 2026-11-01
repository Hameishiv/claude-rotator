<#
Inject-ConsoleInput.ps1 — type text (and Enter) into ANOTHER process's console.

Used by claude-resume-sessions.ps1 to prompt interactive
TUI sessions (Claude Code) after a seat rotation. Works for classic conhost
windows AND ConPTY-backed terminals (VS Code integrated terminal, Windows Terminal):
AttachConsole() joins the target's console, then WriteConsoleInputW() plants key events
in its input buffer, which ConPTY renders to the app as typed input.

MUST run as its own process (it calls FreeConsole on itself): invoke as
  pwsh -NoProfile -File Inject-ConsoleInput.ps1 -TargetPid <pid> -Text "resume" [-NoEnter]
    [-EscapeFirst] [-DelayBeforeEnterMs 300]
Exit codes: 0 ok, 1 attach/write failed (target has no console or access denied).
Stdout survives FreeConsole only when redirected to a pipe (the callers capture it).
#>
param(
  [Parameter(Mandatory)][int]$TargetPid,
  [string]$Text = '',
  [switch]$NoEnter,
  [switch]$EscapeFirst,          # send ESC first (clears a TUI composer/menu before a slash command)
  [int]$DelayBeforeEnterMs = 300 # let slash-command menus settle before Enter picks the match
)

Add-Type -Namespace Win32 -Name ConIn -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateFileW(
  [MarshalAs(UnmanagedType.LPWStr)] string lpFileName, uint dwDesiredAccess, uint dwShareMode,
  IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteConsoleInputW(
  IntPtr hConsoleInput, INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr hObject);
[StructLayout(LayoutKind.Explicit, Size = 20)]
public struct INPUT_RECORD {
  [FieldOffset(0)]  public ushort EventType;        // 1 = KEY_EVENT
  [FieldOffset(4)]  public int    bKeyDown;
  [FieldOffset(8)]  public ushort wRepeatCount;
  [FieldOffset(10)] public ushort wVirtualKeyCode;
  [FieldOffset(12)] public ushort wVirtualScanCode;
  [FieldOffset(14)] public char   UnicodeChar;
  [FieldOffset(16)] public uint   dwControlKeyState;
}
'@

function New-KeyRecords([char]$c, [ushort]$vk) {
  foreach ($down in 1, 0) {
    $r = New-Object Win32.ConIn+INPUT_RECORD
    $r.EventType = 1; $r.bKeyDown = $down; $r.wRepeatCount = 1
    $r.wVirtualKeyCode = $vk; $r.UnicodeChar = $c
    $r
  }
}

function Write-Records($h, [Win32.ConIn+INPUT_RECORD[]]$recs) {
  $n = 0
  if (-not [Win32.ConIn]::WriteConsoleInputW($h, $recs, $recs.Count, [ref]$n) -or $n -ne $recs.Count) {
    throw "WriteConsoleInputW failed (wrote $n of $($recs.Count))"
  }
}

[Win32.ConIn]::FreeConsole() | Out-Null
if (-not [Win32.ConIn]::AttachConsole([uint32]$TargetPid)) {
  Write-Output "ERR AttachConsole($TargetPid) failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"
  exit 1
}
try {
  # GENERIC_READ|GENERIC_WRITE on CONIN$, OPEN_EXISTING
  $h = [Win32.ConIn]::CreateFileW('CONIN$', [uint32]3221225472, 0x3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)  # GENERIC_READ|GENERIC_WRITE
  if ($h -eq [IntPtr]::new(-1)) { Write-Output 'ERR CONIN$ open failed'; exit 1 }
  try {
    if ($EscapeFirst) {
      Write-Records $h (New-KeyRecords ([char]0x1B) 0x1B)
      Start-Sleep -Milliseconds 150
    }
    if ($Text) {
      $recs = foreach ($c in $Text.ToCharArray()) { New-KeyRecords $c 0 }
      Write-Records $h $recs
    }
    if (-not $NoEnter) {
      if ($DelayBeforeEnterMs -gt 0) { Start-Sleep -Milliseconds $DelayBeforeEnterMs }
      Write-Records $h (New-KeyRecords ([char]0x0D) 0x0D)
    }
    Write-Output "OK injected into PID $TargetPid"
    exit 0
  } finally { [Win32.ConIn]::CloseHandle($h) | Out-Null }
} finally { [Win32.ConIn]::FreeConsole() | Out-Null }
