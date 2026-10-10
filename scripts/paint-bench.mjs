// paint-bench.mjs – the painter's share of a frame (src/renderer.js), away from the SQL: a few scenes are
// queried once (frame_faces_fast, frame_ents, the light styles), then painted again and again at each
// resolution, with the surface cache warm (a frame while standing still) and cold (every surface built,
// as when the lights flicker or the view turns into a new room).
//
//   node scripts/paint-bench.mjs [frames]          (BENCH_JSON=file writes the ms there too)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, loadPalette } from '../src/pak.js';
import { createSchema, loadResources, loadMap, setView, SQL_FILES } from '../src/loader.js';
import { Renderer, lightPoint } from '../src/renderer.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(process.env.PAK ?? path.join(root, 'public/pak/pak0.pak')).buffer);
const N = Number(process.argv[2] ?? 20);

const db = new FirebirdBrowser('memory://paint', { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const arr = (s) => db.query(s, [], { rowMode: 'array' }).then((r) => r.rows);
const canvas = { width: 0, height: 0, getContext: () => ({ createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }), putImageData() {} }) };
const renderer = new Renderer(canvas, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });

const SCENES = [
  ['e1m1', 'the start', null],
  ['e1m1', 'the long hall', [-72, 2896, -56, 0]],
  ['e1m4', 'the lake', [1088, -784, 846, 135]],
  ['e1m3', 'the zombie pits', [-128, -824, -322, 0]],
];
const results = [];
for (const [map, label, at] of SCENES) {
  await loadMap(db, pak, res, map, { skill: 1, seed: 1 });
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  if (at) {
    await db.exec(`UPDATE ents SET x = ${at[0]}, y = ${at[1]}, z = ${at[2]}, yaw = ${at[3]} WHERE id = ${pe}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  }
  let last;
  for (let i = 0; i < 3; i++) last = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  renderer.setResources(res);
  const bsp = res.world.bsp;
  renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
  for (const [w, h, sbar] of [[320, 200, 24], [640, 400, 48]]) {
    await setView(db, w, h - sbar, 90);
    const faces = await arr('SELECT * FROM frame_faces_fast');
    const ents = await arr('SELECT * FROM frame_ents');
    const styles = new Float32Array(64);
    for (const [s, v] of await arr('SELECT * FROM frame_lightstyles')) if (s < 64) styles[s] = v;
    renderer.sbarLines = sbar;
    renderer.setSize(w, h);
    const paint = () => {
      renderer.beginFrame({ x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW, pitch: last.PITCH, fov: 90 });
      renderer.drawFaceList(faces, styles, last.TIME_, new Map());
      for (const e of ents) {
        const [, mid, frame, skin, x, y, z, pitch, yaw, roll] = e;
        const m = res.models.get(mid);
        if (m?.kind === 'M') renderer.drawAlias(m.mdl, frame, skin, [x, y, z], [pitch, yaw, roll], Math.min(255, lightPoint(bsp, x, y, z + 8)), { time: last.TIME_ });
      }
      renderer.present();
    };
    const timed = (fn) => { const t0 = performance.now(); for (let i = 0; i < N; i++) fn(); return (performance.now() - t0) / N; };
    renderer.surfCache.clear(); paint();                                  // JIT warm-up
    const warm = timed(paint);
    const cold = timed(() => { renderer.surfCache.clear(); paint(); });
    results.push({ scene: `${map} ${label}`, res: `${w}x${h}`, faces: faces.length, ents: ents.length, warm: warm.toFixed(1), cold: cold.toFixed(1) });
  }
}
console.table(results);
if (process.env.BENCH_JSON) fs.writeFileSync(process.env.BENCH_JSON, JSON.stringify(Object.fromEntries(
  results.flatMap((r) => [[`${r.scene} ${r.res} warm`, +r.warm], [`${r.scene} ${r.res} cold`, +r.cold]]))));
await db.close();
process.exit(0);
