<#
  Installs the local Agent Dashboard app: a logon task that runs `usage-history.py --serve` (no console window,
  via pythonw.exe) and a Start-menu shortcut that opens it as a standalone app window.
    usage-app-install.ps1              install / reinstall
    usage-app-install.ps1 -Uninstall   remove the task and the shortcut
  PowerShell 7. The task runs at Idle CPU priority (Task Scheduler priority 10); usage-history.py also lowers itself to Idle
  and starts every child at Idle, whatever launched it.
#>
param([switch]$Uninstall, [int]$Port = 8787)

$ErrorActionPreference = 'Stop'
try { (Get-Process -Id $PID).PriorityClass = 'Idle' } catch {}      # first: every child below (schtasks, the shortcut writer) inherits Idle
$dir = $PSScriptRoot
$script = Join-Path $dir 'usage-history.py'
$taskName = 'Claude usage dashboard'
$oldTask = 'Claude usage history'
$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnk = Join-Path $menu 'Agent Dashboard.lnk'
$oldLnks = @((Join-Path $menu 'Quota Management.lnk'), (Join-Path $menu 'Quota.lnk'))     # the app's earlier names
$url = "http://127.0.0.1:$Port/"

function Remove-Task($name) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

if ($Uninstall) {
    Remove-Task $taskName
    foreach ($l in @($lnk) + $oldLnks) { if (Test-Path $l) { Remove-Item $l } }
    Write-Host 'Agent Dashboard app removed.'
    return
}

$py = (py -3 -c 'import sys; print(sys.executable)').Trim()
$pythonw = Join-Path (Split-Path $py) 'pythonw.exe'
if (-not (Test-Path $pythonw)) { throw "pythonw.exe not found next to $py" }

& $py $script --make-icons
if ($LASTEXITCODE) { throw 'icon generation failed' }

Remove-Task $oldTask
Remove-Task $taskName
foreach ($l in $oldLnks) { if (Test-Path $l) { Remove-Item $l } }

$action = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$script`" --serve --port $Port" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Priority 10 `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Quota dashboard: samples AI-seat usage every 5 minutes and serves it on 127.0.0.1' | Out-Null
Start-ScheduledTask -TaskName $taskName

$up = $false
for ($i = 0; $i -lt 30 -and -not $up; $i++) {
    try { $up = (Invoke-WebRequest -Uri "${url}api/data" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 }
    catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { throw "the app did not answer on ${url}api/data within 30 s; see .usage-app-log.txt" }

$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
$browser = if (Test-Path $chrome) { $chrome } else { $edge }
$state = if ($env:QUOTA_STATE_DIR) { $env:QUOTA_STATE_DIR } else { Join-Path $HOME '.claude-cli-accounts' }
$sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sh.TargetPath = $browser
$sh.Arguments = "--app=$url"
$sh.IconLocation = Join-Path $state 'usage-app\icon.ico'
$sh.Save()

Write-Host 'Open Start, type Agent Dashboard, right-click it, Pin to taskbar.'
