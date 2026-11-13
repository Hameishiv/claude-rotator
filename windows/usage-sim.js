// Pooled-quota projection shared by the dashboard and its tests. Same semantics as the v1 Python project() and usage-history.py's project().
// `ratePerHour` is %/h of one regular seat, or an array of 24 of them indexed by the local hour of each step (the typical-day profile).
// A seat's optional `w` (default 1) is how many regular seats it counts as: it holds w x 100 %, its use drains in those units (a seat empties when its weighted capacity is
// used) and the pooled points are in weighted % (a full pool is 100 x the sum of the weights). A seat of weight 0 is left out.
function quotaProject(seats, ratePerHour, now, horizonSec = 14 * 86400, stepSec = 600) {
  const prof = Array.isArray(ratePerHour), anyRate = prof ? ratePerHour.some(r => r > 0) : ratePerHour > 0;
  // period must be > 0 or a roll-forward would never end; a seat without one just stops resetting.
  const ss = seats.map(s => ({ used: s.used || 0, reset: s.reset || null, period: s.period > 0 ? s.period : 0, w: s.w == null ? 1 : s.w })).filter(s => s.w > 0);
  const roll = (s, t) => { while (s.reset && s.period && s.reset <= t) { s.used = 0; s.reset += s.period; } };
  for (const s of ss) { while (s.reset && s.period && s.reset <= now) s.reset += s.period; }
  const pts = []; let empty = null;
  for (let t = now; t <= now + horizonSec; t += stepSec) {
    for (const s of ss) roll(s, t);
    const left = ss.reduce((a, s) => a + s.w * (1 - s.used), 0) * 100;
    pts.push([t, Math.round(left * 10) / 10]);
    if (empty === null && anyRate && left < 0.05) empty = t;
    const r = prof ? ratePerHour[new Date(t * 1000).getHours()] : ratePerHour;
    // The step is split at every reset inside it, and the pool's first run-out is recorded where it happens: one before a reset is not hidden
    // by the refill, and none is reported when a reset comes first.
    for (let a = t, b; a < t + stepSec; a = b) {
      b = Math.min(t + stepSec, ...ss.filter(s => s.reset && s.period && s.reset > a).map(s => s.reset));
      let drain = r > 0 ? r / 100 * (b - a) / 3600 : 0;
      const l = ss.reduce((n, s) => n + s.w * (1 - s.used), 0);
      if (empty === null && drain > 0 && drain >= l - 0.0005) empty = a + Math.round((b - a) * Math.min(1, l / drain));
      for (const s of ss.slice().sort((x, y) => (x.reset || Infinity) - (y.reset || Infinity))) {
        if (drain <= 0) break;
        const take = Math.min(s.w * (1 - s.used), drain);
        s.used += take / s.w; drain -= take;
      }
      for (const s of ss) roll(s, b);
    }
  }
  return { pts, empty };
}
// A seat's name for a table or list: always its letter, the email under it (muted, smaller) when emails are shown. `esc` escapes HTML.
// Its weight badge (a neutral "×5", only when the weight is not 1) and in-use badges (CLI / App, coloured pills) sit right after the letter; under it the email, the plan and the measured ratio.
const QUOTA_BADGE = { CLI: ['cli', 'Claude Code CLI'], App: ['app', 'Desktop app'] };
const quotaBadge = (b, seat, esc) => {
  const [cls, who] = QUOTA_BADGE[b] || ['', b], tip = who + (seat ? ' is on seat ' + seat : ' is on this seat');
  return '<span class="bdg' + (cls ? ' ' + cls : '') + '" role="img" title="' + esc(tip) + '" aria-label="' + esc(tip) + '">' + esc(seat ? b + ' ' + seat : b) + '</span>';
};
const quotaNum = n => String(+n.toFixed(2));
function quotaWeight(a, esc) {
  if (a.w == null || a.w === 1) return '';
  const tip = (a.w === 0 ? 'Left out of the pooled numbers' : 'Counts as ' + quotaNum(a.w) + ' regular seats') + (a.wsrc ? ' (from ' + a.wsrc + ')' : '');
  return '<span class="bdg wt" role="img" title="' + esc(tip) + '" aria-label="' + esc(tip) + '">×' + esc(quotaNum(a.w)) + '</span>';
}
// Codex only: the measured capacity ratio (tokens per 1 % of weekly use against the weight-1 seats) as a muted line; amber when it is more than 30 % away from the weight.
function quotaMeasure(a, esc) {
  const r = a.ratio;
  if (!r) return '';
  if (r.x == null) return '<small class="ms" title="' + esc('Needs 5 token measurements from the last 21 days; ' + r.n + ' so far') + '">measured: not enough data</small>';
  const w = a.w == null ? 1 : a.w, off = w > 0 && Math.max(r.x / w, w / r.x) > 1.3;
  const tip = 'Tokens per 1 % of weekly use over the last 21 days (input minus cached plus output), relative to the regular seats' +
    (off ? '. It differs from the configured weight (×' + quotaNum(w) + ') by more than 30 %: check the weight.' : '');
  return '<small class="ms' + (off ? ' warn' : '') + '" title="' + esc(tip) + '">measured ≈ ×' + String(+r.x.toFixed(1)) + ' (' + r.n + ' samples)</small>';
}
// Codex only: the weight the measurements suggest (a.suggest, set by the builder when the ratio is steady and far from the weight) and a button that copies the
// settings fragment for it. Nothing applies it.
const quotaFragment = (a) => '"seatWeights": {"codex": {' + JSON.stringify(a.label) + ': ' + quotaNum(a.suggest.w) + '}}';
function quotaSuggest(a, esc) {
  const s = a.suggest;
  if (!s) return '';
  return '<small class="sg">Suggested weight ×' + quotaNum(s.w) + ' (' + s.n + ' samples) <button class="cp" data-a="copyw" data-v="' + esc(quotaFragment(a)) + '">Copy setting</button></small>';
}
function quotaSeat(a, emails, esc) {
  return esc(a.label) + quotaWeight(a, esc) + (a.badges || []).map(b => quotaBadge(b, '', esc)).join('') + (emails && a.email ? '<small>' + esc(a.email) + '</small>' : '') +
    (a.plan ? '<small class="pl">Plan: ' + esc(a.plan.replace(/_/g, ' ')) + '</small>' : '') + quotaMeasure(a, esc) + quotaSuggest(a, esc);
}
// A provider header's badges with their seat letter ("CLI D", "App B") as HTML, or '' when no seat is known to be in use.
function quotaInUse(p, esc) {
  const u = p.inUse || {};
  return [['cli', 'CLI'], ['app', 'App']].filter(([k]) => u[k]).map(([k, n]) => quotaBadge(n, u[k], esc)).join('');
}
// A pooled figure as a share of the provider's whole pool: 100 % is every seat full. `cap` is 100 per seat (the blob's limit.cap); pooled %/h rates scale the same way.
const quotaShare = (v, cap) => v * 100 / (cap || 100);
// "17d 23h", "5h 12m", "12m": time left until an expiry.
function quotaIn(sec) {
  const m = Math.max(0, Math.floor(sec / 60)), d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60);
  return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + m % 60 + 'm' : m + 'm';
}
// Banked resets (Codex's, and Claude's from the read-only usage call): the count, then a muted line per credit ("x2" when a grant holds more than one, no
// expiry part when it has none); a count above the list says so. A seat that was read and has none shows an empty cell, one never read '–'.
function quotaBankedCell(a, now, fmt, esc) {
  if (a.banked == null) return a.bankedNote ? '<small>' + esc(a.bankedNote) + '</small>' : a.bankedAt ? '' : '–';     // why there is no count, e.g. a setup-token seat
  const l = a.bankedList || [], miss = a.banked - l.reduce((n, c) => n + (c.n || 1), 0);
  return a.banked + l.map(c => '<small>' + esc(c.title) + (c.n > 1 ? ' ×' + c.n : '') +
    (c.expiresAt == null ? '' : ' · expires ' + esc(fmt(c.expiresAt)) + ' (in ' + quotaIn(c.expiresAt - now) + ')') + '</small>').join('') +
    (miss > 0 ? '<small>Expiry not supplied for ' + miss + '</small>' : '');
}
// A table cell's status level: 'ok' | 'warn' | 'bad', or '' when unknown. Claude's comes from the API's own status for the window (allowed, allowed_warning,
// rejected); the others from the used fraction as displayed: capped at 100 %, a warning from 85 % (the Codex rotator's bar).
function quotaLevel(pid, w) {
  if (pid === 'claude') return { allowed: 'ok', allowed_warning: 'warn', rejected: 'bad' }[w.stat] || '';
  if (w.used == null) return '';
  const p = Math.round(w.used * 100);
  return p >= 100 ? 'bad' : p >= 85 ? 'warn' : 'ok';
}
// Claude's reset kinds, as the Apply buttons and their confirmation name them: the noun ("Apply " + noun is the button), what the reset refills, and the window
// whose renewal the dialog shows (and warns about when it is within 24 h; the 5-hour window always is, so it never warns).
const QUOTA_RESET_KINDS = {
  fable: { noun: 'Fable reset', win: 'f', refills: "Refills your Fable allowance and gives back what Fable used of your weekly limit; it doesn't reset the whole week." },
  full: { noun: 'full reset', win: 'w', refills: 'Refills your 5-hour and weekly limits.' },
  weekly: { noun: 'weekly reset', win: 'w', refills: 'Refills your weekly limit.' },
  session: { noun: '5-hour reset', win: 's', refills: 'Refills your 5-hour limit.' },
};
// The switch buttons (app mode only). A seat's roles come from the server (a.switch: the roles whose rotator can use the seat, minus the one it already
// holds); the header button only when the provider's rotator is there (p.best). Codex's header button runs the rotator's --rotate, which takes the NEXT
// saved seat, so it is not called "Best". `busy` disables every one while an action runs.
const QUOTA_SWITCH = {
  claude: { cli: ['Use for CLI', 'Switch the Claude CLI to this seat'], app: ['Use for App', 'Switch the Claude desktop app to this seat'],
    best: ['Best seat', 'Switch the Claude CLI to the seat with the most headroom'] },
  codex: { both: ['Use for CLI + App', 'Switch Codex (CLI and app, one shared login) to this seat'],
    best: ['Next seat', 'Switch Codex to the next saved seat in order (it does not rank seats by headroom)'] },
};
// Which actions ask first: the ones that close an app. The Claude CLI switch and its Best seat run on one click.
const quotaSwitchAsks = (pid, role) => pid === 'codex' || role === 'app';
function quotaSwitchBtn(pid, role, seat, busy, esc) {
  const b = (QUOTA_SWITCH[pid] || {})[role];
  if (!b) return '';
  return '<button class="sw" data-a="sw" data-p="' + esc(pid) + '" data-r="' + esc(role) + '"' + (seat ? ' data-v="' + esc(seat) + '"' : '') +
    ' title="' + esc(busy ? 'Another action is running' : b[1]) + '"' + (busy ? ' disabled' : '') + '>' + esc(b[0]) + '</button>';
}
const quotaSwitchBtns = (p, a, busy, esc) => (a.switch || []).map(r => quotaSwitchBtn(p.id, r, a.label, busy, esc)).join('');
const quotaBestBtn = (p, busy, esc) => p.best ? quotaSwitchBtn(p.id, 'best', '', busy, esc) : '';
// Sum of banked resets over a provider's seats, or null when none of them reports any.
function quotaBankedTotal(p) {
  const s = p.accounts.filter(a => a.banked != null);
  return s.length ? s.reduce((n, a) => n + a.banked, 0) : null;
}
// Why a provider has no pooled chart when every seat is weighted 0 (weight 0 leaves a seat out of the pool only): '' otherwise.
const quotaNoPool = p => p.accounts.length && p.accounts.every(a => a.w === 0) ? 'No seats counted in the pool (all weights are 0).' : '';
if (typeof module !== 'undefined') module.exports = { quotaProject, quotaWeight, quotaMeasure, quotaFragment, quotaSuggest, quotaSeat, quotaInUse, quotaShare, quotaLevel, quotaIn, quotaBankedCell, quotaBankedTotal, QUOTA_RESET_KINDS, QUOTA_SWITCH, quotaSwitchAsks, quotaSwitchBtn, quotaSwitchBtns, quotaBestBtn, quotaNoPool };
