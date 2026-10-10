// qcvm-bench.mjs – how fast is the QuakeC VM? A pure QuakeC loop (anglemod of a
// huge angle), QuakeC function calls (crandom), and E1M1 server frames in
// QuakeC mode with the monsters asleep and with the grunts on the bridge awake.
//
//   node scripts/qcvm-bench.mjs                  (BENCH_JSON=file writes the numbers there too)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
const progs = await loadProgs(db, pak);
if (process.env.QCJIT === 'all') {                 // every function compiled to its own procedure
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`compiled ${jit.compiled.size} functions in ${(jit.ms / 1000).toFixed(1)} s`);
}
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const steps = () => q1('SELECT steps FROM qc_vm').then((r) => Number(r.STEPS));
const out = {};
const median = (a) => [...a].sort((x, y) => x - y)[a.length >> 1];

// ── the interpreter alone ────────────────────────────────────────────────
{
  const s0 = await steps(), t0 = performance.now();
  await db.exec('EXECUTE PROCEDURE qc_sg(4, 1296000)');           // 3600 turns of the loop
  await db.exec("EXECUTE PROCEDURE qc_call(qc_fn('anglemod'))");
  const ms = performance.now() - t0, n = (await steps()) - s0;
  out.loop = { statements: n, ms: Math.round(ms), usPerStatement: +(ms * 1000 / n).toFixed(1) };
}
{
  const s0 = await steps(), t0 = performance.now();
  await db.query("EXECUTE BLOCK AS DECLARE i INTEGER = 0; BEGIN WHILE (i < 300) DO BEGIN EXECUTE PROCEDURE qc_call(qc_fn('crandom')); i = i + 1; END END");
  const ms = performance.now() - t0, n = (await steps()) - s0;
  out.calls = { calls: 300, statements: n, usPerCall: Math.round(ms * 1000 / 300) };
}

// ── server frames in QuakeC mode ─────────────────────────────────────────
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
const frames = async (n, label) => {
  const ms = [], st = [];
  for (let i = 0; i < n; i++) {
    const s0 = await steps(), t0 = performance.now();
    await q1('SELECT * FROM qc_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
    ms.push(performance.now() - t0); st.push((await steps()) - s0);
  }
  out[label] = { frames: n, medianMs: Math.round(median(ms)), medianStatements: median(st), usPerStatement: +(median(ms) * 1000 / Math.max(1, median(st))).toFixed(1) };
};
for (let i = 0; i < 4; i++) await q1('SELECT * FROM qc_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
await frames(20, 'asleep');
// the bridge in the slime hall, facing the grunts; god mode so the run lasts
await db.exec('UPDATE ents SET x = 1150, y = 1030, z = -250, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = 1');
await db.exec('EXECUTE PROCEDURE link_ent(1)');
await db.exec("EXECUTE PROCEDURE qc_sf(1, qc_fdef('v_angle') + 1, 330)");
for (let i = 0; i < 10; i++) await q1('SELECT * FROM qc_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
const awake = (await q1('SELECT COUNT(*) n FROM ents WHERE BIN_AND(flags, 32) <> 0 AND enemy_id = 1')).N;
await frames(20, 'awake');
out.awake.monstersAwake = awake;

console.log(JSON.stringify(out, null, 1));
if (process.env.BENCH_JSON) fs.writeFileSync(process.env.BENCH_JSON, JSON.stringify({
  'loop µs per statement': out.loop.usPerStatement, 'µs per call': out.calls.usPerCall,
  'server frame asleep ms': out.asleep.medianMs, 'server frame awake ms': out.awake.medianMs }));
await db.close();
process.exit(0);
