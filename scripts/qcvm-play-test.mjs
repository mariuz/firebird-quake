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
import { QcJit } from '../src/qcjit.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
const progs = await loadProgs(db, pak);
if (process.env.QCJIT === 'all') {                 // every function compiled to its own procedure
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`compiled ${jit.compiled.size} functions in ${(jit.ms / 1000).toFixed(1)} s`);
}
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

// ── the thunderbolt: its beam is a temp entity with an owner ─────────────
for (let i = 0; i < 10 && (await fld(1, 'weapon')) !== 64; i++) await frame({ imp: 8 });   // ImpulseCommands waits for the rocket's attack_finished
assert((await fld(1, 'weapon')) === 64, 'impulse 8: the thunderbolt (IT_LIGHTNING) in hand');
const fx0 = (await q1('SELECT COALESCE(MAX(id), 0) m FROM fx_events')).M;
pl = await ent(1);
await frame({ fire: 1 });
const beam = await q1(`SELECT n, x, y, z, x2, y2, z2 FROM fx_events WHERE kind = 4 AND id > ${fx0} ORDER BY id`);
assert(!!beam && beam.N === 1 && Math.abs(beam.Z - (pl.Z + 16)) < 1 && Math.hypot(beam.X2 - beam.X, beam.Y2 - beam.Y) > 250,
  `W_FireLightning: TE_LIGHTNING2's WriteEntity is the beam's owner (${beam?.N}), its start the player's origin + 16 up, its end at the wall ${beam ? Math.hypot(beam.X2 - beam.X, beam.Y2 - beam.Y).toFixed(0) : '?'} units away`);
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
// ── SV_ClientThink's details ─────────────────────────────────────────────
// the body leans into a strafe, V_CalcRoll * 4: the velocity along the body's right at the start of the think,
// 8 degrees at 200 units/s and over, positive to the right (the velocity is set: this spot is too cramped to run)
const rightOf = (yaw) => [Math.sin(yaw * Math.PI / 180), -Math.cos(yaw * Math.PI / 180)];
const [rx, ry] = rightOf((await ent(1)).YAW);
await db.exec(`UPDATE ents SET vx = ${rx * 300}, vy = ${ry * 300}, vz = 0, pitch = 0, roll = 0 WHERE id = 1`);
await frame({ s: 350 });
const lean = (await ent(1)).ROLL;
await db.exec(`UPDATE ents SET vx = ${-rx * 100}, vy = ${-ry * 100}, vz = 0, pitch = 0, roll = 0 WHERE id = 1`);
await frame({ s: -350 });
const leanLeft = (await ent(1)).ROLL;
await db.exec('UPDATE ents SET vx = 0, vy = 0, vz = 0 WHERE id = 1');
await frame();
const upright = (await ent(1)).ROLL;
assert(Math.abs(lean - 8) < 1e-6 && Math.abs(leanLeft + 4) < 1e-6 && Math.abs(upright) < 1e-6,
  `the body leans into a strafe as V_CalcRoll has it: 8° right at 300 units/s, -4° left at 100 (${lean.toFixed(2)}°, ${leanLeft.toFixed(2)}°), upright standing (${upright.toFixed(2)}°)`);
// SV_WaterJump: while FL_WATERJUMP holds, the push the progs put in movedir is the velocity, until teleport_time
// or out of the water; on dry land the flag goes at once, after that frame's push
await db.exec('UPDATE ents SET flags = BIN_OR(flags, 2048), vx = 0, vy = 0 WHERE id = 1');
await setf(1, 'movedir', 37, 0); await setf(1, 'movedir', -21, 1); await setf(1, 'teleport_time', t + 2);
const wj0 = (await q1('SELECT vx, vy FROM ents WHERE id = 1'));
await frame();
const wj = await ent(1);
assert((wj.FLAGS & 2048) === 0 && (await fld(1, 'teleport_time')) === 0 && Math.abs(wj.VX - 37) < 1e-6 && Math.abs(wj.VY + 21) < 1e-6 && wj0.VX === 0,
  `a water jump on dry land: that frame's velocity is movedir (${wj.VX.toFixed(1)}, ${wj.VY.toFixed(1)}), then FL_WATERJUMP and teleport_time are cleared`);
// SV_CheckStuck: a walking client inside something solid goes back to its last free place (oldorigin)
await db.exec('UPDATE ents SET vx = 0, vy = 0, vz = 0 WHERE id = 1');
await frame();
const free = await ent(1);
const kept = [await fld(1, 'oldorigin', 0), await fld(1, 'oldorigin', 1), await fld(1, 'oldorigin', 2)];
let wall = null;
for (const [dx, dy] of [[64, 0], [-64, 0], [0, 64], [0, -64], [128, 0], [-128, 0], [0, 128], [0, -128]]) {
  if ((await q1(`SELECT test_position(1, ${free.X + dx}, ${free.Y + dy}, ${free.Z}) s FROM rdb$database`)).S === 1) { wall = [free.X + dx, free.Y + dy, free.Z]; break; }
}
await db.exec(`UPDATE ents SET x = ${wall[0]}, y = ${wall[1]}, z = ${wall[2]}, vx = 0, vy = 0, vz = 0 WHERE id = 1`);
await frame();
const back = await ent(1);
assert(kept.every((v, k) => Math.abs(v - [free.X, free.Y, free.Z][k]) < 1e-6) && Math.hypot(back.X - free.X, back.Y - free.Y) < 1 && Math.abs(back.Z - free.Z) < 2,
  `SV_CheckStuck: oldorigin keeps the free place, and a client put inside a wall is back there the next frame (${back.X.toFixed(0)}, ${back.Y.toFixed(0)})`);
// noclip still touches triggers (SV_LinkEdict(ent, true) for every movetype): an item is picked up
const item = (await qa("SELECT e.id, e.x, e.y, e.z FROM ents e WHERE e.solid = 1 AND BIN_AND(e.flags, 256) <> 0 ORDER BY e.id")).at(-1);
await db.exec(`UPDATE ents SET movetype = 8, x = ${item.X}, y = ${item.Y}, z = ${item.Z + 24}, vx = 0, vy = 0, vz = 0 WHERE id = 1`);
await frame();
const picked = await q1(`SELECT solid, model_id FROM ents WHERE id = ${item.ID}`);
await db.exec('UPDATE ents SET movetype = 3 WHERE id = 1');
assert(!picked || picked.SOLID === 0 || picked.MODEL_ID === null, `noclip touches triggers too: the item under the client (edict ${item.ID}) is picked up`);
// SV_CheckWaterTransition after a monster's step: into the water and out again splashes (misc/h2ohit1.wav), and out of
// it waterlevel is the contents, -1, as Quake leaves it; a fresh edict (watertype 0) takes the water silently
const pool = await q1(`SELECT FIRST 1 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
  WHERE l.contents = -3 AND point_contents((l.minx + l.maxx) / 2, (l.miny + l.maxy) / 2, (l.minz + l.maxz) / 2) = -3 ORDER BY l.id`);
// (a think due each frame, SUB_Null, so the frame visits the grunt: the loop runs the edicts that have work)
const nullFn = (await q1("SELECT qc_fn('SUB_Null') f FROM rdb$database")).F;
const thinkNow = async () => { await setf(grunt, 'think', nullFn); await setf(grunt, 'nextthink', t); };
const splashes = async () => (await q1(`SELECT COUNT(*) n FROM sound_events WHERE ent_id = ${grunt} AND snd = 'misc/h2ohit1.wav'`)).N;
const dry = await ent(grunt);
await db.exec(`UPDATE ents SET watertype = -1, waterlevel = 0 WHERE id = ${grunt}`);
const s0 = await splashes();
await db.exec(`UPDATE ents SET x = ${pool.X}, y = ${pool.Y}, z = ${pool.Z}, flags = BIN_OR(flags, 512) WHERE id = ${grunt}`);
await thinkNow(); await frame();
const wet = await ent(grunt), s1 = await splashes();
await db.exec(`UPDATE ents SET x = ${dry.X}, y = ${dry.Y}, z = ${dry.Z} WHERE id = ${grunt}`);
await thinkNow(); await frame();
const out = await ent(grunt), s2 = await splashes();
await db.exec(`UPDATE ents SET x = ${pool.X}, y = ${pool.Y}, z = ${pool.Z}, watertype = 0 WHERE id = ${grunt}`);
await thinkNow(); await frame();
const fresh = await ent(grunt), s3 = await splashes();
assert(wet.WATERTYPE === -3 && wet.WATERLEVEL === 1 && s1 === s0 + 1 && out.WATERTYPE === -1 && out.WATERLEVEL === -1 && s2 === s1 + 1 && fresh.WATERTYPE === -3 && s3 === s2,
  `SV_CheckWaterTransition: a grunt put into E1M1's water splashes and is in water (type ${wet.WATERTYPE}), out again splashes (level ${out.WATERLEVEL}), and a fresh edict takes the water silently`);
await db.exec(`UPDATE ents SET x = ${dry.X}, y = ${dry.Y}, z = ${dry.Z} WHERE id = ${grunt}`);
// force_retouch (SV_Physics): while it is set every edict is linked again with its touches, still ones too. A grunt
// standing still in E1M1's teleporter is not touched by it until then, and then it is sent to the destination
const tele = (await byClass('trigger_teleport'))[0];
const tb = await ent(tele);
const mid = [tb.X + (tb.MINX + tb.MAXX) / 2, tb.Y + (tb.MINY + tb.MAXY) / 2, tb.Z + tb.MINZ + 25];
await setf(grunt, 'health', 30);
await db.exec(`UPDATE ents SET x = ${mid[0]}, y = ${mid[1]}, z = ${mid[2]}, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 512), solid = 3 WHERE id = ${grunt}`);
await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
await setf(grunt, 'nextthink', 0);
await frame();
const stayed = await ent(grunt);
await db.exec("EXECUTE PROCEDURE qc_sg(qc_gdef('force_retouch'), 2)");
await frame();
const sent = await ent(grunt);
const fr1 = await q1("SELECT qc_g(qc_gdef('force_retouch')) v FROM rdb$database");
await frame();
const fr0 = await q1("SELECT qc_g(qc_gdef('force_retouch')) v FROM rdb$database");
assert(Math.hypot(stayed.X - mid[0], stayed.Y - mid[1]) < 1 && Math.hypot(sent.X - mid[0], sent.Y - mid[1]) > 64 && fr1.V === 1 && fr0.V === 0,
  `force_retouch: a grunt standing in the teleporter stays put until it is set, then is sent on (${Math.hypot(sent.X - mid[0], sent.Y - mid[1]).toFixed(0)} units), and it counts down a frame at a time`);
// SV_PushEntity's MOVE_MISSILE: a flying missile hits a monster with a box 15 each way, so one passing 10 units beside
// a grunt hits it, where a plain box trace on the same clear line misses it; a trigger-solid thing passes (MOVE_NOMONSTERS)
{
  // the middle of a big open leaf: room all round for the lines past it
  const open = await q1(`SELECT FIRST 1 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
    WHERE l.contents = -1 AND l.maxx - l.minx > 200 AND l.maxy - l.miny > 200 AND l.maxz - l.minz > 100 ORDER BY (l.maxx - l.minx) * (l.maxy - l.miny) DESC`);
  await db.exec(`UPDATE ents SET x = ${open.X}, y = ${open.Y}, z = ${open.Z} WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  await db.exec(`UPDATE ents SET solid = 0 WHERE BIN_AND(flags, 32) <> 0 AND id <> ${grunt}`);   // the bystanders out of the way
  const g = await ent(grunt);
  const shot = async (mt, solid, line) => {
    await db.exec(`INSERT INTO ents (id, classname, x, y, z, minx, miny, minz, maxx, maxy, maxz, solid, movetype, watertype)
      VALUES (900001, 'qc', ${line.x}, ${line.y}, ${g.Z}, 0, 0, 0, 0, 0, 0, ${solid}, ${mt}, 0)`);
    const r = await q1(`SELECT hit_ent h, fraction f FROM push_entity(900001, ${line.dx}, ${line.dy}, 0)`);
    await db.exec('DELETE FROM ents WHERE id = 900001');
    return r;
  };
  // past its side, 10 units out, along x or along y, whichever line the walls leave clear
  const lines = [{ x: g.X - 40, y: g.Y + g.MAXY + 10, dx: 80, dy: 0 }, { x: g.X - 40, y: g.Y + g.MINY - 10, dx: 80, dy: 0 },
    { x: g.X + g.MAXX + 10, y: g.Y - 40, dx: 0, dy: 80 }, { x: g.X + g.MINX - 10, y: g.Y - 40, dx: 0, dy: 80 }];
  let line = null, plain = null;
  for (const l of lines) { plain = await shot(10, 2, l); if (plain.F === 1) { line = l; break; } }
  const missile = line && await shot(9, 2, line), trigger = line && await shot(6, 1, line);   // (a fly-missile is MOVE_MISSILE whatever its solid)
  assert(line && missile.H === grunt && missile.F < 1 && trigger.F === 1,
    `MOVE_MISSILE: a missile passing 10 units beside the grunt hits it (fraction ${missile?.F.toFixed(2)}), a bouncing thing on the same line misses, and a tossed trigger-solid one passes through`);
}
// SV_WalkMove's SV_WallFriction and SV_TryUnstick (walk_move given the view's forward vector, as QuakeC mode calls it)
{
  await db.exec(`UPDATE ents SET x = ${free.X}, y = ${free.Y}, z = ${free.Z}, vx = 0, vy = 0, vz = 0, movetype = 3 WHERE id = 1`);
  await db.exec('EXECUTE PROCEDURE link_ent(1)');
  const tr = (x, y, z, dx, dy) => q1(`SELECT fraction f, ex, ey, ez, nx, ny, nz FROM trace_move(1, ${box.join(', ')}, ${x}, ${y}, ${z}, ${x + dx}, ${y + dy}, ${z}, 0)`);
  const AX = [[1, 0], [-1, 0], [0, 1], [0, -1]];
  // a tall wall (blocked at the step height too) facing one of the axes, and the spot 8 units out from it
  let w = null;
  for (const [dx, dy] of AX) {
    const r = await tr(free.X, free.Y, free.Z, dx * 256, dy * 256);
    const hi = await tr(free.X, free.Y, free.Z + 18, dx * 256, dy * 256);
    if (r.F < 1 && Math.abs(r.NX + dx) < 1e-6 && Math.abs(r.NY + dy) < 1e-6 && hi.F < 1 && Math.abs(hi.F * 256 - r.F * 256) < 1) { w = { dx, dy, x: r.EX - dx * 8, y: r.EY - dy * 8, z: r.EZ }; break; }
  }
  const walk = async (x, y, z, vx, vy, fwd) => {
    await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = ${vx}, vy = ${vy}, vz = -80, flags = BIN_OR(flags, 512) WHERE id = 1`);   // (gravity added, as a frame has it)
    await db.exec('EXECUTE PROCEDURE link_ent(1)');
    await db.exec(`EXECUTE PROCEDURE walk_move(1, 0.1, ${fwd ? fwd[0] : 'NULL'}, ${fwd ? fwd[1] : 'NULL'})`);
    return ent(1);
  };
  // running into it at a slant, 300 units/s at the wall and 100 along it (the tangent t)
  const tx = -w.dy, ty = w.dx;
  const faceWall = await walk(w.x, w.y, w.z, w.dx * 300 + tx * 100, w.dy * 300 + ty * 100, [w.dx, w.dy]);
  const faceAlong = await walk(w.x, w.y, w.z, w.dx * 300 + tx * 100, w.dy * 300 + ty * 100, [tx, ty]);
  const psql = await walk(w.x, w.y, w.z, w.dx * 300 + tx * 100, w.dy * 300 + ty * 100, null);
  const along = (e) => e.VX * tx + e.VY * ty;
  assert(w && Math.abs(along(faceWall) - 50) < 1e-6 && Math.abs(along(faceAlong) - 100) < 1e-6 && Math.abs(along(psql) - 100) < 1e-6,
    `SV_WallFriction: running into a wall facing it keeps half the speed along it (${along(faceWall).toFixed(1)}), facing along it all of it (${along(faceAlong).toFixed(1)}); the PSQL game has none (${along(psql).toFixed(1)})`);
  // a jamb: along a wall or across a doorway (its door out of the way), a spot where the way straight on is shut
  // next to one where it is open: the box there catches the jamb's edge by a unit or less, and a run straight on
  // from it is nudged free by TryUnstick
  const findJamb = async (x0, y0, z, dx, dy) => {
    const tx = -dy, ty = dx;
    for (const sgn of [1, -1]) {
      let prev = null;
      for (let k = 0; k <= 160; k++) {
        const x = x0 + sgn * tx * k, y = y0 + sgn * ty * k;
        if (!(await clear(x, y, z))) break;
        const r = await tr(x, y, z, dx * 64, dy * 64), hi = await tr(x, y, z + 18, dx * 64, dy * 64);
        const cur = { x, y, z, dx, dy, shut: r.F < 0.3 && hi.F < 0.3, open: r.F === 1 && hi.F === 1 };
        if (prev?.shut && cur.open) return prev;
        if (prev?.open && cur.shut) return cur;
        prev = cur;
      }
    }
    return null;
  };
  let jamb = await findJamb(w.x, w.y, w.z, w.dx, w.dy);
  for (const d of doors) {
    if (jamb) break;
    const de = await ent(d);
    await db.exec(`UPDATE ents SET solid = 0 WHERE id = ${d}`);
    const cx = de.X + (de.MINX + de.MAXX) / 2, cy = de.Y + (de.MINY + de.MAXY) / 2;
    const [ax, ay] = de.MAXX - de.MINX < de.MAXY - de.MINY ? [1, 0] : [0, 1];
    for (const sgn of [1, -1]) {
      for (const z of [de.Z + de.MINZ + 24.03125, de.Z + de.MINZ + 25.03125]) {
        if (!jamb) jamb = await findJamb(cx - sgn * ax * 40, cy - sgn * ay * 40, z, sgn * ax, sgn * ay);
      }
    }
    await db.exec(`UPDATE ents SET solid = 4 WHERE id = ${d}`);
    if (jamb) { jamb.door = d; await db.exec(`UPDATE ents SET solid = 0 WHERE id = ${d}`); }
  }
  const unstuck = jamb && await walk(jamb.x, jamb.y, jamb.z, jamb.dx * 300, jamb.dy * 300, [jamb.dx, jamb.dy]);
  const stuck = jamb && await walk(jamb.x, jamb.y, jamb.z, jamb.dx * 300, jamb.dy * 300, null);
  if (jamb?.door) await db.exec(`UPDATE ents SET solid = 4 WHERE id = ${jamb.door}`);
  const gone = (e) => (e.X - jamb.x) * jamb.dx + (e.Y - jamb.y) * jamb.dy;
  assert(jamb && gone(unstuck) > 4 && gone(stuck) < 1,
    `SV_TryUnstick: running straight at a jamb that catches the box by a unit, the step-up makes no headway and a nudge sideways lets it through (${jamb ? gone(unstuck).toFixed(1) : '-'} units on; without it ${jamb ? gone(stuck).toFixed(1) : '-'})`);
}
// SV_movestep's SV_CheckBottom: a monster walking towards a drop stops while its middle is still over the floor,
// where the box's trace down alone would let it walk on until a corner was all that stood on the edge
{
  const g0 = await ent(grunt);
  const starts = await qa(`SELECT x, y, z FROM ents WHERE BIN_AND(flags, 32) <> 0 AND id <> ${grunt} ORDER BY id`);
  let edge = null;
  for (const st of starts) {
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      await db.exec(`UPDATE ents SET x = ${st.X}, y = ${st.Y}, z = ${st.Z}, flags = BIN_AND(BIN_OR(flags, 512), BIN_NOT(1024)) WHERE id = ${grunt}`);
      if ((await q1(`SELECT test_position(${grunt}, ${st.X}, ${st.Y}, ${st.Z}) s FROM rdb$database`)).S !== 0) break;
      let k = 0;
      while (k < 64 && (await q1(`SELECT move_step(${grunt}, ${dx * 4}, ${dy * 4}, 0) m FROM rdb$database`)).M === 1) k++;
      if (k === 64) continue;
      const e = await ent(grunt);
      // the refused step: does the box's trace down (as move_step makes it) find a floor there?
      const nz = e.Z + 18;
      const down = await q1(`SELECT fraction f, ez, allsolid a, startsolid s FROM trace_move(${grunt}, ${e.MINX}, ${e.MINY}, ${e.MINZ}, ${e.MAXX}, ${e.MAXY}, ${e.MAXZ}, ${e.X + dx * 4}, ${e.Y + dy * 4}, ${nz}, ${e.X + dx * 4}, ${e.Y + dy * 4}, ${nz - 36}, 0)`);
      if (down.F < 1 && down.A === 0 && down.S === 0) {
        await db.exec(`UPDATE ents SET x = ${e.X + dx * 4}, y = ${e.Y + dy * 4}, z = ${down.EZ} WHERE id = ${grunt}`);
        const hangs = (await q1(`SELECT check_bottom(${grunt}) b FROM rdb$database`)).B === 0;
        await db.exec(`UPDATE ents SET x = ${e.X}, y = ${e.Y}, z = ${e.Z} WHERE id = ${grunt}`);
        const here = (await q1(`SELECT check_bottom(${grunt}) b FROM rdb$database`)).B === 1;
        const again = (await q1(`SELECT move_step(${grunt}, ${dx * 4}, ${dy * 4}, 0) m FROM rdb$database`)).M;
        const still = await ent(grunt);
        if (hangs && here) { edge = { k, again, moved: Math.hypot(still.X - e.X, still.Y - e.Y, still.Z - e.Z) }; break; }
      }
    }
    if (edge) break;
  }
  await db.exec(`UPDATE ents SET x = ${g0.X}, y = ${g0.Y}, z = ${g0.Z}, flags = ${g0.FLAGS} WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  assert(edge && edge.again === 0 && edge.moved === 0,
    `SV_CheckBottom in SV_movestep: a grunt walking to a ledge stops after ${edge?.k} steps with its middle over the floor, refusing the step the box's trace alone allows (a corner would hang over the drop)`);
}
// SV_MoveToGoal and its helpers, on the grunt in the big open leaf
{
  const g0 = await ent(grunt);
  // a floor with room round it: the middle of one of the biggest open leaves, dropped onto what is below
  let open = null, fl = null;
  for (const l of await qa(`SELECT FIRST 30 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
      WHERE l.contents = -1 AND l.maxx - l.minx > 128 AND l.maxy - l.miny > 128 ORDER BY (l.maxx - l.minx) * (l.maxy - l.miny) DESC`)) {
    const d = await q1(`SELECT ez, fraction f, allsolid a, startsolid s FROM trace_move(${grunt}, ${g0.MINX}, ${g0.MINY}, ${g0.MINZ}, ${g0.MAXX}, ${g0.MAXY}, ${g0.MAXZ}, ${l.X}, ${l.Y}, ${l.Z}, ${l.X}, ${l.Y}, ${l.Z - 1000}, 0)`);
    if (d.S === 1 || d.F === 1) continue;
    await db.exec(`UPDATE ents SET x = ${l.X}, y = ${l.Y}, z = ${d.EZ} WHERE id = ${grunt}`);
    if ((await q1(`SELECT check_bottom(${grunt}) b FROM rdb$database`)).B !== 1) continue;
    const room = await q1(`SELECT MIN(t.fraction) f FROM (SELECT 1 k FROM rdb$database) r CROSS JOIN trace_move(${grunt}, ${g0.MINX}, ${g0.MINY}, ${g0.MINZ}, ${g0.MAXX}, ${g0.MAXY}, ${g0.MAXZ}, ${l.X - 24}, ${l.Y}, ${d.EZ + 1}, ${l.X + 24}, ${l.Y}, ${d.EZ + 1}, 0) t`);
    if (room.F === 1) { open = l; fl = d; break; }
  }
  const stand = async (yaw) => {
    await db.exec(`UPDATE ents SET x = ${open.X}, y = ${open.Y}, z = ${fl.EZ}, yaw = ${yaw}, ideal_yaw = ${yaw}, yaw_speed = 20, flags = BIN_AND(BIN_OR(flags, 512), BIN_NOT(1024)) WHERE id = ${grunt}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  };
  const movedBy = async () => { const e = await ent(grunt); return Math.hypot(e.X - open.X, e.Y - open.Y); };
  // SV_StepDirection takes the step unless yaw - ideal_yaw, as it comes, is between 45 and 315: facing 0 and told 90
  // (turned to 20, -70) it steps while turning; told 270 (turned to 340, 70) it only turns
  await stand(0);
  const ccw = (await q1(`SELECT step_direction(${grunt}, 90, 8) r FROM rdb$database`)).R, ccwMoved = await movedBy();
  await stand(0);
  const cw = (await q1(`SELECT step_direction(${grunt}, 270, 8) r FROM rdb$database`)).R, cwMoved = await movedBy();
  assert(ccw === 1 && Math.abs(ccwMoved - 8) < 1e-6 && cw === 1 && cwMoved === 0,
    `SV_StepDirection: turning anticlockwise (0 to 90) the grunt steps while still turning (${ccwMoved.toFixed(1)} units), clockwise (0 to 270) it only turns (${cwMoved.toFixed(1)})`);
  // SV_CloseEnough: with an enemy (any: here the player), a goal within reach ends the move, though it is not the enemy
  const goal = shells;
  const sb = await ent(goal);
  await stand(0);
  await db.exec(`UPDATE ents SET x = ${open.X + g0.MAXX - sb.MINX + 10}, y = ${open.Y}, z = ${fl.EZ} WHERE id = ${goal}`);
  await db.exec(`UPDATE ents SET goal_id = ${goal}, enemy_id = 1 WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE move_to_goal(${grunt}, 8)`);
  const held = await movedBy();
  await db.exec(`UPDATE ents SET x = ${sb.X}, y = ${sb.Y}, z = ${sb.Z} WHERE id = ${goal}`);
  // SV_FixCheckBottom: a grunt that can go nowhere (every step of 4000 units leaves the world) while its middle hangs
  // over a drop is marked FL_PARTIALGROUND
  await stand(0);
  let hang = null;
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    for (let k = 8; k < 400 && !hang; k += 8) {
      const x = open.X + dx * k, y = open.Y + dy * k;
      const d = await q1(`SELECT fraction f, ez, startsolid s FROM trace_move(${grunt}, ${g0.MINX}, ${g0.MINY}, ${g0.MINZ}, ${g0.MAXX}, ${g0.MAXY}, ${g0.MAXZ}, ${x}, ${y}, ${fl.EZ + 18}, ${x}, ${y}, ${fl.EZ - 18}, 0)`);
      if (d.S === 1) break;
      if (d.F === 1) continue;
      await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${d.EZ} WHERE id = ${grunt}`);
      if ((await q1(`SELECT check_bottom(${grunt}) b FROM rdb$database`)).B === 0) hang = { x, y };
    }
    if (hang) break;
  }
  if (hang) await db.exec(`EXECUTE PROCEDURE new_chase_dir(${grunt}, 1, 4000)`);
  const fixed = await ent(grunt);
  await db.exec(`UPDATE ents SET x = ${g0.X}, y = ${g0.Y}, z = ${g0.Z}, flags = ${g0.FLAGS}, goal_id = ${g0.GOAL_ID ?? 'NULL'}, enemy_id = ${g0.ENEMY_ID ?? 'NULL'} WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  assert(held === 0, `SV_CloseEnough: with the player for its enemy, a grunt whose goal (an item) is 10 units off stays put (${held.toFixed(1)} units)`);
  assert(hang && (fixed.FLAGS & 1024) !== 0 && fixed.X === hang.x && fixed.Y === hang.y,
    `SV_FixCheckBottom: a grunt hanging over a ledge with nowhere to step is marked FL_PARTIALGROUND`);
}
// PF_vectoyaw and PF_vectoangles give whole degrees (they cast to int), 90 for straight along y and not 89
{
  const call = async (n, args) => {
    for (const [k, v] of args.entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${4 + k}, ${v})`);
    await db.exec(`EXECUTE PROCEDURE qc_builtin(${n}, 0)`);
    return [await q1('SELECT qc_g(1) v FROM rdb$database'), await q1('SELECT qc_g(2) v FROM rdb$database'), await q1('SELECT qc_g(3) v FROM rdb$database')].map((r) => r.V);
  };
  const yaws = [(await call(13, [1, 2, 0]))[0], (await call(13, [0, 1, 0]))[0], (await call(13, [-1, -1, 0]))[0]];
  const up = await call(51, [1, 0, 1]), down = await call(51, [1, 2, -1]);
  assert(yaws.join() === '63,90,225' && up.join() === '45,0,0' && down.join() === '336,63,0',
    `vectoyaw and vectoangles in whole degrees as Quake casts them: ${yaws.join(', ')}; (1 0 1) ${up.join(' ')}, (1 2 -1) ${down.join(' ')}`);
}
// PF_traceline's trace_inopen is the line having gone through open air (not its hitting something): visible() takes
// a line through air and water both for a crossed surface. From E1M1's water up into the air above it: both set
{
  const pools = await qa(`SELECT FIRST 20 (l.minx + l.maxx) / 2 x, (l.miny + l.maxy) / 2 y, (l.minz + l.maxz) / 2 z FROM leaves l
    WHERE l.contents = -3 AND point_contents((l.minx + l.maxx) / 2, (l.miny + l.maxy) / 2, (l.minz + l.maxz) / 2) = -3 ORDER BY l.id`);
  const g = (name) => q1(`SELECT qc_g(qc_gdef('${name}')) v FROM rdb$database`).then((r) => r.V);
  const traceline = async (a, b) => {
    for (const [k, v] of [...a, ...b, 1, 0, 0, 0].entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${4 + k}, ${v})`);
    await db.exec('EXECUTE PROCEDURE qc_builtin(16, 0)');
    return { f: await g('trace_fraction'), open: await g('trace_inopen'), water: await g('trace_inwater') };
  };
  let wet = null, dry = null;
  for (const p of pools) {
    const sky = await q1(`SELECT ez FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, ${p.X}, ${p.Y}, ${p.Z}, ${p.X}, ${p.Y}, ${p.Z + 512}, 1)`);
    const top = [p.X, p.Y, p.Z + (sky.EZ - p.Z) * 0.9];
    if ((await q1(`SELECT point_contents(${top.join(', ')}) c FROM rdb$database`)).C !== -1) continue;
    wet = await traceline([p.X, p.Y, p.Z], top);
    dry = await traceline([p.X, p.Y, top[2] - 8], top);
    if ((await q1(`SELECT point_contents(${p.X}, ${p.Y}, ${top[2] - 8}) c FROM rdb$database`)).C === -1) break;
  }
  assert(wet && wet.f === 1 && wet.open === 1 && wet.water === 1 && dry.f === 1 && dry.open === 1 && dry.water === 0,
    `traceline from the water up into the air is clear and goes through both (inopen ${wet?.open}, inwater ${wet?.water}); one in the air only, inopen ${dry?.open}, inwater ${dry?.water}`);
}
// PF_findradius chains from the highest edict down (it walks up and puts each in front of the chain)
{
  const p = await ent(1);
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${p.X})`); await db.exec(`EXECUTE PROCEDURE qc_sg(5, ${p.Y})`); await db.exec(`EXECUTE PROCEDURE qc_sg(6, ${p.Z})`);
  await db.exec('EXECUTE PROCEDURE qc_sg(7, 1000)');
  await db.exec('EXECUTE PROCEDURE qc_builtin(22, 0)');
  const chain = [];
  for (let e = (await q1('SELECT qc_g(1) v FROM rdb$database')).V; e && chain.length < 500; e = await fld(e, 'chain')) chain.push(e);
  assert(chain.length > 2 && chain.every((e, k) => k === 0 || e < chain[k - 1]),
    `findradius: ${chain.length} edicts within 1000 units, chained from the highest down (${chain.slice(0, 4).join(', ')}, …)`);
}
// SV_TouchLinks and SV_Impact put self and other back after the touches they run
{
  const g = (k) => q1(`SELECT qc_g(${k}) v FROM rdb$database`).then((r) => r.V);
  const [gs, go] = await q1("SELECT g_self s, g_other o FROM qc_vm WHERE id = 1").then((r) => [r.S, r.O]);
  const g0 = await ent(grunt);
  const tb = await ent((await byClass('trigger_teleport'))[0]);
  const mid = [tb.X + (tb.MINX + tb.MAXX) / 2, tb.Y + (tb.MINY + tb.MAXY) / 2, tb.Z + tb.MINZ + 25];
  await db.exec(`UPDATE ents SET x = ${mid[0]}, y = ${mid[1]}, z = ${mid[2]}, solid = 3 WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE qc_sg(${gs}, 1)`); await db.exec(`EXECUTE PROCEDURE qc_sg(${go}, 7)`);
  await db.exec(`EXECUTE PROCEDURE qc_touch_triggers(${grunt})`);
  const sent = await ent(grunt);
  const afterTouch = [await g(gs), await g(go)];
  const item = (await qa(`SELECT e.id FROM ents e WHERE e.solid = 1 AND BIN_AND(e.flags, 256) <> 0 ORDER BY e.id`)).find(() => true).ID;
  await db.exec(`EXECUTE PROCEDURE qc_sg(${gs}, 1)`); await db.exec(`EXECUTE PROCEDURE qc_sg(${go}, 7)`);
  await db.exec(`EXECUTE PROCEDURE qc_impact(${item}, 0)`);
  const afterImpact = [await g(gs), await g(go)];
  await db.exec(`UPDATE ents SET x = ${g0.X}, y = ${g0.Y}, z = ${g0.Z}, solid = ${g0.SOLID} WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  assert(Math.hypot(sent.X - mid[0], sent.Y - mid[1]) > 64 && afterTouch.join() === '1,7' && afterImpact.join() === '1,7',
    `self and other are put back after a trigger's touch (the teleporter sent the grunt on: self ${afterTouch[0]}, other ${afterTouch[1]}) and after an impact's (an item's touch: ${afterImpact.join(', ')})`);
}
// PF_setmodel sizes an alias model to its fixed box, 16 each way (Mod_LoadAliasModel), until a setsize
{
  const box = async (e) => Promise.all(['mins', 'maxs'].flatMap((f) => [0, 1, 2].map((k) => fld(e, f, k))));
  const before = await box(grunt);
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${grunt})`);
  await db.exec(`EXECUTE PROCEDURE qc_sg(7, ${await fld(grunt, 'model')})`);
  await db.exec('EXECUTE PROCEDURE qc_builtin(3, 0)');
  const after = await box(grunt), row = await ent(grunt);
  for (const [k, v] of before.entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${7 + k}, ${v})`);
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${grunt})`);
  await db.exec('EXECUTE PROCEDURE qc_builtin(4, 0)');
  // and a sprite's, half its widest frame across and half its tallest up and down (Mod_LoadSpriteModel)
  const spr = await q1("SELECT minx, minz, maxx, maxz FROM models WHERE name = 'progs/s_explod.spr'");
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${grunt})`);
  await db.exec("EXECUTE PROCEDURE qc_sg(7, (SELECT qc_newstr('progs/s_explod.spr') FROM rdb$database))");
  await db.exec('EXECUTE PROCEDURE qc_builtin(3, 0)');
  const sprBox = await box(grunt);
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${grunt})`); await db.exec(`EXECUTE PROCEDURE qc_sg(7, ${await fld(grunt, 'model')})`);
  for (const [k, v] of before.entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${7 + k}, ${v})`);
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, ${grunt})`);
  await db.exec('EXECUTE PROCEDURE qc_builtin(4, 0)');
  assert(spr.MINX < 0 && sprBox.join() === [spr.MINX, spr.MINX, spr.MINZ, spr.MAXX, spr.MAXX, spr.MAXZ].join(),
    `setmodel on s_explod.spr gives its sprite box, ${sprBox.slice(0, 3).join(' ')} to ${sprBox.slice(3).join(' ')}`);
  assert(after.join() === '-16,-16,-16,16,16,16' && row.MINZ === -16 && (await box(grunt)).join() === before.join(),
    `setmodel on soldier.mdl gives the box Quake's alias models have, ${after.slice(0, 3).join(' ')} to ${after.slice(3).join(' ')} (in ents too), until setsize (${before.join(' ')} again)`);
}
// SV_PushEntity links the mover with its trigger touches before the impact: a missile that ends its move in a trigger
// against a wall touches the trigger, then the wall (triggers are touched where a move ends, not along it). Both touches are SUB_Remove (each removes its self), so
// in Quake's order both are gone; with the impact first the missile went and the trigger was never touched
{
  const remove = (await q1("SELECT qc_fn('SUB_Remove') f FROM rdb$database")).F;
  const spawn = async () => { await db.exec('EXECUTE PROCEDURE qc_builtin(14, 0)'); return (await q1('SELECT qc_g(1) v FROM rdb$database')).V; };
  const place = async (e, o, mn, mx) => {
    for (const [k, v] of [e, 0, 0, ...o].entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${4 + k}, ${v})`);
    await db.exec('EXECUTE PROCEDURE qc_builtin(2, 0)');
    for (const [k, v] of [e, 0, 0, ...mn, ...mx].entries()) await db.exec(`EXECUTE PROCEDURE qc_sg(${4 + k}, ${v})`);
    await db.exec('EXECUTE PROCEDURE qc_builtin(4, 0)');
  };
  // a wall at least 100 units off the player's free spot from above, at its height
  const z = free.Z;
  let wall = null;
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const t = await q1(`SELECT fraction f, ex, ey, startsolid s FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, ${free.X}, ${free.Y}, ${z}, ${free.X + dx * 600}, ${free.Y + dy * 600}, ${z}, 1)`);
    if (t.S === 0 && t.F < 1 && t.F * 600 > 100) { wall = { dx, dy, x: t.EX, y: t.EY }; break; }
  }
  const missile = await spawn(), trig = await spawn();
  const start = [wall.x - wall.dx * 80, wall.y - wall.dy * 80, z];
  await place(missile, start, [0, 0, 0], [0, 0, 0]);
  await place(trig, [wall.x - wall.dx * 4, wall.y - wall.dy * 4, z], [-8, -8, -8], [8, 8, 8]);   // where the move ends
  await db.exec(`UPDATE ents SET solid = 2, movetype = 9 WHERE id = ${missile}`);
  await db.exec(`UPDATE ents SET solid = 1, movetype = 0 WHERE id = ${trig}`);
  await setf(missile, 'touch', remove); await setf(trig, 'touch', remove);
  await db.exec(`EXECUTE PROCEDURE link_ent(${trig})`);
  const r = await q1(`SELECT fraction f, hit_ent h FROM push_entity(${missile}, ${wall.dx * 160}, ${wall.dy * 160}, 0)`);
  const gone = async (e) => (await q1(`SELECT COUNT(*) n FROM ents WHERE id = ${e}`)).N === 0;
  const [mg, tg] = [await gone(missile), await gone(trig)];
  for (const e of [missile, trig]) if (!(await gone(e))) await db.exec(`EXECUTE PROCEDURE qc_free(${e})`);
  assert(wall && mg && tg,
    `SV_PushEntity: a missile stopped by a wall inside a trigger touches the trigger first (trigger removed: ${tg}), then hits the wall (missile removed: ${mg})`);
}
// groundentity: SV_FlyMove sets it to what a landing stopped on (a SOLID_BSP thing or the world), SV_movestep to what
// a step stands on (LibreQuake's ClientObituary reads it). Set to another edict first, both come back to the world
{
  await db.exec(`UPDATE ents SET x = ${free.X}, y = ${free.Y}, z = ${free.Z}, vx = 0, vy = 0, vz = 0, movetype = 3 WHERE id = 1`);
  await db.exec('EXECUTE PROCEDURE link_ent(1)');
  await setf(1, 'groundentity', grunt);
  await frame();
  const pg = await fld(1, 'groundentity');
  const g0 = await ent(grunt);
  const starts = await qa(`SELECT x, y, z FROM ents WHERE BIN_AND(flags, 32) <> 0 AND id <> ${grunt} ORDER BY id`);
  let stepped = null;
  for (const st of starts) {
    await db.exec(`UPDATE ents SET x = ${st.X}, y = ${st.Y}, z = ${st.Z}, flags = BIN_AND(BIN_OR(flags, 512), BIN_NOT(1024)) WHERE id = ${grunt}`);
    await setf(grunt, 'groundentity', 1);
    for (const [dx, dy] of [[4, 0], [-4, 0], [0, 4], [0, -4]]) {
      if ((await q1(`SELECT move_step(${grunt}, ${dx}, ${dy}, 0) m FROM rdb$database`)).M === 1) {
        stepped = await fld(grunt, 'groundentity');
        const e = await ent(grunt);
        // what the step's trace down stands it on
        const under = await q1(`SELECT hit_ent h FROM trace_move(${grunt}, ${e.MINX}, ${e.MINY}, ${e.MINZ}, ${e.MAXX}, ${e.MAXY}, ${e.MAXZ}, ${e.X}, ${e.Y}, ${e.Z + 18}, ${e.X}, ${e.Y}, ${e.Z - 18}, 0)`);
        stepped = { got: stepped, under: under.H, cls: (await ent(under.H || 0))?.CLASSNAME ?? 'worldspawn' };
        break;
      }
    }
    if (stepped !== null) break;
  }
  await db.exec(`UPDATE ents SET x = ${g0.X}, y = ${g0.Y}, z = ${g0.Z}, flags = ${g0.FLAGS} WHERE id = ${grunt}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${grunt})`);
  assert(pg === 0 && stepped && stepped.got === stepped.under,
    `groundentity: the player's walk on the floor sets it to the world (${pg}), a grunt's step to what it stands on (${stepped?.got}, ${stepped?.cls})`);
}
assert((await errors()).length === 0, 'no QuakeC errors in the whole run');

const sorted = [...frameMs].sort((a, b) => a - b);
console.log(`${frameMs.length} server frames: median ${sorted[sorted.length >> 1].toFixed(0)} ms, max ${sorted[sorted.length - 1].toFixed(0)} ms; ${(await q1('SELECT steps FROM qc_vm')).STEPS} QuakeC statements`);
await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
