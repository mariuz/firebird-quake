// monster-parity-test.mjs – a monster in both games, tic by tic: its level loaded twice with one seed, every monster
// moved out of the way but one (each shareware kind in turn: grunt, dog, knight, ogre, fiend, scrag, shambler,
// zombie), the random generator set to the same seed in both, the player put on a free spot in its sight (out of the
// water and away from triggers), and the monster compared every tic until it has killed the player: its place, frame,
// health, the player's health and the generator itself (both games draw from the seeded rnd(), so its state shows
// that the two make the same random draws in the same order). A monster that parts reports the first tic and both rows.
// Each duel runs in a process of its own (two engines a duel).
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
async function duel(map, mtype, mx, my, D = 300, N = 400) {
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
      const ok = await P.q1(`SELECT test_position(${P.pid}, ${fx}, ${fy}, ${fz}) t, (SELECT fraction FROM trace_move(${c.ID}, 0, 0, 0, 0, 0, 0, ${c.X}, ${c.Y}, ${c.Z + 22}, ${fx}, ${fy}, ${fz + 22}, 1)) f , (SELECT COUNT(*) FROM ents t WHERE t.solid = 1 AND t.x + t.minx < ${fx} + 64 AND t.x + t.maxx > ${fx} - 64 AND t.y + t.miny < ${fy} + 64 AND t.y + t.maxy > ${fy} - 64 AND t.z + t.minz < ${fz} + 64 AND t.z + t.maxz > ${fz} - 256) tr, point_contents(${fx}, ${fy}, ${fz}) w, point_contents(${c.X}, ${c.Y}, ${c.Z}) mw FROM rdb$database`);
      // (out of the water, both: PSQL has no air bubbles yet, whose drift QuakeC draws at random; and away from triggers)
      if (ok.T === 0 && ok.F === 1 && ok.W === -1 && ok.MW === -1 && ok.TR === 0) { M = { ...c, YAW: (c.YAW + da + 360) % 360, PX: fx, PY: fy, PZ: fz }; break search; }
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
  const row = (g) => g.q1(`SELECT e.x, e.y, e.z, e.frame, ${g === P ? 'e.health' : `CAST(qc_f(${qid}, qc_fdef('health')) AS INTEGER) health`}, (SELECT seed FROM rng) seed, e.yaw, e.ideal_yaw FROM ents e WHERE e.id = ${g === P ? M.ID : qid}`);
  const fmt = (r, h) => (process.env.DBGM ? `yaw ${r.YAW} iy ${r.IDEAL_YAW} ` : "") + `${r.X.toFixed(2)} ${r.Y.toFixed(2)} ${r.Z.toFixed(2)} frame ${r.FRAME} hp ${r.HEALTH} seed ${r.SEED} player ${h}`;
  let k = 0, parted = null, last = null, moved = 0, hurt = false;
  for (; k < N; k++) {
    const a = await tic(P), b = await tic(Q);
    const ma = await row(P), mb = await row(Q);
    const dead = a.HEALTH <= 0 && b.HEALTH <= 0;      // the killing blow: the same, but the deaths draw their own
    if ((ma.SEED !== mb.SEED && !dead) || Math.abs(ma.X - mb.X) > 0.01 || Math.abs(ma.Y - mb.Y) > 0.01 || Math.abs(ma.Z - mb.Z) > 0.01 || ma.FRAME !== mb.FRAME
        || ma.HEALTH !== mb.HEALTH || a.HEALTH !== b.HEALTH) { parted = `tic ${k}: PSQL ${fmt(ma, a.HEALTH)} | QuakeC ${fmt(mb, b.HEALTH)}`; break; }
    if (process.env.TRACE && k >= +process.env.TRACE) console.log('T', k, fmt(ma, a.HEALTH), '|', fmt(mb, b.HEALTH));
    if (last) moved += Math.hypot(ma.X - last.X, ma.Y - last.Y);
    if (a.HEALTH < 100) hurt = true;
    last = ma;
    if (a.HEALTH <= 0) break;            // the player's death is not compared
  }
  assert(!parted && hurt, parted ? `${map} ${mtype}: parted at ${parted}` : `${map} ${mtype}: ${k + 1} tics the same, every random draw too, until the player ${last && (await P.q1(`SELECT health FROM ents WHERE id = ${P.pid}`)).HEALTH <= 0 ? 'died' : 'had had enough'} (moved ${moved.toFixed(0)} units)`);
  await P.db.close(); await Q.db.close();
}

const DUELS = [['e1m1', 'army', 0, 576], ['e1m1', 'dog', 88, 1520], ['e1m2', 'knight'], ['e1m2', 'ogre'], ['e1m3', 'demon1'], ['e1m3', 'wizard'], ['e1m6', 'shambler'], ['e1m3', 'zombie']];
const only = process.env.DUEL;
if (!only) {
  for (const [, mtype] of DUELS) {
    const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], { stdio: 'inherit', env: { ...process.env, DUEL: mtype } });
    if (r.status !== 0) failed++;
  }
} else {
  for (const [map, mtype, mx, my] of DUELS) if (only.split(',').includes(mtype)) await duel(map, mtype, mx, my);
  if (!failed) process.exit(0);
}

if (failed) { console.error(`\n${failed} check(s) failed`); process.exit(1); }
console.log('\nall monster parity checks passed');
process.exit(0);
