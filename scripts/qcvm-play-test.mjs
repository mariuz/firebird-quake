// qcvm-play-test.mjs – E1M1 played by the original progs.dat on the engine's
// physics: QuakeC mode (qc_enter) keeps every edict's engine fields in ents,
// so the traces, the pushers, the step and toss physics and the renderer work
// on QuakeC entities. The spawned world settles, the player falls, walks,
// opens a door through its trigger field, picks up shells by walking over
// them, and fires a rocket that flies and explodes against a wall; a grunt
// shows up in the renderer's frame query.
//
//   node scripts/qcvm-play-test.mjs

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

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await loadProgs(db, pak);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const fld = (ent, name, k = 0) => q1(`SELECT qc_f(${ent ?? -1}, qc_fdef('${name}') + ${k}) v FROM rdb$database`).then((r) => r.V);
const setf = (ent, name, v, k = 0) => db.exec(`EXECUTE PROCEDURE qc_sf(${ent}, qc_fdef('${name}') + ${k}, ${v})`);
const str = (ofs) => q1(`SELECT qc_str(${ofs ?? 0}) s FROM rdb$database`).then((r) => r.S);
const fname = async (v) => (await q1(`SELECT name FROM qc_functions WHERE id = ${v ?? -1}`))?.NAME;
const ent = (id) => q1(`SELECT * FROM ents WHERE id = ${id}`);
const modelId = (name) => q1(`SELECT id FROM models WHERE name = '${name}'`).then((r) => r?.ID);
const byClass = (cls) => qa(`SELECT f.ent FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0 WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = '${cls}' ORDER BY f.ent`).then((r) => r.map((x) => x.ENT));
const log = (kind) => qa(`SELECT msg FROM qc_log WHERE kind = '${kind}' ORDER BY id`).then((r) => r.map((x) => x.MSG));
const errors = () => log('error');
const box = [-16, -16, -24, 16, 16, 32];
const traceBox = (x1, y1, z1, x2, y2, z2) => q1(`SELECT fraction f, ex, ey, ez FROM trace_move(1, ${box.join(', ')}, ${x1}, ${y1}, ${z1}, ${x2}, ${y2}, ${z2}, 0)`);
const clear = (x, y, z) => q1(`SELECT test_position(1, ${x}, ${y}, ${z}) t FROM rdb$database`).then((r) => r.T === 0);
const place = async (x, y, z, yaw) => {
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = 0, vy = 0, vz = 0, yaw = ${yaw} WHERE id = 1`);
  await db.exec('EXECUTE PROCEDURE link_ent(1)');
  view.yaw = yaw;
};
const yawTo = (dx, dy) => (Math.atan2(dy, dx) * 180) / Math.PI;

// ── QuakeC mode, E1M1 spawned by its own progs ───────────────────────────
await db.exec('EXECUTE PROCEDURE qc_enter');
assert((await q1('SELECT qc_mode m FROM game')).M === 1, 'QuakeC mode: the VM owns ents');
const sp = await q1('SELECT * FROM qc_spawn_map(1, 1.0)');
await db.exec('EXECUTE PROCEDURE qc_client_connect(1.0)');
assert(sp.FAILED === 0 && (await errors()).length === 0, `qc_spawn_map: ${sp.SPAWNED} spawn functions ran, none failed`);
const unmirrored = (await q1('SELECT COUNT(*) n FROM qc_edicts d WHERE d.free = 0 AND d.id > 0 AND NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = d.id)')).N;
const orphans = (await q1('SELECT COUNT(*) n FROM ents e WHERE NOT EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = e.id AND d.free = 0)')).N;
const nEnts = (await q1('SELECT COUNT(*) n FROM ents')).N;
assert(unmirrored === 0 && orphans === 0, `every live edict but the world has its ents row and nothing else does (${nEnts} rows)`);
const doors = await byClass('door');
const d0 = await ent(doors[0]);
const dModel = await str(await fld(doors[0], 'model'));
assert(doors.length > 0 && d0.SOLID === 4 && d0.MOVETYPE === 7 && d0.MODEL_ID === (await modelId(dModel)), `${doors.length} doors are SOLID_BSP pushers in ents, with their brush models (${dModel})`);

let t = 1.0;
const DT = 0.1;
const view = { pitch: 0, yaw: (await ent(1)).YAW };
let frameMs = [];
const frame = async (o = {}) => {
  const t0 = performance.now();
  const r = await q1(`SELECT * FROM qc_server_frame(${t}, ${DT}, ${o.f ?? 0}, ${o.s ?? 0}, 0, ${o.pitch ?? view.pitch}, ${o.yaw ?? view.yaw}, ${o.fire ?? 0}, ${o.jump ?? 0}, ${o.imp ?? 0})`);
  frameMs.push(performance.now() - t0);
  t = Math.round((t + DT) * 1000) / 1000;
  if (r.FAILED) for (const m of (await errors()).slice(-3)) console.log('   ', m.split('\n')[0]);
  return r;
};

// ── the world settles ─────────────────────────────────────────────────────
let fails = 0;
for (let i = 0; i < 4; i++) fails += (await frame()).FAILED;
assert(fails === 0, `four server frames, nothing failed (${frameMs.map((m) => m.toFixed(0)).join(', ')} ms)`);
const shells = (await byClass('item_shells'))[0];
const sh = await ent(shells);
const shMap = await q1("SELECT oz FROM map_ents WHERE classname = 'item_shells' ORDER BY id");
assert(sh.SOLID === 1 && (sh.FLAGS & 512) && (sh.FLAGS & 256) && /^maps\/b_shell/.test(await str(await fld(shells, 'model'))) && sh.MODEL_ID > 0, 'PlaceItem: the shells are an FL_ITEM trigger, dropped onto the floor by droptofloor, with their box model');
const grunt = (await byClass('monster_army'))[0];
const gr = await ent(grunt);
assert(gr.SOLID === 3 && gr.MOVETYPE === 4 && (gr.FLAGS & 512) && gr.MODEL_ID === (await modelId('progs/soldier.mdl')) && gr.FRAME >= 0 && gr.FRAME <= 7, `walkmonster_start_go: a grunt stands on the floor (SOLID_SLIDEBOX, MOVETYPE_STEP, soldier.mdl, frame ${gr.FRAME})`);
// this test is about the physics: from here the monsters stand still (their thinks stop), as they did before checkclient
// and movetogoal let them see and chase; scripts/qcvm-ai-test.mjs plays them
for (const m of (await qa('SELECT id FROM ents WHERE BIN_AND(flags, 32) <> 0')).map((x) => x.ID)) await setf(m, 'nextthink', 0);
const spot = await q1("SELECT ox, oy, oz FROM map_ents WHERE classname = 'info_player_start'");
let pl = await ent(1);
assert(pl.MODEL_ID === (await modelId('progs/player.mdl')) && pl.SOLID === 3 && pl.MOVETYPE === 3 && (pl.FLAGS & 512) && Math.abs(pl.Z - spot.OZ) < 1.5, `the player stands on the start (z ${pl.Z.toFixed(1)}, spot ${spot.OZ}), MOVETYPE_WALK, on the ground`);

// ── gravity ───────────────────────────────────────────────────────────────
const up = await traceBox(pl.X, pl.Y, pl.Z, pl.X, pl.Y, pl.Z + 128);
const lift = Math.floor(up.EZ - pl.Z) - 1;
await place(pl.X, pl.Y, pl.Z + lift, view.yaw);
let landed = 0;
for (let i = 0; i < 20 && !landed; i++) { await frame(); pl = await ent(1); if (pl.FLAGS & 512) landed = i + 1; }
const fallT = Math.sqrt(2 * lift / 800);
assert(lift > 32 && landed > 0 && Math.abs(landed * DT - fallT) <= 0.15 && Math.abs(pl.Z - spot.OZ) < 1.5, `lifted ${lift} units (to just under the ceiling), the player lands after ${landed} frames (a fall of ${fallT.toFixed(2)} s under 800 gravity)`);

// ── walking: friction, acceleration, the step ────────────────────────────
let best = { d: 0, yaw: 0 };
for (let a = 0; a < 360; a += 45) {
  const r = await traceBox(pl.X, pl.Y, pl.Z, pl.X + Math.cos(a * Math.PI / 180) * 600, pl.Y + Math.sin(a * Math.PI / 180) * 600, pl.Z);
  if (r.F * 600 > best.d) best = { d: r.F * 600, yaw: a };
}
view.yaw = best.yaw;
const w0 = await ent(1);
for (let i = 0; i < 8; i++) await frame({ f: 400 });
pl = await ent(1);
const walked = (pl.X - w0.X) * Math.cos(best.yaw * Math.PI / 180) + (pl.Y - w0.Y) * Math.sin(best.yaw * Math.PI / 180);
const speed = Math.hypot(pl.VX, pl.VY);
// full speed after the first frame (sv_accelerate 10 × 0.1 s × 320), 256 units on flat ground; a slope turns some
// of the gravity pulled into the floor each frame into speed, as in Quake
assert(walked > 200 && walked <= 0.8 * 345 && speed > 300 && speed < 345 && (pl.FLAGS & 512), `walking forward for 0.8 s at yaw ${best.yaw} covers ${walked.toFixed(0)} units on the ground at ${speed.toFixed(0)} units/s (sv_maxspeed 320)`);
// released: ground friction (sv_friction 4, sv_stopspeed 100) takes the run out in a few frames; on a slope what
// is left is NetQuake's creep, gravity's pull into the floor clipped along it each frame (small at 72 Hz, 1-2 units
// a frame at this 0.1 s frame)
const speeds = [];
for (let i = 0; i < 7; i++) { await frame(); pl = await ent(1); speeds.push(Math.hypot(pl.VX, pl.VY)); }
const settled = speeds.findIndex((v) => v < 25) + 1;
// each frame: above sv_stopspeed the speed keeps 1 - 0.1 × 4 = 60 %, below it loses 0.1 × 100 × 4 = 40; the slope gives back its creep
const creep = speeds[speeds.length - 1];
const fits = speeds.slice(1).every((v, i) => Math.abs(v - (Math.max(0, speeds[i] - 0.1 * Math.max(speeds[i], 100) * 4) + creep)) < 2);
assert(settled > 0 && fits && creep < 25, `released, friction brings the run down to the slope's creep in ${settled} frames, each step Quake's (${speeds.map((v) => v.toFixed(0)).join(' → ')} units/s)`);

// ── a door, opened by its trigger field ──────────────────────────────────
const fields = await qa("SELECT e.id, e.owner_id o, e.x + e.minx x0, e.x + e.maxx x1, e.y + e.miny y0, e.y + e.maxy y1, e.z + e.minz z0, e.z + e.maxz z1 FROM ents e WHERE e.solid = 1 AND qc_f(e.id, qc_fdef('touch')) = qc_fn('door_trigger_touch')");
assert(fields.length > 0, `LinkDoors spawned ${fields.length} door trigger fields`);
fields.sort((a, b) => Math.hypot((a.X0 + a.X1) / 2 - spot.OX, (a.Y0 + a.Y1) / 2 - spot.OY) - Math.hypot((b.X0 + b.X1) / 2 - spot.OX, (b.Y0 + b.Y1) / 2 - spot.OY));
let door = null, stand = null;
for (const fd of fields) {
  const dr = await q1(`SELECT e.x + e.minx x0, e.x + e.maxx x1, e.y + e.miny y0, e.y + e.maxy y1, e.z + e.minz z0, e.z + e.maxz z1 FROM ents e WHERE e.id = ${fd.O}`);
  const mv = [await fld(fd.O, 'pos2', 0) - await fld(fd.O, 'pos1', 0), await fld(fd.O, 'pos2', 1) - await fld(fd.O, 'pos1', 1)];
  const cx = (dr.X0 + dr.X1) / 2, cy = (dr.Y0 + dr.Y1) / 2;
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const x = dx ? cx + dx * ((dr.X1 - dr.X0) / 2 + 40) : cx, y = dy ? cy + dy * ((dr.Y1 - dr.Y0) / 2 + 40) : cy;
    if (x < fd.X0 + 17 || x > fd.X1 - 17 || y < fd.Y0 + 17 || y > fd.Y1 - 17) continue;           // inside the trigger field
    // outside the door's swept box, open or shut
    const sx0 = dr.X0 + Math.min(0, mv[0]), sx1 = dr.X1 + Math.max(0, mv[0]), sy0 = dr.Y0 + Math.min(0, mv[1]), sy1 = dr.Y1 + Math.max(0, mv[1]);
    if (x + 16 > sx0 && x - 16 < sx1 && y + 16 > sy0 && y - 16 < sy1) continue;
    const down = await traceBox(x, y, dr.Z1 - 8, x, y, dr.Z0 - 64);
    if (down.F >= 1 || !(await clear(x, y, down.EZ))) continue;
    stand = { x, y, z: down.EZ }; break;
  }
  if (stand) { door = { id: fd.O, ...dr }; break; }
}
assert(!!stand, `a spot inside a door's trigger field, clear of the door's sweep (door edict ${door?.id})`);
const STATE_TOP = 0, STATE_BOTTOM = 1, STATE_UP = 2;
assert((await fld(door.id, 'state')) === STATE_BOTTOM, 'the door is shut (STATE_BOTTOM)');
const dStart = await ent(door.id);
await place(stand.x, stand.y, stand.z, yawTo((door.X0 + door.X1) / 2 - stand.x, (door.Y0 + door.Y1) / 2 - stand.y));
await frame();
const dMoving = await ent(door.id);
assert((await fld(door.id, 'state')) === STATE_UP && Math.hypot(dMoving.VX, dMoving.VY, dMoving.VZ) > 0, `standing in the field: door_trigger_touch → door_use → door_go_up, the door moves (velocity ${[dMoving.VX, dMoving.VY, dMoving.VZ].map((v) => v.toFixed(0)).join(' ')})`);
assert((await log('sound')).some((m) => m.startsWith(`${door.id} `)), 'with its sound');
let top = 0;
for (let i = 0; i < 60 && !top; i++) { await frame(); if ((await fld(door.id, 'state')) === STATE_TOP) top = i + 1; }
const dOpen = await ent(door.id);
const moved = Math.hypot(dOpen.X - dStart.X, dOpen.Y - dStart.Y, dOpen.Z - dStart.Z);
const expect = Math.hypot(await fld(door.id, 'pos2', 0) - await fld(door.id, 'pos1', 0), await fld(door.id, 'pos2', 1) - await fld(door.id, 'pos1', 1), await fld(door.id, 'pos2', 2) - await fld(door.id, 'pos1', 2));
assert(top > 0 && Math.abs(moved - expect) < 0.5 && Math.hypot(dOpen.VX, dOpen.VY, dOpen.VZ) === 0, `the pusher runs on its own clock to pos2 (${moved.toFixed(1)} of ${expect.toFixed(1)} units), SUB_CalcMoveDone at ltime ${dOpen.LTIME.toFixed(2)}, door_hit_top: STATE_TOP after ${top} frames`);

// ── shells picked up by walking over them ────────────────────────────────
const shBox = await ent(shells);
let approach = null;
for (let a = 0; a < 360 && !approach; a += 45) {
  const x = shBox.X + 16 + Math.cos(a * Math.PI / 180) * 96, y = shBox.Y + 16 + Math.sin(a * Math.PI / 180) * 96;
  const down = await traceBox(x, y, shBox.Z + 48, x, y, shBox.Z - 64);
  if (down.F >= 1 || !(await clear(x, y, down.EZ))) continue;
  const path = await traceBox(x, y, down.EZ, shBox.X + 16, shBox.Y + 16, down.EZ);
  if (path.F < 0.99) continue;
  approach = { x, y, z: down.EZ, yaw: yawTo(shBox.X + 16 - x, shBox.Y + 16 - y) };
}
assert(!!approach, 'a clear run-up to a box of shells');
const ammo0 = await fld(1, 'ammo_shells');
await place(approach.x, approach.y, approach.z, approach.yaw);
let got = 0;
for (let i = 0; i < 10 && !got; i++) { await frame({ f: 400 }); if ((await fld(1, 'ammo_shells')) > ammo0) got = i + 1; }
const shAfter = await ent(shells);
assert(got > 0 && (await fld(1, 'ammo_shells')) === ammo0 + 20, `walking over the shells picks them up after ${got} frames (${ammo0} → ${await fld(1, 'ammo_shells')}, SV_TouchLinks → ammo_touch)`);
assert(shAfter.SOLID === 0 && shAfter.MODEL_ID === null && (await log('sprint')).join('').includes('You got the shells'), 'the box is gone from the floor, "You got the shells"');
for (let i = 0; i < 4; i++) await frame();

// ── a rocket against a wall ───────────────────────────────────────────────
await frame({ imp: 9 });
await frame();
assert((await fld(1, 'weapon')) === 32, 'impulse 9: the rocket launcher in hand');
pl = await ent(1);
let aimYaw = null;
for (let a = 0; a < 360; a += 15) {
  const r = await q1(`SELECT fraction f FROM trace_move(1, 0, 0, 0, 0, 0, 0, ${pl.X}, ${pl.Y}, ${pl.Z + 16}, ${pl.X + Math.cos(a * Math.PI / 180) * 2000}, ${pl.Y + Math.sin(a * Math.PI / 180) * 2000}, ${pl.Z + 16}, 0)`);
  if (r.F * 2000 > 300 && r.F * 2000 < 1500) { aimYaw = a; break; }
}
assert(aimYaw !== null, `a wall between 300 and 1500 units away (yaw ${aimYaw})`);
view.yaw = aimYaw;
const rockets0 = (await q1('SELECT ammo_rockets FROM rdb$database CROSS JOIN (SELECT qc_f(1, qc_fdef(\'ammo_rockets\')) ammo_rockets FROM rdb$database)')).AMMO_ROCKETS;
await frame({ fire: 1 });
const missile = (await byClass('missile'))[0];
const m0 = missile ? await ent(missile) : null;
assert(!!missile && m0.MOVETYPE === 9 && m0.SOLID === 2 && m0.OWNER_ID === 1 && m0.MODEL_ID === (await modelId('progs/missile.mdl')) && Math.abs(Math.hypot(m0.VX, m0.VY, m0.VZ) - 1000) < 1, `W_FireRocket: a missile, MOVETYPE_FLYMISSILE at 1000 units/s, owned by the player (${(await fld(1, 'ammo_rockets'))} of ${rockets0} rockets left)`);
let boom = 0, mx = m0.X, my = m0.Y;
for (let i = 0; i < 20 && !boom; i++) {
  await frame();
  const m = await ent(missile);
  if (!m || m.MODEL_ID === (await modelId('progs/s_explod.spr'))) boom = i + 1; else { mx = m.X; my = m.Y; }
}
const flew = Math.hypot(mx - pl.X, my - pl.Y);
assert(boom > 0 && flew > 250, `it flies ${flew.toFixed(0)} units and explodes against the wall after ${boom} frames (T_MissileTouch → BecomeExplosion: the explosion sprite)`);
let gone = 0;
for (let i = 0; i < 10 && !gone; i++) { await frame(); if (!(await q1(`SELECT free FROM qc_edicts WHERE id = ${missile} AND free = 0`))) gone = i + 1; }
assert(gone > 0 && !(await ent(missile)), `the explosion animates and removes itself (${gone} frames), its ents row with it`);
assert((await fld(1, 'health')) === 100, 'the player is far enough not to be hurt');

// ── the renderer sees QuakeC entities ────────────────────────────────────
let look = null, g = null, seen = null;
for (const gid of await byClass('monster_army')) {
  g = await ent(gid);
  for (let a = 0; a < 360 && !look; a += 30) {
  for (const r of [96, 128, 160, 200, 240, 320]) {
    const x = g.X + Math.cos(a * Math.PI / 180) * r, y = g.Y + Math.sin(a * Math.PI / 180) * r;
    const down = await traceBox(x, y, g.Z + 32, x, y, g.Z - 128);
    if (down.F >= 1 || !(await clear(x, y, down.EZ))) continue;
    const sight = await q1(`SELECT fraction f, hit_ent h FROM trace_move(1, 0, 0, 0, 0, 0, 0, ${x}, ${y}, ${down.EZ + 22}, ${g.X}, ${g.Y}, ${g.Z + 10}, 0)`);
    if (sight.F < 1 && sight.H !== gid) continue;
    look = { x, y, z: down.EZ, yaw: yawTo(g.X - x, g.Y - y) }; seen = gid; break;
  }
  }
  if (look) break;
}
assert(!!look, 'a spot with a clear view of a grunt');
await place(look.x, look.y, look.z, look.yaw);
await frame();
const faces = (await q1('SELECT COUNT(*) n FROM frame_faces_fast')).N;
const ents = (await db.query('SELECT * FROM frame_ents', [], { rowMode: 'array' })).rows;
const soldier = await modelId('progs/soldier.mdl');
assert(faces > 20 && ents.some((r) => r[0] === seen && r[1] === soldier), `frame_faces_fast draws ${faces} faces from the QuakeC player's eye and frame_ents lists the grunt (edict ${seen}) with soldier.mdl among ${ents.length} models`);
assert((await errors()).length === 0, 'no QuakeC errors in the whole run');

const sorted = [...frameMs].sort((a, b) => a - b);
console.log(`${frameMs.length} server frames: median ${sorted[sorted.length >> 1].toFixed(0)} ms, max ${sorted[sorted.length - 1].toFixed(0)} ms; ${(await q1('SELECT steps FROM qc_vm')).STEPS} QuakeC statements`);
await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
