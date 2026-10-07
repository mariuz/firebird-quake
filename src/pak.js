// pak.js – Quake's archive formats: PAK (id1/pak0.pak), WAD2 (gfx.wad),
// LMP pictures, the palette and the colormap.

const td = new TextDecoder('latin1');

export const cstr = (bytes, off, len) => {
  let end = off;
  const max = off + len;
  while (end < max && bytes[end] !== 0) end++;
  return td.decode(bytes.subarray(off, end));
};

export class Pak {
  constructor(buffer) {
    this.bytes = new Uint8Array(buffer);
    this.dv = new DataView(buffer);
    if (cstr(this.bytes, 0, 4) !== 'PACK') throw new Error('not a PAK file');
    const dirOff = this.dv.getInt32(4, true);
    const dirLen = this.dv.getInt32(8, true);
    this.files = new Map();
    for (let p = dirOff; p < dirOff + dirLen; p += 64) {
      const name = cstr(this.bytes, p, 56).toLowerCase();
      this.files.set(name, { off: this.dv.getInt32(p + 56, true), size: this.dv.getInt32(p + 60, true) });
    }
  }

  has(name) { return this.files.has(name.toLowerCase()); }

  /** The file's bytes as a Uint8Array view (no copy). */
  get(name) {
    const e = this.files.get(name.toLowerCase());
    if (!e) throw new Error(`${name} not in pak`);
    return this.bytes.subarray(e.off, e.off + e.size);
  }

  /** A copy, as an ArrayBuffer (for DataView parsers and decodeAudioData). */
  buffer(name) {
    return this.get(name).slice().buffer;
  }

  list(prefix = '', suffix = '') {
    return [...this.files.keys()].filter((n) => n.startsWith(prefix) && n.endsWith(suffix)).sort();
  }

  mapNames() {
    return this.list('maps/', '.bsp').map((n) => n.slice(5, -4)).filter((n) => !n.startsWith('b_'));
  }
}

/** Several paks as one (pak0.pak and the registered pak1.pak): a later pak's file shadows an earlier one's. */
export class PakSet {
  constructor(paks) {
    this.paks = paks;
    this.files = new Map();
    for (const pak of paks) for (const name of pak.files.keys()) this.files.set(name, pak);
  }

  has(name) { return this.files.has(name.toLowerCase()); }

  get(name) {
    const pak = this.files.get(name.toLowerCase());
    if (!pak) throw new Error(`${name} not in pak`);
    return pak.get(name);
  }

  buffer(name) { return this.get(name).slice().buffer; }

  list(prefix = '', suffix = '') {
    return [...this.files.keys()].filter((n) => n.startsWith(prefix) && n.endsWith(suffix)).sort();
  }

  mapNames() {
    return this.list('maps/', '.bsp').map((n) => n.slice(5, -4)).filter((n) => !n.startsWith('b_'));
  }
}

/** gfx.wad: WAD2 with the status bar pictures and CONCHARS. */
export class Wad2 {
  constructor(bytes) {
    this.bytes = bytes;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (cstr(bytes, 0, 4) !== 'WAD2') throw new Error('not a WAD2 file');
    const n = dv.getInt32(4, true);
    const dirOff = dv.getInt32(8, true);
    this.lumps = new Map();
    for (let i = 0; i < n; i++) {
      const p = dirOff + i * 32;
      const name = cstr(bytes, p + 16, 16).toUpperCase();
      this.lumps.set(name, { off: dv.getInt32(p, true), size: dv.getInt32(p + 8, true), type: bytes[p + 12] });
    }
  }

  /** A qpic (type 'B' = 0x42): { w, h, data } of palette indices; CONCHARS is raw 128×128. */
  pic(name) {
    const l = this.lumps.get(name.toUpperCase());
    if (!l) return null;
    const b = this.bytes.subarray(l.off, l.off + l.size);
    if (name.toUpperCase() === 'CONCHARS') return { w: 128, h: 128, data: b };
    return qpic(b);
  }
}

/** A .lmp picture: int32 width, int32 height, then palette indices. */
export function qpic(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const w = dv.getInt32(0, true);
  const h = dv.getInt32(4, true);
  return { w, h, data: bytes.subarray(8, 8 + w * h) };
}

/** gfx/palette.lmp → Uint32Array of 256 ABGR pixels (little-endian RGBA bytes). */
export function loadPalette(bytes) {
  const pal = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    pal[i] = (255 << 24) | (bytes[i * 3 + 2] << 16) | (bytes[i * 3 + 1] << 8) | bytes[i * 3];
  }
  pal[255] &= 0x00ffffff; // transparent in sprites and skins
  return pal;
}
