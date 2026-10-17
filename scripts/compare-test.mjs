// compare-test.mjs – the two renderers agree: a frame painted from FRAME_FACES (every vertex projected in SQL)
// and from FRAME_FACES_FAST (SQL picks the faces, the painter projects them) must be the same pixels, as the
// screenshot tool's --compare checks by hand. From E1M1's start, and beside a door with an explosion going
// off, whose light reaches the door's faces only if the slow rows carry the brush model's origin. (An edge on a
// scanline's centre once took another row in each: the painter rounds screen positions to a millionth.)
//
//   node scripts/compare-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak, loadPalette } from '../src/pak.js';
import { createSchema, loadResources, loadMap, setView, SQL_FILES } from '../src/loader.js';
import { Renderer } from '../src/renderer.js';
import { frameDlights } from '../src/dlights.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser(`memory://cmp${Math.random()}`, { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
await setView(db, 320, 176, 90);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const arr = (s) => db.query(s, [], { rowMode: 'array' }).then((r) => r.rows);
await db.exec('UPDATE ents SET health = 0, solid = 0, nextthink = NULL WHERE mtype IS NOT NULL');
const canvas = { width: 0, height: 0, getContext: () => ({ createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }), putImageData() {} }) };
const r = new Renderer(canvas, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });
r.setResources(res);
r.setSize(320, 200);
const pe = (await q1('SELECT ent_id e FROM player')).E;

async function both(label, at, explosion = null) {
  if (at) {
    await db.exec(`UPDATE ents SET x = ${at[0]}, y = ${at[1]}, z = ${at[2]}, yaw = ${at[3]}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
    await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  }
  const last = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');
  const slow = await arr('SELECT * FROM frame_faces'), fast = await arr('SELECT * FROM frame_faces_fast');
  const ents = await arr('SELECT * FROM frame_ents');
  const styles = new Float32Array(64);
  for (const [s, v] of await arr('SELECT * FROM frame_lightstyles')) if (s < 64) styles[s] = v;
  const explosions = explosion ? [{ x: explosion[0], y: explosion[1], z: explosion[2], t0: last.TIME_ }] : [];
  const paint = (draw, xs = explosions) => {
    r.surfCache.clear();
    r.entOrigin.clear();                   // as the page in the slow mode has it: nothing left from a fast frame
    r.beginFrame({ x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW, pitch: last.PITCH, fov: 90 });
    r.dlights = frameDlights({ ents, models: res.models, explosions: xs, time: last.TIME_, rnd: () => 0.5 });
    draw();
    return r.fb.slice();
  };
  const a = paint(() => r.drawFaces(slow, styles, last.TIME_, new Map()));
  const b = paint(() => r.drawFaceList(fast, styles, last.TIME_, new Map()));
  const unlit = explosion ? paint(() => r.drawFaces(slow, styles, last.TIME_, new Map()), []) : null;
  const brush = new Set(fast.filter((f) => f[1] !== 0).map((f) => f[1])).size;
  let diff = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) diff++;
  assert(diff === 0, `${label}: the SQL-projected and the painter-projected frames are the same pixels (${diff} differ; ${fast.length} faces, ${brush} brush models)`);
  return { a, unlit };
}

await both("E1M1's start", null);
// between E1M1's first two doors (brush models), an explosion going off before them
const lit = await both('before the doors, an explosion lighting them', [420, 576, 25, 180], [250, 576, 64]);
let brighter = 0;
for (let i = 0; i < lit.a.length; i++) if (lit.a[i] !== lit.unlit[i]) brighter++;
assert(brighter > 2000, `and the explosion does light the SQL-projected frame (${brighter} pixels changed)`);

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all compare checks passed');
process.exit(failed ? 1 : 0);
