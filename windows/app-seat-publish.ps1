<#
app-seat-publish.ps1 -- laptop half of the box's app-seat heartbeat.

The Merge Driver box's rotator (claude-cli-account.ps1 on Linux, Sync-AppSeatFromLaptop) must not
rotate the CLI onto the seat the Claude DESKTOP app is using, but it cannot read this laptop's
%APPDATA%. So every 5 min (task 'Claude app-seat heartbeat', via app-seat-publish-hidden.vbs) and at the
end of every successful claude-app-rotator.ps1 switch, this publishes the app's current seat to ONE open
issue in your-org/claude-config-backup titled exactly 'app-seat heartbeat (laptop -> box rotator)'.

Body (the box parses line 1 with ^app-seat:\s*([A-Za-z])\s*$ and judges freshness by the issue's
updated_at, stale after 15 min, so 'published:' must differ on every run):
    app-seat: D
    published: <ISO-8601 UTC>
    host: my-laptop
No tokens, emails or uuids go in the body.

SEAT LOOKUP: Get-AppSeatLabel is NOT copied here. It is lifted at run time, by AST, out of
claude-cli-account.ps1 (the file cannot be dot-sourced: it is a script that runs on load), so the
two can never disagree.

If no seat can be determined (or the label is not a single letter the box can parse) nothing is
published: it logs and exits, so the box keeps excluding the last seat it knew.
#>
param()

$ErrorActionPreference = 'Stop'
$Repo   = 'your-org/claude-config-backup'
$Title  = 'app-seat heartbeat (laptop -> box rotator)'
$HostId = 'my-laptop'
$Log    = Join-Path $PSScriptRoot 'app-seat-publish.log'

function Log([string]$m) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try {
    if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 256KB) {
      Get-Content $Log -Tail 200 | Set-Content "$Log.tmp" -Encoding UTF8; Move-Item "$Log.tmp" $Log -Force
    }
    Add-Content -Path $Log -Value $line -Encoding UTF8
  } catch {}
  Write-Host $line
}

try {
  # --- seat: reuse the real Get-AppSeatLabel (no copy) ---
  $src = Join-Path $PSScriptRoot 'claude-cli-account.ps1'
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
  $fn  = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AppSeatLabel' }, $true)
  if (-not $fn) { Log "SKIP: Get-AppSeatLabel not found in $src"; exit 1 }
  . ([scriptblock]::Create($fn.Extent.Text))
  $seat = [string](Get-AppSeatLabel)
  $seat = $seat.Trim()
  if (-not $seat) { Log 'SKIP: app seat could not be determined; nothing published'; exit 0 }
  if ($seat -notmatch '^[A-Za-z]$') { Log "SKIP: seat label '$seat' is not a single letter the box can parse; nothing published"; exit 0 }

  # --- find the one open heartbeat issue, or create it ---
  $env:GH_PROMPT_DISABLED = '1'
  $list = gh issue list -R $Repo --state open --limit 100 --json number,title 2>&1
  if ($LASTEXITCODE -ne 0) { Log "FAIL: gh issue list: $list"; exit 1 }
  $hit = @(($list | ConvertFrom-Json) | Where-Object { $_.title -ceq $Title }) | Sort-Object number | Select-Object -First 1

  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $body  = "app-seat: $seat`npublished: $stamp`nhost: $HostId"

  if (-not $hit) {
    $out = gh issue create -R $Repo --title $Title --body $body 2>&1
    if ($LASTEXITCODE -ne 0) { Log "FAIL: gh issue create: $out"; exit 1 }
    Log "published seat=$seat (created issue: $out)"
    exit 0
  }

  $json = @{ body = $body } | ConvertTo-Json -Compress
  $out  = $json | gh api -X PATCH "repos/$Repo/issues/$($hit.number)" --input - --jq '.updated_at' 2>&1
  if ($LASTEXITCODE -ne 0) { Log "FAIL: gh api PATCH #$($hit.number): $out"; exit 1 }
  Log "published seat=$seat issue=#$($hit.number) updated_at=$out"
} catch {
  Log "FAIL: $($_.Exception.Message)"
  exit 1
}
