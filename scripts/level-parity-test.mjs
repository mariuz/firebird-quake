// level-parity-test.mjs – a whole level in both games, tic by tic: the map loaded twice with one seed, one played by
// the PSQL game (quake_tic), the other by progs.dat (qc_tic), the player standing still at the start, and every
// monster compared each tic (its place and frame) with the random generator's state (both draw from the seeded
// rnd(), so the same state means the same draws in the same order). It holds what the monsters do on their own
// from the level's first frame: their start-up (the spread of their first thinks, the drop to the floor, the path
// walkers' first corner), standing, patrolling, waking and coming for the player, and the doors they open on the way.
// A level that parts reports the first tic and the monsters that differ. Each level runs in a process of its own.
//
//   node scripts/level-parity-test.mjs
//   MAPS=e1m2,e1m6 TICS=600 node scripts/level-parity-test.mjs

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
const MAPS = (process.env.MAPS ?? 'e1m1,e1m2,e1m3,e1m4,e1m5,e1m6').split(',');

if (!process.env.LEVEL) {
  let failed = 0;
  for (const map of MAPS) {
    const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], { env: { ...process.env, LEVEL: map }, stdio: 'inherit' });
    if (r.status !== 0) failed++;
  }
  console.log(failed ? `${failed} level(s) parted` : `all ${MAPS.length} levels the same for ${TICS} tics`);
  process.exit(failed ? 1 : 0);
}

const map = process.env.LEVEL;
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

let parted = null;
if (pm.length !== qm.length) parted = `${pm.length} monsters in the PSQL game, ${qm.length} in QuakeC's`;
else if ((await seed(P)) !== (await seed(Q))) parted = 'the generators differ after the load';
for (let k = 0; k < TICS && !parted; k++) {
  await P.db.query('SELECT health FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  await Q.db.query('SELECT health FROM qc_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  const ra = await rows(P, pm), rb = await rows(Q, qm);
  const bad = ra.map((r, i) => [r, rb[i]]).filter(([r, s]) => !s || Math.abs(r.X - s.X) > 0.01 || Math.abs(r.Y - s.Y) > 0.01 || Math.abs(r.Z - s.Z) > 0.01 || r.FRAME !== s.FRAME);
  const sa = await seed(P), sb = await seed(Q);
  if (sa !== sb || bad.length)
    parted = `tic ${k}: generators ${sa} ${sb}${bad.length ? ', ' : ''}${bad.slice(0, 4).map(([r, s]) => `PSQL ${fmt(r)} QuakeC ${fmt(s)}`).join(', ')}`;
}
if (parted) console.error(`FAIL: ${map} parts at ${parted}`);
else console.log(`ok   ${map}: ${pm.length} monsters the same in both games for ${TICS} tics`);
process.exit(parted ? 1 : 0);
