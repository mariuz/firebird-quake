// levels-test.mjs – every level of the paks it is given, in both logics: the PSQL game loads it and, after
// a second (or once landed: E1M8's start is 630 units up, a slow fall at its gravity of 100), the player
// stands on the floor of an open leaf (or swims) at full health, its monsters are there, each exit names
// a map the paks have and ends the level when fired; and progs.dat spawns it in QuakeC mode with the same
// number of monsters to kill (total_monsters) and plays a second without a QuakeC error. On the shareware pak (the default, and what CI
// runs) that is the start map and episode 1; with the registered pak1.pak beside it, episodes 2 to 4,
// the end map and the deathmatch levels too, which is the only test the registered levels have, since CI
// cannot have the pak:
//
//   node scripts/levels-test.mjs                                  the shareware episode
//   PAK1=/path/to/id1/pak1.pak node scripts/levels-test.mjs       Quake, all four episodes
//   PAK1=… LEVELS=e3m4,e4m8 node scripts/levels-test.mjs          some of them
//   QC=0 node scripts/levels-test.mjs                             the PSQL game only

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [process.env.PAK ?? path.join(root, 'public/pak/pak0.pak'), process.env.PAK1].filter(Boolean);
for (const f of files) if (!fs.existsSync(f)) { console.log(`${f} is missing`); process.exit(1); }
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new PakSet(files.map((f) => new Pak(fs.readFileSync(f).buffer)));
const registered = pak.has('maps/e2m1.bsp');
const qcToo = process.env.QC !== '0';

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://levels', { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const qa = (s) => db.query(s).then((r) => r.rows);
let jit = null;

const only = process.env.LEVELS ? new Set(process.env.LEVELS.split(',')) : null;
const levels = pak.mapNames().filter((m) => (m === 'start' || m === 'end' || /^e\dm\d$/.test(m) || /^dm\d$/.test(m)) && (!only || only.has(m)));
console.log(`${levels.length} levels (${registered ? 'registered' : 'shareware'}): ${levels.join(' ')}`);
const quiet = (m) => m === 'start' || m === 'end' || m.startsWith('dm');   // no monsters, or none required
for (const name of levels) {
  // ── the PSQL game ──
  await db.exec('EXECUTE PROCEDURE qc_leave');
  await loadMap(db, pak, res, name, { skill: 1, seed: 3 });
  // a second, or until landed (E1M8's start is 630 units up: a slow fall at its gravity of 100)
  let r, p;
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  for (let i = 0; i < 100; i++) {
    r = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
    p = await q1(`SELECT flags, (SELECT contents FROM leaves l WHERE l.id = e.leaf) c FROM ents e WHERE e.id = ${pe}`);
    if (i >= 19 && ((p.FLAGS & 512) !== 0 || p.C === -3)) break;
  }
  const total = r.TOTAL_MONSTERS;
  const monsters = (await q1('SELECT COUNT(*) n FROM ents WHERE mtype IS NOT NULL')).N;
  const exits = await qa("SELECT id, map FROM ents WHERE classname = 'trigger_changelevel' ORDER BY id");
  // the shareware start map keeps its gates to episodes 2 to 4 and the end, whose maps only the registered pak has
  const missing = exits.filter((x) => !pak.has(`maps/${String(x.MAP).toLowerCase()}.bsp`) && (registered || !/^(e[2-4]m\d|end)$/i.test(x.MAP)));
  const msg = (await q1('SELECT level_msg m FROM game')).M ?? '';
  const ok = r.HEALTH === 100 && (((p.FLAGS & 512) !== 0 && p.C === -1) || p.C === -3) && (monsters > 0 || quiet(name))
    && (exits.length > 0 || name === 'end' || name.startsWith('dm')) && missing.length === 0;
  assert(ok, `${name.padEnd(5)} "${msg}": ${p.C === -3 ? 'starts in water' : 'stands on the floor'} at full health, ${monsters} monsters, exits to ${exits.map((x) => x.MAP).join(', ') || 'none'}${missing.length ? `, missing ${missing.map((x) => x.MAP).join(', ')}` : ''}`);
  const out = exits.find((x) => pak.has(`maps/${String(x.MAP).toLowerCase()}.bsp`));
  if (out) {
    await db.exec(`EXECUTE PROCEDURE changelevel(${out.ID})`);
    r = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
    assert(r.EXIT_KIND === 1 && r.NEXT_MAP === out.MAP, `${name.padEnd(5)} its exit ends the level for ${out.MAP}`);
  }
  // ── QuakeC mode ──
  if (!qcToo) continue;
  await loadMap(db, pak, res, name, { skill: 1, seed: 3 });
  if (!jit) { jit = new QcJit(db, await loadProgs(db, pak)); await jit.init(); }
  await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  for (let i = 0; i < 20; i++) r = await q1('SELECT * FROM qc_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  if (!jit.compiled.size) await jit.compileHot({ min: 2, max: 32 });
  const errors = (await qa("SELECT msg FROM qc_log WHERE kind = 'error'")).map((x) => x.MSG);
  assert(errors.length === 0 && r.HEALTH === 100 && r.TOTAL_MONSTERS === total,
    `${name.padEnd(5)} QuakeC mode: progs.dat spawns it with the same ${r.TOTAL_MONSTERS} monsters to kill${r.TOTAL_MONSTERS !== total ? ` (the PSQL game counts ${total})` : ''}, a second played at full health without a QuakeC error${errors.length ? ` (${errors[0]})` : ''}`);
}
await db.close();

console.log(failed ? `${failed} failure(s)` : `all ${levels.length} levels passed`);
process.exit(failed ? 1 : 0);
