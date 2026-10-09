// e1m4-test.mjs – the Grisly Grotto's underwater secret: the exit to Ziggurat
// Vertigo lies under the water of the grotto's lake, reached by swimming,
// with a secret area and an underwater trap door along the way.
//
//   node scripts/e1m4-test.mjs

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
await loadMap(db, pak, res, 'e1m4', { skill: 1, seed: 1 });
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
const box = (where) => q1(`SELECT id, x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0, z + maxz z1, (x + minx + x + maxx) / 2 cx, (y + miny + y + maxy) / 2 cy, (z + minz + z + maxz) / 2 cz FROM ents WHERE ${where}`);
const contents = (x, y, z) => q1(`SELECT point_contents(${x}, ${y}, ${z}) c FROM rdb$database`).then((r) => r.C);
const head = (await q1('SELECT m.hull1 h FROM models m JOIN game g ON g.world_model = m.id')).H;

let s = await tic();
assert(s.LEVEL_MSG === 'the Grisly Grotto', `the level is ${s.LEVEL_MSG}`);
assert(s.TOTAL_SECRETS >= 2, `the grotto keeps ${s.TOTAL_SECRETS} secrets`);
const exits = await qa("SELECT id, map FROM ents WHERE classname = 'trigger_changelevel' ORDER BY id");
assert(exits.length === 2 && exits.some((e) => e.MAP === 'e1m5') && exits.some((e) => e.MAP === 'e1m8'), 'two exits: the way on to E1M5, and the secret one to Ziggurat Vertigo');

// ── the secret cave: an underwater door, opened by two buttons through a counter ──
const exit = await box("classname = 'trigger_changelevel' AND map = 'e1m8'");
const main = await box("classname = 'trigger_changelevel' AND map = 'e1m5'");
assert((await contents(main.CX, main.CY, main.CZ)) === -1, 'the ordinary exit stands in the open');
assert((await contents(exit.CX, exit.CY, exit.CZ)) === -1 && exit.Z0 > 852, `the exit to E1M8 stands on a ledge above the lake (z ${exit.Z0}; the surface is near 852)`);
const door = await q1("SELECT id, mv_state, lip, CAST(y AS INTEGER) y, x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0, z + maxz z1 FROM ents WHERE classname = 'func_door' AND targetname = 't98'");
assert(door && door.Z1 < 852 && door.LIP === -384, `an underwater door blocks the way to it (x ${door.X0}..${door.X1}, y ${door.Y0}..${door.Y1}, z ${door.Z0}..${door.Z1}); its lip of -384 will slide it far aside`);
assert((await contents(door.X0 - 20, (door.Y0 + door.Y1) / 2, (door.Z0 + door.Z1) / 2)) === -3, 'the water in front of it');
const buttons = await qa("SELECT id FROM ents WHERE classname = 'func_button' AND target = 't97' ORDER BY id");
const counter = await q1("SELECT id, count_ FROM ents WHERE classname = 'trigger_counter' AND targetname = 't97'");
assert(buttons.length === 2 && counter && counter.COUNT_ === 2 && (await q1("SELECT target t FROM ents WHERE id = " + counter.ID)).T === 't98', 'two buttons feed a counter that targets the door');
const lake = { y: (door.Y0 + door.Y1) / 2, z: (door.Z0 + door.Z1) / 2 };
const swimPath = (x1, x2, z) => q1(`SELECT fraction f, hit_ent h FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${x1}, ${lake.y}, ${z}, ${x2}, ${lake.y}, ${z}, 1)`);
let t = await swimPath(door.X0 - 60, door.X1 + 60, lake.z);
assert(t.F < 1 && t.H === door.ID, 'at depth the door stops a swimmer');

// the first button: one more to go
await db.exec(`EXECUTE PROCEDURE button_fire(${buttons[0].ID}, ${pe})`);
s = await run(3);
assert(/more to go/i.test(s.CPRINT ?? ''), `the first button: "${s.CPRINT}"`);
assert((await q1(`SELECT mv_state m FROM ents WHERE id = ${door.ID}`)).M === 1, 'the door has not moved');
await db.exec(`EXECUTE PROCEDURE button_fire(${buttons[1].ID}, ${pe})`);
s = await run(3);
assert(/completed/i.test(s.CPRINT ?? '') || /secret cave/i.test(s.CPRINT ?? ''), `the second: "${s.CPRINT}"`);
let opened = false;
for (let i = 0; i < 200 && !opened; i++) { s = await tic(); opened = (await q1(`SELECT mv_state m FROM ents WHERE id = ${door.ID}`)).M === 0; }
const d2 = await q1(`SELECT CAST(y AS INTEGER) y FROM ents WHERE id = ${door.ID}`);
assert(opened && d2.Y - door.Y > 500, `the door slides ${d2.Y - door.Y} units aside and rests open`);
assert((await q1("SELECT COUNT(*) n FROM ents WHERE classname = 'trigger_once' AND targetname = 't98'")).N === 0, '"A secret cave has opened..." was announced (its trigger is spent)');
t = await swimPath(door.X0 - 60, door.X1 + 60, lake.z);
assert(t.F === 1, 'and at depth the way through is clear');

// ── swim through, surface by the ledge: the secret ─────────────────────
const sec = (await qa(`SELECT id, (x + minx + x + maxx) / 2 cx, (y + miny + y + maxy) / 2 cy, z + minz z0, z + maxz z1 FROM ents WHERE classname = 'trigger_secret' ORDER BY vlen((x + minx + x + maxx) / 2 - ${exit.CX}, (y + miny + y + maxy) / 2 - ${exit.CY}, 0)`))[0];
assert(sec.Z0 > 852 && sec.Z0 < 900 && (await contents(sec.CX, sec.CY, 820)) === -3, 'a secret trigger hangs just above the water by the ledge: found by surfacing there');
await teleport(door.X0 - 60, lake.y, lake.z, 0);
s = await tic();
assert(s.WATERLEVEL === 3 && s.AMB_WATER > 0, 'the player is under the lake, with the water murmuring');
let found = false, tics = 0;
for (; tics < 300 && !found; tics++) {
  const past = s.PX > door.X1 + 20;                       // through the gap first, then up to the surface by the ledge
  const yaw = past ? (Math.atan2(sec.CY - s.PY, sec.CX - s.PX) * 180) / Math.PI : 0;
  s = await tic([1, 1, 0, yaw - s.YAW, 0, 0, past ? 1 : 0, 1, 0]);
  if (s.FOUND_SECRETS > 0) found = true;
}
assert(found, `swimming through and surfacing by the ledge finds the secret after ${(tics / 20).toFixed(1)} s`);
assert((await sounds('misc/secret.wav')) > 0, 'with the chime');
assert(s.HEALTH === 100, 'with breath to spare');

// ── out of the water onto the ledge (the water jump), and into the slipgate ──
let reached = false, climbed = false;
for (tics = 0; tics < 300 && !reached; tics++) {
  const yaw = (Math.atan2(exit.CY - s.PY, exit.CX - s.PX) * 180) / Math.PI;
  s = await tic([1, 1, 0, yaw - s.YAW, 0, 0, 1, 1, 0]);
  if (!climbed && s.WATERLEVEL === 0 && s.PZ > 852) climbed = true;
  if (s.EXIT_KIND === 1) reached = true;
}
assert(climbed, 'pushing against the ledge, the player hops out of the water (FL_WATERJUMP)');
assert(reached && s.NEXT_MAP === 'e1m8', `and walks into the slipgate: Ziggurat Vertigo, ${(tics / 20).toFixed(1)} s after surfacing`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
