# claude-rotator — multi-account switching for Claude Code

Switches the **Claude Code CLI** (terminal, VS Code, and app-spawned sessions) between
your Anthropic accounts by swapping a **long-lived setup-token**. All accounts share
**one** `~/.claude` config — same skills, MCP connectors, and session history — and only
the auth token changes.

- **Script:** `C:\Dev\Rotators\claude-cli-account.ps1`
- **Invoke via** the `claude-rotator` (or `claude-cli-account`) PowerShell profile function.

> **Where the scripts live** (corrected 2026-08-09 — this file used to point at
> `~\.grok\bin\` for the two rotators, where they do not exist):
>
> | Script | Real path |
> |---|---|
> | `claude-cli-account.ps1` (CLI rotator) | `C:\Dev\Rotators\` |
> | `claude-app-rotator.ps1` (app rotator) | `C:\Dev\Rotators\` |
> | `rotator-functions.ps1` (the profile functions) | `C:\Dev\Rotators\` |
> | `sync-app-history.ps1` | `C:\Users\User\.grok\bin\` |
> | `reset-seat-webview.ps1` | `C:\Users\User\.grok\bin\` |
>
> The profile does not define the functions itself — both shells dot-source
> `C:\Dev\Rotators\rotator-functions.ps1`, so **edit the functions there**.

> Supersedes the old seat-based design. There are **no** separate `CLAUDE_CONFIG_DIR`
> seat directories anymore (`~/.claude-seat2`, `~/.claude-seat3`). An empty/missing seat
> dir is exactly what used to make account C open with no skills and no session history.

## How it works

A long-lived token from `claude setup-token` lives in a separate auth class and is **not**
revoked when you log into another account, so switching is just a matter of pointing the
right places at the right token. Each switch updates **three** sync points so every kind
of session follows:

1. `~/.claude-cli-accounts/.active` — the pointer the `claude` wrappers read on each launch.
2. `CLAUDE_CODE_OAUTH_TOKEN` (User + Process env) — used by terminal / VS Code sessions.
3. `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) — used by **app-spawned**
   sessions, which ignore the env var. Its expiry is pushed +10 years and the refresh token
   blanked, so Claude Code can't silently refresh back to the previous account.

Because the config dir is shared, **all sessions read/write one store** (`~/.claude/projects`).
Nothing needs to be synced between accounts.

## Commands — rotator

Run as `claude-rotator <cmd>` (alias `claude-cli-account <cmd>`).

| Command | Aliases | What it does |
|---|---|---|
| `--status` | `--st` | Active account, all profiles, token fingerprints |
| `--list` | `--ls` | List captured account profiles |
| `--switch <label>` | `--account` / `--acct` / `--use` / `--to <label>`, or just `<label>` | Make `<label>` the active account (updates all 3 sync points) |
| `--rotate [label]` | `--toggle` / `--swap` / `--next` | Cycle to the next account — or, with a label, switch straight to it (`--rotate E` == `--switch E`) |
| `--usage` | `--u` | Session (5h) + weekly (7d) usage for every account |
| `--best` | `--headroom` | Rank accounts by headroom and name the winner. `best` is also a switch target: `--switch best` / `--rotate best` |
| `--capture <label>` | `--save` / `--add <label>` | Paste a setup-token (from `claude setup-token`) and store it |
| `--import <label> <file>` | | Load a setup-token for `<label>` from a file |
| `--clear` | `--none` / `--logout-local` | Unset the env var → revert to the stored login |
| `--help` | `--h` / `--?` | Help |

**Modifiers:** `--refresh` (bypass the usage cache for live numbers) · `--no-usage` /
`--quiet` (skip the usage table normally printed after a switch/rotate).

**Speed (why it is fast again — 2026-08-13).** A switch used to take ~53s. Two causes, both fixed:

1. `[Environment]::SetEnvironmentVariable(...,'User')` took **48s** on this machine. After
   writing the registry, .NET broadcasts `WM_SETTINGCHANGE` with `SendMessageTimeout` and
   waits on every top-level window (~1s each for a busy Electron app; there were 27 windows).
   Now it writes `HKCU:\Environment` directly and fires the same notification with
   `SendNotifyMessage` — fire-and-forget, so nothing is lost, we just don't block.
2. The usage table cost ~27s: two live API probes per account, **serial**. The haiku probe
   answers in ~1s but the `claude-fable-5` probe spends **6–11s queued server-side** before it
   returns headers (streaming + `ResponseHeadersRead` does *not* help — the wait is admission,
   not generation), so the wall clock was the sum of ten round-trips. Now all ten fire at once,
   so the wall clock is the slowest *single* probe.

**Who reads live, who reads cache** (owner ruling 2026-08-13: *"`--status` should be live data,
not cached"*):

| Command | Reads | Cost |
|---|---|---|
| `--status` (incl. bare `claude-rotator`), `--usage` / `claude-usage` | **always live** | 5–13s, whatever the slowest fable probe queues at; 23 haiku + 32 fable tokens per allowed account (measured) |
| the readout after `--switch` / `--rotate` | cache only, never probes | ~2s total |
| anything with `--no-usage` / `--quiet` | no readout | ~2s |

A live `--status` rewrites the cache on its way out, so the readout on your next switch is as
fresh as your last status. Cache TTLs (switch/rotate readout only): 300s session/weekly, 3600s
fable — a 7-day window, so 1h stale is under 1% drift. `--refresh` is now the default for
`--status`/`--usage` and remains accepted as a no-op.

⚠ The 5–13s spread on a live read is **server-side queueing on the fable probe and nothing this
script controls** — the same command measured 4.9s and 12.8s minutes apart. Don't chase it as a
regression.

## Picking an account with headroom (`--best`)

`claude-rotator --best` lists usable seats in the order the watcher would rotate to them —
soonest weekly renewal first — and names the winner.
`--switch best` / `--rotate best` switch straight to it. Capped and **Fable-capped** accounts are
excluded outright, not merely ranked last — Fable runs merge-pr's Gate C.

Weekly is shown but does **not** rank an account down: it is cap-only, and penalising a high-weekly
account would be backwards when the goal is to burn that window through to 100%. This is the
Claude-side counterpart of `codex_failover_review.py`'s `pick_account`.

⚠ **Bare `--rotate` still cycles blindly** (A→B→C→D→F→G) and will happily land you on a capped seat.
`--rotate best` is the one that thinks. Whether the blind cycle should be replaced is open.

## Automatic rotation (`--check-rotate`)

⟨owner directive 2026-08-16 — his words: `~/.claude/CLAUDE-provenance.md` →
`rotator-session-only-caps-and-ping` and `rotator-90pct-weekly-renewal-order-no-fable-poll`
(both supersede the thresholds in the two earlier entries)⟩

The **`Claude usage auto-rotate`** task runs every **5 minutes**, hidden (via
`check-rotate-hidden.vbs`, the same shim pattern as `sync-app-history-hidden.vbs`).

**Three windows, three treatments — this is the whole design:**

| Window | Treatment | Why |
|---|---|---|
| **session (5h)** | **Proactive** — rotate at **85% projected**, not 85% observed | Unused session quota is barely lost: the window refills in hours and you come back to it. Rotating early is close to free, and that is what pays for the margin. |
| **weekly (7d)** | **Cap-only** — burn to 100%, rotate on rejection | Rotating a weekly window early **wastes** it. It does not refill for days. |
| **fable (7d)** | **Cap-only**, watched **risk-armed** | Same reasoning. Baseline is always free; probing arms only within 20 points of the cap. See below. |

**One probe, flat, every 5 minutes.** Haiku on the active account, 23 tokens. Weekly rides that
same response for free — both its `rejected` status and its **reset epoch**. No ramping as the
wall approaches: that existed to protect a bar near 100%, and at 90% there is margin to spare.

**The bar is tested against a PROJECTION, not the raw sample** (2026-09-22). "At 90% there is
margin to spare" was true at 2026-08 burn rates and false at 1–3 points/minute, where one probe
interval burns more than the entire 10-point gap between the bar and the wall. The watcher had
been arriving at **104%** — past the wall, seat already 429ing — and the log said
`session at 104% >= 90%`, which reads like a late trigger but is really a bar that was jumped
clean over. It now reads the slope between the two samples it already pays for and trips the
bar on `s5 + rate × interval`. Rising samples only, so a window reset cannot manufacture
a rate. **No extra probe, no extra tokens, and the probe cadence is still flat** — this is not the
frequency ramping the owner deleted. At today's 85 bar an idle seat rotates at 85%; a seat burning
3 %/min rotates at 73%, which is the same rule, not a second one.

This is the owner's pre-authorised remedy firing: the 90% bar was **explicitly provisional**
("if it fails, we'll lower"), and `CLAUDE-provenance.md` →
`rotator-90pct-weekly-renewal-order-no-fable-poll` names the trigger as *"a session capping before
a rotation lands"*. That happened on 2026-09-20 and again on 2026-09-22. Projecting rather than
flatly lowering the number was the **agent's** substitution — it lowers the effective bar only when
burn warrants, instead of giving up headroom on quiet days.

**The bar is 85 as of 2026-09-23 — the owner lowered it after a third cap, and the projection did
not save that one.** Seat C capped at 100% on 2026-09-23 16:29. ⚠ Be exact about why, because the
obvious reading is wrong and this note was first written with it: **90 was not too high for that
seat.** C burned a slow steady ~0.34 %/min, at which the projection trips at 88%, and C reached 88%
at about 15:55. The probe in that window — 16:00:41 — **failed**, one of four logged
`HttpClient.Timeout of 12 seconds` failures during the climb. So the 90 bar left a trigger window
roughly 35 minutes wide and a ~29-minute blind spell swallowed it whole.

Two things follow, and they are different fixes for different halves:

- **The probe now retries once before the watcher goes blind**, and its back-off uses
  `$SessionProbeSec` rather than a bare 300 — that 300 was the tick race from the success path
  living on in the failure path, turning one failed probe into ten minutes blind instead of five.
  That is the actual cause fix.
- **The bar at 85 is the margin**, not the cure: it puts ~44 minutes between the first
  trip-eligible probe and the wall at that burn rate, against the ~29-minute worst blind spell
  observed. The agent proposed 75 (~74 min, 2.5x the spell); the owner chose **85** on churn
  grounds — 75 rotates every seat roughly 75 minutes earlier than 90 did, which he judged too many
  switches a day. 85 is ~1.5x the worst spell, so the probe retry now carries more of this than the
  bar does. The self-check pins a 40-minute floor (`bar leaves >40 min before the wall at the
  slowest capping burn`), which passes 85 and fails 90, so raising the bar back fails a test rather
  than a seat.

The cost, which he has ruled on twice: an idle seat now rotates with 25% of its session window
unspent. It refills in ~5h and you come back to it.

**`$SessionProbeSec` is 240, deliberately not 300.** The task ticks every 300s and `$now` is read
*after* pwsh startup, measured between ~1s and ~25s depending on load. At 300 the next deadline
landed within a second of the next tick, so any tick that started faster than its predecessor
**skipped the probe entirely** for another five minutes. Measured over 549 logged triggers: 321
correct 5-minute gaps against 39 of 10 minutes and 9 of 15–30 — about 13% of probes silently lost,
and worst exactly when the machine is busy, which is when burn is fastest.

**Fable is watched risk-armed, never on a clock** (owner, 2026-08-16). The baseline is always
acquired **free**: `Select-RotationTarget` probes the candidate's Fable window on the way in, and
`--usage`/`--status`/`--best` all write `usage-cache-fable.json`. The watcher reads that file, so
it never pays to discover where Fable stands — only to watch it once that matters.

| Fable % | Distance to cap | Probe interval |
|---|---|---|
| below 80% | > 20 | **disarmed — no probe at all** |
| 80% | 20 | 1 hour |
| 90% | 10 | 30 min |
| 95% | 5 | 15 min |
| 99%+ | 1 | 15 min (floor — never more often) |

Interval is **3 min per remaining point**, floored at 15 min, ceiling 1 hour — the owner's numbers,
2026-08-16. That slope tracks the measured burn rate **1:1** (peak ~5 points per 15 min ≈ 0.33/min,
so ~3 min per point) rather than halving it for margin, and the reasoning is the whole point:
**the seat is not going to rotate out before Fable burns out anyway, so there is nothing to play
safe against.** Detecting the cap up to 15 minutes late costs nothing real — a session waiting on
Gate C simply waits.

Why this is cheap: a **capped** account 429s instantly and spends nothing, so the only state that
costs anything is "high but not yet capped". A quiet day costs **zero** Fable tokens; a seat parked
at 90% costs 48 probes/day (~1.5k tokens), and at the 15-min floor at most 96/day (~3k).

⚠ **No safety net, by explicit choice.** While disarmed nothing re-reads Fable, so a seat that
climbs past the arming line with no rotation and no manual `--usage`/`--status`/`--best` in between
stays dark until one of those happens.

⚠ **The self-write trap, if you ever touch this code:** record the CACHE's timestamp after a probe,
never `$now`. `Get-UsageCached` stamps the file a second or two later than the caller's `$now`, so
storing `$now` leaves our own write looking newer than the baseline on the next tick — which
re-seeds, zeroes the interval, and probes again every tick, silently collapsing the ladder back
into flat polling. Caught in testing 2026-08-16, not in review.

**Target order: soonest WEEKLY renewal first.** Among seats with session headroom, the one whose
weekly window renews soonest wins — that quota is use-it-or-lose-it, and burning the most
perishable first is the same reasoning as `codex_failover_review.py`'s weekly-regime tiebreak. It
costs nothing to know, since the reset epoch arrives on the probe already paid for.
A seat needs **10 points of session headroom below the bar** (owner, 2026-08-16) to compete on
renewal date; without that guard a seat at 89% would win on renewal alone and re-trigger minutes
later. If nobody is roomy, it falls back to most session headroom.

**The seat `claude-account` is on is NEVER a rotation target** (owner, 2026-08-16). The desktop app
and the CLI would draw on one account's quota, so rotating onto it burns that seat twice as fast
and takes the app down together with the CLI. Detected from the app's live account uuid in
`%APPDATA%\Claude\config.json`, mapped through `~/.claude-app-seats/<seat>/owner-uuid.txt` - the
same ground truth `claude-app-rotator.ps1` uses, and for its reason: that script's `.active`
pointer drifts whenever you log in or out inside the app by hand, so it is only the fallback.
The exclusion lives in `Rank-Accounts`, so `--best` honours it too; an explicit
`--switch <label>` still overrides, deliberately. No label is reserved by letter. Profiles kept
under `~/.claude-cli-accounts/.inactive` are old identities, not candidates, because that
directory is hidden. A subscription-disabled 403 (`oauth_org_not_allowed`) is a different event:
the active seat is refused and the watcher rotates. A timeout is not that refusal and does not
mark every seat disabled.

**After a CAP rotation only, running sessions are pinged** that their quota is back
(`claude-resume-sessions.ps1 -OwnWindowOnly`, which injects with `WriteConsoleInput` and steals no
focus — the VS Code path, which kills and relaunches, is deliberately never used here). A
*proactive* session rotation does not ping: nothing was blocked, so there is nothing to resume and
a ping would only interrupt.

⚠ **A SESSION cap counts as a cap — it did not until 2026-09-22, and that is why stalled review
sessions were never woken.** `Invoke-CheckRotate` classified only `w7_stat` and the Fable status,
never `s5_stat`, so the one window that actually blocks a running session rotated with `$capped`
unset and `Ping-ActiveSessions` was simply not called. `Rank-Accounts` had tested `s5_stat` all
along; only this branch had not. The 2026-09-22 10:06 rotation off a seat at **104%** woke nobody,
while the 2026-09-20 02:56 Fable cap pinged two sessions — same code, different window.
This does **not** widen the owner's ruling: the recorded reason a proactive rotation stays silent
is *"nothing is blocked then, so there is nothing to resume"*, and at 104% the seat is 429ing and
things are very much blocked. The projection fix above should make this branch rare; it is the
backstop for when the seat caps anyway.

**Only sessions a limit actually stopped are pinged (owner, 2026-10-30).** A finished (merged)
session, one parked on a question, and one still working all get nothing: a nudge there just
burns a turn of tokens. `claude-resume-sessions.ps1` reads `~/.claude/sessions/<pid>.json` for the
session id and status, and pings only an idle session whose newest real exchange is the CLI's
`rate_limit` / `billing_error` stop. A `busy`, `waiting` or `shell` session is never touched. If the
session file or transcript can't be read, it pings anyway (fail-open) and says so. `-All` restores
the old ping-everyone behaviour. The rotate log counts the skips (`skipped N not stopped by a limit`).

**The ping count reports what the injector confirmed.** It used to count the
`Own-window session pid` header, which `claude-resume-sessions.ps1` prints *before* attempting
`WriteConsoleInput` — so a failed inject was logged as a successful ping, in the one line you would
read to find out whether the sessions were woken. It now counts `OK injected into PID` and names
the shortfall. Attachability is worth re-checking after a terminal-default change; a harmless probe
that writes zero key records is
`pwsh -NoProfile -File Inject-ConsoleInput.ps1 -TargetPid <pid> -Text '' -NoEnter`.

**Ranking is by the SESSION window alone.** Sorting by the worse of session/weekly penalised a
high-weekly account, which is exactly backwards once weekly is something you want burned to 100%.
Capped and Fable-capped accounts are still excluded outright.

**Selection probes haiku for everyone and fable for one.** Probing fable for all five up front put
**2m14s** between `TRIGGER` and `ROTATED` in the 2026-08-16 03:06 log — long enough to look broken
and to burn several more points. Now it ranks on haiku (~1s, all accounts at once) and pays for a
fable probe one candidate at a time, normally exactly one. Measured trigger→decision: **4s**.

**Measured probe cost** (from the API's own `usage` field, not an estimate): **23 tokens** per
haiku probe, **32** per fable probe. Steady state is one haiku probe per 5 min — **~6.6k
tokens/day** — plus zero Fable while disarmed.

⚠ **Agent inference, not his words — confirm before relying on it:** only the Fable **arming line**
(20 points from the cap); the 1h/30min/15min rungs and the never-more-often-than-15-min floor are
his. Also inference: treating an unreadable fable status as not-capped; refusing
to rotate at all when nothing qualifies; and pinging only after a cap, not after a proactive
rotation. The **90% / 5 min** bar IS his ("Let's try 90%/5min. If it fails, we'll lower.") —
explicitly provisional, so if a session caps before a rotation lands, lower it.

⚠ **It failed three times — 2026-09-20 05:06, 2026-09-22 10:06, 2026-09-23 16:29 — and the bar is
now 85, which IS the remedy he named.** What shipped 2026-09-22 was the agent's substitution: keep
90, test it against a one-interval projection. That measurably works for fast burn (clean rotations
at 85%, 87%, 88%, 89% off 0.7–2.3 %/min) but did not save the third cap, which was slow burn plus a
failed probe. On 2026-09-23 he said to lower the floor; the agent proposed 75 from the blind-spell margin above
and **he chose 85**, rejecting 75 as too much churn. Also agent inference: that a **session** cap should
ping (his ping ruling names weekly and Fable, because he never contemplated the session window
capping at all; the recorded *reason* for the proactive-rotation silence is "nothing is blocked
then", which does not hold at 104%), and the probe retry.

### What rotation does and does not disturb

Rotating does **not** disturb unattended terminal sessions — they keep running through it
(owner, from practice, 2026-08-16). App work needs a close-and-reopen regardless, so it is
unaffected by this either way.

The one case where a session *is* pinned to its launch account: sessions started through the
pwsh `claude` wrapper, which injects `CLAUDE_CODE_OAUTH_TOKEN` — a process's environment cannot
be changed from outside, so those hold their original token until they restart. That is what
`claude-resume-sessions.ps1` is for, and why its header says a VS Code session must restart.
Unattended windows are not launched through the wrapper, so they authenticate from
`~/.claude/.credentials.json`, which `--switch` rewrites.

⚠ The fable window can only be read with a real `claude-fable-5` call — the `7d_oi` headers are
absent from a haiku response (verified 2026-08-13). So there is no cheap way to keep that column
live; the cache is the answer.

## Local rotate proxy (2026-10-30)

`C:\Dev\Rotators\claude-rotate-proxy.py` is a small stdlib-only pass-through proxy on
`127.0.0.1:18484`. It takes two ideas from doxaras/claude-rotate (MIT) and nothing else:

1. **It reads usage off every real response.** The `anthropic-ratelimit-unified-*` headers,
   including the Fable `7d_oi` ones when a Fable request goes through, are written to the same
   `<label>\usage-cache[-fable].json` files a probe writes, tagged `src=proxy`. The watcher uses a
   proxy reading younger than 2 min instead of probing, and the Fable ladder picks it up as a free
   baseline. This closes the blind spells behind the 09-20/09-22/09-23 caps.
2. **A quota 429, or an explicit subscription-disabled 403, retries on the next seat.** When a
   window is `rejected`, or the body is an `oauth_org_not_allowed` / "subscription access disabled"
   403, the proxy runs `--check-rotate --now --source proxy` and retries the request once on
   whatever seat that picked. A per-minute burst 429 is passed through untouched. A timeout or any
   other status is not an access refusal and does not mark seats disabled. No seat letter is
   reserved; the only seat kept out of automatic targets is the desktop app's current identity.

The proxy never picks an account. It always sends the **active** seat's token, re-read on every
request, so a running session follows a rotation without restarting. Only requests carrying one of
the rotator's own setup-tokens are re-pointed; any other token is forwarded unchanged.

**What it covers:**
- Sessions started with the `claude` profile function. The function checks the port at launch:
  if the proxy is down you get a direct session, never a broken one.
- merge-pr review windows. `merge_pr_launcher.py` → `_child_env` sets `ANTHROPIC_BASE_URL` when
  the proxy is up.

**What it cannot cover: desktop-app Code tab sessions.** The app sets
`ANTHROPIC_BASE_URL=https://api.anthropic.com` itself, and that beats every settings file. This was
tested 2026-10-30 with the app's own 2.1.309 binary and `--setting-sources=user,project,local`:
- project/local `env` never sets the base URL;
- `--settings` env sets it only when the process has none.

So close/rotate/reopen stays for the app.

| | |
|---|---|
| Task | `Claude rotate proxy`: at logon, re-launched every minute. A running instance makes the relaunch a no-op, so a dead proxy is back within a minute. |
| Health | `Invoke-RestMethod http://127.0.0.1:18484/__proxy/health` — `ok` is false while the active seat's subscription-disabled cooldown is in force. A live process with a refused seat is not healthy. |
| Log | `~\.claude-cli-accounts\.proxy-log.txt` (rolls at 1 MB) |
| Opt out | `$env:CLAUDE_ROTATOR_PROXY = "0"` for the `claude` function; `MERGE_PR_ROTATE_PROXY=0` for review windows |
| Tests | `claude-rotate-proxy.py --self-test`; `claude-rotate-proxy-test.py` (fake upstream, sandbox seats: quota 429 → rotate → retry, a running session follows, foreign token untouched, no-target returns the original 429) |

⚠ Every proxied terminal session depends on the proxy for its whole life. If it dies mid-session,
that session's requests fail until the task restarts it (≤1 min). Claude Code retries connection
errors, so this usually shows up as a pause, not a failure.

**Also new on 2026-10-30:**
- **`--check-rotate --now [--source X]`** skips the probe schedule and looks immediately. The
  proxy and the StopFailure hook use it. A `--now` check trusts a proxy reading only when that
  reading already shows a rejection; otherwise it probes live, because the session that hit the
  limit may not have gone through the proxy. A burn rate is projected only from samples at least
  2 min apart. Checks are serialised by a mutex
  (`Global\claude-rotator-check`), so the task, the hook and the proxy cannot rotate twice off one
  reading.
- **StopFailure hook.** `stopfailure-rotate.py` (next to `claude-cli-account.ps1`) is registered in
  `~\.claude\settings.json`. When any session stops on `rate_limit` / `billing_error`, or on a
  subscription-disabled 403 (`oauth_org_not_allowed`), it launches `--check-rotate --now` and
  returns at once. If the hook event has no `error` field, it reads only the transcript's newest
  API-error token. A normal stop does not fire. This is the backstop for sessions that don't go
  through the proxy.
- **Rate cap.** The watcher refuses a 4th rotation inside 10 min (`$RotateCapCount`/
  `$RotateCapWindow`), logs `RATE CAP`, and returns 3. Three rotations that fast mean every seat is
  failing.
- **Capture guards.** `--capture`/`--import` refuse a token already stored under another label,
  and refuse to overwrite a label holding a different token unless `--replace` (the old token is
  kept as `token.txt.bak-<stamp>`).

## Commands — PowerShell profile shortcuts

| Command | What it does |
|---|---|
| `claude` | Launch the **current** active account in the shared config (no switch — fastest) |
| `claude1` / `claude2` / `claude3` / `claude4` | Switch to account **A** / **B** / **C** / **D**, then launch (shared config). Seat E was removed 2026-10-12, so there is no `claude5`; `claude6` / `claude7` still map to **F** / **G** |
| `claude-both` | Open two shared-config windows on the active account |
| `claude-rotator <args>` | The rotator CLI (table above) |
| `claude-cli-account <args>` | Same as `claude-rotator` |
| `claude-usage [--refresh]` | Usage table for all accounts |
| `claude-sync-history [-Cwd <path>]` | Backfill the **desktop app** session history with CLI / other-account sessions it never recorded (see "Desktop app session history" below) |
| `claude-account <args>` | Switch the **desktop-app** login (separate tool: `claude-app-rotator.ps1`) |
| `claude-kill` | Kill background CLI `claude` processes (leaves the desktop app alone) |

`claude1/2/3/4/5` print the switch + usage before the REPL starts; plain `claude` never
switches, so it launches instantly.

## Add a new account / seat (both rotators)

Each seat is just a label (A / B / C / D / …). **Nothing is capped at three** — both
rotators enumerate whatever profiles you've captured and `--rotate` cycles all of them.
To add one end-to-end (example below uses `D` = seat6@example.com):

**CLI rotator**
1. Log into the target account in a browser, then mint a long-lived token:
   ```
   claude setup-token
   ```
2. Store it under the label, and set its display email:
   ```
   claude-rotator --capture D        # paste the token when prompted
   claude-rotator --import  D C:\path\to\token.txt   # or load from a file instead
   notepad %USERPROFILE%\.claude-cli-accounts\D\email.txt   # e.g. seat6@example.com
   ```
3. Switch to it any time: `claude-rotator --switch D` (or just `claude4`).

**Desktop app rotator** (separate login store — run with the app fully CLOSED)
1. Open the app, log in as the target account (Settings → Log out → log in), then quit it.
2. Capture that login under the **same label**:
   ```
   claude-account --capture D
   ```
3. Switch any time: `claude-account --switch D` (or `--rotate`, which now includes D).

The `email.txt` you set on the CLI side is reused by the app rotator's display, so both
tools label the seat with the same address.

## Where things live

| Path | Purpose |
|---|---|
| `~/.claude-cli-accounts/<label>/token.txt` | The setup-token (**SECRET**, local-only) |
| `~/.claude-cli-accounts/<label>/email.txt` | The label's account email (display only) |
| `~/.claude-cli-accounts/.active` | Current-account pointer |
| `~/.claude-cli-accounts/.cred-backups/` | Timestamped backups of `.credentials.json` (keeps 12) |
| `~/.claude/` | The **one shared config**: skills, MCP, `projects/` (session history), `.credentials.json` |

## Desktop app account switcher (`claude-account`)

Separate from the CLI rotator above — this swaps the **desktop app's own login**
(`C:\Dev\Rotators\claude-app-rotator.ps1`), stored under `%APPDATA%\Claude`. Keeping the app
on one seat and the CLI on another is fine; they're independent systems.

**Run from a plain terminal with the app fully quit** — capture/switch/rotate need it closed,
and quitting also ends any Claude session bridged through the app, so never run it from inside
a Claude session.

| Command | What it does |
|---|---|
| `claude-account --status` | App state, live account + account UUID, captured profiles |
| `claude-account --switch <label>` | Back up the current login, load profile `<label>` |
| `claude-account --rotate [label]` | Cycle to the next profile (or switch straight to `<label>`) |
| `claude-account --capture <label>` | Save the CURRENT app login as profile `<label>` |
| `claude-account --list` / `--help` | List profiles / print help |

Aliases: `--toggle`/`--swap`/`--next` = `--rotate`; `--use`/`--to` = `--switch`;
`--save`/`--add` = `--capture`. Unknown verbs now **error** (they used to silently print
status — that's why `-rotate`/`-toggle`, the *CLI* rotator's verbs, appeared to do nothing here).

**Every seat is pinned to its account** (`owner-uuid.txt`, written at `--capture`). A capture
refuses to run while the app's current login is already pinned to a *different* seat — you must
actually log into the target account first, otherwise the "new" seat would be a duplicate of the
old one and switching to it would silently land on the same account (how a bogus seat E briefly
shadowed c, 2026-07-07). A switch
refuses to apply a seat whose snapshot holds a different account, and the leaving login is
re-captured into the seat that *actually* matches it (by account UUID) — never into whatever
`.active` claims. **Habit rule:** switch accounts only via `claude-account`, not the app's own
Settings → Log out; if you do log in manually, quit and `--capture <label>` it right away.

After a successful `--switch`/`--rotate` it automatically runs `sync-app-history.ps1` (below),
so the account you land on shows your CLI sessions. It also **re-captures the login you're
leaving** first, so returning to a seat later doesn't force a re-sign-in — snapshots stay fresh.
(The very first switch into each seat after this still signs in once, to replace the old stale
snapshot; from then on it sticks.) Then reopen the app.

**Seat keep-alive** (`claude-app-seat-keepalive.ps1`, scheduled task `Claude app-seat keepalive`,
every 6 h, hidden). Refreshes the OAuth tokens inside every IDLE seat snapshot every 2 days (never the
live seat), and logs `DEAD` for a seat whose refresh chain has already expired, i.e. the seat that will
say "Sign in again" on its next switch-in. `-Status` / `-DryRun` / `-SelfTest`; log
`~\.claude-app-seats\.keepalive-log.txt`. It shares `.seat-write.lock` with `claude-account`, so a
switch/capture waits for it (up to 90 s). Why it exists, and what it does NOT fix:
`C:\Dev\hameishiv-wiki\wiki\handoffs\app-seat-relogin-20260922.md`.

## Desktop app session history (`claude-sync-history`)

The **CLI** (`claude --resume`) sees every session, because all accounts share one
`~/.claude/projects` transcript store. The **desktop app does not scan that store** — it
lists only sessions it has a small *pointer record* for, in its own private index under
`%APPDATA%\Claude\claude-code-sessions`. So CLI sessions — and sessions started under
another account/seat — never appear in the app's history on their own.

`claude-sync-history` adds pointer records for sessions worth keeping and **prunes** the rest
(reversibly). A session is kept only if it is **recent** (last activity within `-MaxAgeDays`,
**default 7**; `0` = no age limit) AND matches a keep category. Older sessions are pruned no
matter how substantive — the transcript is untouched and `claude --resume` still lists it.

1. **Substantive** (the only category kept by default) — not an automated dispatch (merge-pr /
   address-pr, review agents, ping tests, bare slash commands) and ≥ `-MinAssistant` assistant
   turns (default 6);
2. **Interrupted** — a NON-automated session whose transcript doesn't end with a completed
   assistant turn (died mid-tool-call, hit max-tokens, or was Esc-interrupted): resumable
   work, kept even if short (≥ 2 turns). Automated dispatches are excluded — their
   transcripts routinely end at a tool_result even when they finished normally;
3. **Died-pre-merge merge-pr / address-pr** — no merge-success marker AND an unclean tail
   (≥ 2 turns): the run crashed before merging, so it stays findable. Runs that finished
   without merging by design (PR parked for the owner) end cleanly and are pruned.

Categories 2–3 are **OFF by default** — pass `-KeepResumable` to enable them (they stay
CLI-resumable either way). When on, they skip files modified in the last 10 minutes
(still-running sessions).

**Titles:** records get real titles — an existing well-titled record from another bucket is
cloned (preserving the app's own AI titles); otherwise `/rename` customTitle → your first
typed prompt (`~/.claude/history.jsonl`) → summary record → first instruction in the
transcript → datestamp as last resort. Old `Session <datestamp>` records are retitled in
place. It writes to **every account bucket** — accounts that never tracked the workspace get
seeded with the shared workspace guid (fixed 2026-07-06: they used to be silently skipped,
which is why a fresh seat showed an empty history). App-started sessions propagate the same
way: their transcripts land in the shared store, so the next sync copies them into every
other seat's bucket. Idempotent — re-running is safe.

**Stale records are reconciled (2026-10-05).** Each seat has its own record per session, and the
app resumes from the record's `lastAssistantUuid`. Records used to be created once and never
refreshed, so a seat last used days ago showed the session only up to that point (seat A's FABDEM
record stopped at 09-29 while the transcript ran to 10-05). Every sync now finds the record that
points at the transcript's last assistant turn and copies its session state (`lastAssistantUuid`,
`completedTurns`, `postTurnSummary*`, activity times) into every record pointing at an earlier
turn. Originals are copied to `~/.claude-app-seats\.reconcile-backups\<timestamp>\`. Records
whose uuid isn't in the transcript, and sessions touched in the last 10 minutes, are left alone.

**Archives, pins and groups follow you across seats (2026-11-03).** Each seat keeps its own record
per session, with its own `isArchived` and `isStarred` (a sidebar pin). Every sync compares each
record's flags with what it saw last run (`~/.claude-app-seats\.flag-state.json`): a changed flag
(archive/un-archive, pin/unpin) is copied to every seat's record of that session, and "on" wins if two
seats changed opposite ways. The first run, and any session never seen before, use "on for any seat →
on for all". Originals backed up under `~/.claude-app-seats\.flag-sync-backups\<timestamp>\`.

The shared pin list and each seat's sidebar groups live in `%APPDATA%\Claude\claude_desktop_config.json`
(`preferences.epitaxyPrefs`: `starred-local-code-sessions`, `dframe-group-scopes`,
`dframe-code-sections`), keyed by each seat's own record ids. The sync rebuilds the pin list from the
records' `isStarred` and copies every group, its sidebar section and its sessions to every seat
(sessions matched across seats by `cliSessionId`). A group created, renamed or deleted, or a session
moved in or out of one, on any seat since the last run (`.sidebar-state.json`) is applied to all.
**This step runs only while the app is closed** (the live app rewrites that file from memory), so in
practice at a `claude-account --switch`/`--rotate`; the 30-minute task skips it and says so. The file
is backed up to `~/.claude-app-seats\.sidebar-sync-backups\<timestamp>\` before each write. A seat
shows only the group members it has a record for, so sessions pruned from a seat's history (older
than `-MaxAgeDays`) don't appear in its groups. This uses the app's undocumented internal format: an
app update that renames these keys makes the step silently do nothing until it is updated.

**The app reads its index at launch** — after a sync, new records appear when the app is
restarted (or the workspace reopened), not in an already-open window.

```
claude-sync-history                      # sync + prune C:\Dev\hameishiv (default: recent 7d + substantive)
claude-sync-history -DryRun              # preview what would add/prune, change nothing
claude-sync-history -MaxAgeDays 14       # widen/narrow the recency window (0 = keep all ages)
claude-sync-history -KeepResumable       # also keep interrupted / died-pre-merge runs
claude-sync-history -MinAssistant 10     # stricter "substantive" bar
claude-sync-history -Cwd 'C:\Dev\other'  # a different workspace
```

- Script: `C:\Users\User\.grok\bin\sync-app-history.ps1`
- Records it creates are tagged `permissionMode:"default"`; transcripts are never touched.
- **Pruned records are MOVED, not deleted** (reversible) to
  `~/.claude-app-seats\.pruned-history-backups\<timestamp>\` — restore by copying them back
  into `%APPDATA%\Claude\claude-code-sessions`. Tune what's "substantive" via `-MinAssistant`
  and the `$AutoSignature` list at the top of the script; `-NoPrune` adds without removing.
- Runs automatically after every `claude-account --switch`/`--rotate`, **and every 30 minutes**
  via the Windows scheduled task `Claude app-history sync` (hidden window, via
  `sync-app-history-hidden.vbs`; classification cached in
  `~/.claude-app-seats\.sync-classify-cache.json` so periodic runs only re-read changed
  transcripts). Manage: `Disable-ScheduledTask` / `Enable-ScheduledTask -TaskName 'Claude app-history sync'`.
  Manual runs still fine any time.

## Troubleshooting — app sidebar empty on ONE seat (others fine)

Data is intact; the seat's claude.ai **web-view state** (Local Storage etc., the dirs the
app rotator swaps) got damaged/incompletely restored by a swap. Fix (2 min): from a PLAIN
terminal, `pwsh -File C:\Users\User\.grok\bin\reset-seat-webview.ps1` — quits the app,
MOVES that seat's web-view storage to a timestamped backup under `~/.claude-app-seats\`,
keeps login cookies, relaunches. Confirmed working 2026-07-20 (seat B). Do NOT chase the
`[watch-record] i.on is not a function` warning (fires on every seat, harmless) and do NOT
assume data loss. Full record:
`C:\Dev\hameishiv-wiki\wiki\lessons\app-seat-sidebar-empty-reset-webview.md`.

## Desktop-app install flavour (MSIX vs Squirrel) — why path matching is doubled

The desktop app ships in two packaging formats, and **three scripts detect the app by
executable path**, so the format matters to them:

| | MSIX (packaged) | Squirrel (plain install) |
|---|---|---|
| Installs to | `C:\Program Files\WindowsApps\Claude_<ver>_x64__pzs8sxrjxfjjc\` | `%LOCALAPPDATA%\AnthropicClaude\app-<ver>\` |
| Process path | `...\WindowsApps\Claude_*\app\Claude.exe` | `...\AnthropicClaude\app-*\claude.exe` |
| Updates via | Windows deployment stack | its own `Update.exe` |
| Ships `cowork-svc.exe` + VM disk | **yes** (Workspace/Cowork works) | **no** |

**2026-08-09:** the MSIX was removed. Windows had flagged it `Modified, NeedsRemediation`
and refused to activate it, and because it was Developer-signed and sideloaded (not in the
Store, not in winget) there was no source for Windows to remediate from — so it could never
launch again. That is what made "the app won't open until I completely reinstall" recur for
weeks. The machine now runs the Squirrel build only; **Workspace/Cowork is unavailable**
until an `.msix` is obtained direct from Anthropic.

Consequently these four now match **both** paths, so they keep working on either machine
(the other machine may still have the MSIX):

- `rotator-functions.ps1` → `claude-kill` — *spares* the app; without the `AnthropicClaude`
  exclusion it would kill the desktop app it exists to protect.
- `claude-app-rotator.ps1` → `Get-AppProcs` — backs `Assert-Closed`. If this fails to see a
  running app, a `--switch`/`--capture` swaps `Local Storage`/`Network`/`IndexedDB` under a
  live app, which is the known cause of the empty-sidebar corruption below.
- `reset-seat-webview.ps1` — quits and relaunches the app. Also fixed 2026-08-09 to match by
  path rather than process *name*: the name `claude.exe` is shared with the Claude Code CLI,
  so the old check force-killed in-flight CLI sessions too.
- `claude-resume-sessions.ps1` — *excludes* the app from the interactive sessions it resumes.
  The app's main process carries no `--type=` switch, so with only the `WindowsApps` test it
  passed every other filter and would have been killed and "resumed" as if it were a CLI TUI.

## Notes

- **Tokens are secrets.** Never commit `~/.claude-cli-accounts`. They are stored locally
  only and never printed — the tool shows SHA-256 fingerprints, not raw tokens.
- **One active account at a time.** A switch is global: plain `claude` and app-spawned
  sessions follow the last switch. Already-open terminals keep the account they launched
  with (their env token is fixed at launch).
- **Sessions are shared, app history is not.** All accounts write transcripts to
  `~/.claude/projects` — and that includes **app-started Code sessions**, so `claude --resume`
  lists them directly with no sync needed (verified against the v2.1.197 picker internals: it
  scans the project dir and hides only SDK/daemon/sidechain sessions and ones with no extractable
  title; `claude-desktop` sessions all pass). Exceptions that can never reach the CLI: remote/
  cloud sessions and cowork agent-mode sessions (no local transcript), and plain chat (non-Code)
  conversations. The desktop app's history GUI is the opposite: it only lists sessions it has a
  pointer record for (its private index under `%APPDATA%\Claude\claude-code-sessions`), so CLI
  sessions appear there only after `claude-sync-history` runs (automatic on every
  `claude-account` switch, or run it manually).
- **Desktop-app login is separate.** `claude-account` (`claude-app-rotator.ps1`) swaps the
  Electron app's own login under `%APPDATA%\Claude`; this CLI rotator does not touch it.

## Auto-resume after a rotation (`claude-resume`)

After you rotate seats because a session ran out of usage, these nudge every running
session to continue on the new account. All the input plumbing lives in
`SessionInput.ps1` (focus + Unicode `SendInput`) and `Inject-ConsoleInput.ps1`
(`WriteConsoleInput` for classic conhost windows).

- **`claude-resume`** (`claude-resume-sessions.ps1`):
  - **VS Code sessions** are pinned to the seat token they launched with, so they are
    **exited and relaunched**: each session's id + cwd are read from its process, it is
    killed, then a fresh VS Code terminal is opened (`Ctrl+Shift+``), `claude --resume <id>`
    is run (the `claude` profile function injects the now-active seat token), and the word
    **`resume`** is typed in. ConPTY terminals can't take `WriteConsoleInput`, so this path
    uses real keystrokes and briefly steals focus — **run it while away.**
  - **Own-window CLI sessions** (e.g. merge-pr's conhost windows) are already on a spendable
    account, so they just get **`resume`** typed in via `WriteConsoleInput` (no focus steal).
  - The session running the script (and any app-spawned `stream-json` session) is skipped.
  - `-DryRun` previews; `-VSCodeOnly` / `-OwnWindowOnly` scope it; `-Prompt <text>` overrides.

> **Why `WriteConsoleInput` for conhost but keystrokes for ConPTY:** a headless pseudoconsole
> test confirmed `WriteConsoleInput` records are not delivered to a ConPTY client (VS Code /
> Windows Terminal). Classic conhost windows (what `cmd /c start` makes under the current
> "Let Windows decide" default) do accept it. If you switch the default terminal to Windows
> Terminal, own-window sessions become ConPTY and need the keystroke path instead.

## /seats (status inside a session, no model turn)

A Claude Code mod at `mods/seats/ (installed via --plugin-dir or a plugin folder)`
adds `/seats` (runs `claude-cli-account.ps1 --status`). A `command.run` hook answers the command itself, so it costs
no model turn; the status run itself is the usual live read (~5s, tiny probes). Built 2026-11-01,
tested headless with `claude -p --plugin-dir <mod folder> "/seats"`. Needs Claude Code 2.1.287+.

## Usage dashboard (`usage-history.py`)

The `Claude usage history` scheduled task runs `usage-history.py` every 5 minutes. It reads each
seat's `usage-cache[-fable].json` (it never probes), appends a line to
`~/.claude-cli-accounts/.usage-history.jsonl` (35 days kept), and rewrites
`~/.claude-cli-accounts/usage-dashboard.html` from `usage-dashboard.template.html`. The page shows
the weekly quota left (all models or Fable) as a share of the whole pool (100 % = every seat full; the headline says how many seats), the usage rate in % of the whole pool per hour, and a projection of
when the pool runs out, with each seat refilled at its weekly reset. It reloads itself every 5 min.
`--render` re-renders without sampling; `--selftest` runs the checks.

The projection uses, by default, a **typical-day profile** (button `Typical` under `Rate over`): the expected %/h for
each local hour of the day, built from the limit's whole history (up to 35 days), so nights and weekends are not
extrapolated at the daytime rate. `1h`/`3h`/`6h`/`24h` hold that recent rate flat instead. `--backtest` replays the
history, projecting 24 h ahead from every 6 h point with each method (the profile built only from data before that
point), and prints each method's mean absolute error; run it again once more history has accumulated.
Account tables badge the seat each tool is on with a blue `CLI` or violet `App` pill (Codex's app and CLI share one login, so `App`; the provider header repeats them with the seat letter) and colour
each cell: for Claude from the API's own status for that window (`allowed`, `allowed_warning`, `rejected`), for Codex,
xAI and Gemini green below 85 %, yellow from 85 %, red and `capped` at 100 %. A Codex seat with a banked reset gets an
`Apply reset` button (app only; it asks first) that runs `codexRedeemScript` (`rotator.local.json`, default
`~/.claude/skills/merge-pr/scripts/codex_redeem_reset.py`) with `--account X --confirm`; with no such file the button is
not shown. Gemini is readable only while the Antigravity app is open (the `agy` CLI keeps its token to itself).
A reading over 1 h old is shown in a muted warning colour in the `Read` column, over 3 h in a stronger one. A provider with nothing readable (Gemini with the Antigravity app closed) shows just its note.
Limit: a seat used elsewhere (the app, the VM) only updates when something probes it, so its line moves in steps.

Seats are not all the same size (a Codex Pro seat holds several times a Plus seat's allowance), so each seat has a **weight**: how many regular seats it
counts as. Set it in `rotator.local.json` (see `rotator.local.example.json`), per provider and seat letter, first match wins: `seatWeights`
(`{"claude": {"A": 1}, "codex": {"B": 5}}`), then `planWeights` by the plan the provider reports for the seat (`{"codex": {"plus": 1, "pro": 5}}`; the plan name is
matched without regard to case), then 1. There is no built-in plan table: the providers do not publish exact multipliers, so you state them. Only Codex
reports a plan, as `plan_type` in its rollout logs (`~/.codex/**/sessions/**/rollout-*.jsonl`, read locally, nothing is sent anywhere; `auth.json` is never read);
for the other providers set `seatWeights`. A seat with a weight other than 1 shows a small `×5` badge next to its letter in the account tables.

## Keeping the install in sync (`rotator-sync`)

The folder the rotator runs from and this repo's `windows/` folder must hold the same files. The one rule:
**edit on a repo branch, merge it, then run `rotator-sync --pull`.** For a hot-fix made directly in the live
folder, run `rotator-sync --push <branch>` and open a PR from that branch; the next `--pull` then changes
nothing.

Machine-specific values stay out of the scripts so the same file runs live and sits in the repo. Copy
`rotator.local.example.json` to `rotator.local.json` (git-ignored) in the live folder and fill it in:
`heartbeatRepo` and `hostId` (used by `app-seat-publish.ps1` and `claude-cli-account.ps1`; they default to
the example placeholders), `repoClone` (a local clone of this repo, used by `rotator-sync`) and, only if
the live folder is not where `rotator-sync.py` sits, `liveDir`. Extra shell functions that must not be in
the repo go in `rotator-functions.local.ps1` (git-ignored), which `rotator-functions.ps1` dot-sources if it
exists.

| Command | What it does |
|---|---|
| `rotator-sync --check [--quiet]` | Fetches the clone (at most every 6 h), then compares every file under `windows/` at `origin/main` with the live folder, ignoring CRLF/LF and a UTF-8 BOM. Lists `differing` and `missing-live` files; files only in the live folder and `rotator.local.json` / `*.local.*` are ignored. Exit 1 if anything differs. Writes `~/.claude-cli-accounts/.rotator-drift.json`. |
| `rotator-sync --pull` | Copies every differing or missing file from the ref into the live folder, first saving each overwritten file as `<name>.bak-sync-YYYYMMDD-HHMMSS`. Never touches `rotator.local.json` or `*.local.*`. |
| `rotator-sync --push <branch>` | Makes a new worktree of the clone at the ref (`--worktree <path>` to choose where), copies every differing live file into its `windows/`, commits on `<branch>` and prints the worktree path. It never pushes and never opens a PR. |
| `rotator-sync --selftest` | Runs the built-in checks in a temporary repo. |

Options: `--repo <clone>`, `--live <folder>`, `--ref <ref>` (default `origin/main`). The usage dashboard shows a
warning line when `.rotator-drift.json` lists any file, so a live folder that drifted from the repo is visible.
