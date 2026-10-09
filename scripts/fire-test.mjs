// fire-test.mjs – the shambler's lightning and the lava fireballs, as shambler.qc and misc.qc have them.
// A shambler casts on sham_magic6, skips magic7 and magic8, casts on magic9 and magic10, and a fourth
// time on magic11 on nightmare. A misc_fireball throws a lava ball up at its speed plus up to 200, 50
// sideways at most; without a speed key it throws it only up to 200 high (misc.qc's "speed == 1000").
//
//   node scripts/fire-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://fire', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const qa = (s) => db.query(s).then((r) => r.rows);
const tic = () => q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');

// ── the shambler's lightning ───────────────────────────────────────────────
// E1M1's long open floor, the locals dead, the player in god mode; a shambler 350 units off, hunting it
async function attacks(skill, wanted) {
  await loadMap(db, pak, res, 'e1m1', { skill, seed: 21 });
  await db.exec(`UPDATE game SET skill = ${skill}`);
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  await db.exec("UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL");
  await db.exec(`UPDATE ents SET x = -72, y = 2896, z = -56, yaw = 0, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  await tic();
  const sham = (await q1("SELECT id FROM spawn_monster('shambler', 350)")).ID;
  await db.exec(`EXECUTE PROCEDURE found_target(${sham}, ${pe})`);
  const magic = await q1(`SELECT a.first_frame f FROM anims a JOIN ents e ON e.model_id = a.model_id WHERE e.id = ${sham} AND a.anim = 'magic'`);
  let lastFx = (await q1('SELECT COALESCE(MAX(id), 0) m FROM fx_events')).M;
  const seen = [];        // per attack: the magic frames shown and the frames a bolt was cast on
  let cur = null, prev = null;
  for (let i = 0; i < 1200 && seen.filter((a) => a.done).length < wanted; i++) {
    await tic();
    const e = await q1(`SELECT st, frame FROM ents WHERE id = ${sham}`);
    const castOn = prev ?? e.FRAME;     // a think casts on the frame it shows, then steps to the next
    prev = e.FRAME;
    const bolts = await qa(`SELECT id FROM fx_events WHERE kind = 4 AND n = ${sham} AND id > ${lastFx}`);
    if (bolts.length) lastFx = bolts.at(-1).ID;
    if (e.ST === 'missile') {
      if (!cur) { cur = { frames: [], bolts: [] }; seen.push(cur); }
      cur.frames.push(e.FRAME - magic.F);
      for (const _ of bolts) cur.bolts.push(castOn - magic.F);
    } else if (cur) { cur.done = true; cur = null; }
  }
  return seen.filter((a) => a.done);
}
for (const [skill, label, want] of [[1, 'normal', '5,8,9'], [3, 'nightmare', '5,8,9,10']]) {
  const done = await attacks(skill, 2);
  assert(done.length >= 1, `${label}: the shambler casts its lightning (${done.length} attacks watched)`);
  for (const [k, a] of done.entries()) {
    const shown = [...new Set(a.frames)];
    assert(a.bolts.join() === want, `${label}, attack ${k + 1}: bolts on magic frames ${a.bolts.map((f) => f + 1).join(', ')} (sham_magic${want.split(',').map((f) => Number(f) + 1).join(', ')})`);
    assert(!shown.includes(6) && !shown.includes(7), `${label}, attack ${k + 1}: magic7 and magic8 are skipped (frames shown ${shown.map((f) => f + 1).join(' ')})`);
  }
}

// ── the fireballs ───────────────────────────────────────────────────────────
// the start map's three spawners have speed 600: a ball leaves at 600 to 800 up, 50 sideways at most
await loadMap(db, pak, res, 'start', { skill: 1, seed: 4 });
const spawners = await qa("SELECT id, speed FROM ents WHERE think = 'fireball_think'");
async function balls(n) {
  const out = new Map();
  for (let i = 0; i < 400 && out.size < n; i++) {
    await tic();
    for (const b of await qa("SELECT id, vx, vy, vz FROM ents WHERE classname = 'fireball'")) if (!out.has(b.ID)) out.set(b.ID, b);
  }
  return [...out.values()];
}
assert(spawners.length === 3 && spawners.every((s) => s.SPEED === 600), 'the start map\'s three fireball spawners, speed 600');
let got = await balls(6);
// seen on the tic they were thrown, gravity has had one tic (40 units a second) at most
assert(got.length >= 6 && got.every((b) => b.VZ <= 800 && b.VZ >= 600 - 41 && Math.abs(b.VX) <= 50 && Math.abs(b.VY) <= 50),
  `each ball leaves at its speed plus up to 200 up, 50 sideways at most (vz ${got.map((b) => b.VZ.toFixed(0)).join(' ')})`);
// a spawner without a speed key: misc.qc's bug leaves it at 0, so the ball rises up to 200
await loadMap(db, pak, res, 'start', { skill: 1, seed: 4 });
await db.exec("UPDATE ents SET speed = 0 WHERE think = 'fireball_think'");     // as spawned without the key
got = await balls(6);
assert(got.length >= 6 && got.every((b) => b.VZ <= 200 && b.VZ >= -41),
  `without a speed key the ball rises only up to 200 (vz ${got.map((b) => b.VZ.toFixed(0)).join(' ')}), as misc.qc's "self.speed == 1000" leaves it`);

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all fire checks passed');
process.exit(failed ? 1 : 0);
