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

// a swimming monster's eye is lower (swimmonster_start_go: 10)
const fish = await spawn('fish', 200);
assert((await q1(`SELECT eye_height(${fish}) f FROM rdb$database`)).F === 10, "a fish's eye is 10 above its origin");

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
