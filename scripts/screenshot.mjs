// screenshot.mjs – render frames headlessly: the SQL runs in Firebird WASM
// under Node, the painter runs against a stub canvas, and the frames are
// written as PNGs to docs/. Also a convenient end-to-end test.
//
//   node scripts/screenshot.mjs [map] [out-prefix]
//   node scripts/screenshot.mjs e1m1 docs/shot      → docs/shot-e1m1-0.png …
//   options: --at=x,y,z,yaw  --sql="stmt; stmt"  --tics=N  (both repeatable, applied in order)  --single  --fast  --compare  --gallery
//            --qc (QuakeC mode: progs.dat spawns the map and runs the frames)

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, PakSet, Wad2, loadPalette } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES, loadProgs } from '../src/loader.js';
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
// public/pak/pak0.pak, and pak1.pak beside it if you own Quake (or PAK1=/path/to/pak1.pak): the other
// episodes and the registered monsters' models
const pakFiles = [process.env.PAK ?? path.join(root, 'public/pak/pak0.pak'), process.env.PAK1 ?? path.join(root, 'public/pak/pak1.pak')].filter((f) => fs.existsSync(f));
const pak = new PakSet(pakFiles.map((f) => new Pak(fs.readFileSync(f).buffer)));
const res = await loadResources(db, pak, { width: W, height: H - 24 });
const bsp = await loadMap(db, pak, res, mapName);
const renderer = new Renderer(stubCanvas, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });
renderer.setSize(W, H);
renderer.setResources(res);
renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
const hud = new Hud(new Wad2(pak.get('gfx.wad')));

// --qc: QuakeC mode. The map is spawned by progs.dat's own spawn functions and every tic is a QuakeC server
// frame (qc_server_frame) on the engine's physics; the status bar reads the QuakeC player's fields.
const qcMode = process.argv.includes('--qc');
const qc = { t: 1.0, pitch: 0, yaw: 0 };
if (qcMode) {
  await loadProgs(db, pak);
  await db.exec('EXECUTE PROCEDURE qc_enter');
  await db.query('SELECT * FROM qc_spawn_map(1, 1.0)');
  await db.exec('EXECUTE PROCEDURE qc_client_connect(1.0)');
  qc.yaw = (await db.query('SELECT yaw FROM ents WHERE id = 1')).rows[0].YAW;
}

// --at x,y,z,yaw: start the shots from a given spot (for looking at things)
const at = process.argv.find((a) => a.startsWith('--at='));
if (at) {
  const [x, y, z, yaw] = at.slice(5).split(',').map(Number);
  qc.yaw = yaw;
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = (SELECT ent_id FROM player)`);
  await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))');
}
const psqlTic = (args) => db.query('SELECT * FROM quake_tic(?, ?, ?, ?, ?, ?, ?, ?, ?)', args, { rowMode: 'object' }).then((r) => r.rows[0]);
// QuakeC mode: the same arguments (tics, forward, side, yaw and pitch change, fire, jump, run, impulse) as 0.05 s
// server frames, and a row shaped like QUAKE_TIC's for the shot and the status bar
const qcTic = async ([tics, fwd, side, dyaw, dpitch, fire, jump, run, imp]) => {
  qc.yaw += dyaw; qc.pitch = Math.max(-70, Math.min(80, qc.pitch + dpitch));
  for (let i = 0; i < tics; i++) {
    await db.query(`SELECT * FROM qc_server_frame(${qc.t}, 0.05, ${fwd * (run ? 400 : 200)}, ${side * 350}, 0, ${qc.pitch}, ${qc.yaw}, ${fire}, ${jump}, ${i === 0 ? imp : 0})`);
    qc.t = Math.round((qc.t + 0.05) * 1000) / 1000;
  }
  const f = (n) => `qc_f(1, qc_fdef('${n}'))`;
  const r = (await db.query(`SELECT e.x px, e.y py, e.z pz, e.z + 22 view_z, e.yaw, p.pitch, ${f('weapon')} weapon, ${f('health')} health, ${f('armorvalue')} armorvalue,
      ${f('items')} items, ${f('ammo_shells')} shells, ${f('ammo_nails')} nails, ${f('ammo_rockets')} rockets, ${f('ammo_cells')} cells
    FROM ents e CROSS JOIN player p WHERE e.id = 1 AND p.id = 1`, [], { rowMode: 'object' })).rows[0];
  return { ...r, TIME_: qc.t, DMG_TIME: -1 };
};
const tic = qcMode ? qcTic : psqlTic;
// --sql="stmt; stmt": run statements (wake a boss, open a door); --tics=N: let the world run N tics.
// Both may repeat and are applied in the order given, so a scene can be staged in steps.
for (const a of process.argv) {
  if (a.startsWith('--sql=')) {
    for (const stmt of a.slice(6).split(';')) {
      if (!stmt.trim()) continue;
      if (/^\s*select/i.test(stmt)) await db.query(stmt.trim());   // a selectable procedure (spawn_monster) runs only when selected from
      else await db.exec(stmt.trim());
    }
  }
  else if (a.startsWith('--tics=')) { const n = Number(a.slice(7)); for (let i = 0; i < n; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]); }
}
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

// --gallery: one shot from every item spot, facing the longest open direction; a quick way to find views of a level
if (process.argv.includes('--gallery')) {
  const pe = (await db.query('SELECT ent_id e FROM player')).rows[0].E;
  const spots = (await db.query("SELECT classname, CAST((x + minx + x + maxx) / 2 AS INTEGER) cx, CAST((y + miny + y + maxy) / 2 AS INTEGER) cy, CAST(z + minz AS INTEGER) z0 FROM ents WHERE classname STARTING WITH 'item_' OR classname STARTING WITH 'weapon_' OR classname = 'misc_explobox' ORDER BY id")).rows;
  let n = 0;
  for (const s of spots) {
    let best = { f: -1, yaw: 0 };
    for (let yaw = 0; yaw < 360; yaw += 45) {
      const dx = Math.cos((yaw * Math.PI) / 180) * 2000, dy = Math.sin((yaw * Math.PI) / 180) * 2000;
      const f = (await db.query(`SELECT fraction f FROM trace_move(${pe}, -16, -16, -24, 16, 16, 32, ${s.CX}, ${s.CY}, ${s.Z0 + 30}, ${s.CX + dx}, ${s.CY + dy}, ${s.Z0 + 30}, 1)`)).rows[0].F;
      if (f > best.f) best = { f, yaw };
    }
    await db.exec(`UPDATE ents SET x = ${s.CX}, y = ${s.CY}, z = ${s.Z0 + 30}, yaw = ${best.yaw}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
    for (let i = 0; i < 8; i++) await tic([1, 0, 0, 0, 0, 0, 0, 1, 0]);
    await shot(`gallery-${String(n++).padStart(2, '0')}_${s.CLASSNAME}_${s.CX}_${s.CY}_${s.Z0 + 30}_${best.yaw}`);
  }
  await db.close(); process.exit(0);
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
