// e1m3-test.mjs – the Necropolis' zombie pits: the gold key and the rocket
// launcher lie on a trigger; taking them wakes the pit zombies (targetname
// t83) and slides the pit doors open. Zombies take ten shotgun pellets and
// shrug them off, go down from a hard hit and get up again, throw their own
// flesh, and only a gibbing blow finishes them.
//
//   node scripts/e1m3-test.mjs

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
await loadMap(db, pak, res, 'e1m3', { skill: 1, seed: 1 });
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const tic = (a = [1, 0, 0, 0, 0, 0, 0, 1, 0]) => q1('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a);
const run = async (n, a) => { let s; for (let i = 0; i < n; i++) s = await tic(a); return s; };
const sounds = (like) => q1(`SELECT COUNT(*) n FROM sound_events WHERE snd LIKE '${like}'`).then((r) => r.N);
const pe = (await q1('SELECT ent_id e FROM player')).E;
const teleport = async (x, y, z, yaw) => {
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
};
const zombie = (id) => q1(`SELECT id, st, anim, health, enemy_id, solid, model_id, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y, CAST(z AS INTEGER) z FROM ents WHERE id = ${id}`);

let s = await tic();
assert(s.LEVEL_MSG === 'the Necropolis', `the level is ${s.LEVEL_MSG}`);
const all = (await q1("SELECT COUNT(*) n FROM ents WHERE mtype = 'zombie'")).N;
assert(all >= 30, `forty zombies are placed, ${all} of them on this skill`);
const pit = await qa("SELECT id, st, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y, CAST(z AS INTEGER) z FROM ents WHERE mtype = 'zombie' AND targetname = 't83' ORDER BY id");
assert(pit.length === 5 && pit.every((z) => z.ST === 'stand'), 'five of them wait in the pits, standing (targetname t83)');
const key = await q1("SELECT id, x, y, z FROM ents WHERE classname = 'item_key2'");
const rl = await q1("SELECT spawnflags FROM map_ents WHERE classname = 'weapon_rocketlauncher'");
assert(rl && rl.SPAWNFLAGS === 1792 && !(await q1("SELECT id FROM ents WHERE classname = 'weapon_rocketlauncher'")), 'the rocket launcher beside it is deathmatch-only (absent on every skill)');
const trig = await q1("SELECT id, x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0, z + maxz z1 FROM ents WHERE classname = 'trigger_once' AND target = 't83'");
assert(key && trig && key.X > trig.X0 && key.X < trig.X1 && key.Y > trig.Y0 && key.Y < trig.Y1, 'the gold key lies on the trigger that wakes them');
const doors = await qa("SELECT id, spawnflags, mv_state, CAST(z AS INTEGER) z, CAST(y AS INTEGER) y FROM ents WHERE classname = 'func_door' AND targetname = 't83' ORDER BY id");
assert(doors.length === 5, `five pit doors answer to the same trigger (${doors.length})`);

// ── take the key: the trap springs ──────────────────────────────────────
await teleport(key.X, key.Y, key.Z + 30, 0);
s = await run(6);
assert((s.ITEMS & 262144) !== 0, `the gold key is taken (${s.MSG})`);
assert(!(await q1(`SELECT id FROM ents WHERE id = ${trig.ID}`)), 'the trigger is spent');
const woke = await qa("SELECT id, st, enemy_id FROM ents WHERE mtype = 'zombie' AND targetname = 't83'");
assert(woke.every((z) => z.ST === 'run' && z.ENEMY_ID === pe), 'the pit zombies wake and come for the player');
assert((await q1("SELECT COUNT(*) n FROM ents WHERE mtype = 'zombie' AND targetname IS NULL AND st = 'run'")).N === 0, 'the others go on sleeping');
s = await run(10);
const moved = await qa("SELECT id, mv_state, CAST(z AS INTEGER) z, CAST(y AS INTEGER) y FROM ents WHERE classname = 'func_door' AND targetname = 't83' ORDER BY id");
assert(moved.some((d, i) => d.Z !== doors[i].Z || d.Y !== doors[i].Y || d.MV_STATE !== doors[i].MV_STATE), 'the pit doors start to move');

// ── zombies die hard ───────────────────────────────────────────────────
const z1 = pit[2];   // the one under the trapdoor, in the pit beneath the key
let z = await zombie(z1.ID);
assert(z.HEALTH === 60, 'a zombie has 60 health');
for (let i = 0; i < 10; i++) await db.exec(`EXECUTE PROCEDURE t_damage(${z1.ID}, ${pe}, ${pe}, 4)`);
z = await zombie(z1.ID);
assert(z.HEALTH === 60 && z.ST !== 'die' && z.ST !== 'dead', 'ten shotgun pellets leave it at 60: small wounds close');
assert((await sounds('zombie/z_pain.wav')) === 0, 'and do not even make it flinch');
await db.exec(`EXECUTE PROCEDURE t_damage(${z1.ID}, ${pe}, ${pe}, 30)`);
z = await zombie(z1.ID);
assert(z.ST === 'pain' && z.ANIM === 'paine' && z.HEALTH === 60, `a hard hit knocks it down (${z.ANIM}) but does not kill it`);
assert((await sounds('zombie/z_pain.wav')) > 0, 'with a groan');
s = await run(70);
z = await zombie(z1.ID);
assert((z.ST === 'run' || z.ST === 'missile') && z.HEALTH === 60, `three seconds later it is up and after the player again (${z.ST})`);
// it throws its own flesh
await teleport(z.X + 160, z.Y, z.Z + 24, 180);
let gib = null;
for (let i = 0; i < 160 && !gib; i++) { await tic(); gib = await q1("SELECT id FROM ents WHERE classname = 'zombie_gib'"); }
assert(!!gib, 'it throws a lump of flesh at the player');
assert((await sounds('zombie/z_shot1.wav')) > 0, 'with the sound of the throw');
// only gibbing finishes it: a rocket's worth of damage
const killed0 = s.KILLED;
await db.exec(`EXECUTE PROCEDURE t_damage(${z1.ID}, ${pe}, ${pe}, 100)`);
z = await zombie(z1.ID);
assert(z.ST === 'dead' && z.SOLID === 0, 'a rocket blows it apart');
assert((await sounds('zombie/z_gib.wav')) > 0, 'with the wet sound of gibbing');
assert((await q1("SELECT COUNT(*) n FROM ents WHERE classname = 'gib'")).N >= 3, 'flesh flies');
assert(z.MODEL_ID === (await q1("SELECT id FROM models WHERE name = 'progs/h_zombie.mdl'")).ID, 'and its head rolls');
s = await tic();
assert(s.KILLED === killed0 + 1, 'the kill is counted');
await db.exec(`EXECUTE PROCEDURE t_damage(${z1.ID}, ${pe}, ${pe}, 100)`);
assert((await zombie(z1.ID))?.ST === 'dead', 'and stays dead');

// CheckWaterJump in the PSQL game (E1M3's water has such a wall): waist deep against a wall that reaches the waist (8 up) but not the head (maxs_z up), facing it,
// with no input at all: the hop out (225 up), and SV_WaterJump's push into the wall (its normal × -50) carries the
// player over it and out of the water
{
  const q = q1;
  const line = (x, y, z, dx, dy) => q(`SELECT fraction f, nx, ny FROM trace_move(${pe}, 0, 0, 0, 0, 0, 0, ${x}, ${y}, ${z}, ${x + dx}, ${y + dy}, ${z}, 1)`);
  const box = (x, y, z, dx, dy, dz) => q(`SELECT fraction f FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${x}, ${y}, ${z}, ${x + dx}, ${y + dy}, ${z + dz}, 0)`);
  let spot = null;
  search: for (const l of (await db.query('SELECT minx, miny, minz, maxx, maxy, maxz FROM leaves WHERE contents = -3 ORDER BY id')).rows) {
    for (let x = l.MINX + 16; x < l.MAXX; x += 16) for (let y = l.MINY + 16; y < l.MAXY; y += 16) for (let z = l.MINZ + 25; z < l.MAXZ; z += 4) {
      // waterlevel 2: the box's middle (4 up) in the water, the eye (22 up) out of it
      const c = await q(`SELECT point_contents(${x}, ${y}, ${z - 23}) f, point_contents(${x}, ${y}, ${z + 4}) c, point_contents(${x}, ${y}, ${z + 22}) e, test_position(${pe}, ${x}, ${y}, ${z}) t FROM rdb$database`);
      if (c.F !== -3 || c.C !== -3 || c.E !== -1 || c.T !== 0) continue;
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        // a plain wall facing back (its normal against the way in) with room on top for the player
        const w = await line(x, y, z + 8, dx * 24, dy * 24);
        if (w.F === 1 || Math.abs(w.NX + dx) > 1e-6 || Math.abs(w.NY + dy) > 1e-6 || (await line(x, y, z + 32, dx * 24, dy * 24)).F < 1) continue;
        if ((await box(x, y, z, 0, 0, 40)).F === 1 && (await box(x, y, z + 40, dx * 40, dy * 40, 0)).F === 1) { spot = { x, y, z, dx, dy }; break search; }
      }
    }
  }
  assert(spot, 'a waist-high wall by the water to climb out at');
  if (spot) {
    await db.exec(`UPDATE ents SET x = ${spot.x}, y = ${spot.y}, z = ${spot.z}, vx = 0, vy = 0, vz = 0, flags = BIN_AND(flags, BIN_NOT(2048)), yaw = ${Math.atan2(spot.dy, spot.dx) * 180 / Math.PI} WHERE id = ${pe}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
    await q(`SELECT * FROM check_water(${pe})`);              // the level a frame there would have stored (PlayerPreThink reads it)
    await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
    const j1 = await q(`SELECT vz, flags FROM ents WHERE id = ${pe}`);
    for (let i = 0; i < 20; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
    const j2 = await q(`SELECT x, y, z, waterlevel wl FROM ents WHERE id = ${pe}`);
    const on = (j2.X - spot.x) * spot.dx + (j2.Y - spot.y) * spot.dy;
    await db.exec(`UPDATE ents SET flags = BIN_AND(flags, BIN_NOT(2048)), teleport_time = 0 WHERE id = ${pe}`);
    assert((j1.FLAGS & 2048) !== 0 && Math.abs(j1.VZ - 225) < 0.01 && j2.WL === 0 && on > 16 && j2.Z > spot.z + 8,
      `CheckWaterJump with no input: the hop out (vz ${j1.VZ.toFixed(1)}), and SV_WaterJump's push takes the player over the wall and out of the water (${on.toFixed(0)} on, ${(j2.Z - spot.z).toFixed(0)} up)`);
  }
}

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
