// qcjit-test.mjs – QuakeC compiled to PSQL (src/qcjit.js): every function of progs.dat compiles to a
// procedure; the self-contained ones (no calls, no field writes) give the interpreter's results on the
// same arguments, globals included; and E1M1 plays in QuakeC mode while the hot functions get compiled
// between frames, as the page does.
//
//   node scripts/qcjit-test.mjs              (PAK=... for another pak0.pak; LQ=... a second progs to compile)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const lqPath = process.env.LQ ?? path.join(root, 'public/pak/lq1/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) failures++; };
const q1 = (db, s) => db.query(s).then((r) => r.rows[0]);

// ── every function compiles (another progs.dat too, in a process of its own: LibreQuake's, built by FTEQCC) ──
if (process.argv[2] === '--compile-all') {
  const db = new FirebirdBrowser('memory://all', { transport: new DirectTransport() });
  await createSchema(db, sql);
  const progs = await loadProgs(db, new Pak(fs.readFileSync(process.argv[3]).buffer));
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`${jit.compiled.size} of ${jit.body.size} functions compiled in ${(jit.ms / 1000).toFixed(1)} s${jit.failed.size ? ': ' + [...jit.failed].slice(0, 3).map(([f, m]) => `${progs.functions[f].name} ${m}`).join('; ') : ''}`);
  process.exit(jit.failed.size ? 1 : 0);
}
if (fs.existsSync(lqPath)) {
  let out, ok = true;
  try { out = execFileSync(process.execPath, [fileURLToPath(import.meta.url), '--compile-all', lqPath], { encoding: 'utf8' }).trim(); } catch (e) { ok = false; out = String(e.stdout ?? e.message).trim(); }
  check(ok, `LibreQuake: ${out.split(/\r?\n/).pop()}`);
}

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const progs = await loadProgs(db, pak);
const jit = new QcJit(db, progs);
await jit.init();
await jit.compileAll();
check(jit.failed.size === 0 && jit.compiled.size === jit.body.size, `progs.dat: ${jit.compiled.size} of ${jit.body.size} functions compiled in ${(jit.ms / 1000).toFixed(1)} s`);
const kinds = { loops: 0, machine: 0 };
for (const f of jit.body.keys()) { const s = jit.source(f); if (/ L\d+: WHILE|^L\d+: WHILE/m.test(s)) kinds.loops++; if (/^M: WHILE/m.test(s)) kinds.machine++; }
check(kinds.machine === 0, `structured: ${kinds.loops} with loops, ${kinds.machine} as a loop over blocks`);

// ── the self-contained functions: interpreted and compiled agree ────────
// (no field store, no OP_STATE, calls only of deterministic builtins or of other such functions: what
// they do is their return value and the globals they write, the compiled ones' own variables aside)
const PURE = new Set([1, 9, 12, 13, 26, 27, 36, 37, 38, 43, 51]);   // makevectors normalize vlen vectoyaw ftos vtos rint floor ceil fabs vectoangles
const image = new Map(progs.globals);
const pure = new Set();
for (let changed = true; changed;) {
  changed = false;
  for (const [f, [first, last]] of jit.body) {
    if (pure.has(f)) continue;
    let ok = true;
    for (let s = first; s <= last && ok; s++) {
      const [, op, a] = progs.statements[s];
      if ((op >= 37 && op <= 42) || op === 60) ok = false;
      else if (op >= 51 && op <= 59) {
        const g = progs.functions[Math.round(image.get(a) ?? 0)];
        ok = !!g && g.id !== 0 && (g.first_statement < 0 ? PURE.has(-g.first_statement) : pure.has(g.id));
      }
    }
    if (ok) { pure.add(f); changed = true; }
  }
}
const self = [...pure];
const args = [[0, 0, 0], [370, -45, 1], [-725.5, 2, 0.25], [90, 180, 270], [1, 1, 1], [-1, 0, 3]];
let agree = 0, disagree = [];
const snapshot = async (own) => (await db.query('SELECT ofs, v FROM qc_globals WHERE ofs > 27 ORDER BY ofs')).rows.filter((r) => !own.has(r.OFS)).map((r) => `${r.OFS}:${r.V}`).join(',');
for (const f of self) {
  const fn = progs.functions[f];
  for (const a of args) {
    const results = [];
    for (const compiled of [0, 1]) {
      await db.exec('EXECUTE PROCEDURE qc_reset');
      await db.exec(`UPDATE qc_functions SET compiled = ${compiled} WHERE id = ${f}`);
      // every parameter slot gets the same three numbers (a vector, or a float and spares)
      await db.exec(`UPDATE qc_globals SET v = CASE MOD(ofs - 4, 3) WHEN 0 THEN ${a[0]} WHEN 1 THEN ${a[1]} ELSE ${a[2]} END WHERE ofs BETWEEN 4 AND 27`);
      let err = null;
      try { await db.exec(`EXECUTE PROCEDURE qc_call(${f})`); } catch (e) { err = e.message.split('\n').slice(-2).join(' '); }
      const r = await q1(db, 'SELECT qc_g(1) a, qc_g(2) b, qc_g(3) c FROM rdb$database');
      results.push(err ? `error ${err.replace(/statement \d+/, '')}` : `${r.A},${r.B},${r.C}|${await snapshot(jit.vars.get(f))}`);
    }
    if (results[0] === results[1]) agree++;
    else disagree.push(`${fn.name}(${a}): ${results[0].slice(0, 80)} vs ${results[1].slice(0, 80)}`);
  }
}
check(disagree.length === 0 && agree > 0, `${self.length} self-contained functions, ${agree} runs agree${disagree.length ? `, ${disagree.length} differ: ${disagree.slice(0, 3).join(' | ')}` : ''}`);

// anglemod's loops, far out
await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${360 * 400 + 30})`);
let t0 = performance.now();
await db.exec("EXECUTE PROCEDURE qc_call(qc_fn('anglemod'))");
const am = await q1(db, 'SELECT qc_g(1) v FROM rdb$database');
check(Math.abs(am.V - 30) < 1e-6, `anglemod(${360 * 400 + 30}) = ${am.V} compiled, 400 turns of its loop in ${(performance.now() - t0).toFixed(0)} ms`);
await db.close();

// ── E1M1 played while the hot functions get compiled ─────────────────────
// a fresh progs: nothing compiled, then what the frames call most, a few at a time
const db2 = new FirebirdBrowser('memory://play', { transport: new DirectTransport() });
await createSchema(db2, sql);
const res2 = await loadResources(db2, pak);
await loadMap(db2, pak, res2, 'e1m1', { skill: 1, seed: 1 });
const jit2 = new QcJit(db2, await loadProgs(db2, pak));
await jit2.init();
await db2.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
await jit2.compileHot({ min: 2, max: 32 });
const spawned = jit2.compiled.size;
const ms = [];
// walk forward, then onto the bridge facing the grunts (god mode), firing
for (let i = 0; i < 120; i++) {
  if (i === 40) {
    await db2.exec('UPDATE ents SET x = 1150, y = 1030, z = -250, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = 1');
    await db2.exec('EXECUTE PROCEDURE link_ent(1)');
    await db2.exec("EXECUTE PROCEDURE qc_sf(1, qc_fdef('v_angle') + 1, 330)");
    // the grunts nearby see the player, through QuakeC's own FoundTarget (sight itself is random)
    for (const g of (await db2.query(`SELECT f.ent FROM qc_fields f JOIN ents e ON e.id = f.ent WHERE f.ofs = qc_fdef('classname')
        AND qc_str(CAST(f.v AS INTEGER)) = 'monster_army' AND (e.x - 1150) * (e.x - 1150) + (e.y - 1030) * (e.y - 1030) < 1000 * 1000`)).rows) {
      await db2.exec(`EXECUTE PROCEDURE qc_sf(${g.ENT}, qc_fdef('enemy'), 1)`);
      await db2.exec(`EXECUTE PROCEDURE qc_run('FoundTarget', ${g.ENT})`);
    }
  }
  t0 = performance.now();
  await q1(db2, `SELECT * FROM qc_tic(1, ${i < 40 ? 1 : 0}, 0, 0, 0, ${i > 60 && i % 10 === 0 ? 1 : 0}, 0, 1, 0)`);
  ms.push(performance.now() - t0);
  if (i % 10 === 9) await jit2.compileHot({ min: 3, max: 4 });
}
const errors = (await db2.query("SELECT msg FROM qc_log WHERE kind = 'error'")).rows;
check(errors.length === 0, `120 tics of E1M1 with no QuakeC error${errors.length ? ': ' + errors[0].MSG : ''}`);
const hot = (await db2.query('SELECT FIRST 6 name, compiled FROM qc_functions WHERE first_statement > 0 ORDER BY calls DESC')).rows;
check(hot.every((h) => h.COMPILED === 1), `the hottest functions are compiled: ${hot.map((h) => h.NAME).join(', ')} (${spawned} after the spawn, ${jit2.compiled.size} now)`);
const hunting = (await db2.query(`SELECT e.id, q.name FROM ents e JOIN qc_functions q ON q.id = CAST(qc_f(e.id, qc_fdef('think')) AS INTEGER)
  WHERE BIN_AND(e.flags, 32) <> 0 AND e.enemy_id = 1`)).rows;
check(hunting.some((h) => /^army_(run|atk|pain)/.test(h.NAME)), `${hunting.length} grunts hunt the player: ${hunting.map((h) => h.NAME).join(', ')}`);
// (the shell count may also grow: a dead grunt's backpack)
const shots = (await q1(db2, "SELECT COUNT(*) n FROM qc_log WHERE kind = 'sound' AND msg LIKE '%weapons/guncock%'")).N;
check(shots > 0, `the shotgun fired ${shots} times`);
const sorted = [...ms.slice(60)].sort((a, b) => a - b);
console.log(`the last 60 tics: median ${sorted[30].toFixed(0)} ms, max ${sorted[59].toFixed(0)} ms`);

await db2.close();
console.log(failures ? `${failures} failed` : 'all good');
process.exit(failures ? 1 : 0);
