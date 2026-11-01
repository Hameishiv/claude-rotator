<#
SessionInput.ps1 — dot-source to load [SessionInput], the input/focus engine shared by
claude-resume-sessions.ps1.

Two delivery paths, because Windows consoles come in two flavours:
  * classic conhost  -> WriteConsoleInput after AttachConsole (no focus steal). Proven working.
  * ConPTY (VS Code / Windows Terminal) -> WriteConsoleInput is NOT delivered to the client
    (proven with a headless pseudoconsole test), so we fall back to real OS keystrokes:
    SetForegroundWindow + SendInput. That is what the VS Code path uses.

SendInput types via KEYEVENTF_UNICODE (one Unicode code unit per key event), so any text —
paths, quotes, GUIDs — is delivered verbatim with no SendKeys-style escaping and no keyboard
-layout dependence. Chords (Enter, Ctrl+Shift+`) use virtual-key codes.
#>

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class SessionInput {
  // ---- focus ----
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  const int SW_RESTORE = 9;

  // Foreground-lock-resistant focus: attach our input queue to the current foreground
  // thread's so SetForegroundWindow is honoured even when we aren't already foreground.
  public static bool Focus(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return false;
    IntPtr fg = GetForegroundWindow();
    uint us = GetCurrentThreadId();
    uint fgThread = GetWindowThreadProcessId(fg, out _);
    uint tgtThread = GetWindowThreadProcessId(hwnd, out _);
    if (fgThread != us) AttachThreadInput(us, fgThread, true);
    if (tgtThread != us && tgtThread != fgThread) AttachThreadInput(us, tgtThread, true);
    ShowWindow(hwnd, SW_RESTORE);
    BringWindowToTop(hwnd);
    bool ok = SetForegroundWindow(hwnd);
    if (fgThread != us) AttachThreadInput(us, fgThread, false);
    if (tgtThread != us && tgtThread != fgThread) AttachThreadInput(us, tgtThread, false);
    Thread.Sleep(120);
    return ok && GetForegroundWindow() == hwnd;
  }

  // ---- SendInput ----
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public int pad; }
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] pInputs, int cb);
  const uint INPUT_KEYBOARD = 1;
  const uint KEYEVENTF_KEYUP = 0x0002;
  const uint KEYEVENTF_UNICODE = 0x0004;

  static INPUT KeyVk(ushort vk, bool up) {
    var i = new INPUT(); i.type = INPUT_KEYBOARD;
    i.ki.wVk = vk; i.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0; return i;
  }
  static INPUT KeyUni(char c, bool up) {
    var i = new INPUT(); i.type = INPUT_KEYBOARD;
    i.ki.wScan = c; i.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0); return i;
  }
  static void Send(INPUT[] arr) { SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT))); }

  public static void TypeText(string s) {
    foreach (char c in s) {
      Send(new[] { KeyUni(c, false), KeyUni(c, true) });
      Thread.Sleep(4);
    }
  }
  public static void Enter() { Send(new[] { KeyVk(0x0D, false), KeyVk(0x0D, true) }); Thread.Sleep(30); }
  public static void Escape() { Send(new[] { KeyVk(0x1B, false), KeyVk(0x1B, true) }); Thread.Sleep(30); }

  // Ctrl+Shift+<vk> (used for VS Code "new terminal" = Ctrl+Shift+Backtick, vk 0xC0 OEM_3)
  public static void CtrlShift(ushort vk) {
    Send(new[] {
      KeyVk(0x11, false), KeyVk(0x10, false),   // Ctrl down, Shift down
      KeyVk(vk, false), KeyVk(vk, true),
      KeyVk(0x10, true), KeyVk(0x11, true)       // Shift up, Ctrl up
    });
    Thread.Sleep(60);
  }
}
'@
