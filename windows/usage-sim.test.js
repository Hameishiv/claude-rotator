const assert = require('assert');
const { quotaProject, quotaWeight, quotaMeasure, quotaFragment, quotaSuggest, quotaSeat, quotaInUse, quotaShare, quotaLevel, quotaIn, quotaBankedCell, quotaBankedTotal, QUOTA_RESET_KINDS, QUOTA_SWITCH, quotaSwitchAsks, quotaSwitchBtn, quotaSwitchBtns, quotaBestBtn } = require('./usage-sim.js');
const now = 1000000, far = now + 30 * 86400, W = 7 * 86400;

// two seats at 50% used, far resets, 50 %/h: 100% left, drains empty after 2 h
{
  const r = quotaProject([{ used: 0.5, reset: far, period: W }, { used: 0.5, reset: far, period: W }], 50, now);
  assert.strictEqual(r.pts[0][0], now);
  assert.strictEqual(r.pts[0][1], 100);
  assert.strictEqual(r.empty, now + 7200);
}
// capped seat resetting in 1 h, rate 0: refills at now+3600, never empty
{
  const r = quotaProject([{ used: 1, reset: now + 3600, period: W }], 0, now);
  assert.strictEqual(r.empty, null);
  assert.strictEqual(r.pts.find(p => p[0] === now + 3000)[1], 0);
  assert.strictEqual(r.pts.find(p => p[0] === now + 3600)[1], 100);
}
// soonest reset drains first: seat A resets in 1 h, B far. After 1 h at 100 %/h (=1 seat/h) A is empty and refills,
// B untouched, so the pool is 200 at the reset step.
{
  const r = quotaProject([{ used: 0, reset: far, period: W }, { used: 0, reset: now + 3600, period: W }], 100, now);
  assert.strictEqual(r.pts.find(p => p[0] === now + 3600)[1], 200);
  // and the far seat was not touched before then: left never below 100 in the first hour
  assert.ok(r.pts.filter(p => p[0] <= now + 3600).every(p => p[1] >= 100));
}
// a reset already in the past rolls forward: period 1 day, reset 2.5 days ago -> next is 0.5 day ahead, used kept
{
  const r = quotaProject([{ used: 0.4, reset: now - 2.5 * 86400, period: 86400 }], 0, now);
  assert.strictEqual(r.pts[0][1], 60);
  assert.strictEqual(r.pts.find(p => p[0] === now + 43200)[1], 100);
}
// the pool runs out between steps, just before a reset refills it: the first depletion is still reported (95 % used, 60 %/h -> empty after 5 min;
// the reset at 10 min would hide it if depletion were only checked at step starts)
{
  const r = quotaProject([{ used: 0.95, reset: now + 600, period: W }], 60, now, 3600);
  assert.strictEqual(r.empty, now + 300);
  // ... and a reset that comes first (2 min, before the 5-min run-out) refills it: no run-out within the hour
  assert.strictEqual(quotaProject([{ used: 0.95, reset: now + 120, period: W }], 60, now, 3600).empty, null);
}
// null reset drains last and a missing period does not hang
{
  const r = quotaProject([{ used: 0, reset: null, period: 0 }], 100, now, 7200);
  assert.strictEqual(r.empty, now + 3600);
}
// typical-day profile: a 24-array is read by the local hour of each step. Seats and a profile that drains only in local hour 0.
{
  const mid = new Date(2026, 0, 5, 0, 0, 0).getTime() / 1000;      // a local midnight, so the test holds in any timezone
  const prof = Array(24).fill(0); prof[0] = 100;
  const two = () => [{ used: 0, reset: mid + 30 * 86400, period: W }, { used: 0, reset: mid + 30 * 86400, period: W }];
  let r = quotaProject(two(), prof, mid, 5 * 3600);
  assert.strictEqual(r.pts.find(p => p[0] === mid + 3600)[1], 100);       // one seat's worth drained in hour 0, then nothing
  assert.strictEqual(r.pts[r.pts.length - 1][1], 100);
  assert.strictEqual(r.empty, null);
  r = quotaProject(two(), Array(24).fill(50), mid, 5 * 3600);                // flat array == the number 50
  assert.strictEqual(r.empty, mid + 14400);       // 200 % pool at 50 %/h
  assert.deepStrictEqual(r.pts, quotaProject(two(), 50, mid, 5 * 3600).pts);
  assert.strictEqual(quotaProject(two(), Array(24).fill(0), mid, 3600).empty, null);
  // the array drains hour by hour: 100 %/h in hour 0 and 50 %/h in hour 1 -> 1 seat + 0.5 seat gone by the end of hour 1
  const p2 = Array(24).fill(0); p2[0] = 100; p2[1] = 50;
  assert.strictEqual(quotaProject(two(), p2, mid, 7200).pts.find(p => p[0] === mid + 7200)[1], 50);
}
// weighted pool: a x5 seat B and a regular seat A, far resets. Pool 600; 100 %/h is one regular seat an hour, so it is empty after 6 h
{
  const two = () => [{ used: 0, reset: far, period: W }, { used: 0, reset: far, period: W, w: 5 }];
  let r = quotaProject(two(), 100, now);
  assert.strictEqual(r.pts[0][1], 600);
  assert.strictEqual(r.pts.find(p => p[0] === now + 3600)[1], 500);
  assert.strictEqual(r.empty, now + 6 * 3600);
  // used fractions are of each seat's own capacity: A half used, B 10 % used -> (0.5 + 5 x 0.9) x 100
  assert.strictEqual(quotaProject([{ used: 0.5, reset: far, period: W }, { used: 0.1, reset: far, period: W, w: 5 }], 0, now).pts[0][1], 500);
  // soonest reset drains first and a seat empties when its weighted capacity is used: B (x5) resets in 30 min, 600 %/h = a regular seat per 10 min
  r = quotaProject([{ used: 0, reset: far, period: W }, { used: 0, reset: now + 1800, period: W, w: 5 }], 600, now, 3600);
  assert.deepStrictEqual([600, 1200, 1800, 2400].map(d => r.pts.find(p => p[0] === now + d)[1]), [500, 400, 600, 500]);
  // weight 0 holds nothing; a missing w is 1 (the same points as an explicit 1)
  assert.strictEqual(quotaProject([{ used: 0.5, reset: far, period: W, w: 0 }], 100, now).pts[0][1], 0);
  assert.deepStrictEqual(quotaProject([{ used: 0.3, reset: far, period: W }], 50, now).pts, quotaProject([{ used: 0.3, reset: far, period: W, w: 1 }], 50, now).pts);
  // quotaShare of a weighted pool: 500 of a 600 cap
  assert.strictEqual(Math.round(quotaShare(500, 600)), 83);
}
// weight badge: neutral pill with a title saying where the weight came from; none at weight 1
{
  const esc = s => String(s).replace(/</g, '&lt;');
  assert.strictEqual(quotaWeight({ label: 'B' }, esc), '');
  assert.strictEqual(quotaWeight({ label: 'B', w: 1 }, esc), '');
  const t5 = 'Counts as 5 regular seats (from seatWeights)';
  assert.strictEqual(quotaWeight({ label: 'B', w: 5, wsrc: 'seatWeights' }, esc), `<span class="bdg wt" role="img" title="${t5}" aria-label="${t5}">×5</span>`);
  assert.ok(quotaWeight({ w: 5, wsrc: 'plan Pro' }, esc).includes('title="Counts as 5 regular seats (from plan Pro)"'));
  assert.ok(quotaWeight({ w: 0.5 }, esc).includes('×0.5') && quotaWeight({ w: 0.5 }, esc).includes('Counts as 0.5 regular seats'));
  assert.ok(quotaWeight({ w: 0, wsrc: 'seatWeights' }, esc).includes('Left out of the pooled numbers (from seatWeights)'));
  assert.strictEqual(quotaSeat({ label: 'B', w: 5, wsrc: 'seatWeights', badges: ['App'] }, false, esc), 'B' + quotaWeight({ w: 5, wsrc: 'seatWeights' }, esc) + '<span class="bdg app" role="img" title="Desktop app is on this seat" aria-label="Desktop app is on this seat">App</span>');
}
// measured ratio (Codex): nothing without a ratio; "not enough data" without x; amber when it is more than 30 % off the weight (a ratio of the two, either way)
{
  const esc = s => String(s).replace(/</g, '&lt;');
  assert.strictEqual(quotaMeasure({ label: 'A' }, esc), '');
  assert.strictEqual(quotaMeasure({ label: 'A', ratio: { n: 3 } }, esc), '<small class="ms" title="Needs 5 token measurements from the last 21 days; 3 so far">measured: not enough data</small>');
  const line = a => quotaMeasure(a, esc);
  assert.ok(line({ w: 5, ratio: { x: 4.6, n: 12 } }).includes('>measured ≈ ×4.6 (12 samples)</small>'));
  assert.ok(!line({ w: 5, ratio: { x: 4.6, n: 12 } }).includes('warn'));                   // 5 / 4.6 = 1.09
  assert.ok(!line({ ratio: { x: 1.29, n: 6 } }).includes('warn'));                          // weight 1: 1.29 is within 30 %
  assert.ok(line({ ratio: { x: 1.31, n: 6 } }).includes('class="ms warn"'));
  assert.ok(line({ ratio: { x: 0.76, n: 6 } }).includes('class="ms warn"'));                // 1 / 0.76 = 1.32: below the weight counts too
  assert.ok(!line({ ratio: { x: 0.78, n: 6 } }).includes('warn'));
  const off = line({ w: 5, wsrc: 'seatWeights', ratio: { x: 2.9, n: 14 } });
  assert.ok(off.includes('class="ms warn"') && off.includes('differs from the configured weight (×5) by more than 30 %') && off.includes('×2.9 (14 samples)'));
  assert.ok(!line({ w: 0, ratio: { x: 3, n: 9 } }).includes('warn'));                       // weight 0: nothing to compare
  assert.ok(line({ ratio: { x: 1, n: 8 } }).includes('×1 (8 samples)'));
  // under the seat name: email, then plan (underscores read as spaces), then the measured line
  assert.strictEqual(quotaSeat({ label: 'B', email: 'b@x.org', plan: 'self_serve_business_prolite', ratio: { n: 0 } }, true, esc),
    'B<small>b@x.org</small><small class="pl">Plan: self serve business prolite</small>' + quotaMeasure({ ratio: { n: 0 } }, esc));
}
// suggested weight (Codex): nothing without a suggestion; the line with the sample count and the copy button; the copied fragment is valid JSON once braced
{
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  assert.strictEqual(quotaSuggest({ label: 'B' }, esc), '');
  const b = { label: 'B', suggest: { w: 3, n: 24 } };
  assert.strictEqual(quotaFragment(b), '"seatWeights": {"codex": {"B": 3}}');
  assert.deepStrictEqual(JSON.parse('{' + quotaFragment(b) + '}'), { seatWeights: { codex: { B: 3 } } });
  assert.strictEqual(quotaFragment({ label: 'C', suggest: { w: 1.5, n: 30 } }), '"seatWeights": {"codex": {"C": 1.5}}');
  assert.strictEqual(quotaSuggest(b, esc), '<small class="sg">Suggested weight ×3 (24 samples) <button class="cp" data-a="copyw" data-v="&quot;seatWeights&quot;: {&quot;codex&quot;: {&quot;B&quot;: 3}}">Copy setting</button></small>');
  // under the seat: after the measured line, which stays as it is (amber included)
  const seat = { label: 'B', w: 1, ratio: { x: 3.1, n: 24 }, suggest: { w: 3, n: 24 } };
  assert.strictEqual(quotaSeat(seat, false, esc), 'B' + quotaMeasure(seat, esc) + quotaSuggest(seat, esc));
  assert.ok(quotaSeat(seat, false, esc).includes('class="ms warn"') && quotaSeat(seat, false, esc).indexOf('measured') < quotaSeat(seat, false, esc).indexOf('Suggested'));
}
// seat name: the letter always, the email under it only when shown and known
{
  const esc = s => String(s).replace(/</g, '&lt;');
  assert.strictEqual(quotaSeat({ label: 'A', email: 'a@x.org' }, false, esc), 'A');
  assert.strictEqual(quotaSeat({ label: 'A', email: 'a@x.org' }, true, esc), 'A<small>a@x.org</small>');
  assert.strictEqual(quotaSeat({ label: 'B', email: null }, true, esc), 'B');
  assert.strictEqual(quotaSeat({ label: '<', email: '<e>' }, true, esc), '&lt;<small>&lt;e></small>');
  const cli = '<span class="bdg cli" role="img" title="Claude Code CLI is on this seat" aria-label="Claude Code CLI is on this seat">CLI</span>';
  const app = '<span class="bdg app" role="img" title="Desktop app is on this seat" aria-label="Desktop app is on this seat">App</span>';
  assert.strictEqual(quotaSeat({ label: 'D', email: 'd@x.org', badges: ['CLI', 'App'] }, true, esc), 'D' + cli + app + '<small>d@x.org</small>');
  assert.strictEqual(quotaSeat({ label: 'D', badges: [] }, true, esc), 'D');
  // provider header: the same pills with the seat letter, and a title that names the seat
  const hcli = '<span class="bdg cli" role="img" title="Claude Code CLI is on seat D" aria-label="Claude Code CLI is on seat D">CLI D</span>';
  const happ = '<span class="bdg app" role="img" title="Desktop app is on seat B" aria-label="Desktop app is on seat B">App B</span>';
  assert.strictEqual(quotaInUse({ inUse: { cli: 'D', app: 'B' } }, esc), hcli + happ);
  assert.strictEqual(quotaInUse({ inUse: { app: 'B' } }, esc), happ);
  assert.strictEqual(quotaInUse({}, esc), '');
}
// banked resets: a cache with credits, one without, a count above the list
{
  const id = s => String(s), fmt = t => 'T' + t;
  assert.strictEqual(quotaIn(17 * 86400 + 23 * 3600 + 59), '17d 23h');
  assert.strictEqual(quotaIn(5 * 3600 + 12 * 60), '5h 12m');
  assert.strictEqual(quotaIn(-5), '0m');
  const two = { banked: 2, bankedList: [{ title: 'Full reset', expiresAt: now + 86400 }, { title: 'Full reset (Weekly + 5 hr)', expiresAt: now + 3600 }] };
  assert.strictEqual(quotaBankedCell(two, now, fmt, id), `2<small>Full reset · expires T${now + 86400} (in 1d 0h)</small><small>Full reset (Weekly + 5 hr) · expires T${now + 3600} (in 1h 0m)</small>`);
  assert.strictEqual(quotaBankedCell({}, now, fmt, id), '–');
  assert.strictEqual(quotaBankedCell({ bankedNote: 'Reset credits need a full Claude login (not a setup-token)' }, now, fmt, id), '<small>Reset credits need a full Claude login (not a setup-token)</small>');
  assert.strictEqual(quotaBankedCell({ banked: 0, bankedList: [] }, now, fmt, id), '0');
  assert.strictEqual(quotaBankedCell({ banked: 3, bankedList: two.bankedList }, now, fmt, id).endsWith('<small>Expiry not supplied for 1</small>'), true);
  assert.strictEqual(quotaBankedCell({ banked: 2 }, now, fmt, id), '2<small>Expiry not supplied for 2</small>');
  // Claude's: a grant holding several resets says so (and is not "missing"), one without an expiry has no expiry part, a seat read with none is empty, never read is a dash, a note says why
  assert.strictEqual(quotaBankedCell({ banked: 3, bankedAt: now, bankedList: [{ title: 'Fable reset', n: 2, expiresAt: now + 86400 }, { title: 'Reset', expiresAt: null }] }, now, fmt, id),
    `3<small>Fable reset ×2 · expires T${now + 86400} (in 1d 0h)</small><small>Reset</small>`);
  assert.strictEqual(quotaBankedCell({ bankedAt: now }, now, fmt, id), '');
  assert.strictEqual(quotaBankedCell({ bankedNote: 'sign-in needed' }, now, fmt, id), '<small>sign-in needed</small>');     // why there is no count is shown, not only in a tooltip
  assert.strictEqual(quotaBankedTotal({ accounts: [two, { banked: 1 }, {}] }), 3);
  assert.strictEqual(quotaBankedTotal({ accounts: [{}, {}] }), null);
}
// Claude's Apply kinds: the four the server accepts (usage-history.py RESET_KINDS), the owner's wording for Fable and full, a window each
{
  assert.deepStrictEqual(Object.keys(QUOTA_RESET_KINDS), ['fable', 'full', 'weekly', 'session']);
  assert.strictEqual('Apply ' + QUOTA_RESET_KINDS.fable.noun, 'Apply Fable reset');
  assert.strictEqual('Apply ' + QUOTA_RESET_KINDS.full.noun, 'Apply full reset');
  assert.strictEqual(QUOTA_RESET_KINDS.fable.refills, "Refills your Fable allowance and gives back what Fable used of your weekly limit; it doesn't reset the whole week.");
  assert.strictEqual(QUOTA_RESET_KINDS.full.refills, 'Refills your 5-hour and weekly limits.');
  assert.deepStrictEqual(Object.values(QUOTA_RESET_KINDS).map(k => k.win), ['f', 'w', 'w', 's']);
}
// share of the whole pool: 162 of 600 -> 27 %, a pooled 3.6 %/h over 6 seats -> 0.6 %/h; a missing cap means one seat
assert.strictEqual(Math.round(quotaShare(162, 600)), 27);
assert.strictEqual(quotaShare(3.6, 600), 0.6);
assert.strictEqual(quotaShare(50, undefined), 50);
assert.strictEqual(quotaShare(600, 600), 100);
// status levels: Claude by the API's status (unknown is neutral), the others by the displayed percentage
{
  assert.deepStrictEqual(['allowed', 'allowed_warning', 'rejected', undefined, 'odd'].map(stat => quotaLevel('claude', { used: 0.99, stat })), ['ok', 'warn', 'bad', '', '']);
  assert.deepStrictEqual([0, 0.84, 0.845, 0.85, 0.994, 0.995, 1].map(used => quotaLevel('codex', { used })), ['ok', 'ok', 'warn', 'warn', 'warn', 'bad', 'bad']);
  assert.strictEqual(quotaLevel('grok', { used: 1 }), 'bad');
  assert.strictEqual(quotaLevel('gemini', { used: 0.9 }), 'warn');
  assert.strictEqual(quotaLevel('gemini', { used: null }), '');
}
// switch buttons: the server's roles per seat, the header button only with p.best, one click only for the Claude CLI ones, all disabled while busy
{
  const e = s => String(s).replace(/"/g, '&quot;');
  const cl = { id: 'claude', best: true }, cx = { id: 'codex' };
  assert.strictEqual(quotaSwitchBtns(cl, { label: 'B', switch: ['cli', 'app'] }, false, e),
    '<button class="sw" data-a="sw" data-p="claude" data-r="cli" data-v="B" title="Switch the Claude CLI to this seat">Use for CLI</button>' +
    '<button class="sw" data-a="sw" data-p="claude" data-r="app" data-v="B" title="Switch the Claude desktop app to this seat">Use for App</button>');
  assert.strictEqual(quotaSwitchBtns(cl, { label: 'B' }, false, e), '');
  assert.strictEqual(quotaSwitchBtns(cx, { label: 'A', switch: ['both', 'cli'] }, true, e),
    '<button class="sw" data-a="sw" data-p="codex" data-r="both" data-v="A" title="Another action is running" disabled>Use for CLI + App</button>');   // an unknown role draws nothing
  assert.strictEqual(quotaBestBtn(cl, false, e), '<button class="sw" data-a="sw" data-p="claude" data-r="best" title="Switch the Claude CLI to the seat with the most headroom">Best seat</button>');
  assert.strictEqual(quotaBestBtn(cx, false, e), '');
  assert.ok(quotaBestBtn({ id: 'codex', best: true }, false, e).includes('>Next seat<'));
  assert.strictEqual(quotaSwitchBtn('grok', 'best', '', false, e), '');
  assert.deepStrictEqual([['claude', 'cli'], ['claude', 'best'], ['claude', 'app'], ['codex', 'both'], ['codex', 'best']].map(([p, r]) => quotaSwitchAsks(p, r)), [false, false, true, true, true]);
  assert.deepStrictEqual(Object.keys(QUOTA_SWITCH.claude), ['cli', 'app', 'best']);
}
// a provider with no pooled chart (every seat weighted 0) still gets its accounts table, and says why there is no chart
{
  const { quotaNoPool } = require('./usage-sim.js');
  assert.strictEqual(quotaNoPool({ accounts: [{ w: 0 }, { w: 0 }] }), 'No seats counted in the pool (all weights are 0).');
  assert.strictEqual(quotaNoPool({ accounts: [{ w: 0 }, {}] }), '');
  assert.strictEqual(quotaNoPool({ accounts: [] }), '');
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const src = tpl.slice(tpl.indexOf('function panel(p, W) {'), tpl.indexOf('\nfunction render('));
  const deps = { ui: { lim: {} }, D: { app: true }, esc: s => String(s), sh: x => x, quotaBankedTotal: () => null, quotaInUse: () => '', quotaBestBtn: () => '',
    swBusy: () => false, rateFor: () => ({}), seatsTxt: () => '', fr: x => x, chart: () => '', nm: a => a.label, accounts: () => '<ACCOUNTS>', quotaNoPool };
  const panel = new Function(...Object.keys(deps), src + '\nreturn panel;')(...Object.values(deps));
  const zero = panel({ id: 'claude', name: 'Claude', total: 2, limits: [], accounts: [{ label: 'A', w: 0, note: '' }, { label: 'B', w: 0, note: '' }] }, 600);
  assert.ok(zero.includes('<ACCOUNTS>') && zero.includes('No seats counted in the pool (all weights are 0).') && !zero.includes('No usage data yet.'), zero);
  const none = panel({ id: 'grok', name: 'xAI', total: 1, limits: [], accounts: [{ label: 'grok', note: '' }] }, 600);
  assert.ok(none.includes('<ACCOUNTS>') && none.includes('No usage data yet.'), none);
}
// a Codex seat whose last reset is unconfirmed shows that instead of Apply reset, so a retry cannot mint a second claim
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const src = tpl.slice(tpl.indexOf('const resetBtn = '), tpl.indexOf('\nfunction accounts('));
  const resetBtn = new Function('D', 'esc', 'QUOTA_RESET_KINDS', src + '\nreturn resetBtn;')({ app: true }, s => String(s), QUOTA_RESET_KINDS);
  const cx = { id: 'codex', canReset: true };
  assert.ok(resetBtn(cx, { label: 'A', banked: 2 }).includes('>Apply reset</button>'));
  assert.strictEqual(resetBtn(cx, { label: 'A', banked: 2, resetPending: true }),
    '<small class="muted">Last reset unconfirmed</small><button class="rs" data-a="rsclear" data-v="A">Clear</button>');
  // through accounts(): the reset column stays when nothing is banked anywhere but a seat has a pending claim or an unconfirmed reset
  const tblSrc = tpl.slice(tpl.indexOf('const resetBtn = '), tpl.indexOf('\nfunction panel('));
  const accounts = new Function('D', 'esc', 'QUOTA_RESET_KINDS', 'quotaBankedTotal', 'quotaBankedCell', 'quotaLevel', 'quotaSwitchBtns', 'swBusy', 'nm', 'bkTitle',
    'readAge', 'ago', 'fmtRS', 'closed', 'fmtDT', tblSrc + '\nreturn accounts;')({ app: true, now: 1000 }, s => String(s), QUOTA_RESET_KINDS, quotaBankedTotal, () => '–',
    () => '', () => '', () => false, a => a.label, () => '', () => '', String, String, {}, String);
  const clT = accounts({ id: 'claude', canReset: true, limits: [], accounts: [{ label: 'A', windows: [], resets: [{ kind: 'full', pending: true }] }] });
  assert.ok(clT.includes('<th>Banked resets</th>') && clT.includes('>Resend pending full reset</button>'), clT);
  const cxT = accounts({ id: 'codex', canReset: true, limits: [], accounts: [{ label: 'B', windows: [], banked: 0, resetPending: true }] });
  assert.ok(cxT.includes('Last reset unconfirmed') && cxT.includes('data-a="rsclear"'), cxT);
  assert.ok(!accounts({ id: 'codex', canReset: true, limits: [], accounts: [{ label: 'B', windows: [] }] }).includes('Banked resets'));
  // setup-token-only Claude seats have no count but a note saying why: the column (and that explanation) stays
  const noteT = accounts({ id: 'claude', canReset: true, limits: [], accounts: [{ label: 'A', windows: [], bankedNote: 'Reset credits need a full Claude login' }] });
  assert.ok(noteT.includes('<th>Banked resets</th>'), noteT);
  // the hand clear asks first, with Cancel as the default
  const clrSrc = tpl.slice(tpl.indexOf('let rs = null;'), tpl.indexOf('\nfunction toast('));
  const dlg = { innerHTML: '', opened: 0, showModal() { this.opened++; } };
  const fns = new Function('D', '$', 'esc', 'ui', 'fmtDT', 'quotaIn', 'QUOTA_RESET_KINDS', clrSrc + '\nreturn { openClear, st: () => rs };')(
    { now: 1, providers: [{ id: 'codex', accounts: [{ label: 'B', resetPending: true, resetPendingId: 'm-1' }, { label: 'C' }, { label: 'L', resetPending: true, resetPendingId: '' }] }] }, () => dlg, s => String(s), {}, String, String, QUOTA_RESET_KINDS);
  fns.openClear('C');                                                           // a Codex seat with no unconfirmed mark in view: nothing to clear, nothing opens
  assert.ok(dlg.opened === 0 && fns.st() === null);
  fns.openClear('B');
  assert.ok(dlg.opened === 1 && dlg.innerHTML.includes('Only clear this after codex-usage shows the reset was not used. Clearing lets you apply a reset on this seat again.')
    && /<button data-a="rscancel" autofocus>Cancel<\/button><button class="primary" data-a="rsgo">Clear<\/button>/.test(dlg.innerHTML) && fns.st().clear === true, dlg.innerHTML);
  assert.strictEqual(fns.st().rid, 'm-1');                                      // the Codex Clear names the mark the page showed
  assert.ok(/rs\.clear \? \(cl \? '\/api\/claude-reset-clear' : '\/api\/codex-reset-clear'\)/.test(tpl) && /a === 'rsclear'\) return openClear\(v, el\.dataset\.p, el\.dataset\.k\)/.test(tpl));
}
// a Claude seat+kind with a pending (unsettled) claim is offered as a resend, even with no credit of that kind listed, and its dialog says so
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const btnSrc = tpl.slice(tpl.indexOf('const resetBtn = '), tpl.indexOf('\nfunction accounts('));
  const resetBtn = new Function('D', 'esc', 'QUOTA_RESET_KINDS', btnSrc + '\nreturn resetBtn;')({ app: true }, s => String(s), QUOTA_RESET_KINDS);
  const cl = { id: 'claude', canReset: true };
  // a pending claim that never settles can be cleared by hand: a Clear beside its Resend, and none beside a plain Apply
  assert.strictEqual(resetBtn(cl, { label: 'A', resets: [{ kind: 'full', pending: true }] }),
    '<button class="rs" data-a="reset" data-p="claude" data-v="A" data-k="full">Resend pending full reset</button>' +
    '<button class="rs" data-a="rsclear" data-p="claude" data-v="A" data-k="full">Clear</button>');
  assert.ok(resetBtn(cl, { label: 'A', resets: [{ kind: 'full', left: 1, endsAt: null }] }).includes('>Apply full reset<'));
  assert.ok(!resetBtn(cl, { label: 'A', resets: [{ kind: 'full', left: 1, endsAt: null }] }).includes('rsclear'));
  const dlgSrc = tpl.slice(tpl.indexOf('let rs = null;'), tpl.indexOf('\nfunction toast('));
  const dlg = { innerHTML: '', opened: 0, showModal() { this.opened++; } };
  const D = { now: 1000, providers: [{ id: 'claude', accounts: [{ label: 'A', windows: [], resets: [{ kind: 'full', pending: true }] }] },
    { id: 'codex', accounts: [{ label: 'A', windows: [], resetPending: true, resetPendingId: 'cx-9' }, { label: 'L', windows: [], resetPending: true }] }] };
  const openReset = new Function('D', '$', 'esc', 'ui', 'fmtDT', 'quotaIn', 'QUOTA_RESET_KINDS', dlgSrc + '\nreturn openReset;')(
    D, () => dlg, s => String(s), { emails: false }, String, String, QUOTA_RESET_KINDS);
  openReset('claude', 'A', 'full');
  assert.ok(dlg.opened === 1 && dlg.innerHTML.includes('Resend the pending full reset to seat A?') && dlg.innerHTML.includes('>Resend full reset</button>')
    && dlg.innerHTML.includes('cannot use a second reset') && !dlg.innerHTML.includes("can't be undone"), dlg.innerHTML);
  // confirming a resend names its claim (resend + request id), so a claim settled meanwhile is refused rather than replaced by a new one
  const doSrc = tpl.slice(tpl.indexOf('async function doReset() {'), tpl.indexOf('\n// The rotator actions'));
  D.providers[0].accounts[0].resets = [{ kind: 'full', pending: true, rid: 'r-1' }, { kind: 'fable', left: 1, endsAt: null }];
  const sent = [], dlg2 = Object.assign(dlg, { close() {}, querySelector: () => ({}), querySelectorAll: () => [] });
  const pair = new Function('D', '$', 'esc', 'ui', 'fmtDT', 'quotaIn', 'QUOTA_RESET_KINDS', 'fetch', 'toast', 'loadData',
    dlgSrc + '\n' + doSrc + '\nreturn { openReset, openClear, doReset };')(D, () => dlg2, s => String(s), { emails: false }, String, String, QUOTA_RESET_KINDS,
    async (u, o) => { sent.push([u, JSON.parse(o.body)]); return { status: 200, json: async () => ({ outcome: 'ok', text: 'x' }) }; }, () => {}, () => {});
  (async () => {
    pair.openReset('claude', 'A', 'full'); await pair.doReset();
    pair.openReset('claude', 'A', 'fable'); await pair.doReset();
    assert.deepStrictEqual(sent, [['/api/claude-reset', { seat: 'A', kind: 'full', resend: true, requestId: 'r-1' }], ['/api/claude-reset', { seat: 'A', kind: 'fable' }]]);
    // the hand clear of a pending Claude claim asks first (Cancel is the default), then names the claim the page showed (its request id), so a claim replaced meanwhile is refused
    pair.openClear('A', 'claude', 'full');
    assert.ok(dlg2.innerHTML.includes('Clear the pending full reset on seat A?') && /<button data-a="rscancel" autofocus>Cancel<\/button><button class="primary" data-a="rsgo">Clear<\/button>/.test(dlg2.innerHTML), dlg2.innerHTML);
    await pair.doReset();
    assert.deepStrictEqual(sent[2], ['/api/claude-reset-clear', { seat: 'A', kind: 'full', requestId: 'r-1' }]);
    assert.strictEqual(sent.length, 3);
    // the Codex Clear names the unconfirmed mark the page showed too (a mark from before ids existed sends the empty id), so a mark replaced meanwhile is refused, not dropped
    pair.openClear('A', 'codex');
    await pair.doReset();
    pair.openClear('L', 'codex');
    await pair.doReset();
    assert.deepStrictEqual(sent.slice(3), [['/api/codex-reset-clear', { seat: 'A', requestId: 'cx-9' }], ['/api/codex-reset-clear', { seat: 'L', requestId: '' }]]);
    sent.length = 3;
    const opened = dlg2.opened;
    pair.openClear('A', 'claude', 'nonsense');                                    // an unknown kind opens nothing
    pair.openClear('A', 'claude', 'fable');                                       // a kind with no pending claim in view opens nothing: there is no claim to name
    assert.strictEqual(dlg2.opened, opened);                                      // no dialog was shown ...
    await pair.doReset();                                                         // ... so there is nothing to confirm: a confirm click sends nothing
    assert.strictEqual(sent.length, 3);
  })().catch(e => { console.error(e); process.exit(1); });
}
// an unreadable provider cache (D.pcacheError): a banner with the server's message, and no Apply / Resend / Clear anywhere while it is set; a 500 answer's text reaches the toast
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const bannerSrc = tpl.slice(tpl.indexOf('function pcacheShow('), tpl.indexOf('function driftRow('));
  const pcacheShow = new Function(bannerSrc + '\nreturn pcacheShow;')();
  assert.ok(/<div id="pcerr" class="pcerr" role="alert" hidden><\/div>\r?\n<main id="app"><\/main>/.test(tpl), 'the banner sits outside #app');
  assert.ok(tpl.includes("pcacheShow(document.getElementById('pcerr'), D.pcacheError);") && !tpl.includes('pcacheBanner('), 'render() only sets the banner, never rebuilds it');
  // the alert's text changes only when the message does, so an unchanged message is not read out again on every render; textContent, never markup
  const el = { dataset: {}, textContent: '', hidden: true, sets: 0 };
  const wrap = new Proxy(el, { set(o, k, v) { if (k === 'textContent') o.sets++; o[k] = v; return true; } });
  pcacheShow(wrap, 'usage-cache.json <b> cannot be read.');
  assert.ok(el.textContent === 'usage-cache.json <b> cannot be read.' && el.hidden === false && el.sets === 1);
  pcacheShow(wrap, 'usage-cache.json <b> cannot be read.'); assert.strictEqual(el.sets, 1);            // same message: untouched, so not announced again
  pcacheShow(wrap, 'm2'); assert.ok(el.textContent === 'm2' && el.sets === 2);                       // a new message is set (and announced) once
  pcacheShow(wrap, ''); assert.ok(el.hidden === true && el.textContent === '');                        // gone: hidden
  pcacheShow(null, 'x');                                                                             // no element: nothing to do
  const btnSrc = tpl.slice(tpl.indexOf('const resetBtn = '), tpl.indexOf('\nfunction accounts('));
  const mk = D => new Function('D', 'esc', 'QUOTA_RESET_KINDS', btnSrc + '\nreturn resetBtn;')(D, s => String(s), QUOTA_RESET_KINDS);
  const cl = { id: 'claude', canReset: true }, cx = { id: 'codex', canReset: true };
  const acc = { label: 'A', banked: 2, resetPending: true, resets: [{ kind: 'full', pending: true, rid: 'r' }, { kind: 'fable', left: 1, endsAt: null }] };
  assert.ok(mk({ app: true })(cl, acc).includes('Resend pending') && mk({ app: true })(cx, acc).includes('rsclear'));      // without the error: the buttons are there
  assert.strictEqual(mk({ app: true, pcacheError: 'x' })(cl, acc), '');
  assert.strictEqual(mk({ app: true, pcacheError: 'x' })(cx, acc), '');
  // the dialogs do not open either (a stale button, or a click already in flight)
  const dlgSrc = tpl.slice(tpl.indexOf('let rs = null;'), tpl.indexOf('\nfunction toast('));
  const dlg = { innerHTML: '', opened: 0, showModal() { this.opened++; } };
  const D = { now: 1000, pcacheError: 'x', providers: [{ id: 'claude', accounts: [{ label: 'A', windows: [], resets: [{ kind: 'full', pending: true, rid: 'r' }] }] }] };
  const f = new Function('D', '$', 'esc', 'ui', 'fmtDT', 'quotaIn', 'QUOTA_RESET_KINDS', dlgSrc + '\nreturn { openReset, openClear };')(D, () => dlg, s => String(s), {}, String, String, QUOTA_RESET_KINDS);
  f.openReset('claude', 'A', 'full'); f.openClear('A', 'claude', 'full');
  assert.strictEqual(dlg.opened, 0);
  delete D.pcacheError;
  f.openClear('A', 'claude', 'full');
  assert.strictEqual(dlg.opened, 1);
  // the server's 500 body (the PcacheError message) is what the toast shows
  const doSrc = tpl.slice(tpl.indexOf('async function doReset() {'), tpl.indexOf('\n// The rotator actions'));
  const toasts = [], dlg2 = Object.assign(dlg, { close() {}, querySelector: () => ({}), querySelectorAll: () => [] });
  const g = new Function('D', '$', 'esc', 'ui', 'fmtDT', 'quotaIn', 'QUOTA_RESET_KINDS', 'fetch', 'toast', 'loadData', dlgSrc + '\n' + doSrc + '\nreturn { openClear, doReset };')(
    D, () => dlg2, s => String(s), {}, String, String, QUOTA_RESET_KINDS,
    async () => ({ status: 500, json: async () => ({ outcome: 'error', text: 'usage-cache.json cannot be read. Check the seats limits first.' }) }), (t, o) => toasts.push([t, o]), () => {});
  g.openClear('A', 'claude', 'full');
  g.doReset().then(() => assert.deepStrictEqual(toasts, [['usage-cache.json cannot be read. Check the seats limits first.', 'error']])).catch(e => { console.error(e); process.exit(1); });
}
// the update notice speaks to an end user: what is out of date and the one command that fixes it; no --push
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const src = tpl.slice(tpl.indexOf('function driftRow(d) {'), tpl.indexOf('\nfunction applyTheme('));
  const driftRow = new Function('closed', 'ico', 'esc', 'ago', src + '\nreturn driftRow;')({}, () => '', s => String(s), String);
  const two = driftRow({ n: 2, names: ['a.ps1', 'b.py'], checked: 5 });
  assert.ok(two.includes('Update available from GitHub (2 files differ)') && two.includes('<code>rotator-sync --pull</code>') && two.includes('<li>a.ps1</li>'), two);
  assert.ok(driftRow({ n: 1, names: ['a.ps1'] }).includes('(1 file differs)'));
  assert.ok(!/--push|--check/.test(tpl.slice(tpl.indexOf('function driftRow(d) {'), tpl.indexOf('\nfunction applyTheme('))));
}
// the emails button names what a click does: Show while hidden, Hide while shown
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const i = tpl.indexOf('`<button data-a="emails"'), j = tpl.indexOf('</button>`', i) + '</button>`'.length;
  const btn = new Function('ui', 'ico', 'return ' + tpl.slice(i, j));
  assert.strictEqual(btn({ emails: false }, () => ''), '<button data-a="emails">Show emails</button>');
  assert.strictEqual(btn({ emails: true }, () => ''), '<button data-a="emails">Hide emails</button>');
}
// the refresh button is plain "Refresh"
{
  const tpl = require('fs').readFileSync(require('path').join(__dirname, 'usage-dashboard.template.html'), 'utf8');
  const i = tpl.indexOf('(D.app ? `<button class="primary" data-a="refresh"'), j = tpl.indexOf("</button>` : '')", i) + "</button>` : '')".length;
  const btn = new Function('D', 'busy', 'ico', 'return ' + tpl.slice(i, j));
  assert.strictEqual(btn({ app: true }, false, () => ''), '<button class="primary" data-a="refresh">Refresh</button>');
  assert.ok(!tpl.includes('Refresh all credentials'));
}
// the app is called "Agent Dashboard" everywhere a user sees its name; the installer clears the shortcuts of its earlier names
{
  const rd = f => require('fs').readFileSync(require('path').join(__dirname, f), 'utf8');
  const tpl = rd('usage-dashboard.template.html'), ins = rd('usage-app-install.ps1');
  assert.ok(tpl.includes('<title>Agent Dashboard</title>') && tpl.includes('<h1>Agent Dashboard</h1>') && !/Quota Management/.test(tpl));
  assert.ok(ins.includes("'Agent Dashboard.lnk'") && ins.includes("'Quota Management.lnk'") && ins.includes("'Quota.lnk'")
    && /foreach \(\$l in @\(\$lnk\) \+ \$oldLnks\)/.test(ins) && /foreach \(\$l in \$oldLnks\)/.test(ins) && ins.includes("$taskName = 'Claude usage dashboard'"));
}
// public install: no file names one machine's folders or one person's private notes (the merge-pr review skipping is an optional feature
// that looks for its own state and is allowed to name it; tests may carry sample command lines)
{
  const fs = require('fs'), path = require('path'), root = path.join(__dirname, '..');
  const files = [];
  const walk = d => { for (const n of fs.readdirSync(d)) { if (n === '.git' || n === 'node_modules' || n === 'fixtures') continue; const f = path.join(d, n);
    if (fs.statSync(f).isDirectory()) walk(f); else if (/\.(ps1|py|js|ts|vbs|json|md|html)$/.test(n) && !/\.local\./.test(n)) files.push(f); } };
  walk(root);
  const bad = /C:[\\/]+Dev[\\/]+Rotators|hameishiv-wiki|C:[\\/]+Dev[\\/]+hameishiv|skills[\\/]+merge-pr[\\/]+scripts[\\/]+codex_redeem/i;
  const hits = files.filter(f => !/test-rotate-projection\.ps1$|usage-sim\.test\.js$/.test(f) && bad.test(fs.readFileSync(f, 'utf8'))).map(f => path.relative(root, f));
  assert.deepStrictEqual(hits, []);
  // the relaunch test lowers itself to Idle before it starts any child (owner rule: every run and test at Idle)
  const rl = fs.readFileSync(path.join(__dirname, 'test-app-relaunch.ps1'), 'utf8'), body = rl.slice(rl.indexOf('#>'));
  const idle = body.indexOf("(Get-Process -Id $PID).PriorityClass = 'Idle'");
  assert.ok(idle > 0 && idle < body.search(/& pwsh|Start-Process|& \$script/));
  assert.ok(files.some(f => f.endsWith('check-rotate-hidden.vbs')) && /WScript\.ScriptFullName/.test(fs.readFileSync(path.join(__dirname, 'check-rotate-hidden.vbs'), 'utf8')));
}
console.log('usage-sim tests passed');
