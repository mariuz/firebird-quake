// e1m8-test.mjs – Ziggurat Vertigo, the low-gravity secret level: worldspawn
// sets sv_gravity to 100 there (800 everywhere else), so the player floats
// over jumps, grenades sail, and falls are gentle. Also the way out to E1M5.
//
//   node scripts/e1m8-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const tic = (a = [1, 0, 0, 0, 0, 0, 0, 1, 0]) => q1('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a);
const run = async (n, a) => { let s; for (let i = 0; i < n; i++) s = await tic(a); return s; };

/** Jump from standing still and return the highest point reached and the hang time in tics. */
async function jump() {
  // settle on the floor first: at gravity 100 the drop from the spawn spot takes a while
  let s0 = await tic(), still = 0;
  for (let i = 0; i < 400 && still < 4; i++) { const s1 = await tic(); still = Math.abs(s1.PZ - s0.PZ) < 0.01 ? still + 1 : 0; s0 = s1; }
  let s = await tic([1, 0, 0, 0, 0, 0, 1, 1, 0]);  // jump pressed for one tic
  let peak = s.PZ, tics = 0;
  for (let i = 0; i < 400; i++) {
    s = await tic();
    tics++;
    if (s.PZ > peak) peak = s.PZ;
    if (Math.abs(s.PZ - s0.PZ) < 1 && i > 2 && s.PZ <= peak - 1) break;
  }
  return { height: peak - s0.PZ, tics };
}

// ── the normal world first, for comparison ──────────────────────────────
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
assert((await q1('SELECT gravity g FROM game')).G === 800, 'E1M1 has sv_gravity 800');
const normal = await jump();
assert(normal.height > 35 && normal.height < 60, `an E1M1 jump rises ${normal.height.toFixed(0)} units (Quake: ~45)`);

// ── Ziggurat Vertigo ───────────────────────────────────────────────────
await loadMap(db, pak, res, 'e1m8', { skill: 1, seed: 1 });
let s = await tic();
assert(s.MAP_NAME === 'e1m8' && s.LEVEL_MSG === 'Ziggurat Vertigo', `the level is ${s.LEVEL_MSG}`);
assert((await q1('SELECT gravity g FROM game')).G === 100, 'worldspawn sets sv_gravity 100 on E1M8');
assert(s.LEAF > 0 && (await q1('SELECT COUNT(*) n FROM frame_faces_fast')).N > 10, 'the start of the ziggurat renders');
const monsters = (await q1("SELECT COUNT(*) n FROM ents WHERE mtype IS NOT NULL")).N;
assert(monsters > 10, `${monsters} monsters wait on the level`);

const low = await jump();
assert(low.height > 6 * normal.height, `a low-gravity jump rises ${low.height.toFixed(0)} units, ${(low.height / normal.height).toFixed(1)}× the normal one`);
assert(low.tics > 4 * normal.tics, `and hangs ${(low.tics / 20).toFixed(1)} s against ${(normal.tics / 20).toFixed(1)} s`);

// a grenade: with gravity 100 it is still in the air long after a normal one would have landed
await tic([1, 0, 0, 0, 0, 0, 0, 1, 9]);          // all weapons
await tic([1, 0, 0, 0, 0, 0, 0, 1, 6]);          // the grenade launcher
await run(10);
s = await tic([1, 0, 0, 0, -20, 1, 0, 1, 0]);    // lob it upward
const g = await q1("SELECT id, z, vz FROM ents WHERE classname = 'grenade'");
assert(!!g, 'a grenade was lobbed');
let airborne = 0;
for (let i = 0; i < 48; i++) {                   // 2.4 s: the fuse is 2.5 s
  await tic();
  const gg = await q1(`SELECT z, flags FROM ents WHERE id = ${g.ID}`);
  if (!gg) break;
  if ((gg.FLAGS & 512) === 0) airborne++;
}
assert(airborne >= 40, `the grenade stayed airborne for ${(airborne / 20).toFixed(1)} s until its fuse`);

// every walking monster stands on the ground (hull-2 ogres and shamblers included: a trace
// bug once reported their hull as solid everywhere, so none of them ever touched the floor)
const walkers = await qa("SELECT id, z, BIN_AND(flags, 512) og FROM ents WHERE mtype IS NOT NULL AND BIN_AND(flags, 3) = 0 AND st = 'stand'");
assert(walkers.length > 10 && walkers.every((w) => w.OG === 512), `all ${walkers.length} walking monsters stand on the ground`);
// monsters fall gently too: lift one 24 units and watch it drift down for half a second
// one with headroom: an ogre's hull is 64 tall and the ziggurat's corridors are low
const grunt = await q1(`SELECT e.id, e.z FROM ents e JOIN monster_types t ON t.name = e.mtype JOIN models m ON m.id = (SELECT world_model FROM game)
  WHERE e.mtype IS NOT NULL AND BIN_AND(e.flags, 3) = 0 AND e.st = 'stand'
    AND hull_contents(1, IIF(t.hull = 2, m.hull2, m.hull1), e.x, e.y, e.z + 40) = -1 ROWS 1`);
await db.exec(`UPDATE ents SET z = z + 24, flags = BIN_AND(flags, BIN_NOT(512)), vz = 0 WHERE id = ${grunt.ID}`);
await run(10);
const g2 = await q1(`SELECT z FROM ents WHERE id = ${grunt.ID}`);
const dropped = grunt.Z + 24 - g2.Z;
assert(dropped > 6 && dropped < 24, `in half a second the lifted monster fell ${dropped.toFixed(0)} units (gravity 100: ~12; 800 would have landed it)`);

// ── the way out ─────────────────────────────────────────────────────────
const exits = await qa("SELECT map FROM ents WHERE classname = 'trigger_changelevel'");
assert(exits.length === 1 && exits[0].MAP === 'e1m5', 'the ziggurat leads back to E1M5');
const tr = await q1("SELECT id, x + (minx + maxx) / 2 cx, y + (miny + maxy) / 2 cy, z + (minz + maxz) / 2 cz FROM ents WHERE classname = 'trigger_changelevel'");
await db.exec(`UPDATE ents SET x = ${tr.CX}, y = ${tr.CY}, z = ${tr.CZ}, vx = 0, vy = 0, vz = 0 WHERE id = (SELECT ent_id FROM player)`);
await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))');
s = await tic();
assert(s.EXIT_KIND === 1 && s.NEXT_MAP === 'e1m5', 'touching the exit asks for E1M5');
// execute_changelevel: the view moves to one of the level's intermission cameras, looking along its mangle
const cams = await qa("SELECT ox, oy, oz, mpitch, myaw FROM map_ents WHERE classname = 'info_intermission'");
const cam = cams.find((c) => Math.abs(c.OX - s.PX) < 0.5 && Math.abs(c.OY - s.PY) < 0.5 && Math.abs(c.OZ - s.PZ) < 0.5);
assert(cams.length > 0 && cam && Math.abs(s.YAW - cam.MYAW) < 0.5 && Math.abs(s.PITCH - cam.MPITCH) < 0.5 && Math.abs(s.VIEW_Z - s.PZ) < 0.01,
  `the view goes to an info_intermission (${cam ? `${cam.OX} ${cam.OY} ${cam.OZ}, looking ${cam.MYAW}° at pitch ${cam.MPITCH}` : 'none'}), the eye at the spot`);
assert(s.INTERMISSION === 1 && s.CDTRACK === 3, `with the stats screen and the intermission music (track ${s.CDTRACK})`);
const s2 = await tic();
assert(Math.abs(s2.PX - s.PX) < 0.01 && Math.abs(s2.PZ - s.PZ) < 0.01, 'and the camera stays put');

// and back on E1M5 gravity is normal again
await loadMap(db, pak, res, 'e1m5', { skill: 1, newGame: false, seed: 1 });
assert((await q1('SELECT gravity g FROM game')).G === 800, 'E1M5 restores sv_gravity 800');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
