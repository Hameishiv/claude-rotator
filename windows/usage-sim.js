// Pooled-quota projection shared by the dashboard and its tests. Same semantics as the v1 Python project().
function quotaProject(seats, ratePerHour, now, horizonSec = 14 * 86400, stepSec = 600) {
  // period must be > 0 or a roll-forward would never end; a seat without one just stops resetting.
  const ss = seats.map(s => ({ used: s.used || 0, reset: s.reset || null, period: s.period > 0 ? s.period : 0 }));
  const roll = (s, t) => { while (s.reset && s.period && s.reset <= t) { s.used = 0; s.reset += s.period; } };
  for (const s of ss) { while (s.reset && s.period && s.reset <= now) s.reset += s.period; }
  const pts = []; let empty = null;
  for (let t = now; t <= now + horizonSec; t += stepSec) {
    for (const s of ss) roll(s, t);
    const left = ss.reduce((a, s) => a + (1 - s.used), 0) * 100;
    pts.push([t, Math.round(left * 10) / 10]);
    if (empty === null && ratePerHour > 0 && left < 0.05) empty = t;
    let drain = ratePerHour > 0 ? ratePerHour / 100 * stepSec / 3600 : 0;
    for (const s of ss.slice().sort((a, b) => (a.reset || Infinity) - (b.reset || Infinity))) {
      if (drain <= 0) break;
      const take = Math.min(1 - s.used, drain);
      s.used += take; drain -= take;
    }
  }
  return { pts, empty };
}
// A seat's name for a table or list: always its letter, the email under it (muted, smaller) when emails are shown. `esc` escapes HTML.
function quotaSeat(a, emails, esc) { return esc(a.label) + (emails && a.email ? '<small>' + esc(a.email) + '</small>' : ''); }
if (typeof module !== 'undefined') module.exports = { quotaProject, quotaSeat };
