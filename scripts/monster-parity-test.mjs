// monster-parity-test.mjs – a monster in both games, tic by tic: its level loaded twice with one seed, every monster
// moved out of the way but one (each shareware kind in turn: grunt, dog, knight, ogre, fiend, scrag, shambler,
// zombie), the random generator set to the same seed in both, the player put on a free spot in its sight (away from
// triggers), and the monster compared every tic until it has killed the player: its place, frame,
// health, the player's health and the generator itself (both games draw from the seeded rnd(), so its state shows
// that the two make the same random draws in the same order). A monster that parts reports the first tic and both rows.
// Then each the other way round: the player, in god mode, shoots it every 0.6 s (the zombie with rockets) until it
// lies dead, its pains and death compared the same way (DUEL=army:fight); and each kind that patrols a path walking
// it unseen (DUEL=army:walk). Each duel runs in a process of its own (two
// engines a duel).
//
//   node scripts/monster-parity-test.mjs
//   DUEL=wizard TRACE=0 DBGM=1 node scripts/monster-parity-test.mjs     one duel, every tic of it, the yaws too

import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(pakPath).buffer);
let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const open = async (name) => {
  const db = new FirebirdBrowser(`memory://${name}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const res = await loadResources(db, pak);
  return { db, res, q1: (s) => db.query(s).then((r) => r.rows[0]) };
};

// one monster (its mtype and its place on E1M1) against the player, D units in front of it
async function duel(map, mtype, mx, my, fight = false, D = 300, N = 400) {
  const P = await open(`p${mtype}`); await loadMap(P.db, pak, P.res, map, { skill: 1, seed: 1 });
  const Q = await open(`q${mtype}`); await loadMap(Q.db, pak, Q.res, map, { skill: 1, seed: 1 });
  await loadProgs(Q.db, pak); await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  const tic = (g) => g.q1(`SELECT health FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, 0, 0, 0, 0, 1, 0)`);
  for (const g of [P, Q]) for (let k = 0; k < 10; k++) await tic(g);     // QuakeC's items and monsters placed
  // the player: entity 1 in QuakeC mode, wherever the map put it in the PSQL game (E1M3's doors come first)
  P.pid = (await P.q1('SELECT player_ent() id FROM rdb$database')).ID; Q.pid = 1;
  // the monster at (mx, my), or (when mx is null) the first of its kind with a free spot in front of it in sight
  let M = null;
  for (const c of (await P.db.query(`SELECT id, x, y, z, yaw FROM ents WHERE mtype = '${mtype}' AND health > 0 ${mx == null ? '' : `AND ABS(x - ${mx}) < 1 AND ABS(y - ${my}) < 1`} ORDER BY id`)).rows) {
    // the same monster in QuakeC mode, at its place
    if (!(await Q.q1(`SELECT id, x, y, z FROM ents WHERE solid = 3 AND id <> ${Q.pid} AND ABS(x - ${c.X}) < 48 AND ABS(y - ${c.Y}) < 48 AND ABS(z - ${c.Z}) < 48 ORDER BY (x - ${c.X}) * (x - ${c.X}) + (y - ${c.Y}) * (y - ${c.Y}) ROWS 1`))) { if (process.env.DBGM) console.log('noqc', c.ID, c.X, c.Y, c.Z); continue; }
    // a free spot for the player in front of it (straight ahead, else turned toward one aside or behind it, on its
    // floor or a step up), in sight
    search: for (const da of [0, 20, -20, 40, -40, 60, -60, 90, -90, 120, -120, 150, -150, 180]) for (let dz = 0; dz <= 48; dz += 8) for (let d = D; d >= 64; d -= 16) {
      const a = ((c.YAW + da) * Math.PI) / 180, fx = Math.round(c.X + Math.cos(a) * d), fy = Math.round(c.Y + Math.sin(a) * d), fz = c.Z + dz;   // whole units: QuakeC's floats see the angle to them as PSQL's doubles do
      const ok = await P.q1(`SELECT test_position(${P.pid}, ${fx}, ${fy}, ${fz}) t, (SELECT fraction FROM trace_move(${c.ID}, 0, 0, 0, 0, 0, 0, ${c.X}, ${c.Y}, ${c.Z + 22}, ${fx}, ${fy}, ${fz + 22}, 1)) f , (SELECT COUNT(*) FROM ents t WHERE t.solid = 1 AND t.x + t.minx < ${fx} + 64 AND t.x + t.maxx > ${fx} - 64 AND t.y + t.miny < ${fy} + 64 AND t.y + t.maxy > ${fy} - 64 AND t.z + t.minz < ${fz} + 64 AND t.z + t.maxz > ${fz} - 256) tr FROM rdb$database`);
      // (away from triggers: E1M6's exit pit)
      if (ok.T === 0 && ok.F === 1 && ok.TR === 0) { M = { ...c, YAW: (c.YAW + da + 360) % 360, PX: fx, PY: fy, PZ: fz }; break search; }
    }
    if (M) break;
  }
  if (!M) { assert(false, `${map} ${mtype}: one with room in front of it`); return; }
  // the same monster in QuakeC mode (the nearest: a flyer or a monster that dropped may sit a little apart), put where
  // the PSQL one stands
  const qid = (await Q.q1(`SELECT id, x, y, z FROM ents WHERE solid = 3 AND id <> ${Q.pid} AND ABS(x - ${M.X}) < 48 AND ABS(y - ${M.Y}) < 48 AND ABS(z - ${M.Z}) < 48 ORDER BY (x - ${M.X}) * (x - ${M.X}) + (y - ${M.Y}) * (y - ${M.Y}) ROWS 1`))?.ID;
  if (!qid) { assert(false, `${mtype}: the same monster in QuakeC mode`); return; }
  await Q.db.exec(`UPDATE ents SET x = ${M.X}, y = ${M.Y}, z = ${M.Z}, yaw = ${M.YAW}, ideal_yaw = ${M.YAW} WHERE id = ${qid}`);
  await P.db.exec(`UPDATE ents SET yaw = ${M.YAW}, ideal_yaw = ${M.YAW} WHERE id = ${M.ID}`);
  await Q.db.exec(`EXECUTE PROCEDURE link_ent(${qid})`);
  // every other monster out of the world, thinking no more
  await P.db.exec(`UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL, x = x + 50000 WHERE mtype IS NOT NULL AND id <> ${M.ID}`);
  await Q.db.exec(`UPDATE ents SET solid = 0, x = x + 50000 WHERE id <> ${qid} AND (BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_'))`);
  for (const g of [P, Q]) for (const r of (await g.db.query('SELECT id FROM ents WHERE x > 40000')).rows) {
    await g.db.exec(`EXECUTE PROCEDURE link_ent(${r.ID})`);
    // (in QuakeC dead too: a trigger's monster_use wakes no monster without health)
    if (g === Q) for (const f of ['nextthink', 'health', 'takedamage']) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('${f}'), 0)`);
  }
  // the lava's fireballs (E1M6) still: each game throws them on its own clock, drawing at random
  await P.db.exec("UPDATE ents SET nextthink = NULL WHERE classname IN ('misc_fireball', 'fireball')");
  for (const r of (await Q.db.query("SELECT e.id FROM ents e WHERE qc_f(e.id, qc_fdef('think')) IN (qc_fn('fire_fly'), qc_fn('fire_touch'))")).rows)
    await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('nextthink'), 0)`);
  // the player in front of it, on the free spot
  const { PX: px, PY: py, PZ: pz } = M;
  if (process.env.DBGM) console.log('spot', M.ID, qid, px, py, pz);
  for (const g of [P, Q]) { await g.db.exec(`UPDATE ents SET x = ${px}, y = ${py}, z = ${pz}, vx = 0, vy = 0, vz = 0 WHERE id = ${g.pid}`); await g.db.exec(`EXECUTE PROCEDURE link_ent(${g.pid})`); }
  // the same frame and think phase in both: standing, its next think next tic (set_anim has entered stand1, so
  // QuakeC's next think is army_stand2 or the like), and one seed
  const stand = (await P.q1(`SELECT t.stand_anim a FROM monster_types t WHERE t.name = '${mtype}'`)).A;
  await P.db.exec(`EXECUTE PROCEDURE set_anim(${M.ID}, '${stand}')`);
  await P.db.exec(`UPDATE ents SET nextthink = (SELECT time_ FROM game) + 0.05 WHERE id = ${M.ID}`);
  const qt = (await Q.q1('SELECT time_ t FROM game')).T;
  const fn = { army: 'army_stand2', dog: 'dog_stand2', knight: 'knight_stand2', ogre: 'ogre_stand2', demon1: 'demon1_stand2', wizard: 'wiz_stand2', shambler: 'sham_stand2', zombie: 'zombie_stand2' }[mtype];
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('frame'), (SELECT frame FROM ents WHERE id = ${qid}))`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('think'), qc_fn('${fn}'))`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('nextthink'), ${qt + 0.05})`);
  await P.db.exec(`UPDATE ents SET frame = (SELECT a.first_frame FROM anims a WHERE a.model_id = ents.model_id AND a.anim = '${stand}') WHERE id = ${M.ID}`);
  for (const g of [P, Q]) await g.db.exec('UPDATE rng SET seed = 12345');
  // checkclient's leaf found afresh in both at the first think (the last one was found when other monsters looked)
  await P.db.exec('UPDATE game SET check_time = NULL'); await Q.db.exec('UPDATE qc_vm SET check_time = NULL');
  const row = (g) => g.q1(`SELECT e.x, e.y, e.z, e.frame, ${g === P ? 'e.health' : `CAST(qc_f(${qid}, qc_fdef('health')) AS INTEGER) health`}, (SELECT seed FROM rng) seed, e.yaw, e.ideal_yaw, (SELECT p.x || ' ' || p.y || ' ' || p.z FROM ents p WHERE p.id = ${g.pid}) ppos FROM ents e WHERE e.id = ${g === P ? M.ID : qid}`);
  const fmt = (r, h) => (process.env.DBGM ? `yaw ${r.YAW} iy ${r.IDEAL_YAW} player at ${r.PPOS} ` : '') + `${r.X.toFixed(2)} ${r.Y.toFixed(2)} ${r.Z.toFixed(2)} frame ${r.FRAME} hp ${r.HEALTH} seed ${r.SEED} player ${h}`;
  // fighting back: in god mode (the player's pains are not drawn: T_Damage leaves before th_pain), shells to spare, the
  // view turned to the monster's middle every tic in each game (the same turn while the two agree), a shot every 0.6 s
  // (held, the next shot falls exactly 0.5 s on, where each game's clock rounds its own way)
  // (the zombie takes rockets: its health is back to 60 at every hit, and only 60 at once gibs it)
  const rl = mtype === 'zombie';
  if (fight) for (const g of [P, Q]) {
    await g.db.query("SELECT msg FROM host_cmd('god', '', '')"); await g.db.query("SELECT msg FROM host_cmd('give', 's', '100')");
    if (rl) { await g.db.query("SELECT msg FROM host_cmd('give', '7', '')"); await g.db.query("SELECT msg FROM host_cmd('give', 'r', '20')"); }
  }
    const aim = async (g) => {
    const v = await g.q1(`SELECT p.x px, p.y py, p.z pz, m.x mx, m.y my, m.z + (m.minz + m.maxz) / 2 mz FROM ents p, ents m WHERE p.id = ${g.pid} AND m.id = ${g === P ? M.ID : qid}`);
    const yaw = (Math.atan2(v.MY - v.PY, v.MX - v.PX) * 180) / Math.PI, pitch = (-Math.atan2(v.MZ - (v.PZ + 22), Math.hypot(v.MX - v.PX, v.MY - v.PY)) * 180) / Math.PI;
    const cur = g.view ?? { yaw: 0, pitch: 0 };
    return { yd: ((((yaw - cur.yaw) % 360) + 540) % 360) - 180, pd: pitch - cur.pitch };
  };
  const ftic = async (g, k) => {
    const t = await aim(g);
    const r = await g.q1(`SELECT health, yaw, pitch - punch pitch FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, ${t.yd}, ${t.pd}, ${k % 12 === 0 ? 1 : 0}, 0, 1, 0)`);
    g.view = { yaw: r.YAW, pitch: r.PITCH };
    return r;
  };
  if (fight) for (const g of [P, Q]) g.view = await g.q1(`SELECT yaw, pitch - punch pitch FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, 0, 0, 0, 0, 1, ${rl ? 7 : 0})`).then((r) => ({ yaw: r.YAW, pitch: r.PITCH }));
  if (fight) for (const g of [P, Q]) await g.db.exec('UPDATE rng SET seed = 12345');
  let k = 0, parted = null, last = null, moved = 0, hurt = false, still = 0;
  for (; k < N; k++) {
    const a = await (fight ? ftic(P, k) : tic(P)), b = await (fight ? ftic(Q, k) : tic(Q));
    const ma = await row(P), mb = await row(Q);
    const dead = a.HEALTH <= 0 && b.HEALTH <= 0;      // the killing blow: the same, but the deaths draw their own
    if ((ma.SEED !== mb.SEED && !dead) || Math.abs(ma.X - mb.X) > 0.01 || Math.abs(ma.Y - mb.Y) > 0.01 || Math.abs(ma.Z - mb.Z) > 0.01 || ma.FRAME !== mb.FRAME
        || ma.HEALTH !== mb.HEALTH || a.HEALTH !== b.HEALTH) { parted = `tic ${k}: PSQL ${fmt(ma, a.HEALTH)} | QuakeC ${fmt(mb, b.HEALTH)}`; break; }
    if (process.env.TRACE && k >= +process.env.TRACE) console.log('T', k, fmt(ma, a.HEALTH), '|', fmt(mb, b.HEALTH));
    if (last) moved += Math.hypot(ma.X - last.X, ma.Y - last.Y);
    if (a.HEALTH < 100) hurt = true;
    still = last && ma.HEALTH <= 0 && ma.FRAME === last.FRAME ? still + 1 : 0;
    last = ma;
    if (a.HEALTH <= 0) break;            // the player's death is not compared
    if (fight && still >= 20) break;     // the monster dead, its last frame shown a second
  }
  if (fight) assert(!parted && last && last.HEALTH <= 0, parted ? `${map} ${mtype} shot at: parted at ${parted}` : `${map} ${mtype} shot at: ${k + 1} tics the same, every random draw too, until it lay dead (${last ? `hp ${last.HEALTH}, frame ${last.FRAME}` : ''})`);
  else assert(!parted && hurt, parted ? `${map} ${mtype}: parted at ${parted}` : `${map} ${mtype}: ${k + 1} tics the same, every random draw too, until the player ${last && (await P.q1(`SELECT health FROM ents WHERE id = ${P.pid}`)).HEALTH <= 0 ? 'died' : 'had had enough'} (moved ${moved.toFixed(0)} units)`);
  await P.db.close(); await Q.db.close();
}

// E1M4's air_bubbles, in both games: every monster away, the bubble makers started on the same tic from one seed
// (their bubbles so far gone), then the generator and the bubbles compared every tic: make_bubbles's next bubble 0.5
// to 1.5 s on, bubble_bob's three draws a bob, the split on the fourth bob, the end on the twentieth
async function bubbles(map, N = 300) {
  const P = await open('pbub'); await loadMap(P.db, pak, P.res, map, { skill: 1, seed: 1 });
  const Q = await open('qbub'); await loadMap(Q.db, pak, Q.res, map, { skill: 1, seed: 1 });
  await loadProgs(Q.db, pak); await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  for (const g of [P, Q]) await g.db.query("SELECT msg FROM host_cmd('notarget', '', '')");
  const tic = (g) => g.q1(`SELECT health FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, 0, 0, 0, 0, 1, 0)`);
  for (const g of [P, Q]) for (let k = 0; k < 10; k++) await tic(g);
  await P.db.exec('UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL, x = x + 50000 WHERE mtype IS NOT NULL');
  await Q.db.exec("UPDATE ents SET solid = 0, x = x + 50000 WHERE BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_')");
  for (const g of [P, Q]) for (const r of (await g.db.query('SELECT id FROM ents WHERE x > 40000')).rows) {
    await g.db.exec(`EXECUTE PROCEDURE link_ent(${r.ID})`);
    if (g === Q) for (const f of ['nextthink', 'health', 'takedamage']) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('${f}'), 0)`);
  }
  const bub = "(SELECT m.id FROM models m WHERE m.name = 'progs/s_bubble.spr')";
  await P.db.exec(`DELETE FROM ents WHERE model_id = ${bub}`);
  const pt = (await P.q1('SELECT time_ t FROM game')).T;
  await P.db.exec(`UPDATE ents SET nextthink = ${pt} + 0.05 WHERE think = 'make_bubbles'`);
  for (const r of (await Q.db.query(`SELECT id FROM ents WHERE model_id = ${bub}`)).rows) await Q.db.exec(`EXECUTE PROCEDURE qc_free(${r.ID})`);
  const qt = (await Q.q1('SELECT time_ t FROM game')).T;
  const makers = (await Q.db.query("SELECT e.id FROM ents e WHERE qc_f(e.id, qc_fdef('think')) = qc_fn('make_bubbles')")).rows;
  for (const r of makers) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('nextthink'), ${qt + 0.05})`);
  const pm = (await P.q1("SELECT COUNT(*) n FROM ents WHERE think = 'make_bubbles'")).N;
  for (const g of [P, Q]) await g.db.exec('UPDATE rng SET seed = 12345');
  const row = (g) => g.q1(`SELECT (SELECT seed FROM rng) seed, (SELECT COUNT(*) FROM ents WHERE model_id = ${bub}) n FROM rdb$database`);
  let parted = null, most = 0, k = 0;
  for (; k < N && !parted; k++) {
    await tic(P); await tic(Q);
    const a = await row(P), b = await row(Q);
    if (a.SEED !== b.SEED || a.N !== b.N) parted = `tic ${k}: PSQL seed ${a.SEED} bubbles ${a.N} | QuakeC seed ${b.SEED} bubbles ${b.N}`;
    most = Math.max(most, a.N);
  }
  assert(!parted && pm > 0 && pm === makers.length && most > 2, parted ? `${map} air_bubbles: parted at ${parted}`
    : `${map} air_bubbles: ${pm} bubble makers, ${N} tics the same, every random draw too (up to ${most} bubbles at once)`);
  await P.db.close(); await Q.db.close();
}

// a monster on its path_corner patrol in both games, unseen (notarget): put at the same place, frame and think phase,
// heading for the same corner along the same ideal_yaw, from one seed, and compared every tic (place, frame, the
// generator): ai_walk's steps and movetogoal's draws, the corners touched (t_movetarget), the idle sounds
async function walker(map, mtype, N = 400) {
  const P = await open(`pw${mtype}`); await loadMap(P.db, pak, P.res, map, { skill: 1, seed: 1 });
  const Q = await open(`qw${mtype}`); await loadMap(Q.db, pak, Q.res, map, { skill: 1, seed: 1 });
  await loadProgs(Q.db, pak); await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  for (const g of [P, Q]) await g.db.query("SELECT msg FROM host_cmd('notarget', '', '')");
  const tic = (g) => g.q1(`SELECT health FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, 0, 0, 0, 0, 1, 0)`);
  for (const g of [P, Q]) for (let k = 0; k < 10; k++) await tic(g);
  P.pid = (await P.q1('SELECT player_ent() id FROM rdb$database')).ID; Q.pid = 1;
  const M = await P.q1(`SELECT e.id, e.x, e.y, e.z, e.yaw, e.ideal_yaw, e.goal_id, c.x cx, c.y cy, c.z cz FROM ents e JOIN ents c ON c.id = e.goal_id WHERE e.mtype = '${mtype}' AND e.st = 'walk' AND e.health > 0 ORDER BY e.id ROWS 1`);
  if (!M) { assert(false, `${map} ${mtype}: one walking a path`); return; }
  const near = (x, y, z, extra = '') => Q.q1(`SELECT id FROM ents WHERE id <> 1 ${extra} AND ABS(x - ${x}) < 48 AND ABS(y - ${y}) < 48 AND ABS(z - ${z}) < 48 ORDER BY (x - ${x}) * (x - ${x}) + (y - ${y}) * (y - ${y}) ROWS 1`);
  const qid = (await near(M.X, M.Y, M.Z, 'AND solid = 3'))?.ID;
  const qgoal = (await Q.q1(`SELECT id FROM ents WHERE ABS(x - ${M.CX}) < 1 AND ABS(y - ${M.CY}) < 1 AND ABS(z - ${M.CZ}) < 1 AND qc_str(CAST(qc_f(id, qc_fdef('classname')) AS INTEGER)) = 'path_corner' ROWS 1`))?.ID;
  if (!qid || !qgoal) { assert(false, `${mtype}: the same walker and corner in QuakeC mode (${qid}, ${qgoal})`); return; }
  // every other monster away
  await P.db.exec(`UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL, x = x + 50000 WHERE mtype IS NOT NULL AND id <> ${M.ID}`);
  await Q.db.exec(`UPDATE ents SET solid = 0, x = x + 50000 WHERE id <> ${qid} AND (BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_'))`);
  for (const g of [P, Q]) for (const r of (await g.db.query('SELECT id FROM ents WHERE x > 40000')).rows) {
    await g.db.exec(`EXECUTE PROCEDURE link_ent(${r.ID})`);
    if (g === Q) for (const f of ['nextthink', 'health', 'takedamage']) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('${f}'), 0)`);
  }
  // the same place, heading and goal; walk1 shown, the next think next tic (army_walk2 or the like)
  const walk = (await P.q1(`SELECT t.walk_anim a FROM monster_types t WHERE t.name = '${mtype}'`)).A;
  await Q.db.exec(`UPDATE ents SET x = ${M.X}, y = ${M.Y}, z = ${M.Z}, yaw = ${M.YAW}, ideal_yaw = ${M.IDEAL_YAW} WHERE id = ${qid}`);
  await Q.db.exec(`EXECUTE PROCEDURE link_ent(${qid})`);
  for (const f of ['goalentity', 'movetarget']) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('${f}'), ${qgoal})`);
  await P.db.exec(`EXECUTE PROCEDURE set_anim(${M.ID}, '${walk}')`);
  await P.db.exec(`UPDATE ents SET nextthink = (SELECT time_ FROM game) + 0.05 WHERE id = ${M.ID}`);
  const fn = { army: 'army_walk2', dog: 'dog_walk2', knight: 'knight_walk2', ogre: 'ogre_walk2', demon1: 'demon1_walk2', wizard: 'wiz_walk2', shambler: 'sham_walk2', zombie: 'zombie_walk2', enforcer: 'enf_walk2' }[mtype];
  const qt = (await Q.q1('SELECT time_ t FROM game')).T;
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('frame'), ${(await P.q1(`SELECT frame FROM ents WHERE id = ${M.ID}`)).FRAME})`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('think'), qc_fn('${fn}'))`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('nextthink'), ${qt + 0.05})`);
  for (const g of [P, Q]) await g.db.exec('UPDATE rng SET seed = 12345');
  const row = (g) => g.q1(`SELECT e.x, e.y, e.z, e.frame, e.yaw, ${g === P ? 'e.goal_id' : `CAST(qc_f(e.id, qc_fdef('goalentity')) AS INTEGER)`} goal, (SELECT seed FROM rng) seed FROM ents e WHERE e.id = ${g === P ? M.ID : qid}`);
  const fmt = (r) => `${r.X.toFixed(2)} ${r.Y.toFixed(2)} ${r.Z.toFixed(2)} yaw ${r.YAW.toFixed(1)} frame ${r.FRAME} seed ${r.SEED}`;
  let parted = null, moved = 0, last = null, lastQ = null, turns = 0, k = 0;
  for (; k < N && !parted; k++) {
    await tic(P); await tic(Q);
    const a = await row(P), b = await row(Q);
    if (a.SEED !== b.SEED || Math.abs(a.X - b.X) > 0.01 || Math.abs(a.Y - b.Y) > 0.01 || Math.abs(a.Z - b.Z) > 0.01 || a.FRAME !== b.FRAME) parted = `tic ${k}: PSQL ${fmt(a)} | QuakeC ${fmt(b)}`;
    if (process.env.TRACE && k >= +process.env.TRACE) console.log('T', k, fmt(a), '|', fmt(b));
    if (last) { moved += Math.hypot(a.X - last.X, a.Y - last.Y); if (a.GOAL !== last.GOAL) turns++; }
    if (last && (a.GOAL !== last.GOAL) !== (b.GOAL !== lastQ.GOAL)) parted = parted ?? `tic ${k}: a corner reached in one game only (PSQL ${last.GOAL} → ${a.GOAL}, QuakeC ${lastQ.GOAL} → ${b.GOAL})`;
    lastQ = b;
    last = a;
  }
  assert(!parted && moved > 50 && turns > 0, parted ? `${map} ${mtype} walking: parted at ${parted}` : `${map} ${mtype} walking its path: ${N} tics the same, every random draw too (walked ${moved.toFixed(0)} units, ${turns} corner(s) reached)`);
  await P.db.close(); await Q.db.close();
}

const DUELS = [['e1m1', 'army', 0, 576], ['e1m1', 'dog', 88, 1520], ['e1m2', 'knight'], ['e1m2', 'ogre'], ['e1m3', 'demon1'], ['e1m3', 'wizard'], ['e1m6', 'shambler'], ['e1m3', 'zombie']];
// the levels where each kind walks a path at the start (no dog or shambler does: E1M6's shambler's target is a door)
const WALKS = [['e1m1', 'army'], ['e1m2', 'knight'], ['e1m2', 'ogre'], ['e1m3', 'demon1'], ['e1m3', 'zombie'], ['e1m4', 'wizard']];
const only = process.env.DUEL;
if (!only) {
  for (const mtype of [...DUELS.map((d) => d[1]), ...DUELS.map((d) => `${d[1]}:fight`), ...WALKS.map((w) => `${w[1]}:walk`), 'bubbles']) {
    const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], { stdio: 'inherit', env: { ...process.env, DUEL: mtype } });
    if (r.status !== 0) failed++;
  }
} else {
  for (const [map, mtype, mx, my] of DUELS) {
    if (only.split(',').includes(mtype)) await duel(map, mtype, mx, my);
    if (only.split(',').includes(`${mtype}:fight`)) await duel(map, mtype, mx, my, true);
  }
  for (const [map, mtype] of WALKS) if (only.split(',').includes(`${mtype}:walk`)) await walker(map, mtype);
  if (only.split(',').includes('bubbles')) await bubbles('e1m4');
  if (!failed) process.exit(0);
}

if (failed) { console.error(`\n${failed} check(s) failed`); process.exit(1); }
console.log('\nall monster parity checks passed');
process.exit(0);
