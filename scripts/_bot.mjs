import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const res = await loadResources(db, pak); await loadMap(db, pak, res, 'e1m1');
const tic = (a) => db.query('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a).then((r) => r.rows[0]);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const qa = (s) => db.query(s).then((r) => r.rows);
const teleport = async (x, y, z, yaw) => { await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = (SELECT ent_id FROM player)`); await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))'); };
let s;
// 1. a grunt fight: stand 160 units from grunt 68, facing it
await teleport(160, 576, 48, 180);
s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
for (let i = 0; i < 20; i++) s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
let g = await q1('SELECT st, enemy_id, health, anim, frame FROM ents WHERE id = 68');
console.log('grunt after 1 s in view:', g);
let shots = 0;
for (let i = 0; i < 100; i++) {
  const gg = await q1('SELECT x, y, z, st, health FROM ents WHERE id = 68');
  if (!gg || gg.HEALTH <= 0 || gg.ST === 'die' || gg.ST === 'dead') { console.log(`grunt ${gg?.ST ?? 'gone'} after ${shots} shots, ${i} tics`); break; }
  const yaw = Math.atan2(gg.Y - s.PY, gg.X - s.PX) * 180 / Math.PI;
  const pitch = -Math.atan2(gg.Z + 8 - s.VIEW_Z, Math.hypot(gg.X - s.PX, gg.Y - s.PY)) * 180 / Math.PI;
  s = await tic([1, 0, 0, yaw - s.YAW, pitch - s.PITCH, 1, 0, 1, 0]);
  shots++;
}
console.log('player health', s.HEALTH, 'shells', s.SHELLS, 'kills', s.KILLED, '/', s.TOTAL_MONSTERS, 'dmg_take', s.DMG_TAKE);
console.log('sounds', (await qa('SELECT snd, COUNT(*) n FROM sound_events GROUP BY snd ORDER BY n DESC')).map((r) => `${r.SND}×${r.N}`).join(' '));
console.log('fx', (await qa('SELECT kind, COUNT(*) n FROM fx_events GROUP BY kind')).map((r) => `${r.KIND}×${r.N}`).join(' '));
for (let i = 0; i < 30; i++) s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
console.log('grunt final', await q1('SELECT st, health, frame, anim FROM ents WHERE id = 68'));
const bp = await q1("SELECT x, y, z, ammo_shells FROM ents WHERE classname = 'backpack'");
console.log('backpack', bp);
if (bp) {
  await teleport(bp.X, bp.Y, bp.Z + 30, 0);
  for (let i = 0; i < 10; i++) s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  console.log('after backpack: shells', s.SHELLS, 'msg', s.MSG, 'left:', (await qa("SELECT COUNT(*) n FROM ents WHERE classname = 'backpack'"))[0].N);
}
// 2. a plain door: stand 100 units in front of door 2 (centre 232,564,64)
const d = await q1('SELECT id, x + (minx + maxx) / 2 cx, y + (miny + maxy) / 2 cy, z + (minz + maxz) / 2 cz, minx, maxx, miny, maxy, minz, maxz, mv_state, p2x, p2y, p2z FROM ents WHERE id = 2');
console.log('door 2', d);
// the door spans x 200..264? find an empty spot near it
const head = (await q1('SELECT m.hull1 h FROM models m JOIN game g ON g.world_model = m.id')).H;
for (const [dx, dy] of [[0, -120], [0, 120], [-120, 0], [120, 0]]) {
  const x = d.CX + dx, y = d.CY + dy, z = d.CZ + 10;
  const c = (await q1(`SELECT hull_contents(1, ${head}, ${x}, ${y}, ${z}) c FROM rdb$database`)).C;
  if (c !== -1) continue;
  await teleport(x, y, z, Math.atan2(-dy, -dx) * 180 / Math.PI);
  s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  console.log('standing at', x, y, z, 'leaf', s.LEAF);
  for (let i = 0; i < 40; i++) s = await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]);
  const d2 = await q1('SELECT mv_state, CAST(x AS INTEGER) x, CAST(y AS INTEGER) y, CAST(z AS INTEGER) z FROM ents WHERE id = 2');
  console.log('door after walking at it:', d2, 'player', s.PX.toFixed(0), s.PY.toFixed(0), s.PZ.toFixed(0));
  break;
}
console.log('door sounds', (await qa("SELECT snd, COUNT(*) n FROM sound_events WHERE snd LIKE 'doors/%' GROUP BY snd")).map((r) => `${r.SND}×${r.N}`).join(' '));
// 3. an item: health box
const it = await q1("SELECT id, classname, x, y, z FROM ents WHERE classname = 'item_health' ROWS 1");
await teleport(it.X + 16, it.Y + 16, it.Z + 30, 0);
await db.exec('UPDATE ents SET health = 50 WHERE id = (SELECT ent_id FROM player)');
for (let i = 0; i < 10; i++) s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
console.log('health after box:', s.HEALTH, 'msg', s.MSG);
// 4. keep running the whole level for 200 tics with monsters awake: any errors?
await db.exec("UPDATE ents SET enemy_id = (SELECT ent_id FROM player), st = 'run', anim = NULL WHERE mtype IS NOT NULL AND st IN ('stand', 'walk')");
const t0 = performance.now();
for (let i = 0; i < 100; i++) s = await tic([2, 0, 0, 0, 0, 0, 0, 1, 0]);
console.log('200 tics with all monsters chasing:', (performance.now() - t0).toFixed(0), 'ms; health', s.HEALTH, 'states', (await qa("SELECT st, COUNT(*) n FROM ents WHERE mtype IS NOT NULL GROUP BY st")).map((r) => `${r.ST}:${r.N}`).join(' '));
console.log('monster positions moved:', (await qa("SELECT COUNT(*) n FROM ents WHERE mtype IS NOT NULL AND (ABS(x - spawn_x) > 10 OR ABS(y - spawn_y) > 10)"))[0].N);
await db.close(); process.exit(0);
