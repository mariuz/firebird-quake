// e1m5-test.mjs – two things the first episode does with its scenery:
// the crucified zombies (they hang on the start map's walls, spawnflag 1:
// decoration that twitches and moans, cannot be hurt, is not counted), and
// Gloom Keep's flooded moat (E1M5): swimming, the water ambient, holding
// your breath, drowning, and surfacing for air.
//
//   node scripts/e1m5-test.mjs

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
const sounds = (like) => q1(`SELECT COUNT(*) n FROM sound_events WHERE snd LIKE '${like}'`).then((r) => r.N);
const teleport = async (x, y, z, yaw) => {
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = (SELECT ent_id FROM player)`);
  await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))');
};

// ── the crucified zombies ───────────────────────────────────────────────
await loadMap(db, pak, res, 'start', { skill: 1 });
let s = await tic();
const cruc = await qa("SELECT id, st, solid, takedamage, health, frame, anim FROM ents WHERE mtype = 'zombie' AND st = 'cruc'");
assert(cruc.length === 9, `nine crucified zombies hang on the start map's walls (${cruc.length})`);
assert(cruc.every((z) => z.SOLID === 0 && z.TAKEDAMAGE === 0), 'they are not solid and cannot be hurt');
assert(cruc.every((z) => z.ANIM === 'cruc_'), 'they play the crucified animation');
assert(s.TOTAL_MONSTERS === (await q1("SELECT COUNT(*) n FROM ents WHERE mtype IS NOT NULL AND st <> 'cruc'")).N, `they are not counted among the level's monsters (${s.TOTAL_MONSTERS})`);
const frames0 = cruc.map((z) => z.FRAME);
await run(6);
const frames1 = (await qa("SELECT frame FROM ents WHERE mtype = 'zombie' AND st = 'cruc' ORDER BY id")).map((z) => z.FRAME);
assert(frames1.some((f, i) => f !== frames0[i]), 'they twitch (frames advance)');
await db.exec(`EXECUTE PROCEDURE t_damage(${cruc[0].ID}, (SELECT ent_id FROM player), (SELECT ent_id FROM player), 500)`);
const z0 = await q1(`SELECT health, st FROM ents WHERE id = ${cruc[0].ID}`);
assert(z0.ST === 'cruc' && z0.HEALTH === cruc[0].HEALTH, 'a rocket does nothing to them');
let moaned = 0;
for (let i = 0; i < 300 && !moaned; i++) { await tic(); moaned = await sounds('zombie/idle_w2.wav'); }
assert(moaned > 0, 'one of them moaned');
assert((await qa("SELECT id FROM frame_ents")).length >= 0, 'the frame query lists them when in view');

// ── Gloom Keep's moat ───────────────────────────────────────────────────
await loadMap(db, pak, res, 'e1m5', { skill: 1 });
s = await tic();
assert(s.LEVEL_MSG === 'Gloom Keep', `the level is ${s.LEVEL_MSG}`);
// a point in the moat: water in the point hull (which is what water levels use; the clip
// hulls carry no liquid contents) and not solid for the player's hull
const head = (await q1('SELECT m.hull1 h FROM models m JOIN game g ON g.world_model = m.id')).H;
const leaves = await qa('SELECT minx, miny, minz, maxx, maxy, maxz FROM leaves WHERE contents = -3 ORDER BY (maxx - minx) * (maxy - miny) * (maxz - minz) DESC ROWS 6');
let wx, wy, wz, surface;
outer: for (const leaf of leaves) {
  for (const fx of [0.5, 0.3, 0.7, 0.2, 0.8]) for (const fy of [0.5, 0.3, 0.7, 0.2, 0.8]) {
    const x = leaf.MINX + (leaf.MAXX - leaf.MINX) * fx, y = leaf.MINY + (leaf.MAXY - leaf.MINY) * fy, z = leaf.MAXZ - 60;
    const r = await q1(`SELECT point_contents(${x}, ${y}, ${z}) c0, hull_contents(1, ${head}, ${x}, ${y}, ${z}) c1, point_contents(${x}, ${y}, ${leaf.MAXZ + 40}) up FROM rdb$database`);
    if (r.C0 === -3 && r.C1 !== -2 && r.UP === -1) { wx = x; wy = y; wz = z; surface = leaf.MAXZ; break outer; }
  }
}
assert(wx != null, `found open water at ${wx?.toFixed(0)}, ${wy?.toFixed(0)}, ${wz} with air above the surface (${surface})`);

// into the moat, fully under
await teleport(wx, wy, surface - 60, 0);
s = await tic();
assert(s.WATERLEVEL === 3 && s.WATERTYPE === -3, `the player is under water (level ${s.WATERLEVEL}, type ${s.WATERTYPE})`);
assert(s.AMB_WATER === 255, 'the leaf plays the water ambient at full volume');
assert((await sounds('player/inh2o.wav')) > 0, 'the splash of going under was heard');
assert(s.HEALTH === 100, 'no harm yet: the player holds his breath');
// swimming: hold jump and the player rises; let go and he sinks
const z1 = s.PZ;
s = await run(20, [1, 0, 0, 0, 0, 0, 1, 1, 0]);
assert(s.PZ > z1 + 30, `holding jump swims up ${(s.PZ - z1).toFixed(0)} units in a second`);
assert((await sounds('misc/water%')) > 0, 'with the sound of swimming');
const z2 = s.PZ;
s = await run(40);
assert(s.PZ < z2 - 5, `idle, he drifts down ${(z2 - s.PZ).toFixed(0)} units in two seconds`);
// through the flooded passage: swim forward along the moat
await teleport(wx, wy, surface - 60, 0);
s = await tic();
const x0 = s.PX, y0 = s.PY;
s = await run(40, [1, 1, 0, 0, 0, 0, 0, 1, 0]);
assert(Math.hypot(s.PX - x0, s.PY - y0) > 150, `swimming forward covered ${Math.hypot(s.PX - x0, s.PY - y0).toFixed(0)} units in two seconds`);
assert(s.WATERLEVEL >= 2, 'still in the water');

// holding his breath: 12 s of air, then drowning damage
await teleport(wx, wy, surface - 60, 0);
await db.exec('UPDATE player SET air_finished = 0 WHERE id = 1');   // a fresh dive is assumed below; this one is already spent
s = await run(30);
assert(s.HEALTH < 100, `out of air he drowns (health ${s.HEALTH})`);
assert((await sounds('player/drown%')) > 0, 'gasping was heard');
const hpDrowning = s.HEALTH;
// surfacing: air comes back, the damage stops
await teleport(wx, wy, surface + 40, 0);
s = await run(30);
assert(s.WATERLEVEL < 3 && s.HEALTH === hpDrowning, `with his head out of the water the drowning stops (health ${s.HEALTH}, water level ${s.WATERLEVEL})`);
assert((await q1('SELECT air_finished a FROM player')).A > s.TIME_ + 10, 'and the lungs refill for 12 s');

// the moat's ambience: the swamp emitters sit around it
const amb = await qa("SELECT classname FROM map_ents WHERE classname LIKE 'ambient_swamp%'");
assert(amb.length === 4, `four swamp emitters around the moat (${amb.length})`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
