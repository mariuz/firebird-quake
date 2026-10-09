// e1m6-test.mjs – The Door To Chthon's gold key: the runekey doors refuse
// the player until he carries the key, taking the key wakes what guards
// it, the doors take the key and open, and beyond them lies the way to
// the House of Chthon.
//
//   node scripts/e1m6-test.mjs

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
await loadMap(db, pak, res, 'e1m6', { skill: 1, seed: 1 });
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
const GOLD = 262144, SILVER = 131072;
const doorRow = (id) => q1(`SELECT id, mv_state, items, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y, x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0 FROM ents WHERE id = ${id}`);

let s = await tic();
assert(s.LEVEL_MSG === 'The Door To Chthon', `the level is ${s.LEVEL_MSG}`);
// the ogres beyond the gold doors and the shambler by the exit wander and block at random: this is a
// test of keys and doors, so only the key's guard stays alive
const keyTarget = (await q1("SELECT target t FROM ents WHERE classname = 'item_key2'")).T;
await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL AND COALESCE(targetname, '') <> '${keyTarget}'`);
assert((await q1('SELECT world_type w FROM game')).W === 1, 'a metal level: its keys are runekeys');

// ── the gold doors ──────────────────────────────────────────────────────
const gold = await qa(`SELECT id FROM ents WHERE classname = 'func_door' AND items = ${GOLD} ORDER BY id`);
assert(gold.length === 2, `two door halves want the gold runekey (${gold.length})`);
let d = await doorRow(gold[0].ID);
assert(d.MV_STATE === 1, 'they are shut');
const front = { x: d.X0 - 40, y: (d.Y0 + d.Y1) / 2, z: d.Z0 + 30 };
await teleport(front.x, front.y, front.z, 0);
await run(5);
s = await run(20, [1, 1, 0, 0, 0, 0, 0, 1, 0]);                      // walk into the door
assert(/gold runekey/i.test(s.CPRINT ?? ''), `without the key the door says: "${s.CPRINT}"`);
assert((await sounds('doors/runetry.wav')) > 0, 'with the locked-door sound');
d = await doorRow(gold[0].ID);
assert(d.MV_STATE === 1 && s.PX < d.X0, 'and stays shut; the player is held in front of it');

// ── the key, and what taking it wakes ───────────────────────────────────
const key = await q1("SELECT id, x, y, z, target FROM ents WHERE classname = 'item_key2'");
assert(!!key, 'the gold runekey lies in the level');
const guards = await qa(`SELECT id, mtype, st FROM ents WHERE targetname = '${key.TARGET}' AND mtype IS NOT NULL`);
assert(guards.length >= 1 && guards.every((g) => g.ST === 'stand'), `the key is watched by a ${guards.map((g) => g.MTYPE).join(', ')} that waits`);
await teleport(key.X, key.Y, key.Z + 30, 0);
s = await run(5);
assert((s.ITEMS & GOLD) !== 0, `the key is taken: "${s.MSG}"`);
assert(/gold runekey/i.test(s.MSG ?? ''), 'and called by its metal-level name');
assert((await sounds('misc/runekey.wav')) > 0, 'with the runekey chime');
assert(!(await q1(`SELECT id FROM ents WHERE id = ${key.ID}`)), 'the key is gone from the floor');
const woke = await qa(`SELECT id, mtype, st, enemy_id FROM ents WHERE targetname = '${key.TARGET}' AND mtype IS NOT NULL`);
assert(woke.every((g) => g.ST === 'run' && g.ENEMY_ID === pe), 'taking it wakes the guard, who comes for the player');
await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE targetname = '${keyTarget}' AND mtype IS NOT NULL`);   // and is seen to; the doors are next

// ── back at the doors: the key opens them, and is spent ─────────────────
await teleport(front.x, front.y, front.z, 0);
await run(45);                                                      // a door answers a touch only every two seconds
s = await run(10, [1, 1, 0, 0, 0, 0, 0, 1, 0]);
d = await doorRow(gold[0].ID);
assert(d.MV_STATE === 2 || d.MV_STATE === 0, `walking into it with the key opens the door (state ${d.MV_STATE})`);
assert((s.ITEMS & GOLD) === 0, 'the key is used up');
assert((await sounds('doors/ddoor1.wav')) > 0, 'the door moves with its sound');
let through = false;
for (let i = 0; i < 80 && !through; i++) { s = await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]); if (s.PX > d.X1 + 20) through = true; }
assert(through, `the player walks through (x ${s.PX.toFixed(0)})`);
d = await doorRow(gold[0].ID);
assert(d.MV_STATE === 0 && Math.abs(d.Y) > 40, 'the door half slid aside and rests open');

// ── the silver doors still refuse him ───────────────────────────────────
const silver = await qa(`SELECT id FROM ents WHERE classname = 'func_door' AND items = ${SILVER} ORDER BY id`);
assert(silver.length === 2, `two door halves want the silver runekey (${silver.length})`);
const sd = await doorRow(silver[0].ID);
await teleport(sd.X1 + 40, (sd.Y0 + sd.Y1) / 2, sd.Z0 + 30, 180);
await run(5);
s = await run(20, [1, 1, 0, 0, 0, 0, 0, 1, 0]);
assert(/silver runekey/i.test(s.CPRINT ?? ''), `the silver doors say: "${s.CPRINT}"`);
assert((await doorRow(silver[0].ID)).MV_STATE === 1, 'and stay shut');

// ── beyond the gold doors: the way to the House of Chthon ───────────────
const exit = await q1("SELECT id, map, x + minx x0, x + maxx x1, (y + miny + y + maxy) / 2 cy, z + minz z0 FROM ents WHERE classname = 'trigger_changelevel'");
assert(exit && exit.MAP === 'e1m7', 'the exit leads to the House of Chthon');
assert(exit.X0 > d.X1, 'and lies beyond the gold doors');
// a clear spot in the hallway before it (the trigger's box starts below the floor)
let standZ = null;
for (const z of [exit.Z0 + 40, exit.Z0 + 80, exit.Z0 + 120, exit.Z0 + 160]) if ((await q1(`SELECT test_position(${pe}, ${exit.X0 - 60}, ${exit.CY}, ${z}) t FROM rdb$database`)).T === 0) { standZ = z; break; }
assert(standZ != null, `open air before the exit at z ${standZ}`);
await teleport(exit.X0 - 60, exit.CY, standZ, 0);
await run(15);                                                       // land
let left = false;
for (let i = 0; i < 60 && !left; i++) { s = await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]); if (s.EXIT_KIND === 1) left = true; }
assert(left && s.NEXT_MAP === 'e1m7', 'walking into it asks for E1M7');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
