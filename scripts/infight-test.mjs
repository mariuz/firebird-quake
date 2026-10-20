// infight-test.mjs – monsters fighting monsters (combat.qc's T_Damage, ai.qc's ai_run): a monster hurt
// by another turns on it unless it is of its own kind (soldiers excepted), remembering the player it
// was hunting; the two fight; when its enemy dies it goes back to the player. Staged in E1M1's wide
// hall, the locals out of the way.
//
//   node scripts/infight-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { frameDlights } from '../src/dlights.js';

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
const tic = (a = [1, 0, 0, 0, 0, 0, 0, 1, 0]) => q1('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a);

// a long open floor (500 units east of a dog's post, the far end of E1M1), the locals dead and not solid,
// the player in god mode, facing along it
const spot = async () => {
  await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL`);
  await db.exec(`UPDATE ents SET x = -72, y = 2896, z = -56, yaw = 0, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  await tic();
  return pe;
};
const spawn = async (name, dist) => (await q1(`SELECT id FROM spawn_monster('${name}', ${dist})`)).ID;
const mon = (id) => q1(`SELECT id, classname, st, health, enemy_id, oldenemy_id, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y FROM ents WHERE id = ${id}`);
const sounds = (like) => q1(`SELECT COUNT(*) n FROM sound_events WHERE snd LIKE '${like}'`).then((r) => r.N);
const hunt = (id, pe) => db.exec(`EXECUTE PROCEDURE found_target(${id}, ${pe})`);
const hurt = (targ, attacker, dmg) => db.exec(`EXECUTE PROCEDURE t_damage(${targ}, ${attacker}, ${attacker}, ${dmg})`);

// ── an ogre's hit turns a knight on it ───────────────────────────────────
let pe = await spot();
const knight = await spawn('knight', 120);
const ogre = await spawn('ogre', 320);
await hunt(knight, pe); await hunt(ogre, pe);
await tic();
assert((await mon(knight)).ENEMY_ID === pe && (await mon(ogre)).ENEMY_ID === pe, `a knight (edict ${knight}) and an ogre (edict ${ogre}) hunt the player`);
const sightBefore = await sounds('knight/ksight.wav');
await hurt(knight, ogre, 5);
let k = await mon(knight);
assert(k.ENEMY_ID === ogre && k.OLDENEMY_ID === pe && k.ST !== 'stand', `hurt by the ogre, the knight turns on it (FoundTarget) and remembers the player (oldenemy)`);
// sight and CheckAttack go eye to eye (origin + view_ofs): the player's 22, a monster's 25, a fish's 10, so a
// monster aims at another monster's eye and not at the height of the player's
{
  const eyes = await q1(`SELECT eye_height(${pe}) p, eye_height(${knight}) k, (SELECT eye_height(id) FROM ents WHERE classname = 'trigger_changelevel' ROWS 1) s FROM rdb$database`);
  assert(eyes.P === 22 && eyes.K === 25 && eyes.S === 0, `eye heights: the player ${eyes.P}, a knight ${eyes.K}, a trigger its origin (${eyes.S})`);
}
assert((await sounds('knight/ksight.wav')) > sightBefore, 'with its sight sound');

// the ogre's own kind is spared: another knight's blow does not change a knight's mind
const knight2 = await spawn('knight', 200);
await hunt(knight2, pe);
await hurt(knight2, knight, 1);
assert((await mon(knight2)).ENEMY_ID === pe, 'a knight hurt by a knight keeps hunting the player (same class)');
// …but soldiers turn on soldiers
const army1 = await spawn('army', 160), army2 = await spawn('army', 240);
await hunt(army1, pe); await hunt(army2, pe);
await hurt(army2, army1, 1);
assert((await mon(army2)).ENEMY_ID === army1, 'a grunt hurt by a grunt turns on him (the soldiers\' exception)');
// the attacker it already fights changes nothing, nor does the world
await hurt(knight, ogre, 1);
await db.exec(`EXECUTE PROCEDURE t_damage(${knight}, 0, 0, 1)`);
k = await mon(knight);
assert(k.ENEMY_ID === ogre && k.OLDENEMY_ID === pe, 'hurt again by the ogre, or by the world, the knight keeps its enemy and its memory');

// ── the fight: the knight goes for the ogre; the ogre turns on it; one of them dies ──
await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE id IN (${knight2}, ${army1}, ${army2})`);
await db.exec(`UPDATE ents SET health = 40 WHERE id = ${ogre}`);         // a short fight
let o, turned = 0, ogreHurt = 0;
for (let i = 0; i < 400; i++) {
  await tic();
  o = await mon(ogre); k = await mon(knight);
  if (!ogreHurt && o.HEALTH < 40) ogreHurt = i + 1;
  if (!turned && o.ENEMY_ID === knight) turned = i + 1;
  if (o.HEALTH <= 0 || k.HEALTH <= 0) break;
}
assert(ogreHurt > 0, `the knight reaches the ogre and cuts it (after ${(ogreHurt * 0.05).toFixed(1)} s, ${40 - o.HEALTH} damage by now)`);
assert(turned > 0 && (o.OLDENEMY_ID === pe || o.HEALTH <= 0), 'the ogre turns on the knight in turn, remembering the player');
const winner = o.HEALTH <= 0 ? knight : ogre, loser = winner === knight ? ogre : knight;
assert((await mon(loser)).HEALTH <= 0, `the fight ends: the ${winner === knight ? 'knight' : 'ogre'} kills the ${winner === knight ? 'ogre' : 'knight'}`);
let w;
for (let i = 0; i < 10; i++) { await tic(); w = await mon(winner); if (w.ENEMY_ID === pe) break; }
assert(w.ENEMY_ID === pe && w.OLDENEMY_ID === null && w.ST !== 'stand', 'its enemy dead, the survivor goes back to the player (ai_run: HuntTarget on oldenemy)');
const s = await tic();
assert(s.KILLED === 1, `the level counts the kill all the same, as Quake's Killed does (${s.KILLED} of ${s.TOTAL_MONSTERS})`);

// a grunt's shot flashes (army_fire's EF_MUZZLEFLASH) for the frame it was fired in, and the flash lights
// the room as the player's does
{
  const grunt = await spawn('army', 200);
  // on the player's floor, in its sight, all of it on the floor
  const p = await q1(`SELECT x, y, z FROM ents WHERE id = ${pe}`);
  for (const [dx, dy] of [[160, 0], [-160, 0], [0, 160], [0, -160], [110, 110], [-110, -110]]) {
    const ok = await q1(`SELECT test_position(${grunt}, ${p.X + dx}, ${p.Y + dy}, ${p.Z}) t,
      (SELECT fraction FROM trace_move(NULL, 0,0,0,0,0,0, ${p.X + dx}, ${p.Y + dy}, ${p.Z + 25}, ${p.X}, ${p.Y}, ${p.Z + 22}, 1)) f FROM rdb$database`);
    if (ok.T !== 0 || ok.F < 1) continue;
    await db.exec(`UPDATE ents SET x = ${p.X + dx}, y = ${p.Y + dy}, z = ${p.Z}, attack_finished = 0 WHERE id = ${grunt}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
    // standing squarely (SV_CheckBottom): one left hanging over a drop that cannot step is let fall, as Quake does
    if ((await q1(`SELECT check_bottom(${grunt}) b FROM rdb$database`)).B === 1) break;
  }
  await hunt(grunt, pe);
  let lit = null, after = null;
  for (let i = 0; i < 200 && lit === null; i++) {
    await tic();
    const e = await q1(`SELECT effects f FROM ents WHERE id = ${grunt}`);
    if (e.F & 2) { lit = i; after = (await tic(), (await q1(`SELECT effects f FROM ents WHERE id = ${grunt}`)).F); }
  }
  const lights = frameDlights({ ents: [[grunt, 0, 0, 0, 0, 0, 0, 0, 90, 0, 2]], models: new Map(), qc: false, time: 0 });
  assert(lit !== null && (after & 2) === 0 && lights.length === 1 && lights[0].minlight === 32,
    `a grunt firing at the player flashes (tic ${lit}) for that frame only, and the flash is a light in the PSQL game too`);
}

// T_RadiusDamage: the blast reaches what findradius finds, the middles within damage + 40 (a sphere, not a box), and
// a shambler takes half of it; a grunt off diagonally 200 units from a 120 blast (inside the old box, outside the
// sphere) is not hurt, a shambler 80 units off takes half of 120 - 40
{
  const pe2 = await spot();
  const p = await q1(`SELECT x, y, z FROM ents WHERE id = ${pe2}`);
  await db.exec(`INSERT INTO ents (id, classname, x, y, z) VALUES (900002, 'blast', ${p.X}, ${p.Y}, ${p.Z})`);
  const g = await spawn('army', 100);
  const gc = await q1(`SELECT minz, maxz FROM ents WHERE id = ${g}`);
  // its middle 141 units off on each axis across: 200 units away (at the height of the blast)
  let placed = false;
  for (const [sx, sy] of [[1, 1], [1, -1], [-1, 1], [-1, -1]]) {
    const x = p.X + sx * 141.5, y = p.Y + sy * 141.5, z = p.Z - (gc.MINZ + gc.MAXZ) / 2;
    if ((await q1(`SELECT test_position(${g}, ${x}, ${y}, ${z}) t FROM rdb$database`)).T === 0) {
      await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, health = 500 WHERE id = ${g}`); placed = true; break;
    }
  }
  const sh = await spawn('shambler', 80);
  const sc = await q1(`SELECT x + (minx + maxx) / 2 x, y + (miny + maxy) / 2 y, z + (minz + maxz) / 2 z FROM ents WHERE id = ${sh}`);
  await db.exec(`UPDATE ents SET health = 1000 WHERE id = ${sh}`);
  await db.exec(`EXECUTE PROCEDURE t_radius_damage(900002, 900002, 120, ${pe2})`);
  const gh = (await q1(`SELECT health h FROM ents WHERE id = ${g}`)).H, shh = (await q1(`SELECT health h FROM ents WHERE id = ${sh}`)).H;
  const sd = Math.hypot(sc.X - p.X, sc.Y - p.Y, sc.Z - p.Z);
  await db.exec('DELETE FROM ents WHERE id = 900002');
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, takedamage = 0, nextthink = NULL WHERE id IN (${g}, ${sh})`);
  assert(placed && gh === 500 && Math.abs((1000 - shh) - (120 - 0.5 * sd) * 0.5) <= 1,
    `T_RadiusDamage: a grunt 200 units off a 120 blast is out of its reach (health ${gh}), a shambler ${sd.toFixed(0)} off takes half (${1000 - shh})`);
}

// SV_CheckWaterTransition after a monster's think: a grunt put into E1M1's water splashes (misc/h2ohit1.wav) and
// takes the water's type, and put back on dry land splashes again
{
  const g = await spawn('army', 120);
  const pool = await q1(`SELECT FIRST 1 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
    WHERE l.contents = -3 AND point_contents((l.minx + l.maxx) / 2, (l.miny + l.maxy) / 2, (l.minz + l.maxz) / 2) = -3 ORDER BY l.id`);
  const dry = await q1(`SELECT x, y, z FROM ents WHERE id = ${g}`);
  const splashes = async () => (await q1(`SELECT COUNT(*) n FROM sound_events WHERE ent_id = ${g} AND snd = 'misc/h2ohit1.wav'`)).N;
  const thinkNow = () => db.exec(`UPDATE ents SET nextthink = (SELECT g.time_ FROM game g WHERE g.id = 1) WHERE id = ${g}`);
  await tic(); await tic();
  const s0 = await splashes();
  await db.exec(`UPDATE ents SET x = ${pool.X}, y = ${pool.Y}, z = ${pool.Z}, flags = BIN_OR(flags, 512) WHERE id = ${g}`);
  await thinkNow(); await tic();
  const wet = await q1(`SELECT watertype wt FROM ents WHERE id = ${g}`), s1 = await splashes();
  await db.exec(`UPDATE ents SET x = ${dry.X}, y = ${dry.Y}, z = ${dry.Z} WHERE id = ${g}`);
  await thinkNow(); await tic();
  const s2 = await splashes();
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, takedamage = 0, nextthink = NULL WHERE id = ${g}`);
  assert(wet.WT === -3 && s1 === s0 + 1 && s2 === s1 + 1,
    `SV_CheckWaterTransition in the PSQL game: a grunt into the water splashes and is in it (type ${wet.WT}), out again splashes (${s0} → ${s1} → ${s2})`);
}

// PF_aim in the PSQL game: a grunt in front and above, the player looking level; the rocket goes up at it (autoaim,
// sv_aim 0.93), turned only in height (its run across stays the view's)
{
  const pe3 = await spot();
  const p = await q1(`SELECT x, y, z, yaw FROM ents WHERE id = ${pe3}`);
  const g = await spawn('army', 200);
  const g0 = await q1(`SELECT x, y, z FROM ents WHERE id = ${g}`);
  let up = null;
  for (const dz of [60, 48, 72, 40]) {
    if ((await q1(`SELECT test_position(${g}, ${g0.X}, ${g0.Y}, ${p.Z + dz}) t FROM rdb$database`)).T === 0) { up = dz; break; }
  }
  await db.exec(`UPDATE ents SET z = ${p.Z + up}, nextthink = NULL, movetype = 0, flags = BIN_OR(flags, 512) WHERE id = ${g}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${g})`);
  const yaw = Math.atan2(g0.Y - p.Y, g0.X - p.X) * 180 / Math.PI;
  await db.exec(`UPDATE ents SET yaw = ${yaw} WHERE id = ${pe3}`);
  await db.exec('UPDATE player SET pitch = 0, weapon = 32, rockets = 10, attack_finished = 0, items = BIN_OR(items, 32)');
  const before = (await q1('SELECT MAX(id) m FROM ents')).M;
  await db.exec('EXECUTE PROCEDURE player_fire(1)');
  const r = await q1(`SELECT vx, vy, vz FROM ents WHERE id > ${before} ORDER BY id`);
  const run = Math.hypot(r.VX, r.VY);
  const across = (r.VX * Math.cos(yaw * Math.PI / 180) + r.VY * Math.sin(yaw * Math.PI / 180)) / run;
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, takedamage = 0, nextthink = NULL WHERE id = ${g}`);
  assert(up && r.VZ > 100 && across > 0.999 && Math.abs(Math.hypot(r.VX, r.VY, r.VZ) - 1000) < 1,
    `PF_aim in the PSQL game: looking level at a grunt ${up} units up, the rocket climbs at it (${r.VZ.toFixed(0)} up of 1000), still along the view across`);
}

// FindTarget: an invisible player is never seen, nor one with notarget; but a monster that saw the player (the
// sight_entity of FoundTarget, for 0.1 s) wakes another that sees it, invisible player or not, unless that one lies in
// ambush (spawnflags & 3)
{
  const pe4 = await spot();
  const p = await q1(`SELECT x, y, z, yaw FROM ents WHERE id = ${pe4}`);
  const a = await spawn('army', 120), b = await spawn('army', 240);
  // a where it sees the player, b where it sees a (on the floor, in the open)
  const placeSeeing = async (m, target, from) => {
    const tz = (await q1(`SELECT z FROM ents WHERE id = ${target}`)).Z;
    for (let d = from; d < from + 400; d += 40) for (let k = 0; k < 16; k++) {
      const t = (await q1(`SELECT x, y FROM ents WHERE id = ${target}`));
      const x = t.X + Math.cos(k * Math.PI / 8) * d, y = t.Y + Math.sin(k * Math.PI / 8) * d;
      if ((await q1(`SELECT test_position(${m}, ${x}, ${y}, ${tz}) t FROM rdb$database`)).T !== 0) continue;
      await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${tz} WHERE id = ${m}`);
      await db.exec(`EXECUTE PROCEDURE link_ent(${m})`);
      if ((await q1(`SELECT visible(${m}, ${target}) v FROM rdb$database`)).V === 1) return true;
    }
    return false;
  };
  const placed = (await placeSeeing(a, pe4, 120)) && (await placeSeeing(b, a, 120));
  const ap = await q1(`SELECT x, y FROM ents WHERE id = ${a}`), bp = await q1(`SELECT x, y FROM ents WHERE id = ${b}`);
  // a faces the player, b faces a
  const yawTo = (f, to) => Math.atan2(to.Y - f.Y, to.X - f.X) * 180 / Math.PI;
  await db.exec(`UPDATE ents SET yaw = ${yawTo(ap, p)}, enemy_id = NULL, st = 'stand', nextthink = NULL WHERE id = ${a}`);
  await db.exec(`UPDATE ents SET yaw = ${yawTo(bp, ap)}, enemy_id = NULL, st = 'stand', nextthink = NULL, spawnflags = 0 WHERE id = ${b}`);
  await db.exec("UPDATE game SET sight_entity = NULL, sight_entity_time = -1");
  const find = async (m) => (await q1(`SELECT find_target(${m}) f FROM rdb$database`)).F;
  const seen0 = await find(a);
  await db.exec('UPDATE player SET invisible_finished = (SELECT g.time_ + 30 FROM game g WHERE g.id = 1)');
  let invisibleSeen = 0;
  for (let i = 0; i < 100; i++) invisibleSeen += (await find(a)) ? 1 : 0;
  await db.exec('UPDATE player SET invisible_finished = 0');
  await db.exec(`UPDATE ents SET flags = BIN_OR(flags, 128) WHERE id = ${pe4}`);
  const notarget = await find(a);
  await db.exec(`UPDATE ents SET flags = BIN_AND(flags, BIN_NOT(128)) WHERE id = ${pe4}`);
  // invisible again: a is set on the player (FoundTarget), and b, which sees a, wakes onto the player through it
  await db.exec('UPDATE player SET invisible_finished = (SELECT g.time_ + 30 FROM game g WHERE g.id = 1)');
  await db.exec(`EXECUTE PROCEDURE found_target(${a}, ${pe4})`);
  const viaA = await find(b);
  await db.exec(`UPDATE ents SET spawnflags = 1 WHERE id = ${b}`);
  const ambush = await find(b);
  await db.exec('UPDATE player SET invisible_finished = 0');
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, takedamage = 0, nextthink = NULL WHERE id IN (${a}, ${b})`);
  assert(placed && seen0 === pe4 && invisibleSeen === 0 && notarget === 0 && viaA === pe4 && ambush === 0,
    `FindTarget: the player is seen (${seen0}), not when invisible (${invisibleSeen} of 100) or notarget (${notarget}); a monster that saw it wakes another through it (${viaA}), but not one in ambush (${ambush})`);
}

// a swimming monster's eye is lower (swimmonster_start_go: 10)
const fish = await spawn('fish', 200);
assert((await q1(`SELECT eye_height(${fish}) f FROM rdb$database`)).F === 10, "a fish's eye is 10 above its origin");

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
