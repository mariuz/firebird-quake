import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { Pak, loadPalette } from '../src/pak.js';
import { Mdl } from '../src/mdl.js';
import { Renderer } from '../src/renderer.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
for (const n of ['progs/v_shot.mdl', 'progs/soldier.mdl']) {
  const m = new Mdl(pak.buffer(n), n);
  let mn = [1e9, 1e9, 1e9], mx = [-1e9, -1e9, -1e9];
  const v = m.frames[0].verts;
  for (let i = 0; i < m.numVerts; i++) for (let k = 0; k < 3; k++) { const c = v[i * 4 + k] * m.scale[k] + m.origin[k]; mn[k] = Math.min(mn[k], c); mx[k] = Math.max(mx[k], c); }
  console.log(n, 'scale', m.scale.map((x) => x.toFixed(3)), 'origin', m.origin.map((x) => x.toFixed(1)), 'bbox', mn.map((x) => x.toFixed(1)), mx.map((x) => x.toFixed(1)), 'tris', m.numTris, 'skin', m.skinW, m.skinH);
}
const stub = { getContext: () => ({ createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }), putImageData() {} }) };
const r = new Renderer(stub, { palette: loadPalette(pak.get('gfx/palette.lmp')), colormap: pak.get('gfx/colormap.lmp') });
r.setSize(320, 200);
r.beginFrame({ x: 0, y: 0, z: 0, yaw: 0, pitch: 0, fov: 90 });
const vm = new Mdl(pak.buffer('progs/v_shot.mdl'), 'v_shot');
r.drawAlias(vm, 0, 0, [0, 0, 0], [0, 0, 0], 255, { near: 1 });
let x0 = 999, x1 = -1, y0 = 999, y1 = -1, n = 0;
for (let y = 0; y < 200; y++) for (let x = 0; x < 320; x++) if (r.fb[y * 320 + x]) { n++; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
console.log('viewmodel pixels', n, 'bbox x', x0, x1, 'y', y0, y1);
// a soldier 160 units ahead
r.beginFrame({ x: 0, y: 0, z: 46, yaw: 0, pitch: 0, fov: 90 });
const sol = new Mdl(pak.buffer('progs/soldier.mdl'), 'soldier');
r.drawAlias(sol, 0, 0, [160, 0, 24], [0, 180, 0], 255, {});
x0 = 999; x1 = -1; y0 = 999; y1 = -1; n = 0;
for (let y = 0; y < 200; y++) for (let x = 0; x < 320; x++) if (r.fb[y * 320 + x]) { n++; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
console.log('soldier pixels', n, 'bbox x', x0, x1, 'y', y0, y1, '(expected ~56 tall)');
