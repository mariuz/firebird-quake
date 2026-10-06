// sql-smoke.mjs – run the game's SQL against the real Firebird WASM engine
// in Node: load the PAK and a map, play some tics, render frames, assert.
//
//   PAK=path/to/pak0.pak node scripts/sql-smoke.mjs [map]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const mapName = process.argv[2] ?? 'e1m1';
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
function assert(cond, msg) {
  if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`);
}
const t = () => performance.now();
const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });

let t0 = t();
await createSchema(db, sql);
console.log(`schema        ${(t() - t0).toFixed(0)} ms`);

const pak = new Pak(fs.readFileSync(pakPath).buffer);
t0 = t();
const res = await loadResources(db, pak);
console.log(`resources     ${(t() - t0).toFixed(0)} ms (${res.models.size} models)`);

t0 = t();
const bsp = await loadMap(db, pak, res, mapName);
console.log(`map ${mapName}      ${(t() - t0).toFixed(0)} ms`);

const counts = (await db.query(
  `SELECT (SELECT COUNT(*) FROM faces) f, (SELECT COUNT(*) FROM face_verts) fv, (SELECT COUNT(*) FROM leaves) l,
          (SELECT COUNT(*) FROM hulls) h, (SELECT COUNT(*) FROM ents) e, (SELECT COUNT(*) FROM ents WHERE mtype IS NOT NULL) m,
          (SELECT COUNT(*) FROM ents WHERE leaf IS NULL AND solid <> 0) nolink
     FROM rdb$database`)).rows[0];
console.log(counts);
assert(counts.F > 0 && counts.L > 0, 'map geometry loaded');
assert(counts.M > 0, `monsters spawned (${counts.M})`);

const tic = (args) => db.query('SELECT * FROM quake_tic(?, ?, ?, ?, ?, ?, ?, ?, ?)', args).then((r) => r.rows[0]);
let s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
console.log('start', { x: s.PX, y: s.PY, z: s.PZ, yaw: s.YAW, leaf: s.LEAF, health: s.HEALTH, msg: s.LEVEL_MSG });
assert(s.LEAF > 0, 'player stands in a non-solid leaf');
const start = { x: s.PX, y: s.PY, z: s.PZ };

t0 = t();
for (let i = 0; i < 20; i++) s = await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]);
console.log(`20 tics walking ${(t() - t0).toFixed(0)} ms`, { x: s.PX, y: s.PY, z: s.PZ });
const moved = Math.hypot(s.PX - start.x, s.PY - start.y);
assert(moved > 50, `player walked forward (${moved.toFixed(1)} units)`);
assert(Math.abs(s.PZ - start.z) < 64, `player stayed on the floor (dz ${(s.PZ - start.z).toFixed(1)})`);

t0 = t();
s = await tic([1, 0, 0, 0, 0, 1, 0, 1, 0]);
console.log(`fire            ${(t() - t0).toFixed(0)} ms; shells ${s.SHELLS}`);
assert(s.SHELLS === 24, 'shotgun consumed a shell');
const fired = (await db.query("SELECT COUNT(*) n FROM sound_events WHERE snd = 'weapons/guncock.wav'")).rows[0].N;
assert(fired > 0, 'firing queued the shotgun sound');

for (let i = 0; i < 3; i++) {
  t0 = t();
  const faces = await db.query('SELECT * FROM frame_faces', [], { rowMode: 'array' });
  const t1 = t();
  const ents = await db.query('SELECT * FROM frame_ents', [], { rowMode: 'array' });
  const t2 = t();
  const nf = new Set(faces.rows.map((r) => r[0])).size;
  console.log(`frame ${i}: ${faces.rows.length} vertex rows / ${nf} faces in ${(t1 - t0).toFixed(0)} ms, ${ents.rows.length} ents in ${(t2 - t1).toFixed(0)} ms`);
  if (i === 0) assert(nf > 20, `the frame has faces (${nf})`);
  await tic([1, 0, 0, 45, 0, 0, 0, 1, 0]);
}

// a full turn: every heading has geometry
for (let a = 0; a < 4; a++) {
  await tic([1, 0, 0, 90, 0, 0, 0, 1, 0]);
  const r = (await db.query('SELECT COUNT(DISTINCT face) c FROM frame_faces')).rows[0].C;
  assert(r > 10, `heading +${(a + 1) * 90}°: ${r} faces`);
}

// monsters think: run 40 tics and see that the state machine runs without error
t0 = t();
for (let i = 0; i < 20; i++) s = await tic([2, 0, 0, 0, 0, 0, 0, 1, 0]);
console.log(`40 tics idle    ${(t() - t0).toFixed(0)} ms`);
const mon = (await db.query("SELECT st, COUNT(*) n FROM ents WHERE mtype IS NOT NULL GROUP BY st")).rows;
console.log('monster states', mon);

// cheat, then rocket the floor: radius damage must hurt us
s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 9]);
assert(s.ROCKETS === 100, 'impulse 9 gave ammo');
await tic([1, 0, 0, 0, 0, 0, 0, 1, 7]);
s = await tic([1, 0, 0, 0, 80, 1, 0, 1, 0]);
for (let i = 0; i < 10; i++) s = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
assert(s.HEALTH < 100, `rocket at our feet hurt us (health ${s.HEALTH})`);

// teleport a door into view: open the first door by firing it
const door = (await db.query("SELECT FIRST 1 id, z, p2z, p2x, p2y FROM ents WHERE classname = 'func_door'")).rows[0];
if (door) {
  await db.exec(`EXECUTE PROCEDURE door_fire(${door.ID}, ${(await db.query('SELECT ent_id FROM player')).rows[0].ENT_ID})`);
  for (let i = 0; i < 30; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const d2 = (await db.query(`SELECT x, y, z, mv_state FROM ents WHERE id = ${door.ID}`)).rows[0];
  assert(d2 && (Math.abs(d2.Z - door.Z) > 1 || Math.abs(d2.X) > 1 || Math.abs(d2.Y) > 1), `door moved (state ${d2?.MV_STATE})`);
}

// every sound we queued exists in the pak
const snds = (await db.query('SELECT DISTINCT snd FROM sound_events')).rows.map((r) => r.SND);
const missing = snds.filter((n) => !pak.has('sound/' + n));
assert(missing.length === 0, `all queued sounds exist in the pak (${missing.join(', ') || 'none missing'})`);
// and every sound name in monster_types / game.sql exists
const refs = [...new Set([...Object.values(sql).join('\n').matchAll(/'([a-z0-9_\/]+\.wav)'/g)].map((m) => m[1]))];
// the registered episodes' monsters have sounds the shareware pak does not carry
const registeredOnly = /^(enforcer|hknight|shalrath|blob|fish|boss2)\//;
const missing2 = refs.filter((n) => !registeredOnly.test(n) && !pak.has('sound/' + n));
assert(missing2.length === 0, `all referenced sounds exist in the pak (${missing2.join(', ') || 'none missing'})`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
