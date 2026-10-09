// hazard-test.mjs – what hurts the player besides monsters, as client.qc's WaterMove and triggers.qc's
// hurt_touch do it: slime (E1M1) takes 4 × waterlevel a second, nothing in the biosuit; lava (E1M8)
// 10 × waterlevel every 0.2 s, every second in the biosuit (a hit waits until time is past the
// wait, so at 20 tics a second lava hits every fifth tic, four times a second, as Quake does). Each
// in the PSQL game and in QuakeC mode, where progs.dat's own WaterMove reads the engine's waterlevel
// and watertype. (trigger_hurt is tested in scripts/lq-test.mjs, in lq_e0m7's boss trap.)
//
//   node scripts/hazard-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

async function session(pakFiles) {
  const db = new FirebirdBrowser(`memory://hz${Math.random()}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const pak = new PakSet(pakFiles.map((f) => new Pak(fs.readFileSync(f).buffer)));
  const res = await loadResources(db, pak);
  const q1 = (s) => db.query(s).then((r) => r.rows[0]);
  const qa = (s) => db.query(s).then((r) => r.rows);
  let qc = false, progs = false;
  const api = {
    db, q1, qa,
    async level(map, mode) {
      qc = mode === 'qc';
      await db.exec('EXECUTE PROCEDURE qc_leave');
      await loadMap(db, pak, res, map, { skill: 1, seed: 5 });
      if (qc) {
        if (!progs) { await loadProgs(db, pak); progs = true; }
        await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
      }
      // the monsters out of the way: only the hazard hurts
      await db.exec(qc ? "UPDATE ents SET solid = 0, x = x + 50000 WHERE BIN_AND(flags, 32) <> 0 OR id IN (SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) STARTING WITH 'monster_')"
                       : 'UPDATE ents SET health = 0, solid = 0, nextthink = NULL, think = NULL WHERE mtype IS NOT NULL');
      await api.tic();
      await api.health(100000);     // no dying while the probes stand in the liquid
      return api.tic();
    },
    tic: () => q1(`SELECT * FROM ${qc ? 'qc_tic' : 'quake_tic'}(1, 0, 0, 0, 0, 0, 0, 1, 0)`),
    pe: async () => (qc ? 1 : (await q1('SELECT ent_id e FROM player')).E),
    async place(x, y, z) {
      const pe = await api.pe();
      await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
      await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
    },
    async health(v) {
      const pe = await api.pe();
      if (qc) await db.exec(`EXECUTE PROCEDURE qc_sf(1, qc_fdef('health'), ${v})`);
      else await db.exec(`UPDATE ents SET health = ${v} WHERE id = ${pe}`);
    },
    async suit(seconds) {
      if (qc) {
        const t = (await q1('SELECT time_ t FROM game')).T;
        await db.exec(`EXECUTE PROCEDURE qc_sf(1, qc_fdef('radsuit_finished'), ${t + seconds})`);
        await db.exec(`EXECUTE PROCEDURE qc_sf(1, qc_fdef('items'), ${(await q1("SELECT CAST(qc_f(1, qc_fdef('items')) AS INTEGER) i FROM rdb$database")).I | 2097152})`);
      } else await db.exec(`UPDATE player SET radsuit_finished = (SELECT time_ FROM game) + ${seconds}, items = BIN_OR(items, 2097152)`);
    },
    // a standing spot in a liquid: a leaf of those contents, its middle dropped onto the floor, where the
    // player is in it up to the waist (waterlevel 2), or failing that to the feet
    async inLiquid(contents) {
      const leaves = await qa(`SELECT id, minx, miny, minz, maxx, maxy, maxz FROM leaves WHERE contents = ${contents} ORDER BY (maxx - minx) * (maxy - miny) DESC`);
      let best = null;
      for (const l of leaves.slice(0, 40)) {
        for (const [fx, fy] of [[0.5, 0.5], [0.3, 0.3], [0.7, 0.7], [0.3, 0.7], [0.7, 0.3]]) {
          const x = l.MINX + (l.MAXX - l.MINX) * fx, y = l.MINY + (l.MAXY - l.MINY) * fy, top = l.MAXZ - 1;
          if ((await q1(`SELECT point_leaf(${x}, ${y}, ${top}) l FROM rdb$database`)).L !== l.ID) continue;
          const down = await q1(`SELECT fraction f, ez FROM trace_move(NULL, -16, -16, -24, 16, 16, 32, ${x}, ${y}, ${top}, ${x}, ${y}, ${top - 400}, 1)`);
          if (down.F >= 1 || (await q1(`SELECT test_position(1, ${x}, ${y}, ${down.EZ}) t FROM rdb$database`)).T !== 0) continue;
          const spot = { x, y, z: down.EZ };
          await api.place(x, y, down.EZ);
          await api.tic();
          const e = await q1(`SELECT waterlevel w, watertype t FROM ents WHERE id = ${await api.pe()}`);
          if (e.T === contents && e.W >= 1 && (!best || e.W > best.wl)) best = { ...spot, wl: e.W };
          if (best?.wl === 2) return best;
        }
      }
      return best;
    },
    // health lost over n tics standing at a spot
    async loss(spot, n, start = 900) {
      await api.place(spot.x, spot.y, spot.z);
      await api.health(start);
      let r;
      for (let i = 0; i < n; i++) {
        await api.place(spot.x, spot.y, spot.z); r = await api.tic();
      }
      return start - r.HEALTH;
    },
  };
  return api;
}

const id = await session([pakPath]);
for (const mode of ['psql', 'qc']) {
  const label = mode === 'qc' ? 'QuakeC mode' : 'the PSQL game';
  // slime: 4 × waterlevel once a second, nothing in the suit
  await id.level('e1m1', mode);
  const slime = await id.inLiquid(-4);
  assert(!!slime, `${label}: a spot in E1M1's slime (waterlevel ${slime?.wl})`);
  if (slime) {
    const lost = await id.loss(slime, 40);    // two seconds: two hits
    assert(lost === 2 * 4 * slime.wl, `${label}: slime takes 4 × waterlevel a second (${lost} in 2 s, expected ${2 * 4 * slime.wl})`);
    await id.suit(30);
    assert((await id.loss(slime, 40)) === 0, `${label}: nothing in the biosuit`);
  }
  // lava: 10 × waterlevel every 0.2 s, once a second in the suit
  await id.level('e1m8', mode);
  const lava = await id.inLiquid(-5);
  assert(!!lava, `${label}: a spot in E1M8's lava (waterlevel ${lava?.wl})`);
  if (lava) {
    const lost = await id.loss(lava, 20);     // one second: a hit every fifth tic, four
    assert(lost === 4 * 10 * lava.wl, `${label}: lava takes 10 × waterlevel every 0.2 s, past the wait (${lost} in 1 s, expected ${4 * 10 * lava.wl})`);
    await id.suit(30);
    const suited = await id.loss(lava, 40);
    assert(suited === 2 * 10 * lava.wl, `${label}: in the biosuit, once a second (${suited} in 2 s, expected ${2 * 10 * lava.wl})`);
  }
}
await id.db.close();

console.log(failed ? `${failed} failure(s)` : 'all hazard checks passed');
process.exit(failed ? 1 : 0);
