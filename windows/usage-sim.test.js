const assert = require('assert');
const { quotaProject, quotaSeat, quotaInUse, quotaLevel, quotaIn, quotaBankedCell, quotaBankedTotal } = require('./usage-sim.js');
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
  assert.strictEqual(quotaBankedCell({ banked: 0, bankedList: [] }, now, fmt, id), '0');
  assert.strictEqual(quotaBankedCell({ banked: 3, bankedList: two.bankedList }, now, fmt, id).endsWith('<small>Expiry not supplied for 1</small>'), true);
  assert.strictEqual(quotaBankedCell({ banked: 2 }, now, fmt, id), '2<small>Expiry not supplied for 2</small>');
  assert.strictEqual(quotaBankedTotal({ accounts: [two, { banked: 1 }, {}] }), 3);
  assert.strictEqual(quotaBankedTotal({ accounts: [{}, {}] }), null);
}
// status levels: Claude by the API's status (unknown is neutral), the others by the displayed percentage
{
  assert.deepStrictEqual(['allowed', 'allowed_warning', 'rejected', undefined, 'odd'].map(stat => quotaLevel('claude', { used: 0.99, stat })), ['ok', 'warn', 'bad', '', '']);
  assert.deepStrictEqual([0, 0.84, 0.845, 0.85, 0.994, 0.995, 1].map(used => quotaLevel('codex', { used })), ['ok', 'ok', 'warn', 'warn', 'warn', 'bad', 'bad']);
  assert.strictEqual(quotaLevel('grok', { used: 1 }), 'bad');
  assert.strictEqual(quotaLevel('gemini', { used: 0.9 }), 'warn');
  assert.strictEqual(quotaLevel('gemini', { used: null }), '');
}
console.log('usage-sim tests passed');
