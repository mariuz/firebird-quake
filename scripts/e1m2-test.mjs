// e1m2-test.mjs – Castle of the Damned's drawbridge: a slab standing in the
// moat channel (func_door *42, "t123") that sinks slowly when the player
// steps onto the bank in front of it, until its top lies just under the
// water, and the moat can be waded across.
//
//   node scripts/e1m2-test.mjs

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
await loadMap(db, pak, res, 'e1m2', { skill: 1, seed: 1 });
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
const door = () => q1("SELECT id, mv_state, CAST(z AS INTEGER) z, speed, p2z, lip, noise1, noise2, x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0, z + maxz z1 FROM ents WHERE classname = 'func_door' AND targetname = 't123'");
const trace = (x1, y1, z1, x2, y2, z2) => q1(`SELECT fraction f, hit_ent h, ez FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${x1}, ${y1}, ${z1}, ${x2}, ${y2}, ${z2}, 1)`);

let s = await tic();
assert(s.LEVEL_MSG === 'Castle of the Damned', `the level is ${s.LEVEL_MSG}`);

// ── the bridge, raised ───────────────────────────────────────────────────
let d = await door();
assert(!!d && d.MV_STATE === 1 && d.Z === 0, 'the drawbridge slab stands in the moat channel, raised');
assert(d.SPEED === 50 && d.P2Z === -112 && d.LIP === 6, `it will sink 112 units at 50 per second (lip ${d.LIP})`);
const cy = (d.Y0 + d.Y1) / 2;             // the channel runs across x at this y
const bank = { x: d.X0 - 48, z: 199 };     // the near bank's floor trigger sits at z 193..199
const far = { x: d.X1 + 48 };
// the slab plugs an opening in the castle wall: stone above it, moat water on both sides
const water = await q1(`SELECT point_contents(${(d.X0 + d.X1) / 2}, ${cy}, ${d.Z1 + 4}) above, point_contents(${d.X0 - 8}, ${cy}, 160) near_, point_contents(${d.X1 + 8}, ${cy}, 160) far_ FROM rdb$database`);
assert(water.ABOVE === -2 && water.NEAR_ === -3 && water.FAR_ === -3, 'it plugs an opening in the wall, with the moat (28 units deep) on both sides');
const trig = await q1("SELECT id, x + minx x0, x + maxx x1, z + minz z0, z + maxz z1 FROM ents WHERE classname = 'trigger_once' AND target = 't123'");
assert(!!trig && trig.X1 < d.X0 && trig.Z1 === 199, 'a floor trigger on the near bank lowers it');
const wade = 195;                          // a wading player's origin, above the ramp the far bank rises on
let t = await trace(bank.x, cy, wade, d.X1 + 8, cy, wade);   // to just past the slab: the far bank is a step up
assert(t.F < 1 && t.H === d.ID, 'raised, the slab blocks the way across');

// ── step onto the bank: the bridge sinks ────────────────────────────────
await teleport(trig.X1 - 60, cy, bank.z + 30, 0);
s = await run(3);
d = await door();
assert(d.MV_STATE === 2, `stepping on the bank starts it sinking (state ${d.MV_STATE})`);
assert((await sounds(d.NOISE2)) > 0, `the stone grinds (${d.NOISE2})`);
assert(!(await q1(`SELECT id FROM ents WHERE id = ${trig.ID}`)), 'the trigger is spent');
// 112 units at 50/s: about 2.2 s
s = await run(40);
d = await door();
assert(d.MV_STATE === 2 && d.Z < -60 && d.Z > -112, `two seconds in it is still going down (z ${d.Z})`);
s = await run(20);
d = await door();
assert(d.MV_STATE === 0 && d.Z === -112, `then it rests at the bottom (z ${d.Z}, state ${d.MV_STATE})`);
assert((await sounds(d.NOISE1)) > 0, `with the stop sound (${d.NOISE1})`);
const top = d.Z1;
const surface = 172;
assert(top < surface && top > surface - 30, `its top (${top}) lies just under the water (${surface}): a ford`);
t = await trace(bank.x, cy, wade, d.X1 + 8, cy, wade);
assert(t.F === 1, 'lowered, the way across is clear');

// ── wade across ─────────────────────────────────────────────────────────
await teleport(bank.x, cy, bank.z + 30, 0);
await run(5);
let onBridge = false, wading = false, crossed = false;
for (let i = 0; i < 160 && !crossed; i++) {
  s = await tic([1, 1, 0, 0, 0, 0, 0, 0, 0]);     // walking, so the slab is sampled more than once on the way
  if (s.PX > d.X0 && s.PX < d.X1) {
    const down = await q1(`SELECT hit_ent h FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${s.PX}, ${s.PY}, ${s.PZ}, ${s.PX}, ${s.PY}, ${s.PZ - 40}, 1)`);
    if (down.H === d.ID) onBridge = true;
    if (s.WATERLEVEL >= 1) wading = true;
  }
  if (s.PX > far.x) crossed = true;
}
assert(onBridge, 'over the channel the player stands on the sunken slab');
assert(wading, 'with his feet in the water');
assert(crossed, `and reaches the far bank (x ${s.PX.toFixed(0)}, health ${s.HEALTH})`);
assert(s.HEALTH === 100, 'unharmed');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
