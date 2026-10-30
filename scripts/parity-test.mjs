// parity-test.mjs – the two games side by side: E1M1 loaded twice with the same seed, once for the PSQL game
// (quake_tic) and once for QuakeC mode (qc_tic: id's progs.dat on the engine's physics), and the same input given
// to both, tic by tic. The PSQL game is a rewrite of progs.dat, so the player must come out the same in both: its
// place to a hundredth, its view, health, armor, ammo, weapon and the view weapon's frame, every tic. Walking,
// a ramp, strafing, wall slides, the shotgun, the nailgun held, a rocket jump, falls and a hard landing, swimming,
// drowning and slime. A scenario that parts reports the first tic and both rows.
//
//   node scripts/parity-test.mjs          (DBG=n prints both players' ents rows from tic n-4 of each scenario)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const pak = new Pak(fs.readFileSync(pakPath).buffer);
const open = async (name) => {
  const db = new FirebirdBrowser(`memory://${name}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const res = await loadResources(db, pak);
  return { db, res, q1: (s) => db.query(s).then((r) => r.rows[0]) };
};
const P = await open('psql');
await loadMap(P.db, pak, P.res, 'e1m1', { skill: 1, seed: 1 });
const Q = await open('qc');
await loadMap(Q.db, pak, Q.res, 'e1m1', { skill: 1, seed: 1 });
await loadProgs(Q.db, pak);
await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');

// no monster joins in or stands in the way: they wander by each game's own random numbers
for (const g of [P, Q]) await g.db.query("SELECT msg FROM host_cmd('notarget', '', '')");
// (after half a second, once QuakeC's items have dropped: PlaceItem runs 0.2 s in)
for (const g of [P, Q]) await g.q1(`SELECT tic FROM ${g === P ? 'quake_tic' : 'qc_tic'}(10, 0, 0, 0, 0, 0, 0, 1, 0)`);
await P.db.exec('UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL, x = x + 50000 WHERE mtype IS NOT NULL');
await Q.db.exec("UPDATE ents SET solid = 0, x = x + 50000 WHERE BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_')");
for (const g of [P, Q]) for (const r of (await g.db.query('SELECT id FROM ents WHERE x > 40000')).rows) await g.db.exec(`EXECUTE PROCEDURE link_ent(${r.ID})`);

const tic = (g, i) => g.q1(`SELECT px, py, pz, yaw, pitch - punch pitch, punch, health, armorvalue, armortype, shells, nails, rockets, cells, items, weapon, weaponframe, waterlevel, msg, dmg_pitch, dmg_roll FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, ${i.f ?? 0}, ${i.s ?? 0}, ${i.yaw ?? 0}, ${i.pitch ?? 0}, ${i.fire ?? 0}, ${i.jump ?? 0}, ${i.run ?? 1}, ${i.imp ?? 0})`);
const place = (x, y, z, vz = 0) => Promise.all([P, Q].map(async (g) => {
  await g.db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = 0, vy = 0, vz = ${vz} WHERE id = 1`);
  await g.db.exec('EXECUTE PROCEDURE link_ent(1)');
}));
const fmt = (r) => `${r.PX.toFixed(2)} ${r.PY.toFixed(2)} ${r.PZ.toFixed(2)} yaw ${r.YAW} pitch ${r.PITCH.toFixed(3)} punch ${r.PUNCH} wl ${r.WATERLEVEL} hp ${r.HEALTH} ap ${r.ARMORVALUE} at ${r.ARMORTYPE} ammo ${r.SHELLS}/${r.NAILS}/${r.ROCKETS}/${r.CELLS} items ${r.ITEMS} w ${r.WEAPON} wf ${r.WEAPONFRAME} kick ${r.DMG_PITCH.toFixed(2)}/${r.DMG_ROLL.toFixed(2)} msg ${JSON.stringify(r.MSG)}`;
let maxKick = 0;     // the largest view kick seen (V_ParseDamage), both games agreeing
// the same input to both, tic by tic: the first tic where they part, or null
const play = async (inputs) => {
  let a, b;
  for (let k = 0; k < inputs.length; k++) {
    a = await tic(P, inputs[k]); b = await tic(Q, inputs[k]);
    if (process.env.DBG && k >= +process.env.DBG - 4) { const sel = 'SELECT x, y, z, vx, vy, vz, flags, waterlevel wl FROM ents WHERE id = 1'; console.log('DBG', k, JSON.stringify(await P.q1(sel)), JSON.stringify(await Q.q1(sel))); }
    const near = Math.abs(a.PX - b.PX) < 0.01 && Math.abs(a.PY - b.PY) < 0.01 && Math.abs(a.PZ - b.PZ) < 0.01;
    if (Math.abs((((a.YAW - b.YAW) % 360) + 540) % 360 - 180) > 1e-6) return { k, a, b, why: 'YAW' };
    for (const c of ['PITCH', 'PUNCH', 'WATERLEVEL', 'HEALTH', 'ARMORVALUE', 'ARMORTYPE', 'SHELLS', 'NAILS', 'ROCKETS', 'CELLS', 'ITEMS', 'WEAPON', 'WEAPONFRAME', 'DMG_PITCH', 'DMG_ROLL']) if (Math.abs(a[c] - b[c]) > 1e-6) return { k, a, b, why: c };
    if ((a.MSG ?? '') !== (b.MSG ?? '')) return { k, a, b, why: 'MSG' };
    if (!near) return { k, a, b, why: 'position' };
    maxKick = Math.max(maxKick, Math.abs(a.DMG_PITCH), Math.abs(a.DMG_ROLL));
  }
  return { k: inputs.length, a, b, why: null };
};
const rep = (n, i) => Array.from({ length: n }, (_, k) => (typeof i === 'function' ? i(k) : i));
const check = async (name, inputs, extra = () => true) => {
  const r = await play(inputs);
  const ok = r.why === null && extra(r.a);
  assert(ok, r.why === null ? `${name}: ${inputs.length} tics, the same (${fmt(r.a)})`
    : `${name}: parted at tic ${r.k} on ${r.why}: PSQL ${fmt(r.a)} | QuakeC ${fmt(r.b)}`);
  return r.a;
};
const q = (sql) => P.q1(sql);

// ── from the start: standing, running down the ramp, strafing while turning, a running jump, walking ──
await check('walking from the start', [
  ...rep(10, {}), ...rep(20, { f: 1 }), ...rep(10, { f: 1, s: 1, yaw: 3 }),
  ...rep(10, (k) => ({ f: 1, jump: k === 2 ? 1 : 0 })), ...rep(20, { f: 1, run: 0, yaw: -5 }), ...rep(10, {}),
], (a) => a.PY > 400);

// ── backing up, sidestepping and looking down (the body's pitch is a third of the view's) ──
await check('backing, sidestepping, looking down', [
  ...rep(8, { pitch: 10 }), ...rep(15, { f: 1 }), ...rep(10, { f: -1 }), ...rep(10, { s: -1, run: 0 }),
  ...rep(8, { pitch: -10 }), ...rep(10, {}),
]);

// ── running into walls at a slant (SV_WallFriction, the slide along them) ──
for (const yaw of [20, 70, 135]) await check(`running at the wall, turned ${yaw}°`, [...rep(1, { yaw }), ...rep(30, { f: 1 }), ...rep(5, {}), ...rep(1, { yaw: -yaw })]);

// ── firing the shotgun: the shells, the weapon's frames ──
await check('firing the shotgun', [...rep(1, { fire: 1 }), ...rep(12, {}), ...rep(3, { fire: 1 }), ...rep(12, {})], (a) => a.SHELLS < 25);

// ── a weapon change during a shot (ImpulseCommands waits for attack_finished), the nailgun held and let go, a rocket at the feet (a rocket jump: the blast's fixed 120, half to oneself) ──
for (const g of [P, Q]) for (const [a1, a2] of [['4', ''], ['n', '100'], ['7', ''], ['r', '10']]) await g.db.query('SELECT msg FROM host_cmd(?, ?, ?)', ['give', a1, a2]);
await check('a weapon change waits for the shot', [{ imp: 2 }, ...rep(3, {}), { fire: 1 }, { imp: 4 }, ...rep(14, {})], (a) => a.WEAPON === 4);
await check('the nailgun', [{ imp: 4 }, ...rep(5, {}), ...rep(25, { fire: 1 }), ...rep(15, {})], (a) => a.NAILS < 100 && a.WEAPON === 4);
maxKick = 0;
await check('a rocket jump', [{ imp: 7 }, ...rep(5, {}), { pitch: 80 }, { fire: 1, jump: 1 }, ...rep(25, {}), { pitch: -80 }], (a) => a.ROCKETS === 9 && a.HEALTH < 100 && maxKick > 1);

// ── a fall from as high as the level allows onto a dry floor (the spot with the most room above it among the
// entities' places) ──
let fall = null;
let best = 0;
for (const m of (await P.db.query("SELECT ox, oy, oz FROM map_ents WHERE classname NOT STARTING WITH 'light' AND classname <> 'worldspawn' ORDER BY id")).rows) {
  const fl = await q(`SELECT ez, fraction f FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${m.OX}, ${m.OY}, ${m.OZ + 40}, ${m.OX}, ${m.OY}, ${m.OZ - 100}, 0)`);
  if (fl.F === 1) continue;
  const up = await q(`SELECT ez FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${m.OX}, ${m.OY}, ${fl.EZ}, ${m.OX}, ${m.OY}, ${fl.EZ + 600}, 0)`);
  const at = up.EZ - fl.EZ > best && await q(`SELECT test_position(1, ${m.OX}, ${m.OY}, ${fl.EZ}) t, point_contents(${m.OX}, ${m.OY}, ${fl.EZ - 20}) c FROM rdb$database`);
  if (at && at.T === 0 && at.C === -1) { best = up.EZ - fl.EZ; fall = { x: m.OX, y: m.OY, z: fl.EZ, h: Math.min(500, best - 8) }; }
}
assert(fall, `a spot with room to fall${fall ? ` (${fall.h.toFixed(0)} units)` : ''}`);
if (fall) {
  await place(fall.x, fall.y, fall.z + fall.h);
  const landed = await check(`a fall of ${fall.h.toFixed(0)}`, rep(30, {}), (a) => a.PZ === fall.z);
  // a hard landing: thrown down at 800 from 100 up (PlayerPostThink's jump_flag past -650: five points)
  await place(fall.x, fall.y, fall.z + 100, -800);
  await check('a hard landing', rep(20, {}), (a) => a.PZ === fall.z && a.HEALTH === landed.HEALTH - 5);
}

// a spot over a liquid (contents -3 water, -4 slime): free 30 above its surface, at least `depth` deep
const liquidSpot = async (contents, depth) => {
  const leaves = await P.db.query(`SELECT minx, miny, maxx, maxy, maxz FROM leaves WHERE contents = ${contents} AND maxx - minx >= 64 AND maxy - miny >= 64 ORDER BY (maxx - minx) * (maxy - miny) DESC`).then((r) => r.rows);
  for (const l of leaves) for (let fx = 0.25; fx < 1; fx += 0.25) for (let fy = 0.25; fy < 1; fy += 0.25) {
    const cx = Math.round(l.MINX + (l.MAXX - l.MINX) * fx), cy = Math.round(l.MINY + (l.MAXY - l.MINY) * fy);
    if ((await q(`SELECT point_contents(${cx}, ${cy}, ${l.MAXZ - 2}) c FROM rdb$database`)).C !== contents) continue;
    let z = l.MAXZ - 2;                                          // the surface: where the liquid ends going up
    while ((await q(`SELECT point_contents(${cx}, ${cy}, ${z + 1}) c FROM rdb$database`)).C === contents) z += 1;
    if ((await q(`SELECT test_position(1, ${cx}, ${cy}, ${z + 30}) t FROM rdb$database`)).T !== 0) continue;
    const floor = await q(`SELECT ez FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${cx}, ${cy}, ${z + 30}, ${cx}, ${cy}, ${z - 400}, 0)`);
    if (z - (floor.EZ - 24) >= depth) return { cx, cy, z, depth: z - (floor.EZ - 24) };
  }
  return null;
};

// ── swimming: into the water from above, forward, down, up, drifting, out ──
const pool = await liquidSpot(-3, 60);
assert(pool, `a pool to swim in${pool ? ` (its surface at ${pool.z}, ${pool.depth} deep)` : ''}`);
if (pool) {
  await place(pool.cx, pool.cy, pool.z + 30);
  await check('swimming', [
    ...rep(15, {}), ...rep(10, { f: 1 }), ...rep(3, { pitch: 20 }), ...rep(10, { f: 1 }), ...rep(10, { jump: 1 }),
    ...rep(3, { pitch: -20 }), ...rep(15, {}), ...rep(10, { s: 1, run: 0 }), ...rep(10, { f: 1, jump: 1 }),
  ], (a) => a.WATERLEVEL >= 0);
}

// ── under the water past the air (12 s), drowning; then out, gasping ──
if (pool) {
  for (const g of [P, Q]) await g.db.query('SELECT msg FROM host_cmd(?, ?, ?)', ['give', 'h', '100']);
  await place(pool.cx, pool.cy, pool.z - 20);
  await check('drowning', [...rep(3, { pitch: 30 }), ...rep(300, { f: 0.2, run: 0 }), ...rep(3, { pitch: -30 }), ...rep(30, { jump: 1 })], (a) => a.HEALTH < 100);
}

// ── into the slime: a bite going in, another the frame after (WaterMove clears dmgtime), then one a second ──
const slime = await liquidSpot(-4, 0);
assert(slime, 'slime to fall into');
if (slime) {
  for (const g of [P, Q]) await g.db.query('SELECT msg FROM host_cmd(?, ?, ?)', ['give', 'h', '100']);
  await place(slime.cx, slime.cy, slime.z + 30);
  await check('into the slime', [...rep(50, {}), ...rep(20, { jump: 1, f: 1 })], (a) => a.HEALTH < 100);
}

// ── walking into things: each kind of item, a door, a button, a lift, the teleporter ──
// a free floor spot `d` units from a point, with a clear walk to it; the player put there and turned to face it
const approach = async (x, y, z, id = null) => {
  for (const d of [80, 96, 64, 112, 48, 32]) for (let k = 0; k < 16; k++) {
    const a = (k * Math.PI) / 8, sx = x + Math.cos(a) * d, sy = y + Math.sin(a) * d;
    const fl = await q(`SELECT ez, fraction f FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${sx}, ${sy}, ${z + 64}, ${sx}, ${sy}, ${z - 60}, 0)`);
    if (fl.F === 1 || Math.abs(fl.EZ - (z + 24)) > 32) continue;
    // free in both worlds (their monsters stand in different places)
    if ((await q(`SELECT test_position(1, ${sx}, ${sy}, ${fl.EZ}) t FROM rdb$database`)).T !== 0) continue;
    if ((await Q.q1(`SELECT test_position(1, ${sx}, ${sy}, ${fl.EZ}) t FROM rdb$database`)).T !== 0) continue;
    // an item: a clear walk most of the way to it; a mover: the walk meets it (a door, a lift, a button) after a while
    const walk = id === null
      ? await q(`SELECT fraction f, hit_ent h FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${sx}, ${sy}, ${fl.EZ}, ${sx + (x - sx) * 0.75}, ${sy + (y - sy) * 0.75}, ${fl.EZ}, 1)`)
      : await q(`SELECT fraction f, hit_ent h FROM trace_move(1, -16, -16, -24, 16, 16, 32, ${sx}, ${sy}, ${fl.EZ}, ${x}, ${y}, ${fl.EZ}, 1)`);
    if (id === null ? walk.F < 1 : walk.H !== id || walk.F < 0.2) continue;
    await place(sx, sy, fl.EZ);
    const yaw = (await tic(P, {})).YAW; await tic(Q, {});
    let turn = (Math.atan2(y - sy, x - sx) * 180) / Math.PI - yaw;
    turn = ((turn % 360) + 540) % 360 - 180;
    return turn;
  }
  return null;
};
// the items of a kind still there (not taken, and in single player: not deathmatch-only)
const spots = async (cls) => (await P.db.query(`SELECT x ox, y oy, z oz FROM ents WHERE classname = '${cls}' AND solid = 1 ORDER BY id`)).rows;
for (const g of [P, Q]) await g.db.query('SELECT msg FROM host_cmd(?, ?, ?)', ['god', '', '']);
for (const cls of ['item_health', 'item_shells', 'item_spikes', 'item_rockets', 'item_armor1', 'item_armor2', 'weapon_supershotgun', 'weapon_nailgun',
  'weapon_supernailgun', 'weapon_grenadelauncher', 'weapon_rocketlauncher', 'item_artifact_envirosuit', 'item_artifact_super_damage', 'item_artifact_invulnerability']) {
  let done = false;
  const ms = await spots(cls);
  if (!ms.length) { console.log(`--   no ${cls} in single player here`); continue; }
  for (const m of ms) {
    for (const g of [P, Q]) await g.db.exec(`UPDATE ents SET health = 60 WHERE id = 1`);
    if (Q) await Q.db.exec("EXECUTE PROCEDURE qc_sf(1, qc_fdef('health'), 60)");
    const mt0 = (await P.q1('SELECT msg_time t FROM player')).T;
    const turn = await approach(m.OX + 16 * (cls.startsWith('item_') && !cls.includes('armor') && !cls.includes('artifact')), m.OY + 16 * (cls.startsWith('item_') && !cls.includes('armor') && !cls.includes('artifact')), m.OZ);
    if (turn === null) continue;
    // walked into it: the pickup's message printed (the PSQL game's msg_time moves on)
    const before = failed;
    await check(`picking up ${cls}`, [{ yaw: turn }, ...rep(14, { f: 1, run: 0 }), ...rep(cls === 'item_health' ? 160 : 6, {})]);
    if (failed > before) { done = true; break; }       // parted: reported
    if ((await P.q1('SELECT msg_time t FROM player')).T === mt0) continue;   // walked past it: the next one
    done = true;
    break;
  }
  if (!done) console.log(`--   no way found to walk into ${cls} (${ms.length} of them)`);
}

// doors, buttons, the lifts and the teleporter: walked into from 96 units off, and on for 3 s
for (const cls of ['func_door', 'func_button', 'func_plat', 'trigger_teleport']) {
  const ms = (await P.db.query(`SELECT x + (minx + maxx) / 2 ox, y + (miny + maxy) / 2 oy, z + minz oz, id FROM ents WHERE classname = '${cls}' ORDER BY id`)).rows;
  let n = 0;
  for (const m of ms) {
    if (n >= 2) break;
    const turn = await approach(m.OX, m.OY, m.OZ, cls === 'trigger_teleport' ? null : m.ID);
    if (turn === null) continue;
    // set off: a door or button that moves (or a lift that goes), or the teleporter that sends the player on
    const at = async () => JSON.stringify(await P.q1(`SELECT x, y, z, mv_state FROM ents e WHERE id = ${m.ID}`));
    const p0 = await at(), q0 = await P.q1('SELECT x, y FROM ents WHERE id = 1');
    let moved = false;
    const r = await check(`walking into ${cls} ${n + 1}`, [{ yaw: turn }, ...rep(30, { f: 1, run: 0 }), ...rep(30, {})], () => true);
    moved = cls === 'trigger_teleport' ? Math.hypot(r.PX - q0.X, r.PY - q0.Y) > 300 : (await at()) !== p0;
    if (!moved) { console.log(`--   ${cls} ${m.ID} did not move: another`); continue; }
    n++;
  }
  if (!n) console.log(`--   no way found to walk into ${cls}`);
}

if (failed) { console.error(`\n${failed} check(s) failed`); process.exit(1); }
console.log('\nall parity checks passed');
process.exit(0);
