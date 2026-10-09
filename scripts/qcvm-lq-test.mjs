// qcvm-lq-test.mjs – LibreQuake's progs.dat in QuakeC mode. FTEQCC builds it with the locals of
// different functions overlapping (Quake's VM saves a callee's locals on entry and restores them on
// exit, so they cannot clash): LinkDoors and EntitiesTouching share their slots, and without the save
// the door chain never ended. The level spawns, the doors link, the player walks; the run compiled to
// PSQL (in a process of its own) ends where the interpreted one does.
//
//   node scripts/qcvm-lq-test.mjs            (needs npm run fetch-librequake)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = process.env.LQ_DIR ?? path.join(root, 'public/pak/lq1');
const MAP = 'lq_e0m1';
const compiled = process.argv[2] === '--compiled';
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) failures++; };

const db = new FirebirdBrowser('memory://lq', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new PakSet(['pak0.pak', 'pak1.pak'].filter((f) => fs.existsSync(path.join(dir, f))).map((f) => new Pak(fs.readFileSync(path.join(dir, f)).buffer)));
const res = await loadResources(db, pak);
await loadMap(db, pak, res, MAP, { skill: 1, seed: 1 });
const progs = await loadProgs(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const qa = (s) => db.query(s).then((r) => r.rows);
if (compiled) {
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
}
const shared = progs.functions.filter((f) => f.shared).length;
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
const errors = async () => (await qa("SELECT msg FROM qc_log WHERE kind = 'error'")).map((e) => String(e.MSG).split('\n')[0]);
const ms = [];
let r;
for (let i = 0; i < 40; i++) {
  const t0 = performance.now();
  r = await q1(`SELECT * FROM qc_tic(1, ${i < 30 ? 1 : 0}, 0, 0, 0, 0, 0, 1, 0)`);
  ms.push(performance.now() - t0);
}
const pos = `${r.PX.toFixed(3)} ${r.PY.toFixed(3)} ${r.PZ.toFixed(3)}`;
if (compiled) { console.log(`POS ${pos}`); process.exit((await errors()).length ? 1 : 0); }

check(shared > 100, `${shared} of LibreQuake's functions have locals that overlap others' (FTEQCC)`);
const live = (await q1('SELECT COUNT(*) n FROM qc_edicts WHERE free = 0')).N;
check(live > 100, `${MAP} spawned through progs.dat: ${live} edicts live`);
const errs = await errors();
check(errs.length === 0, `40 tics with no QuakeC error${errs.length ? ': ' + errs.slice(0, 2).join(' | ') : ''}`);
// LinkDoors ran for every door: each points at the master of its group (owner), and none still waits to link
const doors = await qa(`SELECT d.ent, IIF(qc_f(d.ent, qc_fdef('think')) = qc_fn('LinkDoors'), 1, 0) linker, IIF(qc_f(d.ent, qc_fdef('nextthink')) > 0, 1, 0) pending, qc_f(d.ent, qc_fdef('owner')) owner
  FROM (SELECT f.ent FROM qc_fields f JOIN qc_edicts e ON e.id = f.ent AND e.free = 0 WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'door') d`);
const linkers = doors.filter((d) => d.LINKER === 1);
check(linkers.length > 3 && linkers.every((d) => d.OWNER > 0 && d.PENDING === 0), `${linkers.length} doors linked into ${new Set(linkers.map((d) => d.OWNER)).size} groups (LinkDoors walked each chain to its end)`);
const sorted = [...ms].sort((a, b) => a - b);
check(sorted[sorted.length - 1] < 3000, `no tic runs away: median ${sorted[20].toFixed(0)} ms, max ${sorted[39].toFixed(0)} ms`);
const msg = r.MSG ?? '';
check(/joined/.test(msg), `the player joined ("${msg.trim()}") and walked to ${pos}`);
let out = '';
try { out = execFileSync(process.execPath, [fileURLToPath(import.meta.url), '--compiled'], { encoding: 'utf8' }); } catch (e) { out = String(e.stdout ?? '') + ' exit ' + e.status; }
const cpos = (out.match(/POS (.*)/) ?? [])[1];
check(cpos === pos, `compiled to PSQL, the same walk ends at the same point (${cpos ?? out.trim().slice(-200)})`);
await db.close();
console.log(failures ? `${failures} failed` : 'all good');
process.exit(failures ? 1 : 0);
