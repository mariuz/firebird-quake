// nav-test.mjs – the bots' map of the level (sql/bots.sql, FrikBot's dynamic waypoints): E1M1 as a
// deathmatch with one bot, the player hidden from it (notarget). The bot and the player drop nodes where
// they walk, linked the way they went (a drop one way, level ground both ways, every link a clear line);
// a drop is linked one way, a stride both; the bot runs a way bot_plan lays through the links to a node a
// dozen links off, node by node, and arrives; a link it cannot cross is struck off.
//
//   node scripts/nav-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(process.env.PAK ?? path.join(root, 'public/pak/pak0.pak')).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser(`memory://nav${Math.random()}`, { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const qa = (s) => db.query(s).then((r) => r.rows);
const tic = (o = {}) => q1(`SELECT * FROM qc_tic(1, ${o.fwd ?? 0}, 0, ${o.yaw ?? 0}, 0, 0, 0, 1, 0)`);
const counts = async () => q1('SELECT (SELECT COUNT(*) FROM nav_nodes) n, (SELECT COUNT(*) FROM nav_links) l FROM rdb$database');
const pos = (e) => q1(`SELECT x, y, z FROM ents WHERE id = ${e}`);

await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 5 });
await loadProgs(db, pak);
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 5 });
await db.exec('EXECUTE PROCEDURE qc_setup_server(1, 0, 1, 0, 0)');
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
await q1("SELECT msg FROM host_cmd('notarget', '', '')");
assert((await counts()).N === 0, 'a new level: the map is empty');

// ── learning: the player walks a lap of the start, the bot roams ──
const p0 = await pos(1);
for (let i = 0; i < 160; i++) await tic({ fwd: 1, yaw: i % 40 < 10 ? 9 : 0 });
const byPlayer = await q1('SELECT COUNT(*) n FROM nav_track WHERE c = 1');
for (let i = 0; i < 1000; i++) await tic();
const c = await counts();
assert(c.N >= 30 && c.L >= 30 && byPlayer.N === 1, `the player and the bot leave a map behind them: ${c.N} nodes, ${c.L} links`);
const spacing = await q1('SELECT MIN(SQRT((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))) d FROM nav_nodes a JOIN nav_nodes b ON b.id > a.id AND ABS(a.z - b.z) < 24 AND nav_clear(a.x, a.y, a.z, b.x, b.y, b.z) = 1');
assert(spacing.D >= 32, `no two nodes in sight of each other on one level closer than a stride (closest ${spacing.D.toFixed(0)})`);
const blind = await q1('SELECT COUNT(*) n FROM nav_links l JOIN nav_nodes a ON a.id = l.a JOIN nav_nodes b ON b.id = l.b WHERE nav_clear(a.x, a.y, a.z, b.x, b.y, b.z) = 0 AND (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) <= 65536');
assert(blind.N === 0, 'every link (but a teleporter\'s) is a clear line');
// a drop: the player's last node 40 units up (a ledge it came off), then a mark where it stands: linked
// down, not back up; a stride on the level: linked both ways
{
  const p = await pos(1);
  const f = await q1(`SELECT flags fl FROM ents WHERE id = 1`);
  await db.exec(`INSERT INTO nav_nodes (id, x, y, z) VALUES (90001, ${p.X} + 50, ${p.Y}, ${p.Z} + 40)`);
  await db.exec('UPDATE OR INSERT INTO nav_track (c, node, mx) VALUES (1, 90001, NULL) MATCHING (c)');
  await db.exec('DELETE FROM nav_nodes WHERE id <> 90001 AND ABS(x - ' + p.X + ') < 70 AND ABS(y - ' + p.Y + ') < 70');
  await db.exec('EXECUTE PROCEDURE nav_mark(1)');
  const here = (await q1('SELECT node n FROM nav_track WHERE c = 1')).N;
  const down = (await q1(`SELECT COUNT(*) n FROM nav_links WHERE a = 90001 AND b = ${here}`)).N;
  const up = (await q1(`SELECT COUNT(*) n FROM nav_links WHERE a = ${here} AND b = 90001`)).N;
  assert((f.FL & 512) !== 0 && here !== 90001 && down === 1 && up === 0, `off a ledge 40 units up: linked down (${down}), not back up (${up})`);
  await db.exec(`UPDATE nav_nodes SET z = ${p.Z} WHERE id = 90001`);
  await db.exec('UPDATE OR INSERT INTO nav_track (c, node, mx) VALUES (1, 90001, NULL) MATCHING (c)');
  await db.exec('EXECUTE PROCEDURE nav_mark(1)');
  assert((await q1(`SELECT COUNT(*) n FROM nav_links WHERE a = ${here} AND b = 90001`)).N === 1, 'a stride on the level: linked both ways');
  await db.exec('DELETE FROM nav_links WHERE a = 90001 OR b = 90001');
  await db.exec('DELETE FROM nav_nodes WHERE id = 90001');
}

// ── a way through the links, run node by node ──
// two nodes far apart by the links and out of sight of each other (round a corner), else the farthest pair
let from = null, goal = null;
for (const { ID } of await qa('SELECT id FROM nav_nodes ORDER BY id ROWS 30')) {
  await db.exec(`EXECUTE PROCEDURE nav_bfs(${ID})`);
  const f = await q1(`SELECT id, x, y, z FROM nav_nodes WHERE id = ${ID}`);
  const g = await q1(`SELECT s.node, s.depth, d.x, d.y, d.z, nav_clear(${f.X}, ${f.Y}, ${f.Z}, d.x, d.y, d.z) seen
    FROM nav_search s JOIN nav_nodes d ON d.id = s.node WHERE s.depth >= 6 ORDER BY 6, s.depth DESC ROWS 1`);
  if (g && (!goal || (g.SEEN < goal.SEEN) || (g.SEEN === goal.SEEN && g.DEPTH > goal.DEPTH))) { from = f; goal = g; }
  if (goal?.SEEN === 0) break;
}
const inSight = goal.SEEN;
assert(goal.DEPTH >= 6, `node ${goal.NODE} is ${goal.DEPTH} links from node ${from.ID}${inSight ? '' : ', round a corner (out of sight)'}`);
await db.exec(`UPDATE ents SET x = ${from.X}, y = ${from.Y}, z = ${from.Z} + 1, vx = 0, vy = 0, vz = 0 WHERE id = 2`);
await db.exec('EXECUTE PROCEDURE link_ent(2)');
await db.exec("EXECUTE PROCEDURE qc_sf(2, qc_fdef('health'), 100)");
const plan = await q1(`SELECT ok FROM bot_plan(2, ${from.X}, ${from.Y}, ${from.Z}, ${goal.NODE})`);
await db.exec('UPDATE bots SET route_at = (SELECT time_ FROM game), look_at = 1e9, enemy = NULL, goal = NULL WHERE c = 2');
const steps = (await q1('SELECT COUNT(*) n FROM bot_route WHERE c = 2')).N;
assert(plan.OK === 1 && steps === goal.DEPTH, `bot_plan lays the way: ${steps} steps`);
let best = Infinity, at = -1;
for (let i = 0; i < 20 * 30 && best > 48; i++) {
  await tic();
  const b = await pos(2);
  const d = Math.hypot(b.X - goal.X, b.Y - goal.Y);
  if (d < best) { best = d; at = i; }
}
const left = await q1('SELECT route_goal g, route_step s FROM bots WHERE c = 2');
assert(best <= 48, `the bot runs it and arrives (${best.toFixed(0)} units from the node, after ${(at / 20).toFixed(1)} s; step ${left.S})`);

// ── a link that is no way is struck off ──
// a node in the void beyond the map, linked from the goal: the bot cannot get there
await db.exec(`INSERT INTO nav_nodes (id, x, y, z) VALUES (99999, ${goal.X}, ${goal.Y}, ${goal.Z} + 400)`);
await db.exec(`INSERT INTO nav_links (a, b) VALUES (${goal.NODE}, 99999)`);
const prev = await q1(`SELECT FIRST 1 l.a a FROM nav_links l WHERE l.b = ${goal.NODE} AND l.a <> 99999`);
await db.exec(`INSERT INTO nav_links (a, b) SELECT ${prev.A}, ${goal.NODE} FROM rdb$database WHERE NOT EXISTS (SELECT 1 FROM nav_links WHERE a = ${prev.A} AND b = ${goal.NODE})`);
const g = await pos(2);
const p2 = await q1(`SELECT ok FROM bot_plan(2, ${g.X}, ${g.Y}, ${g.Z}, 99999)`);
await db.exec('UPDATE bots SET route_at = (SELECT time_ FROM game) WHERE c = 2');
for (let i = 0; i < 20 * 6; i++) await tic();
const gone = (await q1(`SELECT COUNT(*) n FROM nav_links WHERE b = 99999`)).N;
assert(p2.OK === 1 && gone === 0, 'a link the bot could not cross in three seconds is struck off the map');

// ── a save keeps the map ──
{
  const before = await counts();
  await db.exec('EXECUTE PROCEDURE save_game(3)');
  await db.exec('DELETE FROM nav_links'); await db.exec('DELETE FROM nav_nodes');
  await db.exec('EXECUTE PROCEDURE load_game(3)');
  const after = await counts();
  assert(after.N === before.N && after.L === before.L && before.N > 0, `saved and loaded, the bots keep their map (${after.N} nodes, ${after.L} links)`);
}

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all nav checks passed');
process.exit(failed ? 1 : 0);
