// bsp.js – Quake BSP version 29. Everything the SQL side needs is produced
// as plain arrays; everything only the painter needs (texels, lightmaps)
// stays here.

import { cstr } from './pak.js';

const LUMP = {
  entities: 0, planes: 1, textures: 2, vertices: 3, visibility: 4, nodes: 5, texinfo: 6, faces: 7,
  lighting: 8, clipnodes: 9, leaves: 10, marksurfaces: 11, edges: 12, surfedges: 13, models: 14,
};

export const CONTENTS = { EMPTY: -1, SOLID: -2, WATER: -3, SLIME: -4, LAVA: -5, SKY: -6 };

export class Bsp {
  constructor(buffer, name = '') {
    this.name = name;
    const dv = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    this.bytes = bytes;
    const version = dv.getInt32(0, true);
    if (version !== 29) throw new Error(`${name}: BSP version ${version}, expected 29`);
    const lump = (i) => ({ off: dv.getInt32(4 + i * 8, true), len: dv.getInt32(8 + i * 8, true) });

    // entities
    const el = lump(LUMP.entities);
    this.entityText = cstr(bytes, el.off, el.len);
    this.entities = parseEntities(this.entityText);

    // planes
    let l = lump(LUMP.planes);
    this.planes = [];
    for (let p = l.off; p < l.off + l.len; p += 20) {
      this.planes.push({
        nx: dv.getFloat32(p, true), ny: dv.getFloat32(p + 4, true), nz: dv.getFloat32(p + 8, true),
        dist: dv.getFloat32(p + 12, true), type: dv.getInt32(p + 16, true),
      });
    }

    // vertices
    l = lump(LUMP.vertices);
    this.vertices = new Float32Array(bytes.buffer.slice(l.off, l.off + l.len));

    // visibility (compressed PVS), decompressed per leaf below
    l = lump(LUMP.visibility);
    const visdata = bytes.subarray(l.off, l.off + l.len);

    // nodes
    l = lump(LUMP.nodes);
    this.nodes = [];
    for (let p = l.off; p < l.off + l.len; p += 24) {
      this.nodes.push({
        plane: dv.getInt32(p, true),
        children: [dv.getInt16(p + 4, true), dv.getInt16(p + 6, true)],
        mins: [dv.getInt16(p + 8, true), dv.getInt16(p + 10, true), dv.getInt16(p + 12, true)],
        maxs: [dv.getInt16(p + 14, true), dv.getInt16(p + 16, true), dv.getInt16(p + 18, true)],
        firstFace: dv.getUint16(p + 20, true), numFaces: dv.getUint16(p + 22, true),
      });
    }

    // texinfo
    l = lump(LUMP.texinfo);
    this.texinfo = [];
    for (let p = l.off; p < l.off + l.len; p += 40) {
      this.texinfo.push({
        s: [dv.getFloat32(p, true), dv.getFloat32(p + 4, true), dv.getFloat32(p + 8, true)], soff: dv.getFloat32(p + 12, true),
        t: [dv.getFloat32(p + 16, true), dv.getFloat32(p + 20, true), dv.getFloat32(p + 24, true)], toff: dv.getFloat32(p + 28, true),
        miptex: dv.getInt32(p + 32, true), flags: dv.getInt32(p + 36, true),
      });
    }

    // textures (miptex)
    l = lump(LUMP.textures);
    this.textures = [];
    if (l.len > 0) {
      const n = dv.getInt32(l.off, true);
      for (let i = 0; i < n; i++) {
        const o = dv.getInt32(l.off + 4 + i * 4, true);
        if (o < 0) { this.textures.push(null); continue; }
        const p = l.off + o;
        const tname = cstr(bytes, p, 16).toLowerCase();
        const w = dv.getInt32(p + 16, true);
        const h = dv.getInt32(p + 20, true);
        const offs = [0, 1, 2, 3].map((m) => dv.getInt32(p + 24 + m * 4, true));
        const mips = offs.map((mo, m) => bytes.subarray(p + mo, p + mo + ((w * h) >> (2 * m))));
        this.textures.push({ name: tname, w, h, mips });
      }
    }

    // faces
    l = lump(LUMP.faces);
    this.faces = [];
    for (let p = l.off; p < l.off + l.len; p += 20) {
      this.faces.push({
        plane: dv.getUint16(p, true), side: dv.getUint16(p + 2, true),
        firstEdge: dv.getInt32(p + 4, true), numEdges: dv.getUint16(p + 8, true),
        texinfo: dv.getUint16(p + 10, true),
        styles: [bytes[p + 12], bytes[p + 13], bytes[p + 14], bytes[p + 15]],
        lightofs: dv.getInt32(p + 16, true),
      });
    }

    // lighting
    l = lump(LUMP.lighting);
    this.lightdata = bytes.subarray(l.off, l.off + l.len);

    // clipnodes
    l = lump(LUMP.clipnodes);
    this.clipnodes = [];
    for (let p = l.off; p < l.off + l.len; p += 8) {
      this.clipnodes.push({ plane: dv.getInt32(p, true), children: [dv.getInt16(p + 4, true), dv.getInt16(p + 6, true)] });
    }

    // leaves
    l = lump(LUMP.leaves);
    this.leaves = [];
    for (let p = l.off; p < l.off + l.len; p += 28) {
      this.leaves.push({
        contents: dv.getInt32(p, true), visofs: dv.getInt32(p + 4, true),
        mins: [dv.getInt16(p + 8, true), dv.getInt16(p + 10, true), dv.getInt16(p + 12, true)],
        maxs: [dv.getInt16(p + 14, true), dv.getInt16(p + 16, true), dv.getInt16(p + 18, true)],
        firstMarksurface: dv.getUint16(p + 20, true), numMarksurfaces: dv.getUint16(p + 22, true),
        ambient: [bytes[p + 24], bytes[p + 25], bytes[p + 26], bytes[p + 27]],
      });
    }

    // marksurfaces
    l = lump(LUMP.marksurfaces);
    this.marksurfaces = new Uint16Array(bytes.buffer.slice(l.off, l.off + l.len));

    // edges, surfedges
    l = lump(LUMP.edges);
    this.edges = new Uint16Array(bytes.buffer.slice(l.off, l.off + l.len));
    l = lump(LUMP.surfedges);
    this.surfedges = new Int32Array(bytes.buffer.slice(l.off, l.off + l.len));

    // models
    l = lump(LUMP.models);
    this.models = [];
    for (let p = l.off; p < l.off + l.len; p += 64) {
      this.models.push({
        mins: [dv.getFloat32(p, true), dv.getFloat32(p + 4, true), dv.getFloat32(p + 8, true)],
        maxs: [dv.getFloat32(p + 12, true), dv.getFloat32(p + 16, true), dv.getFloat32(p + 20, true)],
        origin: [dv.getFloat32(p + 24, true), dv.getFloat32(p + 28, true), dv.getFloat32(p + 32, true)],
        headnode: [dv.getInt32(p + 36, true), dv.getInt32(p + 40, true), dv.getInt32(p + 44, true), dv.getInt32(p + 48, true)],
        visleafs: dv.getInt32(p + 52, true), firstFace: dv.getInt32(p + 56, true), numFaces: dv.getInt32(p + 60, true),
      });
    }

    // Decompress the PVS of every leaf of the world model into a hex string:
    // leaf j visible ⇔ bit (j-1) set. Leaf 0 is the solid outside and never in a PVS.
    const nleaves = this.models.length ? this.models[0].visleafs : this.leaves.length - 1;
    this.numVisLeaves = nleaves;
    const rowBytes = (nleaves + 7) >> 3;
    this.pvsHex = new Array(this.leaves.length);
    const hex = '0123456789abcdef';
    for (let i = 0; i < this.leaves.length; i++) {
      const lf = this.leaves[i];
      let s = '';
      if (i === 0 || lf.visofs < 0 || !visdata.length) {
        this.pvsHex[i] = ''; // "" = everything visible
        continue;
      }
      let p = lf.visofs;
      let out = 0;
      while (out < rowBytes) {
        if (visdata[p]) {
          const b = visdata[p++];
          s += hex[b & 15] + hex[b >> 4]; // low nibble first: leaf bit (j) at hex char j>>2
          out++;
        } else {
          let c = visdata[p + 1];
          p += 2;
          while (c-- > 0 && out < rowBytes) { s += '00'; out++; }
        }
      }
      this.pvsHex[i] = s;
    }

    this.computeFaceExtents();
  }

  /** The face's ordered vertex indices (surfedges resolved). */
  faceVertexIndices(f) {
    const out = [];
    for (let i = 0; i < f.numEdges; i++) {
      const se = this.surfedges[f.firstEdge + i];
      out.push(se >= 0 ? this.edges[se * 2] : this.edges[-se * 2 + 1]);
    }
    return out;
  }

  vertex(i) {
    return [this.vertices[i * 3], this.vertices[i * 3 + 1], this.vertices[i * 3 + 2]];
  }

  /** Quake's CalcSurfaceExtents: texture-space bounds, lightmap size. */
  computeFaceExtents() {
    for (const f of this.faces) {
      const ti = this.texinfo[f.texinfo];
      let smin = Infinity, smax = -Infinity, tmin = Infinity, tmax = -Infinity;
      const idx = this.faceVertexIndices(f);
      f.verts = idx;
      for (const vi of idx) {
        const v = this.vertex(vi);
        const s = v[0] * ti.s[0] + v[1] * ti.s[1] + v[2] * ti.s[2] + ti.soff;
        const t = v[0] * ti.t[0] + v[1] * ti.t[1] + v[2] * ti.t[2] + ti.toff;
        if (s < smin) smin = s; if (s > smax) smax = s;
        if (t < tmin) tmin = t; if (t > tmax) tmax = t;
      }
      const bs = Math.floor(smin / 16), bt = Math.floor(tmin / 16);
      const es = Math.ceil(smax / 16), et = Math.ceil(tmax / 16);
      f.texturemins = [bs * 16, bt * 16];
      f.extents = [(es - bs) * 16, (et - bt) * 16];
      f.lightW = (f.extents[0] >> 4) + 1;
      f.lightH = (f.extents[1] >> 4) + 1;
      const tex = this.textures[ti.miptex];
      f.sky = tex && tex.name.startsWith('sky');
      f.liquid = tex && tex.name.startsWith('*');
    }
  }
}

/** The entity lump: [{ classname, origin: 'x y z', ... }, ...] with lower-cased keys. */
export function parseEntities(text) {
  const ents = [];
  const re = /\{([^}]*)\}/g;
  let m;
  while ((m = re.exec(text))) {
    const kv = {};
    const pr = /"([^"]*)"\s*"([^"]*)"/g;
    let p;
    while ((p = pr.exec(m[1]))) kv[p[1].toLowerCase()] = p[2];
    ents.push(kv);
  }
  return ents;
}

export const parseVec = (s) => {
  if (!s) return [0, 0, 0];
  const a = s.trim().split(/\s+/).map(Number);
  return [a[0] || 0, a[1] || 0, a[2] || 0];
};
