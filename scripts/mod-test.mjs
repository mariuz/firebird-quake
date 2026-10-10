// mod-test.mjs – mods: a mod's zip laid over the shareware pak as Quake lays a game directory over id1
// (src/zip.js), and its own progs.dat run by the QuakeC VM. Three released mods (npm run fetch-mods):
// id's progs 1.06 recompiled with the fish fix (a progs.dat inside a pak2.pak), Reinforcer 1.1 and
// FrikBot X, which adds bots into spare client slots and moves them with its own QuakeC physics. What
// they found in the VM: client edicts did not exist until a client connected (FrikBot counts them with
// nextent at worldspawn), colormap and team were not set on connect, findradius returned the world when
// a radius reached the map's centre, and progs strings with Quake's coloured characters failed to load.
//
//   node scripts/mod-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet } from '../src/pak.js';
import { modFromZip } from '../src/zip.js';
import { dequake } from '../src/progs.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const modPath = (zip) => [path.join(root, 'public/pak/mods', zip), path.join(root, 'mods', zip)].find((p) => fs.existsSync(p));
const id1 = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

assert(dequake('\x90\x92\x91 \xe6\xf2\xe9\xeb\n') === '[0] frik\n', "Quake's coloured characters read as plain ASCII, one for one (gold brackets and digits, high-bit letters)");

if (!['fbxc.zip', 'progs106fishfix.zip', 'reinforcer_11.zip'].every(modPath)) {
  console.log('note: the mods are missing (npm run fetch-mods): their checks skipped');
  process.exit(failed ? 1 : 0);
}

// a level in QuakeC mode under a mod: the database, the paks, the compiled QuakeC, helpers on fields
async function level(zip, { map = 'e1m1', dm = 0, slots = 0 } = {}) {
  const mod = await modFromZip(fs.readFileSync(modPath(zip)).buffer, zip);
  const pak = new PakSet([id1, ...mod.paks]);
  const db = new FirebirdBrowser(`memory://mod${Math.random()}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const res = await loadResources(db, pak);
  await loadMap(db, pak, res, map, { seed: 1 });
  const jit = new QcJit(db, await loadProgs(db, pak));
  await jit.init();
  const q1 = (s) => db.query(s).then((r) => r.rows[0]);
  const qa = (s) => db.query(s).then((r) => r.rows);
  await db.exec(`EXECUTE PROCEDURE qc_setup_server(${dm}, 0, 0, 0, 0)`);
  if (slots) await db.exec(`EXECUTE PROCEDURE qc_set_maxclients(${slots})`);
  await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  const errors = async () => (await qa("SELECT msg FROM qc_log WHERE kind = 'error'")).map((r) => r.MSG);
  const tic = (fwd = 0, yaw = 0, imp = 0) => q1(`SELECT * FROM qc_tic(1, ${fwd}, 0, ${yaw}, 0, 0, 0, 1, ${imp})`);
  const o = (await q1("SELECT qc_fdef('origin') o FROM rdb$database")).O;
  const at = (e) => q1(`SELECT qc_f(${e}, ${o}) x, qc_f(${e}, ${o} + 1) y, qc_f(${e}, ${o} + 2) z FROM rdb$database`);
  return { mod, pak, db, jit, q1, qa, errors, tic, at };
}

// ── the layering ─────────────────────────────────────────────────────────
{
  const f = await modFromZip(fs.readFileSync(modPath('fbxc.zip')).buffer);
  const set = new PakSet([id1, ...f.paks]);
  assert(f.name === 'frikbot' && f.progs && set.get('progs.dat') !== id1.get('progs.dat') && set.has('progs/beam.mdl') && set.has('maps/e1m1.bsp'),
    "FrikBot X's zip (fbxc/frikbot/…): its progs.dat and progs/beam.mdl over id1's files, id1's maps still there");
  const p = await modFromZip(fs.readFileSync(modPath('progs106fishfix.zip')).buffer);
  const set2 = new PakSet([id1, ...p.paks]);
  assert(p.paks.length === 2 && p.progs && set2.get('progs.dat').length !== id1.get('progs.dat').length,
    "the fish fix's pak2.pak inside its zip: its progs.dat shadows id1's (a game directory's paks before its loose files)");
}

// ── each mod spawns E1M1 and plays it ────────────────────────────────────
for (const zip of ['progs106fishfix.zip', 'reinforcer_11.zip', 'fbxc.zip']) {
  const L = await level(zip);
  const p0 = await L.at(1);
  for (let i = 0; i < 40; i++) await L.tic(i > 10 ? 1 : 0);
  const p1 = await L.at(1);
  const errs = await L.errors();
  assert(errs.length === 0 && Math.hypot(p1.X - p0.X, p1.Y - p0.Y) > 32,
    `${L.mod.name}: E1M1 spawned by its progs.dat, 40 tics without a QuakeC error, the player walked ${Math.hypot(p1.X - p0.X, p1.Y - p0.Y).toFixed(0)} units${errs.length ? ` (${errs[0]})` : ''}`);
  if (zip === 'progs106fishfix.zip') {
    // findradius from near the map's centre with a radius that reaches it: a chain of entities, not the world
    await L.db.exec('EXECUTE PROCEDURE qc_sg(4, 0); EXECUTE PROCEDURE qc_sg(5, 0); EXECUTE PROCEDURE qc_sg(6, 0); EXECUTE PROCEDURE qc_sg(7, 13000)');
    await L.db.exec('EXECUTE PROCEDURE qc_builtin(22, 0)');
    const head = (await L.q1('SELECT CAST(qc_g(1) AS INTEGER) e FROM rdb$database')).E;
    const solid = head ? (await L.q1(`SELECT qc_f(${head}, qc_fdef('solid')) s FROM rdb$database`)).S : 0;
    assert(head > 0 && solid !== 0, `findradius(origin, 13000) starts its chain at edict ${head}, a solid one, as PF_findradius (after the world, SOLID_NOT left out)`);
  }
  await L.db.close();
}

// ── FrikBot X: bots in a deathmatch ──────────────────────────────────────
{
  const L = await level('fbxc.zip', { dm: 1, slots: 4 });
  const slots = (await L.qa("SELECT d.id FROM qc_edicts d WHERE d.id BETWEEN 1 AND 4 AND d.free = 0")).length;
  assert(slots === 4, `four client edicts in use from worldspawn on, as SV_SpawnServer makes them (${slots})`);
  for (let i = 0; i < 5; i++) await L.tic();
  await L.tic(0, 0, 100);
  await L.tic(0, 0, 100);
  const scores = await L.qa('SELECT c, name FROM qc_scores');
  const bots = scores.filter((s) => s.C > 1);
  assert(bots.length === 2 && bots.every((b) => b.NAME), `impulse 100 twice: two FrikBots connect into spare slots (${bots.map((b) => `${b.NAME} in ${b.C}`).join(', ')})`);
  const start = await Promise.all(bots.map((b) => L.at(b.C)));
  for (let i = 0; i < 80; i++) {
    await L.tic();
    if (i % 40 === 39) await L.jit.compileHot({ min: 3, max: 20 });
  }
  const end = await Promise.all(bots.map((b) => L.at(b.C)));
  const moved = start.map((s, i) => Math.hypot(end[i].X - s.X, end[i].Y - s.Y));
  const errs = await L.errors();
  assert(moved.every((d) => d > 64) && errs.length === 0,
    `in four seconds both bots roam the level on FrikBot's own QuakeC physics, which the engine leaves to the mod (${moved.map((d) => d.toFixed(0)).join(' and ')} units)${errs.length ? ` (${errs[0]})` : ''}`);
  await L.db.close();
}

console.log(failed ? `${failed} failure(s)` : 'all mod checks passed');
process.exit(failed ? 1 : 0);
