// sql-smoke.mjs – run the game's SQL against the real Firebird WASM engine
// in Node: load the PAK and a map, play some tics, render frames, assert.
//
//   PAK=path/to/pak0.pak node scripts/sql-smoke.mjs [map]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet } from '../src/pak.js';
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

// PAK1=path/to/pak1.pak adds a second pak (the registered data, or LibreQuake's free pak1)
const pakPaths = [pakPath, process.env.PAK1 ?? path.join(path.dirname(pakPath), 'pak1.pak')].filter((f, i) => i === 0 || fs.existsSync(f));
const pak = new PakSet(pakPaths.map((f) => new Pak(fs.readFileSync(f).buffer)));
t0 = t();
const res = await loadResources(db, pak);
console.log(`resources     ${(t() - t0).toFixed(0)} ms (${res.models.size} models)`);

t0 = t();
const bsp = await loadMap(db, pak, res, mapName, { seed: 1 });   // seeded: the same random choices every run
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

// SV_WallFriction in the PSQL game (walk_move given the view's forward vector): the player at a tall wall, moving
// into it at a slant, the same tic with no input run twice, facing along the wall and facing it; facing it keeps half
// the speed along the wall (1 + d, d = normal · forward + 0.5 = -0.5), facing along it all of it
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  const box = (await db.query(`SELECT minx, miny, minz, maxx, maxy, maxz, x, y, z, yaw FROM ents WHERE id = ${pe}`)).rows[0];
  const tr = (x, y, z, dx, dy) => db.query(`SELECT fraction f, ex, ey, ez, nx, ny FROM trace_move(${pe}, ${box.MINX}, ${box.MINY}, ${box.MINZ}, ${box.MAXX}, ${box.MAXY}, ${box.MAXZ}, ${x}, ${y}, ${z}, ${x + dx}, ${y + dy}, ${z}, 0)`).then((r) => r.rows[0]);
  let w = null;
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const r = await tr(start.x, start.y, start.z, dx * 256, dy * 256), hi = await tr(start.x, start.y, start.z + 18, dx * 256, dy * 256);
    if (r.F < 1 && Math.abs(r.NX + dx) < 1e-6 && Math.abs(r.NY + dy) < 1e-6 && hi.F < 1 && Math.abs(hi.F - r.F) * 256 < 1) { w = { dx, dy, x: r.EX - dx * 4, y: r.EY - dy * 4, z: r.EZ }; break; }
  }
  // standing on the floor there (the start may still be falling)
  w.z = (await db.query(`SELECT ez FROM trace_move(${pe}, ${box.MINX}, ${box.MINY}, ${box.MINZ}, ${box.MAXX}, ${box.MAXY}, ${box.MAXZ}, ${w.x}, ${w.y}, ${w.z}, ${w.x}, ${w.y}, ${w.z - 256}, 0)`)).rows[0].EZ;
  const tx = -w.dy, ty = w.dx;
  const along = async (yaw) => {
    await db.exec(`UPDATE ents SET x = ${w.x}, y = ${w.y}, z = ${w.z}, vx = ${w.dx * 300 + tx * 100}, vy = ${w.dy * 300 + ty * 100}, vz = 0, yaw = ${yaw}, flags = BIN_OR(flags, 512) WHERE id = ${pe}`);
    await db.exec(`UPDATE player SET pitch = 0 WHERE id = 1`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
    await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
    const e = (await db.query(`SELECT vx, vy, x, y, z, flags FROM ents WHERE id = ${pe}`)).rows[0];
    return e.VX * tx + e.VY * ty;
  };
  const deg = (x, y) => Math.atan2(y, x) * 180 / Math.PI;
  const slide = await along(deg(tx, ty)), into = await along(deg(w.dx, w.dy));
  assert(w && slide > 10 && Math.abs(into / slide - 0.5) < 0.01,
    `SV_WallFriction in the PSQL game: moving into a wall, facing it keeps half the speed along it (${into.toFixed(1)} of ${slide.toFixed(1)} facing along it)`);
  await db.exec(`UPDATE ents SET x = ${box.X}, y = ${box.Y}, z = ${box.Z}, yaw = ${box.YAW}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
}

// T_Damage spends the armor and gives the push before it looks at god mode: in god mode a 50-point blast from
// below leaves the health, takes 15 of green armor (0.3 × 50) and throws the player up (50 × 8)
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  const e0 = (await db.query(`SELECT x, y, z, health, flags FROM ents WHERE id = ${pe}`)).rows[0];
  await db.exec(`UPDATE ents SET flags = BIN_OR(flags, 64), vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec('UPDATE player SET armorvalue = 100, armortype = 0.3');
  await db.exec(`INSERT INTO ents (id, classname, x, y, z) VALUES (900003, 'blast', ${e0.X}, ${e0.Y}, ${e0.Z - 40})`);
  await db.exec(`EXECUTE PROCEDURE t_damage(${pe}, 900003, 900003, 50)`);
  const e1 = (await db.query(`SELECT health, vz FROM ents WHERE id = ${pe}`)).rows[0];
  const pl = (await db.query('SELECT armorvalue av FROM player')).rows[0];
  await db.exec('DELETE FROM ents WHERE id = 900003');
  await db.exec(`UPDATE ents SET flags = ${e0.FLAGS}, vz = 0 WHERE id = ${pe}`);
  await db.exec('UPDATE player SET armorvalue = 0, armortype = 0');
  assert(e1.HEALTH === e0.HEALTH && pl.AV === 85 && Math.abs(e1.VZ - 400) < 1,
    `T_Damage in god mode: the health stays (${e1.HEALTH}), the armor is spent (${pl.AV}) and the blast throws the player (vz ${e1.VZ.toFixed(0)})`);
}

// PlayerJump comes after SV_ClientThink: the jump's own frame still has the ground's friction, so running at 300 and
// jumping with no input leaves 240 across (300 - 0.05 × 300 × 4), and 270 up less a frame's gravity
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  const e0 = (await db.query(`SELECT x, y, z, yaw FROM ents WHERE id = ${pe}`)).rows[0];
  let dir = null;
  for (const a of [0, 90, 180, 270, 45, 135, 225, 315]) {
    const r = (await db.query(`SELECT fraction f FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${e0.X}, ${e0.Y}, ${e0.Z}, ${e0.X + Math.cos(a * Math.PI / 180) * 64}, ${e0.Y + Math.sin(a * Math.PI / 180) * 64}, ${e0.Z + 16}, 0)`)).rows[0];
    if (r.F === 1) { dir = a; break; }
  }
  const z = (await db.query(`SELECT ez FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${e0.X}, ${e0.Y}, ${e0.Z}, ${e0.X}, ${e0.Y}, ${e0.Z - 64}, 0)`)).rows[0].EZ;
  const vx = Math.cos(dir * Math.PI / 180) * 300, vy = Math.sin(dir * Math.PI / 180) * 300;
  await db.exec(`UPDATE ents SET z = ${z}, vx = ${vx}, vy = ${vy}, vz = 0, flags = BIN_OR(flags, 512) WHERE id = ${pe}`);
  await db.exec('UPDATE player SET jump_released = 1');
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  await tic([1, 0, 0, 0, 0, 0, 1, 1, 0]);
  const e1 = (await db.query(`SELECT vx, vy, vz FROM ents WHERE id = ${pe}`)).rows[0];
  await db.exec(`UPDATE ents SET x = ${e0.X}, y = ${e0.Y}, z = ${e0.Z}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  for (let i = 0; i < 20; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const across = Math.hypot(e1.VX, e1.VY);
  assert(dir !== null && Math.abs(across - 240) < 0.01 && Math.abs(e1.VZ - 230) < 0.01,
    `PlayerJump after SV_ClientThink: a running jump's frame has the ground's friction (${across.toFixed(1)} across, ${e1.VZ.toFixed(1)} up)`);
}

// SV_AirMove's input as Quake's: one tic from rest on the ground reaches half the wish speed (SV_Accelerate: 10 × wish
// × 0.05). A walking strafe wishes 350, capped at 320: 160 (the walk's 200 gave 100); walking forward looking 80° down
// wishes 200 × cos(80° / 3), the body's pitch: 89.4; and backing up just after a teleport is refused
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  const e0 = (await db.query(`SELECT x, y, z, yaw FROM ents WHERE id = ${pe}`)).rows[0];
  // a flat floor near the start (on a slope, gravity clipped against it moves the player too)
  let spot = null;
  for (let r = 0; r <= 256 && !spot; r += 32) for (const [dx, dy] of [[0, 0], [r, 0], [-r, 0], [0, r], [0, -r]]) {
    const d = (await db.query(`SELECT ez, nz, fraction f, startsolid s FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${e0.X + dx}, ${e0.Y + dy}, ${e0.Z}, ${e0.X + dx}, ${e0.Y + dy}, ${e0.Z - 64}, 0)`)).rows[0];
    if (d.S === 0 && d.F < 1 && d.NZ === 1) { spot = { x: e0.X + dx, y: e0.Y + dy, z: d.EZ }; break; }
  }
  const z = spot.z;
  const oneTic = async (fwd, side, pitch, tele = false) => {
    await db.exec(`UPDATE ents SET x = ${spot.x}, y = ${spot.y}, z = ${z}, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 512),
      teleport_time = ${tele ? '(SELECT g.time_ + 1 FROM game g WHERE g.id = 1)' : 0} WHERE id = ${pe}`);
    await db.exec(`UPDATE player SET pitch = ${pitch}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
    await tic([1, fwd, side, 0, 0, 0, 0, 0, 0]);
    const e = (await db.query(`SELECT vx, vy FROM ents WHERE id = ${pe}`)).rows[0];
    return Math.hypot(e.VX, e.VY);
  };
  const strafe = await oneTic(0, 1, 0), down = await oneTic(1, 0, 80), back = await oneTic(-1, 0, 0, true);
  await db.exec(`UPDATE ents SET x = ${e0.X}, y = ${e0.Y}, z = ${e0.Z}, vx = 0, vy = 0, vz = 0, teleport_time = 0 WHERE id = ${pe}`);
  await db.exec('UPDATE player SET pitch = 0');
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  const want = 0.5 * 200 * Math.cos(80 / 3 * Math.PI / 180);
  assert(Math.abs(strafe - 160) < 0.01 && Math.abs(down - want) < 0.01 && back === 0,
    `SV_AirMove's input: a walking strafe ${strafe.toFixed(1)} (160), walking forward looking down ${down.toFixed(1)} (${want.toFixed(1)}), backing out of a teleporter ${back}`);
}

// SV_Physics_Toss's SV_CheckVelocity: something thrown at 5000 units/s across goes at sv_maxvelocity, 2000
{
  const open = (await db.query(`SELECT FIRST 1 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
    WHERE l.contents = -1 AND l.maxx - l.minx > 256 ORDER BY (l.maxx - l.minx) * (l.maxy - l.miny) DESC`)).rows[0];
  await db.exec(`INSERT INTO ents (id, classname, x, y, z, movetype, solid, vx, vy, vz) VALUES (900004, 'gib', ${open.X - 50}, ${open.Y}, ${open.Z}, 6, 0, 5000, 0, 0)`);
  await db.exec('EXECUTE PROCEDURE toss_move(900004, 0.05)');
  const g = (await db.query('SELECT x, vx FROM ents WHERE id = 900004')).rows[0];
  await db.exec('DELETE FROM ents WHERE id = 900004');
  assert(g.VX === 2000 && Math.abs(g.X - (open.X - 50 + 100)) < 1e-6, `SV_CheckVelocity: thrown at 5000 across, it goes at ${g.VX} (100 units in the tic)`);
}

// SV_CheckStuck in the PSQL game: after a tic standing free, the place is kept (player.free_*); put inside a wall, the
// player is back there the next tic
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const here = (await db.query(`SELECT x, y, z FROM ents WHERE id = ${pe}`)).rows[0];
  const kept = (await db.query('SELECT free_x x, free_y y, free_z z FROM player')).rows[0];
  let wall = null;
  for (let d = 64; d <= 1024 && !wall; d += 64) for (const [dx, dy] of [[d, 0], [-d, 0], [0, d], [0, -d]]) {
    if ((await db.query(`SELECT test_position(${pe}, ${here.X + dx}, ${here.Y + dy}, ${here.Z}) s FROM rdb$database`)).rows[0].S === 1) { wall = [here.X + dx, here.Y + dy]; break; }
  }
  await db.exec(`UPDATE ents SET x = ${wall[0]}, y = ${wall[1]}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const back = (await db.query(`SELECT x, y, z FROM ents WHERE id = ${pe}`)).rows[0];
  assert(kept.X === here.X && kept.Y === here.Y && Math.hypot(back.X - here.X, back.Y - here.Y) < 1,
    `SV_CheckStuck in the PSQL game: the free place is kept, and a player put inside a wall is back there the next tic (${back.X.toFixed(0)}, ${back.Y.toFixed(0)})`);
}

// SV_WalkMove while swimming: waist-deep in E1M1's water against a ledge a step above, moving at it (no input, so no
// water jump), the player stairs up onto it in the tic, as Quake's walk does in the water too
{
  const pe = (await db.query('SELECT player_ent() p FROM rdb$database')).rows[0].P;
  const q = (s) => db.query(s).then((r) => r.rows[0]);
  const tr = (x, y, z, dx, dy, dz = 0) => q(`SELECT fraction f, startsolid s FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${x}, ${y}, ${z}, ${x + dx}, ${y + dy}, ${z + dz}, 0)`);
  let ledge = null;
  search: for (const l of (await db.query('SELECT minx, miny, minz, maxx, maxy, maxz FROM leaves WHERE contents = -3 ORDER BY id')).rows) {
    for (let x = l.MINX + 16; x < l.MAXX; x += 32) for (let y = l.MINY + 16; y < l.MAXY; y += 32) for (let z = l.MINZ + 25; z < l.MAXZ; z += 8) {
      const c = await q(`SELECT point_contents(${x}, ${y}, ${z}) c, point_contents(${x}, ${y}, ${z + 22}) e FROM rdb$database`);
      if (c.C !== -3 || c.E !== -1 || (await tr(x, y, z, 0, 0, 0)).S) continue;          // waist deep: waterlevel 2
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const lo = await tr(x, y, z, dx * 64, dy * 64);
        if (lo.F >= 1 || lo.F * 64 < 4 || (await tr(x, y, z, 0, 0, 18)).F < 1) continue;
        if ((await tr(x, y, z + 18, dx * 64, dy * 64)).F * 64 > lo.F * 64 + 24) { ledge = { x: x + dx * (lo.F * 64 - 1), y: y + dy * (lo.F * 64 - 1), z, dx, dy }; break search; }
      }
    }
  }
  if (!ledge) console.log('(no waist-deep water against a step-high ledge in this map: the swimming step is not checked)');
  else {
  await db.exec(`UPDATE ents SET x = ${ledge.x}, y = ${ledge.y}, z = ${ledge.z}, vx = ${ledge.dx * 200}, vy = ${ledge.dy * 200}, vz = 0, yaw = ${Math.atan2(ledge.dy, ledge.dx) * 180 / Math.PI} WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const e = await q(`SELECT x, y, z, waterlevel wl FROM ents WHERE id = ${pe}`);
  const on = (e.X - ledge.x) * ledge.dx + (e.Y - ledge.y) * ledge.dy;
  assert(ledge && e.Z - ledge.z > 4 && on > 0,
    `SV_WalkMove while swimming: waist deep against a ledge, the player stairs up onto it (${(e.Z - ledge.z).toFixed(1)} up, ${on.toFixed(1)} on)`);
  }
}

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
  // the frame query's brush-model cache (vis_faces, rebuilt only when a brush entity moved) follows it
  await db.query('SELECT * FROM frame_faces_fast');
  const seen = (await db.query(`SELECT x, y, z FROM vis_ents WHERE ent_id = ${door.ID}`)).rows[0];
  // (compared here, not in SQL text: the engine's text-to-double conversion is off by an ulp)
  const at = (await db.query(`SELECT DISTINCT ox, oy, oz FROM vis_faces WHERE ent_id = ${door.ID}`)).rows;
  const same = (a, b) => Math.abs(a - b) < 1e-9;
  assert(seen && same(seen.X, d2.X) && same(seen.Y, d2.Y) && same(seen.Z, d2.Z) && at.every((r) => same(r.OX, d2.X) && same(r.OY, d2.Y) && same(r.OZ, d2.Z)),
    `the frame query saw the door move (vis_ents at its new origin; its ${at.length ? 'vis_faces rows there too' : 'faces out of the PVS'})`);
  await db.exec(`DELETE FROM ents WHERE id = ${door.ID}`);   // as a killtarget would
  await db.query('SELECT * FROM frame_faces_fast');
  const gone = (await db.query(`SELECT (SELECT COUNT(*) FROM vis_ents WHERE ent_id = ${door.ID}) + (SELECT COUNT(*) FROM vis_faces WHERE ent_id = ${door.ID}) n FROM rdb$database`)).rows[0].N;
  assert(gone === 0, 'and saw it go: no vis_ents or vis_faces row of a removed brush entity');
}

// every sound we queued exists in the pak
const snds = (await db.query('SELECT DISTINCT snd FROM sound_events')).rows.map((r) => r.SND);
const missing = snds.filter((n) => !pak.has('sound/' + n));
assert(missing.length === 0, `all queued sounds exist in the pak (${missing.join(', ') || 'none missing'})`);
// and every sound name in monster_types / the SQL exists
const refs = [...new Set([...Object.values(sql).join('\n').matchAll(/'([a-z0-9_\/]+\.wav)'/g)].map((m) => m[1]))];
// the registered episodes' monsters have sounds the shareware pak does not carry
const registeredOnly = /^(enforcer|hknight|shalrath|blob|fish|boss2)\//;
const missing2 = refs.filter((n) => !registeredOnly.test(n) && !pak.has('sound/' + n));
assert(missing2.length === 0, `all referenced sounds exist in the pak (${missing2.join(', ') || 'none missing'})`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
