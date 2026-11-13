<#
test-app-relaunch.ps1 — mocked tests for claude-app-rotator.ps1 --switch <label> --relaunch.

Nothing real is closed, switched or launched: the profile folders are a temp dir, the process list is
injected (Get-AppProcs is shadowed), Stop-Process and Start-Process are shadowed to record calls, and
the arg-parse cases run in a child pwsh that exits before any action.

  pwsh -NoProfile -File windows/test-app-relaunch.ps1
#>
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

$script_ = Join-Path $PSScriptRoot 'claude-app-rotator.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("app-relaunch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$keep = @{ USERPROFILE = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
$env:USERPROFILE = $root
$env:APPDATA = Join-Path $root 'AppData'
$env:LOCALAPPDATA = Join-Path $root 'Local'
New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
try {
  # --- arg parse, in a child process (exits before touching anything) ---
  $out = & pwsh -NoProfile -File $script_ --status --relaunch 2>&1 | Out-String
  Check '--relaunch without --switch exits 2' ($LASTEXITCODE -eq 2 -and $out -match 'with --switch') "rc=$LASTEXITCODE out=$out"
  $out = & pwsh -NoProfile -File $script_ --relaunch 2>&1 | Out-String
  Check '--relaunch alone exits 2' ($LASTEXITCODE -eq 2) "rc=$LASTEXITCODE"

  . $script_          # functions only (the dot-source guard returns before any mode runs)
  Check 'dot-source parsed no --relaunch' (-not $Relaunch)

  # --- injected processes ---
  $script:closed = @(); $script:killed = @(); $script:started = @()
  function New-FakeProc([int]$id, [bool]$win) {
    $o = [pscustomobject]@{ Id = $id; MainWindowHandle = $(if ($win) { [IntPtr]1 } else { [IntPtr]::Zero }) }
    $o | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $script:closed += $this.Id; $true }
    $o
  }
  function Stop-Process { $script:killed += 1 }
  function Start-Process { param($FilePath, $ArgumentList) $script:started += , @($FilePath, @($ArgumentList)) }
  $script:CloseWaitSec = 1

  # an app that ignores the close request: abort, never force-kill
  $script:procs = @((New-FakeProc 101 $true), (New-FakeProc 102 $false))
  function Get-AppProcs { $script:procs }
  $t0 = Get-Date
  $r = Close-AppGracefully
  Check 'stuck app: Close-AppGracefully returns $false' ($r -eq $false)
  Check 'stuck app: CloseMainWindow only on the windowed PID' (($script:closed -join ',') -eq '101') "closed=$($script:closed -join ',')"
  Check 'stuck app: nothing force-killed' ($script:killed.Count -eq 0)
  Check 'stuck app: waited about CloseWaitSec' (((Get-Date) - $t0).TotalSeconds -ge 0.9)

  # the whole --relaunch path with a stuck app, in a child pwsh: ABORTED, exit 1, nothing switched, nothing launched
  $seat = Join-Path $root '.claude-app-seats\B'
  New-Item -ItemType Directory -Path $seat -Force | Out-Null
  '{"lastKnownAccountUuid":"u-b"}' | Set-Content (Join-Path $seat 'config.json')
  $child = @"
. '$script_'
`$script:CloseWaitSec = 1
function Get-AppProcs { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o }
function Stop-Process { Write-Host 'KILLED' }
function Start-Process { Write-Host 'LAUNCHED' }
function Invoke-Switch { Write-Host 'SWITCHED' }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'stuck app: --relaunch aborts with exit 1' ($LASTEXITCODE -eq 1 -and $out -match 'ABORTED') "rc=$LASTEXITCODE out=$out"
  Check 'stuck app: no switch, no kill, no launch' ($out -cnotmatch 'SWITCHED|KILLED|LAUNCHED') $out

  # an app that closes: returns $true
  $script:closed = @()
  $script:procs = @((New-FakeProc 201 $true))
  function Get-AppProcs { $p = $script:procs; $script:procs = @(); $p }     # gone after the first look
  Check 'closing app: returns $true' ((Close-AppGracefully) -eq $true)
  Check 'not running: returns $true, nothing closed' ((Close-AppGracefully) -eq $true -and $script:closed.Count -eq 1)

  # success and failure relaunch, in a child pwsh with Invoke-Switch replaced
  foreach ($case in @(@{ name = 'switch ok'; body = "`$script:SwitchDone = `$true"; want = 'Relaunched the Claude app on seat B'; rc = 0 },
                      @{ name = 'switch refused'; body = 'exit 1'; want = 'Switch failed; relaunched the Claude app on its old login'; rc = 1 })) {
    $child = @"
. '$script_'
`$script:n = 0
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Start-Process { param(`$FilePath) Write-Host "LAUNCHED `$FilePath" }
function Find-AppLauncher { @{ file = 'fake-claude.exe'; args = @() } }
function Invoke-Switch { $($case.body) }
Invoke-SwitchRelaunch B
"@
    $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
    Check "$($case.name): exit $($case.rc), relaunched" ($LASTEXITCODE -eq $case.rc -and $out -match 'LAUNCHED fake-claude.exe' -and $out -match [regex]::Escape($case.want)) "rc=$LASTEXITCODE out=$out"
  }

  # launcher: Squirrel stub first, then Update.exe --processStart, else none
  $sq = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
  New-Item -ItemType Directory -Path $sq -Force | Out-Null
  function Get-AppxPackage { $null }
  Check 'no install: no launcher' ($null -eq (Find-AppLauncher))
  'x' | Set-Content (Join-Path $sq 'Update.exe')
  $l = Find-AppLauncher
  Check 'Update.exe --processStart claude.exe' ($l.file -eq (Join-Path $sq 'Update.exe') -and ($l.args -join ' ') -eq '--processStart claude.exe')
  'x' | Set-Content (Join-Path $sq 'claude.exe')
  $l = Find-AppLauncher
  Check 'Squirrel stub preferred' ($l.file -eq (Join-Path $sq 'claude.exe') -and $l.args.Count -eq 0)
  $script:started = @()
  Check 'Start-ClaudeApp launches the stub' ((Start-ClaudeApp) -and $script:started.Count -eq 1 -and $script:started[0][0] -eq (Join-Path $sq 'claude.exe'))
} finally {
  foreach ($k in $keep.Keys) { Set-Item "env:$k" $keep[$k] }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'test-app-relaunch: all passed' -ForegroundColor Green
