// zip.js – a mod as it is distributed: a .zip of a game directory (progs.dat, progs/*.mdl, maps/*.bsp,
// sound/…, and often pak0.pak, pak1.pak…), read with the platform's DecompressionStream (browsers and
// Node 18+), and laid out as Quake lays out a game directory over id1 (COM_AddGameDirectory).

import { Pak } from './pak.js';

const td = new TextDecoder('latin1');

/** The entries of a zip: name → { method, size, csize, off } (the local header's offset). */
function entries(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let p = bytes.length - 22; p >= Math.max(0, bytes.length - 22 - 65535); p--) {
    if (dv.getUint32(p, true) === 0x06054b50) { eocd = p; break; }
  }
  if (eocd < 0) throw new Error('not a zip file');
  const n = dv.getUint16(eocd + 10, true);
  let p = dv.getUint32(eocd + 16, true);
  const out = new Map();
  for (let i = 0; i < n; i++) {
    if (dv.getUint32(p, true) !== 0x02014b50) throw new Error('a damaged zip directory');
    const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), size = dv.getUint32(p + 24, true);
    const nlen = dv.getUint16(p + 28, true), xlen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
    const off = dv.getUint32(p + 42, true);
    const name = td.decode(bytes.subarray(p + 46, p + 46 + nlen)).replace(/\\/g, '/');
    if (!name.endsWith('/')) out.set(name, { method, size, csize, off });
    p += 46 + nlen + xlen + clen;
  }
  return out;
}

async function inflate(data) {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** A file's bytes. Stored and deflated entries only (what every Quake mod zip uses). */
async function extract(bytes, e) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const start = e.off + 30 + dv.getUint16(e.off + 26, true) + dv.getUint16(e.off + 28, true);
  const data = bytes.subarray(start, start + e.csize);
  if (e.method === 0) return data.slice();
  if (e.method === 8) return inflate(data);
  throw new Error(`zip compression method ${e.method} is not supported`);
}

/** Loose files of a game directory, as a pak (for PakSet). */
export class LooseFiles {
  constructor(files) { this.files = files; }   // lower-case name → Uint8Array
  has(name) { return this.files.has(name.toLowerCase()); }
  get(name) {
    const f = this.files.get(name.toLowerCase());
    if (!f) throw new Error(`${name} not in the mod`);
    return f;
  }
  buffer(name) { return this.get(name).slice().buffer; }
}

/**
 * A mod's zip as the paks it adds over id1, lowest priority first: its loose files, then its pak files in
 * order (Quake searches a game directory's pak0, pak1… before its loose files). The game directory is the
 * folder holding progs.dat or a pak file, at any depth (zips often wrap it: fbxc/frikbot/progs.dat).
 * Returns { name, paks, progs } where progs says whether the mod has its own progs.dat.
 */
export async function modFromZip(buffer, label = 'mod') {
  const bytes = new Uint8Array(buffer);
  const all = entries(bytes);
  const roots = [...all.keys()].filter((n) => /(^|\/)(progs\.dat|pak\d+\.pak)$/i.test(n)).map((n) => n.slice(0, n.lastIndexOf('/') + 1));
  if (!roots.length) throw new Error(`${label} has no progs.dat and no pak file`);
  const root = roots.sort((a, b) => a.length - b.length)[0];
  const loose = new Map();
  const paks = [];
  for (const [name, e] of all) {
    if (!name.startsWith(root)) continue;
    const rel = name.slice(root.length).toLowerCase();
    if (/^pak\d+\.pak$/.test(rel)) paks.push([Number(rel.slice(3, -4)), new Pak((await extract(bytes, e)).buffer)]);
    else if (!rel.includes('/') && !/\.(dat|lmp|cfg|rc|wad)$/.test(rel)) continue;   // readmes, batch files, qwprogs…
    else if (!rel.startsWith('src/')) loose.set(rel, await extract(bytes, e));
  }
  paks.sort((a, b) => a[0] - b[0]);
  const layers = [new LooseFiles(loose), ...paks.map(([, p]) => p)];
  const progs = layers.some((l) => l.has('progs.dat'));
  const name = root.split('/').filter(Boolean).pop() ?? label.replace(/\.zip$/i, '');
  return { name, paks: layers, progs };
}
