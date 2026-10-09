// qcvm-ai-test.mjs – progs.dat's monsters on the engine: checkclient lets a
// grunt see the player (FindTarget, FoundTarget, its sight sound), it shoots
// him (FireBullets, the gunshot and blood effects from the temp entities and
// particles), the player shoots it dead with the autoaim, and a dog runs at
// him through movetogoal.
//
//   node scripts/qcvm-ai-test.mjs

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

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });   // seeded: movetogoal's random detours are the same every run
const progs = await loadProgs(db, pak);
if (process.env.QCJIT === 'all') {                 // every function compiled to its own procedure
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`compiled ${jit.compiled.size} functions in ${(jit.ms / 1000).toFixed(1)} s`);
}
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const fld = (ent, name, k = 0) => q1(`SELECT qc_f(${ent}, qc_fdef('${name}') + ${k}) v FROM rdb$database`).then((r) => r.V);
const fname = async (v) => (await q1(`SELECT name FROM qc_functions WHERE id = ${v ?? -1}`))?.NAME;
const ent = (id) => q1(`SELECT * FROM ents WHERE id = ${id}`);
const byClass = (cls) => qa(`SELECT f.ent FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0 WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = '${cls}' ORDER BY f.ent`).then((r) => r.map((x) => x.ENT));
const sounds = (like) => q1(`SELECT COUNT(*) n FROM qc_log WHERE kind = 'sound' AND msg LIKE '%${like}%'`).then((r) => r.N);
const box = [-16, -16, -24, 16, 16, 32];
const traceBox = (x1, y1, z1, x2, y2, z2) => q1(`SELECT fraction f, ex, ey, ez FROM trace_move(1, ${box.join(', ')}, ${x1}, ${y1}, ${z1}, ${x2}, ${y2}, ${z2}, 0)`);
const clear = (x, y, z) => q1(`SELECT test_position(1, ${x}, ${y}, ${z}) t FROM rdb$database`).then((r) => r.T === 0);
const deg = (r) => (r * 180) / Math.PI;
const look = async (yaw, pitch = 0) => {
  await db.exec(`EXECUTE PROCEDURE qc_sf(1, qc_fdef('v_angle') + 1, ${yaw})`);
  await db.exec(`UPDATE player SET pitch = ${pitch} WHERE id = 1`);
};
const lookAt = async (id) => {
  const p = await ent(1), m = await ent(id);
  const dx = m.X - p.X, dy = m.Y - p.Y, dz = (m.Z + (m.MINZ + m.MAXZ) / 2) - (p.Z + 22);
  await look(deg(Math.atan2(dy, dx)), -deg(Math.atan2(dz, Math.hypot(dx, dy))));
};
const ms = [];
const fxSeen = new Set();
const flashed = new Set();     // monsters whose EF_MUZZLEFLASH a row's frame would light
const tic = async (o = {}) => {
  const t0 = performance.now();
  const r = await q1(`SELECT * FROM qc_tic(2, 0, 0, 0, 0, ${o.fire ?? 0}, 0, 1, 0)`);
  ms.push((performance.now() - t0) / 2);
  for (const f of await qa('SELECT DISTINCT kind FROM fx_events')) fxSeen.add(f.KIND);
  for (const f of await qa('SELECT id FROM ents WHERE id > 1 AND BIN_AND(effects, 2) <> 0')) flashed.add(f.ID);
  return r;
};
// a standing spot in front of a monster (within its view), with a clear line of sight between the eyes
const frontOf = async (id, radii) => {
  const m = await ent(id);
  for (const r of radii) {
    for (const k of [0, 1, -1, 2, -2, 3, -3]) {
      const a = (m.YAW + k * 20) * Math.PI / 180;
      const x = m.X + Math.cos(a) * r, y = m.Y + Math.sin(a) * r;
      const down = await traceBox(x, y, m.Z + 40, x, y, m.Z - 160);
      if (down.F >= 1 || !(await clear(x, y, down.EZ))) continue;
      const sight = await q1(`SELECT fraction f FROM trace_move(1, 0, 0, 0, 0, 0, 0, ${x}, ${y}, ${down.EZ + 22}, ${m.X}, ${m.Y}, ${m.Z + 25}, 1)`);
      if (sight.F < 1) continue;
      return { x, y, z: down.EZ, r };
    }
  }
  return null;
};
const place = async (p) => { await db.exec(`UPDATE ents SET x = ${p.x}, y = ${p.y}, z = ${p.z}, vx = 0, vy = 0, vz = 0 WHERE id = 1`); await db.exec('EXECUTE PROCEDURE link_ent(1)'); };

let r = await tic();
for (let i = 0; i < 3; i++) r = await tic();
const setf = (e, name, v) => db.exec(`EXECUTE PROCEDURE qc_sf(${e}, qc_fdef('${name}'), ${v})`);
const now = async () => (await q1('SELECT time_ t FROM game')).T;
const freeze = async (e) => setf(e, 'nextthink', 0);                        // its think stays, it just isn't called
const thaw = async (e) => setf(e, 'nextthink', (await now()) + 0.1);

// ── the cast: a grunt and a dog, each with a spot in front of it; every other monster removed ──
let grunt = null, spot = null, dog = null, dspot = null;
for (const g of await byClass('monster_army')) { spot = await frontOf(g, [260, 320, 380, 200]); if (spot) { grunt = g; break; } }
for (const d of await byClass('monster_dog')) { dspot = await frontOf(d, [420, 360, 300]); if (dspot) { dog = d; break; } }
assert(!!spot && !!dspot, `a spot ${spot?.r} units in front of a grunt (edict ${grunt}) and ${dspot?.r} in front of a dog (edict ${dog}), with clear lines between the eyes`);
const others = (await qa(`SELECT id FROM ents WHERE BIN_AND(flags, 32) <> 0 AND id NOT IN (${grunt}, ${dog})`)).map((x) => x.ID);
for (const e of others) await db.exec(`EXECUTE PROCEDURE qc_free(${e})`);
const g0 = await ent(grunt);
assert((g0.ENEMY_ID ?? 0) === 0 && /^army_stand/.test(await fname(await fld(grunt, 'think'))), `${others.length} other monsters removed; the grunt stands, with no enemy`);

// ── a dog runs at the player: movetogoal ─────────────────────────────────
await freeze(grunt);
await db.exec('UPDATE ents SET flags = BIN_OR(flags, 64) WHERE id = 1');    // FL_GODMODE while the dog bites
await place(dspot);
await lookAt(dog);
const dist = async () => { const p = await ent(1), d = await ent(dog); return Math.hypot(p.X - d.X, p.Y - d.Y); };
const d0 = await dist();
let closed = 0;
for (let i = 0; i < 40 && !closed; i++) { await tic(); if ((await dist()) < d0 - 150) closed = i + 1; }
const d1 = await dist();
assert(closed > 0 && (await ent(dog)).ENEMY_ID === 1 && (await sounds('dog/dsight.wav')) > 0, `the dog sees the player, barks and runs at him: ${d0.toFixed(0)} → ${d1.toFixed(0)} units in ${(closed * 0.1).toFixed(1)} s (ai_run → movetogoal → SV_StepDirection)`);
await freeze(dog);
await setf(dog, 'takedamage', 0);
await db.exec(`UPDATE ents SET solid = 0 WHERE id = ${dog}`);
await db.exec('UPDATE ents SET flags = BIN_AND(flags, BIN_NOT(64)) WHERE id = 1');
for (let i = 0; i < 6; i++) await tic();
await setf(1, 'health', 100);

// ── a grunt sees the player ───────────────────────────────────────────────
await thaw(grunt);
await place(spot);
await lookAt(grunt);
let woke = 0;
for (let i = 0; i < 20 && !woke; i++) { r = await tic(); if ((await ent(grunt)).ENEMY_ID === 1) woke = i + 1; }
assert(woke > 0, `checkclient puts the player in its view: FindTarget, FoundTarget, the enemy is the player after ${(woke * 0.1).toFixed(1)} s`);
assert((await sounds('soldier/sight1.wav')) > 0 && (await fld(grunt, 'goalentity')) === 1, 'with the sight sound, hunting the player (goalentity)');

// ── it shoots ───────────────────────────────────────────────────────────
fxSeen.clear();
let shot = 0, dmgSeen = false;
for (let i = 0; i < 80 && !(shot && r.HEALTH < 100 && dmgSeen); i++) {
  r = await tic(); await lookAt(grunt);
  if (r.DMG_TAKE > 0) dmgSeen = true;
  if (!shot && (await sounds('soldier/sattck1.wav')) > 0) shot = i + 1;
}
const g1 = await ent(grunt);
assert(shot > 0 && r.HEALTH < 100, `army_fire: the grunt shoots the player after ${(shot * 0.1).toFixed(1)} s (health ${r.HEALTH})`);
assert(dmgSeen, 'the damage reaches the row (DMG_TAKE) for the flash');
assert(flashed.has(grunt), 'its muzzle flash (EF_MUZZLEFLASH) is on after the tic it fired in, for the page to light');

assert(fxSeen.has(1) || fxSeen.has(3), `FireBullets' misses (TE_GUNSHOT) and hits (SpawnBlood's particles) become fx events (kinds ${[...fxSeen].sort().join(', ')})`);

// ── the player shoots back, with the autoaim ─────────────────────────────
await db.exec('UPDATE ents SET flags = BIN_OR(flags, 64) WHERE id = 1');    // FL_GODMODE from here
const killed0 = r.KILLED;
let dead = 0;
for (let i = 0; i < 40 && !dead; i++) { await lookAt(grunt); r = await tic({ fire: 1 }); if (r.KILLED > killed0) dead = i + 1; }
for (let i = 0; i < 10 && (await ent(grunt))?.SOLID; i++) await tic();
const gd = await ent(grunt);
assert(dead > 0 && (await fld(grunt, 'health')) <= 0 && (await fld(grunt, 'takedamage')) === 0 && (!gd || gd.SOLID === 0), `shotgun blasts kill it in ${(dead * 0.1).toFixed(1)} s: KILLED ${r.KILLED}, it falls, no longer solid`);
assert((await sounds('soldier/death1.wav')) + (await sounds('player/udeath.wav')) > 0, 'with its death cry');
assert((await q1("SELECT COUNT(*) n FROM qc_log WHERE kind = 'error'")).N === 0, 'no QuakeC errors');

const sorted = [...ms].sort((a, b) => a - b);
console.log(`qc_tic with the monsters awake: median ${sorted[sorted.length >> 1].toFixed(0)} ms per tic, max ${sorted[sorted.length - 1].toFixed(0)} ms`);
await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
