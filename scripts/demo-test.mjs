// demo-test.mjs – demos (sql/demo.sql, src/demos.js): a game of E1M1 recorded through quake_tic, with
// monsters fighting and the player shooting, then played back from the demo in a fresh database and in
// one that has played another level since; every tic of the playback must match the recording bit for
// bit, and so must the entities at the end. Then the same in QuakeC mode.
//
//   node scripts/demo-test.mjs
//   QCJIT=all node scripts/demo-test.mjs     the QuakeC playback compiled, the recording interpreted

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { exportDemo, importDemo, DemoPlayer } from '../src/demos.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(pakPath).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

async function fresh() {
  const db = new FirebirdBrowser(`memory://demo${Math.random()}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  return { db, res: await loadResources(db, pak) };
}
const row = (db, qc, args) => db.query(`SELECT * FROM ${qc ? 'qc_tic' : 'quake_tic'}(?,?,?,?,?,?,?,?,?)`, args).then((r) => r.rows[0]);
const line = (r) => [r.PX, r.PY, r.PZ, r.YAW, r.PITCH, r.HEALTH, r.ARMORVALUE, r.SHELLS, r.WEAPON, r.KILLED].join(',');
const entsOf = async (db) => JSON.stringify((await db.query('SELECT id, classname, x, y, z, health, frame, nextthink FROM ents ORDER BY id')).rows);
// a player's input, as varied as the page's: walking, strafing, mouse turns (fractional degrees),
// looking, firing, jumping, all weapons (impulse 9), a weapon change, 1 to 3 tics a call
const input = (i) => [1 + (i % 5 === 0 ? 1 : 0) + (i % 11 === 0 ? 1 : 0), i % 90 < 60 ? 1 : 0, i % 40 < 10 ? -1 : 0, i % 30 < 5 ? 6.37 + i / 1000 : -0.25,
  i % 60 < 3 ? 1.5 : 0, i % 7 === 0 ? 1 : 0, i % 50 === 0 ? 1 : 0, 1, i === 3 ? 9 : i === 200 ? 7 : 0];

async function startLevel(env, qc, seed) {
  await loadMap(env.db, pak, env.res, 'e1m1', { skill: 2, seed });
  if (qc) await env.db.exec('EXECUTE PROCEDURE qc_begin_map(2, 0)');
}

async function record(env, qc, calls) {
  await startLevel(env, qc, null);                      // a seed of init_map's own choosing
  await env.db.exec('EXECUTE PROCEDURE demo_record');
  const trace = [];
  for (let i = 0; i < calls; i++) trace.push(line(await row(env.db, qc, input(i))));
  await env.db.exec('EXECUTE PROCEDURE demo_stop');
  return { trace, ents: await entsOf(env.db), demo: await exportDemo(env.db) };
}

async function play(env, demo) {
  await importDemo(env.db, demo);
  const d = JSON.parse(JSON.stringify(demo));           // as the page has it, through JSON
  await startLevel(env, d.qc === 1, d.seed);
  const player = new DemoPlayer(d);
  const trace = [];
  for (let args; (args = player.next());) trace.push(line(await row(env.db, d.qc === 1, args)));
  return { trace, ents: await entsOf(env.db) };
}

const first = (a, b) => { const i = a.findIndex((t, k) => t !== b[k]); return i < 0 && a.length === b.length ? -1 : i; };

for (const [qc, calls] of [[false, 700], [true, 250]]) {
  const mode = qc ? 'QuakeC mode' : 'the PSQL game';
  const A = await fresh();
  if (qc) { await loadMap(A.db, pak, A.res, 'e1m1'); await loadProgs(A.db, pak); }
  const rec = await record(A, qc, calls);
  const end = rec.trace.at(-1).split(',');
  assert(rec.demo.tics.length === calls && rec.demo.map === 'e1m1' && rec.demo.qc === (qc ? 1 : 0),
    `${mode}: ${calls} calls recorded on E1M1 with seed ${rec.demo.seed} (the player ends with health ${end[5]}, ${end[9]} kills)`);
  const moved = new Set(rec.trace.map((t) => t.split(',').slice(0, 2).join(','))).size;
  const hurt = new Set(rec.trace.map((t) => t.split(',')[5])).size;
  assert(moved >= 30 && hurt >= 3, `something happens in it: ${moved} distinct positions, ${hurt} different health values`);
  // in the recording's database, after another level
  await A.db.exec('EXECUTE PROCEDURE qc_leave');
  await loadMap(A.db, pak, A.res, 'e1m2');
  for (let i = 0; i < 40; i++) await row(A.db, false, [1, 1, 0, 4, 0, i % 5 === 0 ? 1 : 0, 0, 1, 0]);
  const pa = await play(A, rec.demo);
  assert(first(rec.trace, pa.trace) === -1 && pa.ents === rec.ents, `played back after E1M2 in the same database, it is the same game (diverged at ${first(rec.trace, pa.trace)})`);
  assert(!(await A.db.query('SELECT recording FROM demo')).rows[0].RECORDING, 'playback records nothing');
  await A.db.close();                                 // one engine at a time: compiling all of QuakeC needs the memory
  // in a fresh database
  const B = await fresh();
  if (qc) {
    await loadMap(B.db, pak, B.res, 'e1m1');
    const progs = await loadProgs(B.db, pak);
    // QCJIT=all: the playback runs every function compiled to PSQL, the recording ran them interpreted
    if (process.env.QCJIT === 'all') { const jit = new QcJit(B.db, progs); await jit.init(); await jit.compileAll(); console.log(`playback with ${jit.compiled.size} functions compiled`); }
  }
  const pb = await play(B, rec.demo);
  assert(first(rec.trace, pb.trace) === -1, `played back in a fresh database, every tic matches (diverged at ${first(rec.trace, pb.trace)})`);
  assert(pb.ents === rec.ents, 'and every entity at the end');
  await B.db.close();
}

// a demo starts with its level, and a new level stops a recording
const C = await fresh();
await loadMap(C.db, pak, C.res, 'e1m1');
await row(C.db, false, [1, 0, 0, 0, 0, 0, 0, 1, 0]);
let refused = false;
try { await C.db.exec('EXECUTE PROCEDURE demo_record'); } catch (e) { refused = e.message.includes('first tic'); }
assert(refused, 'recording after the first tic is refused');
await loadMap(C.db, pak, C.res, 'e1m1');
await C.db.exec('EXECUTE PROCEDURE demo_record');
await row(C.db, false, [1, 1, 0, 0, 0, 0, 0, 1, 0]);
await loadMap(C.db, pak, C.res, 'e1m2');
await row(C.db, false, [1, 1, 0, 0, 0, 0, 0, 1, 0]);
const d = (await C.db.query('SELECT recording, calls FROM demo')).rows[0];
assert(d.RECORDING === 0 && d.CALLS === 1, 'the next level stops the recording (one call kept)');
await C.db.close();

console.log(failed ? `${failed} failure(s)` : 'all demo checks passed');
process.exit(failed ? 1 : 0);
