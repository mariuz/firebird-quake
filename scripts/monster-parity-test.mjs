// monster-parity-test.mjs – a monster in both games, tic by tic: E1M1 loaded twice with one seed, every monster
// moved out of the way but one (a grunt, then a dog), the random generator set to the same seed in both, the player
// put where it is seen, and the monster compared every tic until it has killed the player: its place, frame, health,
// the player's health and the generator itself (both games draw from the seeded rnd(), so its state shows that the
// two make the same random draws in the same order). A monster that parts reports the first tic and both rows.
//
//   node scripts/monster-parity-test.mjs

import fs from 'node:fs';
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
async function duel(mtype, mx, my, D = 300, N = 400) {
  const P = await open(`p${mtype}`); await loadMap(P.db, pak, P.res, 'e1m1', { skill: 1, seed: 1 });
  const Q = await open(`q${mtype}`); await loadMap(Q.db, pak, Q.res, 'e1m1', { skill: 1, seed: 1 });
  await loadProgs(Q.db, pak); await Q.db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  const tic = (g) => g.q1(`SELECT health FROM ${g === P ? 'quake_tic' : 'qc_tic'}(1, 0, 0, 0, 0, 0, 0, 1, 0)`);
  for (const g of [P, Q]) for (let k = 0; k < 10; k++) await tic(g);     // QuakeC's items and monsters placed
  const M = await P.q1(`SELECT id, x, y, z, yaw FROM ents WHERE mtype = '${mtype}' AND ABS(x - ${mx}) < 1 AND ABS(y - ${my}) < 1`);
  const qid = (await Q.q1(`SELECT id FROM ents WHERE ABS(x - ${M.X}) < 1 AND ABS(y - ${M.Y}) < 1 AND ABS(z - ${M.Z}) < 2 AND solid = 3`))?.ID;
  if (!qid) { assert(false, `${mtype}: the same monster in QuakeC mode`); return; }
  // every other monster out of the world, thinking no more
  await P.db.exec(`UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL, x = x + 50000 WHERE mtype IS NOT NULL AND id <> ${M.ID}`);
  await Q.db.exec(`UPDATE ents SET solid = 0, x = x + 50000 WHERE id <> ${qid} AND (BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_'))`);
  for (const g of [P, Q]) for (const r of (await g.db.query('SELECT id FROM ents WHERE x > 40000')).rows) {
    await g.db.exec(`EXECUTE PROCEDURE link_ent(${r.ID})`);
    if (g === Q) await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${r.ID}, qc_fdef('nextthink'), 0)`);
  }
  // the player in front of it, on a free spot
  const yaw = (M.YAW * Math.PI) / 180;
  let px, py;
  for (let d = D; d >= 64; d -= 16) {
    px = M.X + Math.cos(yaw) * d; py = M.Y + Math.sin(yaw) * d;
    if ((await P.q1(`SELECT test_position(1, ${px}, ${py}, ${M.Z}) t FROM rdb$database`)).T === 0) break;
  }
  for (const g of [P, Q]) { await g.db.exec(`UPDATE ents SET x = ${px}, y = ${py}, z = ${M.Z}, vx = 0, vy = 0, vz = 0 WHERE id = 1`); await g.db.exec('EXECUTE PROCEDURE link_ent(1)'); }
  // the same frame and think phase in both: standing, its next think next tic (set_anim has entered stand1, so
  // QuakeC's next think is army_stand2 or the like), and one seed
  const stand = (await P.q1(`SELECT t.stand_anim a FROM monster_types t WHERE t.name = '${mtype}'`)).A;
  await P.db.exec(`EXECUTE PROCEDURE set_anim(${M.ID}, '${stand}')`);
  await P.db.exec(`UPDATE ents SET nextthink = (SELECT time_ FROM game) + 0.05 WHERE id = ${M.ID}`);
  const qt = (await Q.q1('SELECT time_ t FROM game')).T;
  const fn = { army: 'army_stand2', dog: 'dog_stand2' }[mtype];
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('frame'), (SELECT frame FROM ents WHERE id = ${qid}))`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('think'), qc_fn('${fn}'))`);
  await Q.db.exec(`EXECUTE PROCEDURE qc_sf(${qid}, qc_fdef('nextthink'), ${qt + 0.05})`);
  await P.db.exec(`UPDATE ents SET frame = (SELECT a.first_frame FROM anims a WHERE a.model_id = ents.model_id AND a.anim = '${stand}') WHERE id = ${M.ID}`);
  for (const g of [P, Q]) await g.db.exec('UPDATE rng SET seed = 12345');
  const row = (g) => g.q1(`SELECT e.x, e.y, e.z, e.frame, ${g === P ? 'e.health' : `CAST(qc_f(${qid}, qc_fdef('health')) AS INTEGER) health`}, (SELECT seed FROM rng) seed FROM ents e WHERE e.id = ${g === P ? M.ID : qid}`);
  const fmt = (r, h) => `${r.X.toFixed(2)} ${r.Y.toFixed(2)} ${r.Z.toFixed(2)} frame ${r.FRAME} hp ${r.HEALTH} seed ${r.SEED} player ${h}`;
  let k = 0, parted = null, last = null, moved = 0, hurt = false;
  for (; k < N; k++) {
    const a = await tic(P), b = await tic(Q);
    const ma = await row(P), mb = await row(Q);
    const dead = a.HEALTH <= 0 && b.HEALTH <= 0;      // the killing blow: the same, but the deaths draw their own
    if ((ma.SEED !== mb.SEED && !dead) || Math.abs(ma.X - mb.X) > 0.01 || Math.abs(ma.Y - mb.Y) > 0.01 || Math.abs(ma.Z - mb.Z) > 0.01 || ma.FRAME !== mb.FRAME
        || ma.HEALTH !== mb.HEALTH || a.HEALTH !== b.HEALTH) { parted = `tic ${k}: PSQL ${fmt(ma, a.HEALTH)} | QuakeC ${fmt(mb, b.HEALTH)}`; break; }
    if (last) moved += Math.hypot(ma.X - last.X, ma.Y - last.Y);
    if (a.HEALTH < 100) hurt = true;
    last = ma;
    if (a.HEALTH <= 0) break;            // the player's death is not compared
  }
  assert(!parted && hurt && moved > 20, parted ? `${mtype}: parted at ${parted}` : `${mtype}: ${k + 1} tics the same, every random draw too, until the player ${last && (await P.q1('SELECT health FROM ents WHERE id = 1')).HEALTH <= 0 ? 'died' : 'had had enough'} (moved ${moved.toFixed(0)} units)`);
  await P.db.close(); await Q.db.close();
}

await duel('army', 0, 576);
await duel('dog', 88, 1520);

if (failed) { console.error(`\n${failed} check(s) failed`); process.exit(1); }
console.log('\nall monster parity checks passed');
process.exit(0);
