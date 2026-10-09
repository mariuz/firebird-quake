// water-test.mjs – see-through liquids (r_wateralpha, Renderer.liquidAlpha): a liquid is drawn translucent only
// where the map was vised for it (QuakeSpasm's test: an open leaf's PVS holds leaves of that liquid), so
// LibreQuake's water shows the floor under it from above, and id's E1M1 slime, vised the old way, stays as
// it was. Each scene is painted twice, opaque and at alpha 0.5, from above the largest liquid surface.
//
//   node scripts/water-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, loadPalette } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { Renderer } from '../src/renderer.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

async function scene(pakFile, map) {
  const db = new FirebirdBrowser(`memory://water${Math.random()}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const pak = new Pak(fs.readFileSync(pakFile).buffer);
  const res = await loadResources(db, pak);
  const bsp = await loadMap(db, pak, res, map, { skill: 1, seed: 1 });
  const q1 = (s) => db.query(s).then((r) => r.rows[0]);
  const arr = (s) => db.query(s, [], { rowMode: 'array' }).then((r) => r.rows);
  await db.exec('UPDATE ents SET health = 0, solid = 0, nextthink = NULL WHERE mtype IS NOT NULL');
  // above the largest liquid surface facing up (not a teleporter), 96 units over it, looking down
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  const water = await db.query(`SELECT f.cx, f.cy, f.cz, m.name FROM faces f JOIN miptex m ON m.id = f.miptex
    WHERE f.id < 1000000 AND m.name STARTING WITH '*' AND m.name NOT STARTING WITH '*tele' AND f.nz > 0.9 AND f.model_id = (SELECT world_model FROM game)
    ORDER BY f.radius DESC ROWS 12`).then((r) => r.rows);
  let at = null;
  for (const w of water) {
    for (const up of [96, 64, 128]) if ((await q1(`SELECT test_position(${pe}, ${w.CX}, ${w.CY}, ${w.CZ + up}) t FROM rdb$database`)).T === 0) { at = { ...w, z: w.CZ + up }; break; }
    if (at) break;
  }
  await db.exec(`UPDATE ents SET x = ${at.CX}, y = ${at.CY}, z = ${at.z}, vx = 0, vy = 0, vz = 0, flags = BIN_OR(flags, 64) WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  const last = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  const faces = await arr('SELECT * FROM frame_faces_fast');
  const styles = new Float32Array(64).fill(1);
  const canvas = { width: 0, height: 0, getContext: () => ({ createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }), putImageData() {} }) };
  const r = new Renderer(canvas, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });
  r.setResources(res);
  const paint = (alpha) => {
    r.liquidAlpha = alpha;
    r.beginFrame({ x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: 0, pitch: 70, fov: 90 });
    r.drawFaceList(faces, styles, 1, new Map());
    r.drawDeferred(1);
    return r.fb.slice();
  };
  const opaque = paint(1), seeThrough = paint(0.5);
  let diff = 0;
  for (let i = 0; i < opaque.length; i++) if (opaque[i] !== seeThrough[i]) diff++;
  await db.close();
  return { bsp, at, diff, pixels: opaque.length };
}

const lq = path.join(root, 'public/pak/lq1/pak0.pak');
if (fs.existsSync(lq)) {
  const s = await scene(lq, 'lq_e0m2');
  assert(s.bsp.seeThrough.has(-3), "lq_e0m2 was vised for its water (an open leaf's PVS holds water leaves)");
  assert(s.diff > s.pixels * 0.05, `over its ${s.at.NAME}, at alpha 0.5 the floor shows through: ${s.diff} of ${s.pixels} pixels change`);
} else console.log(`note: ${lq} missing (npm run fetch-librequake), the LibreQuake half skipped`);
const id = await scene(path.join(root, 'public/pak/pak0.pak'), 'e1m1');
assert(id.bsp.seeThrough.size === 0, 'E1M1 was not vised for its liquids');
assert(id.diff === 0, `over E1M1's ${id.at.NAME}, alpha 0.5 changes nothing: the liquid stays opaque rather than show the void`);

console.log(failed ? `${failed} failure(s)` : 'all water checks passed');
process.exit(failed ? 1 : 0);
