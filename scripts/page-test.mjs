// page-test.mjs – the built page (dist/) starts in a real browser: served as GitHub Pages serves it (no
// COOP/COEP headers), opened in headless Chromium, it opens the database from the schema image, loads the
// start map and runs tics, with no error on the page; then QuakeC mode, a deathmatch with three bots, does
// the same. The Node tests run the game's SQL but never the page, so a page that stopped at start-up (a
// const used above its line) or a QuakeC spawn that failed only on the schema image went out with CI green.
//
//   npm run build && npm run test:page          (CHROME=/path/to/chrome to pick the browser)

import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');
if (!fs.existsSync(path.join(dist, 'index.html'))) { console.error('no dist/: run npm run build first'); process.exit(1); }

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

// dist/ as a static host serves it: no cross-origin isolation headers
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.json': 'application/json', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  let file = path.join(dist, decodeURIComponent(url.pathname));
  if (url.pathname.endsWith('/')) file = path.join(file, 'index.html');
  if (!path.resolve(file).startsWith(dist) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((ok) => server.listen(0, ok));
const base = `http://localhost:${server.address().port}/`;

// a Chromium: CHROME, the one Playwright installed here, or the runner's Chrome
const executablePath = [process.env.CHROME, '/opt/pw-browsers/chromium', '/usr/bin/google-chrome', '/usr/bin/chromium'].find((p) => p && fs.existsSync(p));
const browser = await chromium.launch({ executablePath, args: ['--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
const errors = [], logs = [], missing = new Set();
page.on('response', (r) => { if (r.status() === 404) missing.add(new URL(r.url()).pathname); });
page.on('pageerror', (e) => errors.push(e.stack ?? e.message));
page.on('console', (m) => {
  if (/\[firebird-quake\]/.test(m.text())) logs.push(m.text());
  // a missing file is not an error here (the page probes for music tracks and optional paks): those are listed
  if (m.type() === 'error' && !/^Failed to load resource/.test(m.text())) errors.push(m.text().split('\n')[0]);
});

// the stats line (src/main.js): "<fps> fps, <tics> tics/s · <quake_tic|qc_tic (…)> …", until tics run, or
// until the status line shows an error (boot() and loadLevel catch theirs and show them there, so a failed
// load is no page error and would otherwise only show as the timeout)
async function running(label, logic) {
  try {
    await page.waitForFunction((re) => {
      if (document.getElementById('status')?.classList.contains('error')) return true;
      const m = (document.getElementById('stats')?.textContent ?? '').match(/([\d.]+) tics\/s · (\S+)/);
      return m && Number(m[1]) >= 5 && new RegExp(re).test(m[2]);
    }, logic, { timeout: 180000, polling: 250 });
  } catch { /* reported below */ }
  const stats = (await page.textContent('#stats').catch(() => '')).trim();
  const status = (await page.textContent('#status').catch(() => '')).trim();
  const statusError = await page.evaluate(() => document.getElementById('status')?.classList.contains('error')).catch(() => false);
  const m = stats.match(/([\d.]+) tics\/s · (\S+)/);
  assert(!statusError && m && Number(m[1]) >= 5 && new RegExp(logic).test(m[2]) && errors.length === 0,
    `${label}: the game runs (${statusError ? `the page shows an error: ${status}` : stats.split(' · ').slice(0, 2).join(' · ') || `status: ${status || 'nothing'}`})${errors.length ? `; errors: ${errors.join(' | ')}` : ''}`);
  return !statusError && m;
}

await page.goto(base);
await running('the start map in the PSQL game', '^quake_tic');
assert(logs.some((l) => /database ready in \d+ ms \(the schema from schema-/.test(l)), `the database opened from the schema image (${logs.find((l) => /database ready/.test(l)) ?? 'no log'})`);
assert(!(await page.evaluate(() => crossOriginIsolated)), 'without cross-origin isolation: the engine built without threads needs none');

// QuakeC mode: a deathmatch on E1M1 with three bots, from the page's own settings
await page.evaluate(() => localStorage.setItem('firebird-quake:settings', JSON.stringify({ logic: 'qc', mode: 'deathmatch', bots: 3, map: 'e1m1' })));
await page.reload();
if (await running('QuakeC mode, a deathmatch with three bots on E1M1', '^qc_tic')) {
  // the player and the three bots are in the game (qc_scores lists the clients connected)
  const players = await page.evaluate(() => window.quake.sql('SELECT COUNT(*) FROM qc_scores').then((r) => Number(Object.values(r[0])[0]))).catch((e) => e.message);
  assert(players === 4, `QuakeC mode: four players in qc_scores, the player and three bots (${players})`);
}

if (missing.size) console.log(`(not found, as expected without them: ${[...missing].join(', ')})`);
await browser.close();
server.close();
console.log(failed ? `${failed} failure(s)` : 'all page checks passed');
process.exit(failed ? 1 : 0);
