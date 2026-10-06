// registered-test.mjs – the pak1 monsters' AI, run without pak1: each is
// spawned in E1M1 through SPAWN_MONSTER (their models are absent, so they
// are invisible, but the state machine, movement and attacks are the same),
// made to see the player, and watched for its signature behaviour.
//
//   node scripts/registered-test.mjs

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

// a quiet open spot in E1M1 (the wide hall beyond the first grunt), facing +x
const spot = async () => {
  await loadMap(db, pak, res, 'e1m1', { skill: 1 });
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL`);   // the locals stay out of it
  await db.exec(`UPDATE ents SET x = 160, y = 576, z = 48, yaw = 180, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = ${pe}`);  // god mode
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  await tic();
  return pe;
};
// spawn at the first distance in front of the player whose spot is open
const spawn = async (name, dist = 160) => {
  const head = (await q1('SELECT m.hull1 h FROM models m JOIN game g ON g.world_model = m.id')).H;
  for (const d of [dist, dist - 50, dist - 100, 160, 120]) {
    const ok = (await q1(`SELECT hull_contents(1, ${head}, e.x + COS(e.yaw * 0.0174532925) * ${d}, e.y + SIN(e.yaw * 0.0174532925) * ${d}, e.z + 8) c FROM ents e WHERE e.id = (SELECT ent_id FROM player)`)).C === -1;
    if (ok) return (await q1(`SELECT id FROM spawn_monster('${name}', ${d})`)).ID;
  }
  return (await q1(`SELECT id FROM spawn_monster('${name}', 160)`)).ID;
};
const mon = (id) => q1(`SELECT id, st, anim, anim_frame, health, enemy_id, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y, CAST(z AS INTEGER) z, flags, movetype FROM ents WHERE id = ${id}`);
const sounds = (like) => q1(`SELECT COUNT(*) n FROM sound_events WHERE snd LIKE '${like}'`).then((r) => r.N);
const count = (cls) => q1(`SELECT COUNT(*) n FROM ents WHERE classname = '${cls}'`).then((r) => r.N);
const wake = async (id) => { await db.exec(`EXECUTE PROCEDURE found_target(${id})`); return mon(id); };
const untilState = async (id, states, max = 60) => { let m; for (let i = 0; i < max; i++) { await tic(); m = await mon(id); if (!m || states.includes(m.ST)) break; } return m; };

const types = (await qa('SELECT name FROM monster_types ORDER BY name')).map((r) => r.NAME);
// hold the ranged ones at range: at point-blank a laser spawns inside its target and the knight
// prefers the sword, which is Quake's behaviour but not what this test watches
await db.exec("UPDATE monster_types SET run_speed = 0 WHERE name IN ('enforcer', 'hell_knight', 'shalrath')");
assert(['enforcer', 'hell_knight', 'shalrath', 'tarbaby', 'fish', 'oldone'].every((n) => types.includes(n)), `the registered monsters are defined (${types.length} types)`);

// ── enforcer: sees the player, runs, fires lasers ───────────────────────
let pe = await spot();
let id = await spawn('enforcer');
let m = await untilState(id, ['run']);
assert(m?.ST === 'run' && m.ENEMY_ID === pe, 'the enforcer spots the player and gives chase');
assert((await sounds('enforcer/sight%')) > 0, 'his sight sound was queued');
let lasers = 0;
for (let i = 0; i < 100 && !lasers; i++) { await tic(); lasers = await count('laser'); }
assert(lasers > 0, 'the enforcer fired a laser');
assert((await sounds('enforcer/enfire.wav')) > 0, 'the laser was heard');
let s = await run(40);
assert((await sounds('enforcer/enfstop.wav')) > 0, 'the laser hit something');
await db.exec(`UPDATE ents SET health = 1 WHERE id = ${id}`);
await db.exec(`EXECUTE PROCEDURE t_damage(${id}, ${pe}, ${pe}, 10)`);
await run(30);
assert((await count('backpack')) > 0 && (await q1("SELECT ammo_cells c FROM ents WHERE classname = 'backpack'")).C === 5, 'a dead enforcer drops a pack of cells');

// ── hell knight: a volley of flame spikes, and a sword up close ─────────
pe = await spot();
id = await spawn('hell_knight', 200);
m = await wake(id);
assert(m?.ST === 'run', 'the death knight charges');
let spikes = 0;
for (let i = 0; i < 160 && !spikes; i++) { await tic(); spikes = await count('kspike'); }
assert(spikes > 0, `the death knight threw flame spikes (${spikes} in the air)`);
await db.exec(`UPDATE ents SET x = 160 - 70, y = 576, z = 48 WHERE id = ${id}`);
await db.exec(`EXECUTE PROCEDURE link_ent(${id})`);
let sliced = 0;
for (let i = 0; i < 120 && !sliced; i++) { await tic(); sliced = await sounds('hknight/slash1.wav'); }
assert(sliced > 0, 'at arm\'s length he draws the sword');

// ── vore: a homing pod that turns toward the player ────────────────────
pe = await spot();
id = await spawn('shalrath', 160);
m = await wake(id);
let pod = null;
for (let i = 0; i < 160 && !pod; i++) { await tic(); pod = await q1("SELECT id, vx, vy, think FROM ents WHERE classname = 'voreball'"); }
assert(!!pod && pod.THINK === 'vore_track', 'the vore launched a homing pod');
// sidestep: the pod must turn after the player
await db.exec(`UPDATE ents SET y = y + 200 WHERE id = ${pe}`);
await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
await run(6);
const pod2 = await q1(`SELECT vx, vy FROM ents WHERE id = ${pod.ID}`);
assert(pod2 && pod2.VY > pod.VY + 50, `the pod turned toward the player (vy ${pod.VY.toFixed(0)} → ${pod2?.VY.toFixed(0)})`);
let gone = false;
for (let i = 0; i < 120 && !gone; i++) { await tic(); gone = !(await q1(`SELECT id FROM ents WHERE id = ${pod.ID}`)); }
assert(gone, 'the pod caught up and exploded');

// ── spawn: leaps, and bursts when it dies ───────────────────────────────
pe = await spot();
id = await spawn('tarbaby', 200);
m = await wake(id);
let leapt = false;
for (let i = 0; i < 120 && !leapt; i++) { await tic(); m = await mon(id); if (!m) break; leapt = m.MOVETYPE === 6 || (await sounds('blob/land1.wav')) > 0; }
assert(leapt || !m, 'the spawn jumps at the player');
if (m) {
  await db.exec(`UPDATE ents SET health = 1 WHERE id = ${id}`);
  await db.exec(`EXECUTE PROCEDURE t_damage(${id}, ${pe}, ${pe}, 10)`);
}
assert(!(await mon(id)), 'a dead spawn is gone in a burst');
assert((await sounds('blob/death1.wav')) > 0 && (await q1('SELECT COUNT(*) n FROM fx_events WHERE kind = 8')).N > 0, 'the burst was heard and drawn');

// ── fish: a swimmer that stays in the water ─────────────────────────────
pe = await spot();
id = await spawn('fish', 100);
m = await mon(id);
assert(m && (m.FLAGS & 2) !== 0 && m.MOVETYPE === 5, 'the rotfish is a swimmer');
await db.exec(`UPDATE ents SET enemy_id = ${pe}, st = 'run', anim = NULL WHERE id = ${id}`);
const before = await mon(id);
await run(20);
m = await mon(id);
assert(m && m.X === before.X && m.Y === before.Y, 'out of water it cannot move (a swim step into air is refused)');
assert(m.ST !== 'die', 'and it does not fall out of the world');

// ── Shub-Niggurath: weapons do nothing, a telefrag ends the game ────────
pe = await spot();
id = await spawn('oldone', 300);
m = await mon(id);
assert(m && m.MOVETYPE === 0, 'Shub-Niggurath stands still');
await db.exec(`EXECUTE PROCEDURE t_damage(${id}, ${pe}, ${pe}, 5000)`);
m = await mon(id);
assert(m.HEALTH === 40000, 'rockets do not hurt her');
// a teleporter whose destination is inside her
const dest = await q1(`SELECT id FROM spawn_ent('info_teleport_destination', ${m.X}, ${m.Y}, ${m.Z + 20})`);
await db.exec(`UPDATE ents SET targetname = 'shub_dest', yaw = 0 WHERE id = ${dest.ID}`);
const tp = await q1(`SELECT id FROM spawn_ent('trigger_teleport', 0, 0, 0)`);
await db.exec(`UPDATE ents SET target = 'shub_dest', solid = 1 WHERE id = ${tp.ID}`);
await db.exec(`EXECUTE PROCEDURE teleport_touch(${tp.ID}, ${pe})`);
s = await tic();
assert(s.FINALE === 1, 'telefragging her ends the game (finale)');
assert(/Shub-Niggurath/.test(s.CPRINT ?? ''), 'the congratulations are shown');
assert((await sounds('boss2/death.wav')) > 0, 'her death was heard');

// ── registered flag ─────────────────────────────────────────────────────
assert((await q1('SELECT registered r FROM game')).R === (pak.has('maps/e2m1.bsp') ? 1 : 0), 'the game knows whether pak1 is present');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
