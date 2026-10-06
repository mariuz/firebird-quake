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
await loadMap(db, pak, res, 'e1m4', { skill: 1 });
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

// ── the secret exit is under water ──────────────────────────────────────
const exit = await box("classname = 'trigger_changelevel' AND map = 'e1m8'");
assert((await contents(exit.CX, exit.CY, exit.CZ)) === -3, `the exit to E1M8 lies under the lake (${exit.CX}, ${exit.CY}, ${exit.CZ})`);
const main = await box("classname = 'trigger_changelevel' AND map = 'e1m5'");
assert((await contents(main.CX, main.CY, main.CZ)) === -1, 'the ordinary exit is in the air');

// an approach: open water some way from the exit, with a clear swim to it
let start = null;
outer: for (const dist of [160, 120, 200, 90]) for (const [dx, dy] of [[-1, 0], [0, -1], [1, 0], [0, 1], [-0.7, -0.7], [-0.7, 0.7], [0.7, -0.7], [0.7, 0.7]]) {
  const x = exit.CX + dx * dist, y = exit.CY + dy * dist, z = exit.CZ;
  if ((await contents(x, y, z)) !== -3) continue;
  if ((await q1(`SELECT hull_contents(1, ${head}, ${x}, ${y}, ${z}) c FROM rdb$database`)).C === -2) continue;
  const t = await q1(`SELECT fraction f FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${x}, ${y}, ${z}, ${exit.CX}, ${exit.CY}, ${exit.CZ}, 1)`);
  if (t.F === 1) { start = { x, y, z, yaw: (Math.atan2(exit.CY - y, exit.CX - x) * 180) / Math.PI }; break outer; }
}
assert(!!start, `open water ${start ? Math.hypot(start.x - exit.CX, start.y - exit.CY).toFixed(0) : '?'} units from the exit with a clear swim to it`);

// ── swim to it ──────────────────────────────────────────────────────────
await teleport(start.x, start.y, start.z, start.yaw);
s = await tic();
assert(s.WATERLEVEL === 3, 'the player is under water');
assert(s.AMB_WATER > 0, 'the lake murmurs (water ambient)');
let reached = false, tics = 0;
for (; tics < 200 && !reached; tics++) {
  s = await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]);
  if (s.EXIT_KIND === 1) reached = true;
}
assert(reached && s.NEXT_MAP === 'e1m8', `swimming into the exit asks for Ziggurat Vertigo after ${(tics / 20).toFixed(1)} s`);
assert(s.HEALTH === 100, 'with breath to spare');

// ── the secret area beside it ───────────────────────────────────────────
await loadMap(db, pak, res, 'e1m4', { skill: 1 });
const pe2 = (await q1('SELECT ent_id e FROM player')).E;
const secrets = await qa("SELECT id, (x + minx + x + maxx) / 2 cx, (y + miny + y + maxy) / 2 cy, (z + minz + z + maxz) / 2 cz FROM ents WHERE classname = 'trigger_secret' ORDER BY vlen(x - " + exit.CX + ", y - " + exit.CY + ", z - " + exit.CZ + ")");
const sec = secrets[0];
assert(Math.hypot(sec.CX - exit.CX, sec.CY - exit.CY) < 400, `a secret area lies ${Math.hypot(sec.CX - exit.CX, sec.CY - exit.CY).toFixed(0)} units from the secret exit`);
await db.exec(`UPDATE ents SET x = ${sec.CX}, y = ${sec.CY}, z = ${sec.CZ + 20}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe2}`);
await db.exec(`EXECUTE PROCEDURE link_ent(${pe2})`);
s = await run(3);
assert(s.FOUND_SECRETS === 1, 'stepping into it counts the secret');
assert(/secret area/i.test(s.CPRINT ?? ''), `with the message (${s.CPRINT})`);
assert((await sounds('misc/secret.wav')) > 0, 'and the chime');
assert(!(await q1(`SELECT id FROM ents WHERE id = ${sec.ID}`)), 'and only once');

// ── the underwater trap door ────────────────────────────────────────────
const trap = await box("classname = 'func_door' AND targetname = 't39' AND BIN_AND(spawnflags, 1) <> 0 AND z + maxz < 600");
const trapTrig = await box("classname = 'trigger_once' AND target = 't39' AND spawnflags = 0");
assert(trap && trapTrig && (await contents(trapTrig.CX, trapTrig.CY, trapTrig.CZ)) === -3, 'an underwater trigger governs a door that starts open on the lake bed');
const trap0 = await q1(`SELECT mv_state, CAST(z AS INTEGER) z FROM ents WHERE id = ${trap.ID}`);
await db.exec(`UPDATE ents SET x = ${trapTrig.CX}, y = ${trapTrig.CY}, z = ${trapTrig.CZ}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe2}`);
await db.exec(`EXECUTE PROCEDURE link_ent(${pe2})`);
s = await run(10);
const trap1 = await q1(`SELECT mv_state, CAST(z AS INTEGER) z FROM ents WHERE id = ${trap.ID}`);
assert(trap1.MV_STATE !== trap0.MV_STATE || trap1.Z !== trap0.Z, `swimming through the trigger sets the door moving (state ${trap0.MV_STATE} → ${trap1.MV_STATE}, z ${trap0.Z} → ${trap1.Z})`);
assert(!(await q1(`SELECT id FROM ents WHERE id = ${trapTrig.ID}`)), 'the trigger is spent');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
