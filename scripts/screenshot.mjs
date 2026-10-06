// screenshot.mjs – render frames headlessly: the SQL runs in Firebird WASM
// under Node, the painter runs against a stub canvas, and the frames are
// written as PNGs to docs/. Also a convenient end-to-end test.
//
//   node scripts/screenshot.mjs [map] [out-prefix]
//   node scripts/screenshot.mjs e1m1 docs/shot      → docs/shot-e1m1-0.png …
//   options: --at=x,y,z,yaw  --sql="stmt; stmt"  --tics=N  --single  --fast  --compare

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, Wad2, loadPalette } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { Renderer, lightPoint } from '../src/renderer.js';
import { Hud, VIEW_MODELS } from '../src/hud.js';
import { png } from './png.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mapName = process.argv[2] ?? 'e1m1';
const prefix = process.argv[3] ?? path.join(root, 'docs/screenshot');
const W = 320, H = 200;
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

// a canvas stub: the renderer only needs createImageData/putImageData
const stubCanvas = {
  width: W, height: H,
  getContext: () => ({
    createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
    putImageData(img) { stubCanvas.image = img; },
  }),
};

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const res = await loadResources(db, pak, { width: W, height: H - 24 });
const bsp = await loadMap(db, pak, res, mapName);
const renderer = new Renderer(stubCanvas, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });
renderer.setSize(W, H);
renderer.setResources(res);
renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
const hud = new Hud(new Wad2(pak.get('gfx.wad')));

// --at x,y,z,yaw: start the shots from a given spot (for looking at things)
const at = process.argv.find((a) => a.startsWith('--at='));
if (at) {
  const [x, y, z, yaw] = at.slice(5).split(',').map(Number);
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = (SELECT ent_id FROM player)`);
  await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))');
}
const tic = (args) => db.query('SELECT * FROM quake_tic(?, ?, ?, ?, ?, ?, ?, ?, ?)', args, { rowMode: 'object' }).then((r) => r.rows[0]);
// --sql="stmt; stmt": run statements first (wake a boss, open a door); --tics=N: let the world run N tics before the shots
const pre = process.argv.find((a) => a.startsWith('--sql='));
if (pre) for (const stmt of pre.slice(6).split(';')) if (stmt.trim()) await db.exec(stmt.trim());
const warm = Number(process.argv.find((a) => a.startsWith('--tics='))?.slice(7) ?? 0);
for (let i = 0; i < warm; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
const arr = { rowMode: 'array' };

async function shot(name) {
  const last = await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
  const t0 = performance.now();
  const fast = process.argv.includes('--fast');
  const compare = process.argv.includes('--compare');
  const faces = (await db.query(fast ? 'SELECT * FROM frame_faces_fast' : 'SELECT * FROM frame_faces', [], arr)).rows;
  const facesFast = compare ? (await db.query('SELECT * FROM frame_faces_fast', [], arr)).rows : null;
  const ents = (await db.query('SELECT * FROM frame_ents', [], arr)).rows;
  const styles = new Float32Array(64);
  for (const [s, v] of (await db.query('SELECT * FROM frame_lightstyles', [], arr)).rows) if (s < 64) styles[s] = v;
  const t1 = performance.now();
  renderer.beginFrame({ x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW, pitch: last.PITCH, fov: 90 });
  if (fast) renderer.drawFaceList(faces, styles, last.TIME_, new Map());
  else renderer.drawFaces(faces, styles, last.TIME_, new Map());
  if (compare) {
    const sqlFb = renderer.fb.slice();
    renderer.beginFrame({ x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW, pitch: last.PITCH, fov: 90 });
    renderer.drawFaceList(facesFast, styles, last.TIME_, new Map());
    let diff = 0;
    for (let i = 0; i < sqlFb.length; i++) if (sqlFb[i] !== renderer.fb[i]) diff++;
    console.log(`${name}: SQL-projected vs JS-projected frame differ in ${diff} of ${sqlFb.length} pixels (${facesFast.length} faces)`);
  }
  for (const e of ents) {
    const [, mid, frame, skin, x, y, z, pitch, yaw, roll, effects, alpha, kind] = e;
    const m = res.models.get(mid);
    if (!m) continue;
    if (kind.trim() === 'M') renderer.drawAlias(m.mdl, frame, skin, [x, y, z], [pitch, yaw, roll], effects & 8 ? 255 : lightPoint(bsp, x, y, z + 8), { time: last.TIME_ });
    else if (kind.trim() === 'S') renderer.drawSprite(m.spr, frame, [x, y, z]);
  }
  const vm = res.models.get(res.byName.get(VIEW_MODELS[last.WEAPON]));
  if (vm) { renderer.zb.fill(0); renderer.drawAlias(vm.mdl, 0, 0, [last.PX, last.PY, last.VIEW_Z + 2], [-last.PITCH, last.YAW, 0], Math.max(lightPoint(bsp, last.PX, last.PY, last.PZ), 32), { near: 1 }); }
  hud.draw(renderer, last, last.TIME_);
  renderer.present();
  const t2 = performance.now();
  const nf = fast ? faces.length : new Set(faces.map((r) => r[0])).size;
  console.log(`${name}: ${nf} faces, ${faces.length} vertex rows, ${ents.length} ents — queries ${(t1 - t0).toFixed(0)} ms, raster ${(t2 - t1).toFixed(0)} ms`);
  fs.mkdirSync(path.dirname(prefix), { recursive: true });
  fs.writeFileSync(`${prefix}-${mapName}-${name}.png`, png(W, H, new Uint8Array(stubCanvas.image.data.buffer)));
}

await shot('0');
if (process.argv.includes('--single')) { await db.close(); process.exit(0); }
for (let i = 0; i < 2; i++) await tic([1, 0, 0, 90, 0, 0, 0, 1, 0]);
await shot('1');
// walk ahead a bit and look around
for (let i = 0; i < 40; i++) await tic([1, 1, 0, 0, 0, 0, 0, 1, 0]);
await shot('2');
for (let i = 0; i < 2; i++) await tic([1, 0, 0, 90, 0, 0, 0, 1, 0]);
await shot('3');
await db.close();
process.exit(0);
