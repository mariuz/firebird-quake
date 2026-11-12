// level-parity-test.mjs – a whole level in both games, tic by tic: the map loaded twice with one seed, one played by
// the PSQL game (quake_tic), the other by progs.dat (qc_tic), the player standing still at the start, and every
// monster compared each tic (its place and frame) with the random generator's state (both draw from the seeded
// rnd(), so the same state means the same draws in the same order). It holds what the monsters do on their own
// from the level's first frame: their start-up (the spread of their first thinks, the drop to the floor, the path
// walkers' first corner), standing, patrolling, waking and coming for the player, and the doors they open on the way.
// The edicts too: the PSQL game numbers its entities as QuakeC's edicts (ed_alloc, ed_free), and the number in use and
// the free ones must be QuakeC's every tic. A level that parts reports the first tic and the monsters that differ. Each level runs in a process of its own.
// Then fights (FIGHTS): the player put in both games on the first free spot 192 to 320 units from the first monster
// with one, in its sight and away from triggers, turned to face it and firing every 0.6 s, the player compared every
// tic too (its place and health) for 400 tics: the waking, the chase, the shots both ways, pains, deaths, the
// player's death or its weapon running dry.
//
//   node scripts/level-parity-test.mjs
//   MAPS=e1m2,e1m6 TICS=600 FIGHTS= node scripts/level-parity-test.mjs

import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const TICS = +(process.env.TICS ?? 300);
const MAPS = (process.env.MAPS ?? 'e1m1,e1m2,e1m3,e1m4,e1m5,e1m6').split(',').filter(Boolean);
const FIGHTS = (process.env.FIGHTS ?? 'e1m1,e1m2,e1m3,e1m4,e1m5,e1m6').split(',').filter(Boolean);

if (!process.env.LEVEL) {
  let failed = 0;
  for (const [map, fight] of [...MAPS.map((m) => [m, '']), ...FIGHTS.map((m) => [m, '1'])]) {
    const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], { env: { ...process.env, LEVEL: map, FIGHT: fight }, stdio: 'inherit' });
    if (r.status !== 0) failed++;
  }
  console.log(failed ? `${failed} level(s) parted` : `all ${MAPS.length} levels the same for ${TICS} tics, and ${FIGHTS.length} fights for 400`);
  process.exit(failed ? 1 : 0);
}

const map = process.env.LEVEL, fight = process.env.FIGHT === '1';
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const open = async (name) => {
  const db = new FirebirdBrowser(`memory://${name}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  return { db, res: await loadResources(db, pak) };
};
const P = await open('psql');
await loadMap(P.db, pak, P.res, map, { skill: 1, seed: 7 });
const Q = await open('qc');
await loadMap(Q.db, pak, Q.res, map, { skill: 1, seed: 7 });
// the PSQL game's spawn draws from the generator, QuakeC's spawn draws again: both start from the level's seed
await Q.db.exec('UPDATE rng SET seed = level_seed');
await loadProgs(Q.db, pak);
await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');

const seed = async (g) => (await g.db.query('SELECT seed FROM rng')).rows[0].SEED;
const pm = (await P.db.query('SELECT id FROM ents WHERE mtype IS NOT NULL ORDER BY id')).rows.map((r) => r.ID);
const qm = (await Q.db.query("SELECT e.id FROM ents e WHERE qc_str(CAST(qc_f(e.id, qc_fdef('classname')) AS INTEGER)) STARTING WITH 'monster_' ORDER BY e.id")).rows.map((r) => r.ID);
const rows = async (g, ids) => (ids.length ? (await g.db.query(`SELECT id, x, y, z, frame FROM ents WHERE id IN (${ids.join(',')}) ORDER BY id`)).rows : []);
const fmt = (r) => (r ? `${r.ID}(${r.X.toFixed(1)},${r.Y.toFixed(1)},${r.Z.toFixed(1)} frame ${r.FRAME})` : 'none');

// the fight's spot: tried around the first monster with one, the player's turn to face it
let face = 0, pe = null;
if (fight) {
  pe = (await P.db.query("SELECT id FROM ents WHERE classname = 'player'")).rows[0].ID;
  const pyaw = (await P.db.query(`SELECT yaw FROM ents WHERE id = ${pe}`)).rows[0].YAW;
  let spot = null;
  out: for (const m of (await P.db.query("SELECT id, x, y, z FROM ents WHERE mtype IS NOT NULL AND st <> 'cruc' ORDER BY id")).rows)
    for (const d of [256, 192, 320]) for (let a = 0; a < 360; a += 30) {
      const fx = Math.round(m.X + Math.cos((a * Math.PI) / 180) * d), fy = Math.round(m.Y + Math.sin((a * Math.PI) / 180) * d), fz = Math.round(m.Z);
      const r = (await P.db.query(`SELECT test_position(${pe}, ${fx}, ${fy}, ${fz}) t, (SELECT fraction FROM trace_move(${m.ID}, 0, 0, 0, 0, 0, 0, ${m.X}, ${m.Y}, ${m.Z + 22}, ${fx}, ${fy}, ${fz + 22}, 1)) f, (SELECT COUNT(*) FROM ents t WHERE t.solid = 1 AND t.x + t.minx < ${fx} + 64 AND t.x + t.maxx > ${fx} - 64 AND t.y + t.miny < ${fy} + 64 AND t.y + t.maxy > ${fy} - 64 AND t.z + t.minz < ${fz} + 64 AND t.z + t.maxz > ${fz} - 256) tr FROM rdb$database`)).rows[0];
      if (r.T === 0 && r.F === 1 && r.TR === 0) { spot = [fx, fy, fz]; face = Math.round(((((a + 180 - pyaw) % 360) + 540) % 360) - 180); break out; }
    }
  for (const [g, id] of [[P, pe], [Q, 1]]) {
    await g.db.exec(`UPDATE ents SET x = ${spot[0]}, y = ${spot[1]}, z = ${spot[2]}, vx = 0, vy = 0, vz = 0 WHERE id = ${id}`);
    await g.db.exec(`EXECUTE PROCEDURE link_ent(${id})`);
  }
  // (checkclient's PVS found afresh in both: the last was found where the player stood at the load)
  await P.db.exec('UPDATE game SET check_time = NULL'); await Q.db.exec('UPDATE qc_vm SET check_time = NULL');
}
const N = fight ? 400 : TICS;

let parted = null;
if (pm.length !== qm.length) parted = `${pm.length} monsters in the PSQL game, ${qm.length} in QuakeC's`;
else if ((await seed(P)) !== (await seed(Q))) parted = 'the generators differ after the load';
for (let k = 0; k < N && !parted; k++) {
  const args = fight ? `1, 0, 0, ${k === 0 ? face : 0}, 0, ${k > 0 && k % 12 === 0 ? 1 : 0}, 0, 1, 0` : '1, 0, 0, 0, 0, 0, 0, 1, 0';
  const a = (await P.db.query(`SELECT health, px, py, pz FROM quake_tic(${args})`)).rows[0];
  const b = (await Q.db.query(`SELECT health, px, py, pz FROM qc_tic(${args})`)).rows[0];
  if (a.HEALTH !== b.HEALTH || Math.abs(a.PX - b.PX) > 0.01 || Math.abs(a.PY - b.PY) > 0.01 || Math.abs(a.PZ - b.PZ) > 0.01) {
    parted = `tic ${k}: the player, PSQL ${JSON.stringify(a)} QuakeC ${JSON.stringify(b)}`;
    break;
  }
  // the edicts: the PSQL game's mirror of them (ed_alloc, ed_free) as many as QuakeC's, the same ones free
  const ea = (await P.db.query("SELECT (SELECT num_edicts FROM game) n, (SELECT LIST(edict, ',') FROM (SELECT edict FROM edict_free WHERE free_tic IS NULL ORDER BY edict)) f FROM rdb$database")).rows[0];
  const eb = (await Q.db.query("SELECT (SELECT MAX(id) + 1 FROM qc_edicts) n, (SELECT LIST(id, ',') FROM (SELECT id FROM qc_edicts WHERE free = 1 ORDER BY id)) f FROM rdb$database")).rows[0];
  if (ea.N !== eb.N || (ea.F ?? '') !== (eb.F ?? '')) { parted = `tic ${k}: the edicts, PSQL ${ea.N} (free ${ea.F ?? 'none'}) QuakeC ${eb.N} (free ${eb.F ?? 'none'})`; break; }
  const ra = await rows(P, pm), rb = await rows(Q, qm);
  const bad = ra.map((r, i) => [r, rb[i]]).filter(([r, s]) => !s || Math.abs(r.X - s.X) > 0.01 || Math.abs(r.Y - s.Y) > 0.01 || Math.abs(r.Z - s.Z) > 0.01 || r.FRAME !== s.FRAME);
  const sa = await seed(P), sb = await seed(Q);
  if (sa !== sb || bad.length)
    parted = `tic ${k}: generators ${sa} ${sb}${bad.length ? ', ' : ''}${bad.slice(0, 4).map(([r, s]) => `PSQL ${fmt(r)} QuakeC ${fmt(s)}`).join(', ')}`;
}
const what = fight ? `${map} fight` : map;
if (parted) console.error(`FAIL: ${what} parts at ${parted}`);
else console.log(`ok   ${what}: ${pm.length} monsters${fight ? ' and the player' : ''} the same in both games for ${N} tics`);
process.exit(parted ? 1 : 0);
