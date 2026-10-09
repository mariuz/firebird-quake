// bsp2-test.mjs – the larger-map BSP formats: BSP2 (32-bit indices, float bounds) and RMQ's 2PSB (32-bit
// indices, 16-bit bounds), as QuakeSpasm reads them. No shareware or LibreQuake lite map uses them, so E1M1
// is rewritten in both (the nodes, clipnodes, faces, leaves, marksurfaces and edges re-encoded, every other
// lump copied) and each copy must load to the same rows as the original and play the same game, tic for
// tic, from the same seed and input; the renderer must draw it the same.
//
//   node scripts/bsp2-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { Bsp } from '../src/bsp.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

/** A BSP 29 file rewritten as 'BSP2' or '2PSB'. */
export function widen(src, magic) {
  const dv = new DataView(src.buffer, src.byteOffset, src.byteLength);
  const lump = (i) => [dv.getInt32(4 + i * 8, true), dv.getInt32(8 + i * 8, true)];
  const f2 = magic === 'BSP2';
  const out = [];
  for (let i = 0; i < 15; i++) {
    const [off, len] = lump(i);
    const r = (p) => off + p;
    let chunks = null;
    const conv = (size, n, enc) => {
      const b = new DataView(new ArrayBuffer(n * size));
      for (let k = 0; k < n; k++) enc(b, k * size, k);
      return new Uint8Array(b.buffer);
    };
    const bound = (b, at, v) => (f2 ? b.setFloat32(at, v, true) : b.setInt16(at, v, true));
    const bs = f2 ? 4 : 2;
    if (i === 5) chunks = conv(4 + 8 + 6 * bs + 8, len / 24, (b, o, k) => {      // nodes
      const p = r(k * 24);
      b.setInt32(o, dv.getInt32(p, true), true);
      b.setInt32(o + 4, dv.getInt16(p + 4, true), true); b.setInt32(o + 8, dv.getInt16(p + 6, true), true);
      for (let j = 0; j < 6; j++) bound(b, o + 12 + j * bs, dv.getInt16(p + 8 + j * 2, true));
      b.setUint32(o + 12 + 6 * bs, dv.getUint16(p + 20, true), true); b.setUint32(o + 16 + 6 * bs, dv.getUint16(p + 22, true), true);
    });
    else if (i === 9) chunks = conv(12, len / 8, (b, o, k) => {                      // clipnodes
      const p = r(k * 8);
      b.setInt32(o, dv.getInt32(p, true), true); b.setInt32(o + 4, dv.getInt16(p + 4, true), true); b.setInt32(o + 8, dv.getInt16(p + 6, true), true);
    });
    else if (i === 7) chunks = conv(28, len / 20, (b, o, k) => {                     // faces
      const p = r(k * 20);
      b.setInt32(o, dv.getUint16(p, true), true); b.setInt32(o + 4, dv.getUint16(p + 2, true), true);
      b.setInt32(o + 8, dv.getInt32(p + 4, true), true); b.setInt32(o + 12, dv.getUint16(p + 8, true), true);
      b.setInt32(o + 16, dv.getUint16(p + 10, true), true);
      for (let j = 0; j < 4; j++) b.setUint8(o + 20 + j, dv.getUint8(p + 12 + j));
      b.setInt32(o + 24, dv.getInt32(p + 16, true), true);
    });
    else if (i === 10) chunks = conv(8 + 6 * bs + 12, len / 28, (b, o, k) => {     // leaves
      const p = r(k * 28);
      b.setInt32(o, dv.getInt32(p, true), true); b.setInt32(o + 4, dv.getInt32(p + 4, true), true);
      for (let j = 0; j < 6; j++) bound(b, o + 8 + j * bs, dv.getInt16(p + 8 + j * 2, true));
      const m = o + 8 + 6 * bs;
      b.setUint32(m, dv.getUint16(p + 20, true), true); b.setUint32(m + 4, dv.getUint16(p + 22, true), true);
      for (let j = 0; j < 4; j++) b.setUint8(m + 8 + j, dv.getUint8(p + 24 + j));
    });
    else if (i === 11 || i === 12) chunks = conv(4, len / 2, (b, o, k) => b.setUint32(o, dv.getUint16(r(k * 2), true), true));   // marksurfaces, edges
    else chunks = new Uint8Array(src.buffer, src.byteOffset + off, len);
    out.push(chunks);
  }
  let size = 4 + 15 * 8;
  const offs = out.map((c) => { const o = size; size += (c.length + 3) & ~3; return o; });
  const file = new Uint8Array(size);
  const fv = new DataView(file.buffer);
  for (let k = 0; k < 4; k++) file[k] = magic.charCodeAt(k);
  out.forEach((c, i) => { fv.setInt32(4 + i * 8, offs[i], true); fv.setInt32(8 + i * 8, c.length, true); file.set(c, offs[i]); });
  return file;
}

const pak = new Pak(fs.readFileSync(pakPath).buffer);
const orig = pak.buffer('maps/e1m1.bsp');
const origBytes = new Uint8Array(orig.buffer ?? orig, orig.byteOffset ?? 0, orig.byteLength);
const copies = { bsp2: widen(origBytes, 'BSP2'), '2psb': widen(origBytes, '2PSB') };
// the pak, with the rewritten copies as maps of their own
const pakWith = new Proxy(pak, { get(t, k) {
  if (k === 'buffer') return (n) => { const m = /^maps\/e1m1_(bsp2|2psb)\.bsp$/.exec(n); return m ? copies[m[1]].buffer : t.buffer(n); };
  if (k === 'has') return (n) => /^maps\/e1m1_(bsp2|2psb)\.bsp$/.test(n) || t.has(n);
  const v = t[k]; return typeof v === 'function' ? v.bind(t) : v;
} });

const a = new Bsp(origBytes.slice().buffer, 'e1m1');
for (const [k, c] of Object.entries(copies)) {
  const b = new Bsp(c.buffer, k);
  const same = ['nodes', 'faces', 'clipnodes', 'leaves'].every((l) => JSON.stringify(a[l]) === JSON.stringify(b[l]))
    && [...a.marksurfaces].join() === [...b.marksurfaces].join() && [...a.edges].join() === [...b.edges].join() && a.pvsHex.join() === b.pvsHex.join();
  assert(b.format === (k === 'bsp2' ? 'BSP2' : '2PSB') && same, `E1M1 as ${b.format} (${c.length} bytes against ${origBytes.length}): the parser reads the same nodes, faces, clipnodes, leaves, marksurfaces, edges and PVS`);
}

const db = new FirebirdBrowser('memory://bsp2', { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pakWith);
const qa = (s) => db.query(s, [], { rowMode: 'array' }).then((r) => JSON.stringify(r.rows));
const input = (i) => [1, i % 70 < 50 ? 1 : 0, i % 30 < 8 ? 1 : 0, i % 25 < 4 ? 7 : 0, 0, i % 9 === 0 ? 1 : 0, i % 40 === 0 ? 1 : 0, 1, i === 2 ? 9 : 0];
async function play(name) {
  await loadMap(db, pakWith, res, name, { skill: 1, seed: 77 });
  // the world's rows, model ids made relative to the world's (each load numbers its brush models afresh)
  const tables = await Promise.all([
    qa('SELECT f.id, f.model_id - g.world_model, f.nx, f.ny, f.nz, f.dist, f.nverts, f.miptex, f.sx, f.sy, f.sz, f.soff, f.tx, f.ty, f.tz, f.toff, f.style0 FROM faces f, game g WHERE f.id < 1000000 ORDER BY f.id'),
    qa('SELECT * FROM face_verts WHERE face < 1000000 ORDER BY face, seq'), qa('SELECT * FROM leaves ORDER BY id'),
    qa('SELECT * FROM hulls ORDER BY hull, node'), qa('SELECT * FROM marksurfaces ORDER BY id'),
  ]);
  const trace = [];
  for (let i = 0; i < 150; i++) {
    const r = (await db.query('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', input(i))).rows[0];
    trace.push([r.PX, r.PY, r.PZ, r.HEALTH, r.KILLED, r.LEAF].join());
  }
  return { tables, trace, faces: await qa('SELECT * FROM frame_faces_fast') };
}
const base = await play('e1m1');
for (const k of ['bsp2', '2psb']) {
  const c = await play(`e1m1_${k}`);
  assert(c.tables.every((t, i) => t === base.tables[i]), `${k}: loads to the same faces, vertices, leaves (with their PVS), hull nodes and marksurfaces as E1M1`);
  const at = c.trace.findIndex((t, i) => t !== base.trace[i]);
  assert(at === -1, `${k}: 150 tics of the same input play the same game (diverged at ${at})`);
  assert(c.faces === base.faces, `${k}: and the frame query picks the same faces`);
}
let refused = '';
try { new Bsp(new Uint8Array([30, 0, 0, 0, ...new Array(124).fill(0)]).buffer, 'x'); } catch (e) { refused = e.message; }
assert(/expected 29, BSP2 or 2PSB/.test(refused), `another version is refused by name (${refused})`);

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all BSP2 checks passed');
process.exit(failed ? 1 : 0);
