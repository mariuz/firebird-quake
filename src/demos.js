// demos.js – a demo (sql/demo.sql) out of Firebird and back in, and played back.
//
// exportDemo reads the demo row and its tics into a plain object (the page keeps it in IndexedDB beside
// the saves and offers it as a file); importDemo writes such an object back; DemoPlayer hands the
// recorded arguments to the loop one quake_tic call at a time. Shared by the page and
// scripts/demo-test.mjs.

import { lit, execInserts } from './saves.js';

export const DEMO_VERSION = 1;
const COLS = ['tics', 'fwd', 'side', 'yaw_d', 'pitch_d', 'fire', 'jump', 'run', 'imp'];

/** { version, map, skill, qc, seed, the server's rules (deathmatch, coop, nbots, fraglimit, timelimit),
 *    tics: [[tics, fwd, side, yaw_d, pitch_d, fire, jump, run, imp] …] }, or null. */
export async function exportDemo(db) {
  const d = (await db.query('SELECT map_name, skill, qc_mode, seed, deathmatch, coop, nbots, fraglimit, timelimit FROM demo WHERE id = 1', [], { rowMode: 'object' })).rows[0];
  if (!d?.MAP_NAME) return null;
  const { rows } = await db.query(`SELECT ${COLS.join(', ')} FROM demo_tics ORDER BY n`, [], { rowMode: 'array' });
  return { version: DEMO_VERSION, map: d.MAP_NAME, skill: d.SKILL, qc: d.QC_MODE, seed: Number(d.SEED),
    deathmatch: d.DEATHMATCH, coop: d.COOP, nbots: d.NBOTS, fraglimit: d.FRAGLIMIT, timelimit: d.TIMELIMIT, tics: rows };
}

/** A demo object back into the demo tables (not recording). */
export async function importDemo(db, demo) {
  if (!demo || demo.version !== DEMO_VERSION || !Array.isArray(demo.tics)) throw new Error('not a demo of this version of Firebird Quake');
  await db.exec(`DELETE FROM demo_tics; UPDATE demo SET map_name = ${lit(demo.map)}, skill = ${lit(demo.skill)}, qc_mode = ${lit(demo.qc)}, seed = ${lit(demo.seed)}, recording = 0, calls = ${demo.tics.length},
    deathmatch = ${lit(demo.deathmatch ?? 0)}, coop = ${lit(demo.coop ?? 0)}, nbots = ${lit(demo.nbots ?? 0)}, fraglimit = ${lit(demo.fraglimit ?? 0)}, timelimit = ${lit(demo.timelimit ?? 0)} WHERE id = 1`);
  await execInserts(db, demo.tics.map((r, i) => `INSERT INTO demo_tics (n, ${COLS.join(', ')}) VALUES (${i + 1}, ${r.map(lit).join(', ')});`));
}

/** The recorded calls in order: next() gives a call's nine arguments, or null at the end. */
export class DemoPlayer {
  constructor(demo) { this.demo = demo; this.n = 0; }
  get done() { return this.n >= this.demo.tics.length; }
  next() { return this.done ? null : this.demo.tics[this.n++]; }
  /** the recorded calls that make up about `tics` tics of game time (at least one) */
  take(tics) {
    const out = [];
    let t = 0;
    while (!this.done && (out.length === 0 || t + this.demo.tics[this.n][0] <= tics)) { const r = this.next(); out.push(r); t += r[0]; }
    return out;
  }
}
