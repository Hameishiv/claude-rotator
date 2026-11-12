const assert = require('assert');
const { quotaProject, quotaSeat } = require('./usage-sim.js');
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
// seat name: the letter always, the email under it only when shown and known
{
  const esc = s => String(s).replace(/</g, '&lt;');
  assert.strictEqual(quotaSeat({ label: 'A', email: 'a@x.org' }, false, esc), 'A');
  assert.strictEqual(quotaSeat({ label: 'A', email: 'a@x.org' }, true, esc), 'A<small>a@x.org</small>');
  assert.strictEqual(quotaSeat({ label: 'B', email: null }, true, esc), 'B');
  assert.strictEqual(quotaSeat({ label: '<', email: '<e>' }, true, esc), '&lt;<small>&lt;e></small>');
}
console.log('usage-sim tests passed');
