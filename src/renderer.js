// renderer.js – the painter. Firebird says which polygons are on screen and
// where (FRAME_FACES) and which models stand where (FRAME_ENTS); this file
// turns that into pixels the way Quake's software renderer did: an 8-bit
// framebuffer of palette indices, a z-buffer, perspective-correct spans
// over a surface cache (texture × lightmap → colormap), alias models with
// Gouraud light, billboard sprites, particles and the sky.

import { ANORMS } from './mdl.js';

const SURF_CACHE_MAX = 2000;

export class Renderer {
  constructor(canvas, { palette, colormap }) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false });
    this.palette = palette;      // Uint32Array(256) ABGR
    this.colormap = colormap;    // Uint8Array(64*256)
    this.sinTable = new Float32Array(256);
    for (let i = 0; i < 256; i++) this.sinTable[i] = Math.sin((i / 256) * Math.PI * 2) * 8;
    this.surfCache = new Map();
    this.faceInfo = new Map();   // face id → { bsp, f, tex }
    this.models = null;
    this.particles = [];
    this.sbarLines = 24;
    this.setSize(320, 200);
  }

  setSize(w, h) {
    this.w = w;
    this.h = h;
    this.canvas.width = w;
    this.canvas.height = h;
    this.fb = new Uint8Array(w * h);
    this.zb = new Float32Array(w * h);
    this.image = this.ctx.createImageData(w, h);
    this.pixels = new Uint32Array(this.image.data.buffer);
    this.edgeL = new Float32Array(h * 5);   // x, iz, sz, tz, light per scanline
    this.edgeR = new Float32Array(h * 5);
  }

  /** The model registry (loader.js's res.models) and the BSPs' faces. */
  setResources(res) {
    this.models = res.models;
    this.faceInfo.clear();
    this.surfCache.clear();
    for (const m of res.models.values()) {
      if (m.kind !== 'B' || m.sub !== 0) continue;
      const bsp = m.bsp;
      bsp.faces.forEach((f, i) => {
        const ti = bsp.texinfo[f.texinfo];
        this.faceInfo.set(m.faceBase + i, { bsp, f, tex: bsp.textures[ti.miptex], ti });
      });
    }
  }

  // ─â”€ surface cache (R_DrawSurface) ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€
  surface(faceId, styles, time, frame) {
    const info = this.faceInfo.get(faceId);
    if (!info) return null;
    const { bsp, f } = info;
    let tex = info.tex;
    if (!tex) return null;
    // texture animation (+0name/+1name… at 5 Hz; +aname for buttons pressed)
    if (tex.name[0] === '+') {
      const seq = tex.anim ?? (tex.anim = animSequence(bsp, tex));
      if (frame && seq.alt.length) tex = seq.alt[Math.floor(time * 5) % seq.alt.length];
      else if (seq.main.length > 1) tex = seq.main[Math.floor(time * 5) % seq.main.length];
    }
    let key = faceId;
    let light = 0;
    for (let i = 0; i < 4 && f.styles[i] !== 255; i++) {
      const v = styles[f.styles[i]] ?? 1;
      light = light * 7 + Math.round(v * 16);
    }
    key = faceId + ':' + light + ':' + tex.name;
    let s = this.surfCache.get(key);
    if (s) return s;
    if (this.surfCache.size > SURF_CACHE_MAX) this.surfCache.clear();
    s = this.buildSurface(bsp, f, tex, styles);
    this.surfCache.set(key, s);
    return s;
  }

  buildSurface(bsp, f, tex, styles) {
    const sw = Math.max(1, f.extents[0]);
    const sh = Math.max(1, f.extents[1]);
    const data = new Uint8Array(sw * sh);
    const lw = f.lightW;
    const lh = f.lightH;
    // blocklights: summed, style-scaled light per luxel
    const block = new Float32Array(lw * lh);
    if (f.lightofs >= 0 && bsp.lightdata.length) {
      let off = f.lightofs;
      for (let i = 0; i < 4 && f.styles[i] !== 255; i++) {
        const scale = styles[f.styles[i]] ?? 1;
        for (let k = 0; k < lw * lh; k++) block[k] += bsp.lightdata[off + k] * scale;
        off += lw * lh;
      }
    } else {
      block.fill(f.lightofs === -1 ? 255 : 0); // -1: fullbright (no light data)
    }
    const cm = this.colormap;
    const texw = tex.w, texh = tex.h, mip = tex.mips[0];
    const smin = f.texturemins[0], tmin = f.texturemins[1];
    for (let v = 0; v < sh; v++) {
      const ty = (((v + tmin) % texh) + texh) % texh;
      const lv = v >> 4, lf = (v & 15) / 16;
      const lv1 = Math.min(lv + 1, lh - 1);
      const row = v * sw;
      for (let u = 0; u < sw; u++) {
        const tx = (((u + smin) % texw) + texw) % texw;
        const lu = u >> 4, luf = (u & 15) / 16;
        const lu1 = Math.min(lu + 1, lw - 1);
        const l0 = block[lv * lw + lu] * (1 - luf) + block[lv * lw + lu1] * luf;
        const l1 = block[lv1 * lw + lu] * (1 - luf) + block[lv1 * lw + lu1] * luf;
        const l = l0 * (1 - lf) + l1 * lf;
        let shade = (255 - l) >> 2;
        if (shade < 0) shade = 0; else if (shade > 63) shade = 63;
        data[row + u] = cm[(shade << 8) | mip[ty * texw + tx]];
      }
    }
    return { data, w: sw, h: sh, smin, tmin };
  }

  // ─â”€ a frame ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─
  beginFrame(view) {
    this.view = view;
    const { w, h } = this;
    this.zb.fill(0);
    this.fb.fill(0);
    const yaw = (view.yaw * Math.PI) / 180, pitch = (view.pitch * Math.PI) / 180;
    const sy = Math.sin(yaw), cy = Math.cos(yaw), sp = Math.sin(pitch), cp = Math.cos(pitch);
    view.fwd = [cp * cy, cp * sy, -sp];
    view.right = [sy, -cy, 0];
    view.up = [sp * cy, sp * sy, cp];
    if (view.roll) {
      const r = (view.roll * Math.PI) / 180, cr = Math.cos(r), sr = Math.sin(r);
      const R = view.right, U = view.up;
      view.right = [R[0] * cr + U[0] * sr, R[1] * cr + U[1] * sr, R[2] * cr + U[2] * sr];
      view.up = [-R[0] * sr + U[0] * cr, -R[1] * sr + U[1] * cr, -R[2] * sr + U[2] * cr];
    }
    // the 3D view is the part above the status bar (Quake's vrect: 320×176)
    view.scale = (w / 2) / Math.tan((view.fov * Math.PI) / 360);
    view.cx = w / 2;
    view.cy = (h - this.sbarLines) / 2;
  }

  /**
   * The world and brush models: rows [face, seq, vf, vr, vu, sx, sy, s, t, ent_id]
   * in order (view-space forward/right/up, projected x/y or null when behind
   * the near plane, texel s/t). Polygons that cross the near plane are
   * clipped here, in view space, before scan conversion.
   */
  drawFaces(rows, styles, time, entFrames) {
    let i = 0;
    const n = rows.length;
    const view = this.view;
    const near = 4;
    const poly = [];
    while (i < n) {
      const face = rows[i][0], ent = rows[i][9];
      poly.length = 0;
      let behind = false;
      while (i < n && rows[i][0] === face && rows[i][9] === ent) {
        if (rows[i][2] < near) behind = true;
        poly.push(rows[i]);
        i++;
      }
      if (poly.length < 3) continue;
      const info = this.faceInfo.get(face);
      if (!info) continue;
      // [sx, sy, z, s, t] per vertex
      let verts;
      if (!behind) verts = poly.map((p) => [p[5], p[6], p[2], p[7], p[8]]);
      else {
        verts = [];
        const m = poly.length;
        for (let k = 0; k < m; k++) {
          const a = poly[k], b = poly[(k + 1) % m];
          const ain = a[2] >= near, bin = b[2] >= near;
          if (ain) verts.push([a[5], a[6], a[2], a[7], a[8]]);
          if (ain !== bin) {
            const f = (near - a[2]) / (b[2] - a[2]);
            const r = a[3] + (b[3] - a[3]) * f, u = a[4] + (b[4] - a[4]) * f;
            verts.push([view.cx + (r * view.scale) / near, view.cy - (u * view.scale) / near, near, a[7] + (b[7] - a[7]) * f, a[8] + (b[8] - a[8]) * f]);
          }
        }
        if (verts.length < 3) continue;
      }
      if (info.f.sky) this.fillPolygon(verts, null, 2, time);
      else {
        const s = this.surface(face, styles, time, entFrames.get(ent) ?? 0);
        if (s) this.fillPolygon(verts, s, info.f.liquid ? 1 : 0, time);
      }
    }
  }

  /**
   * FRAME_FACES_FAST rows [face, ent_id, ox, oy, oz]: SQL chose the faces,
   * the vertices come from the BSP held here. Builds the same per-vertex
   * rows FRAME_FACES would and hands them to drawFaces.
   */
  drawFaceList(rows, styles, time, entFrames) {
    const view = this.view;
    const [fx, fy, fz] = view.fwd, [rx, ry, rz] = view.right, [ux, uy, uz] = view.up;
    const near = 4, sc = view.scale, cx = view.cx, cy = view.cy;
    const out = [];
    for (const [face, ent, ox, oy, oz] of rows) {
      const info = this.faceInfo.get(face);
      if (!info) continue;
      const { bsp, f, ti } = info;
      const lx = view.x - ox, ly = view.y - oy, lz = view.z - oz;
      const verts = f.verts, vs = bsp.vertices;
      for (let k = 0; k < verts.length; k++) {
        const vi = verts[k] * 3;
        const x = vs[vi], y = vs[vi + 1], z = vs[vi + 2];
        const dx = x - lx, dy = y - ly, dz = z - lz;
        const vf = dx * fx + dy * fy + dz * fz, vr = dx * rx + dy * ry + dz * rz, vu = dx * ux + dy * uy + dz * uz;
        out.push([face, k, vf, vr, vu, vf >= near ? cx + (vr * sc) / vf : null, vf >= near ? cy - (vu * sc) / vf : null,
          x * ti.s[0] + y * ti.s[1] + z * ti.s[2] + ti.soff, x * ti.t[0] + y * ti.t[1] + z * ti.t[2] + ti.toff, ent]);
      }
    }
    this.drawFaces(out, styles, time, entFrames);
  }

  /**
   * Scan-convert a convex polygon of [sx, sy, z, s, t]. mode 0: textured,
   * 1: liquid (warped), 2: sky. 1/z, s/z and t/z are affine in screen space.
   */
  fillPolygon(poly, surf, mode, time) {
    const { w, h, edgeL, edgeR, fb, zb } = this;
    let ymin = Infinity, ymax = -Infinity;
    for (const p of poly) { if (p[1] < ymin) ymin = p[1]; if (p[1] > ymax) ymax = p[1]; }
    let y0 = Math.max(0, Math.ceil(ymin - 0.5));
    let y1 = Math.min(h - 1, Math.ceil(ymax - 0.5) - 1);
    if (y0 > y1) return;
    for (let y = y0; y <= y1; y++) { edgeL[y * 5] = Infinity; edgeR[y * 5] = -Infinity; }
    const m = poly.length;
    for (let k = 0; k < m; k++) {
      const a = poly[k], b = poly[(k + 1) % m];
      let ax = a[0], ay = a[1], bx = b[0], by = b[1];
      if (ay === by) continue;
      let aiz = 1 / a[2], biz = 1 / b[2];
      let asz = a[3] * aiz, bsz = b[3] * biz, atz = a[4] * aiz, btz = b[4] * biz;
      if (ay > by) {
        [ax, bx] = [bx, ax]; [ay, by] = [by, ay]; [aiz, biz] = [biz, aiz]; [asz, bsz] = [bsz, asz]; [atz, btz] = [btz, atz];
      }
      const dy = by - ay;
      const dx = (bx - ax) / dy, diz = (biz - aiz) / dy, dsz = (bsz - asz) / dy, dtz = (btz - atz) / dy;
      const ys = Math.max(y0, Math.ceil(ay - 0.5)), ye = Math.min(y1, Math.ceil(by - 0.5) - 1);
      for (let y = ys; y <= ye; y++) {
        const t = y + 0.5 - ay;
        const x = ax + dx * t;
        const o = y * 5;
        if (x < edgeL[o]) { edgeL[o] = x; edgeL[o + 1] = aiz + diz * t; edgeL[o + 2] = asz + dsz * t; edgeL[o + 3] = atz + dtz * t; }
        if (x > edgeR[o]) { edgeR[o] = x; edgeR[o + 1] = aiz + diz * t; edgeR[o + 2] = asz + dsz * t; edgeR[o + 3] = atz + dtz * t; }
      }
    }
    const sd = surf ? surf.data : null;
    const sw = surf ? surf.w : 0, sh = surf ? surf.h : 0, smin = surf ? surf.smin : 0, tmin = surf ? surf.tmin : 0;
    const sin = this.sinTable;
    const tphase = (time * 20) & 255;
    const view = this.view;
    for (let y = y0; y <= y1; y++) {
      const o = y * 5;
      const xl = edgeL[o], xr = edgeR[o];
      if (xl === Infinity || xr === -Infinity) continue;
      const xs = Math.max(0, Math.ceil(xl - 0.5)), xe = Math.min(w - 1, Math.ceil(xr - 0.5) - 1);
      if (xs > xe) continue;
      const span = xr - xl || 1;
      const diz = (edgeR[o + 1] - edgeL[o + 1]) / span;
      const dsz = (edgeR[o + 2] - edgeL[o + 2]) / span;
      const dtz = (edgeR[o + 3] - edgeL[o + 3]) / span;
      const t0 = xs + 0.5 - xl;
      let iz = edgeL[o + 1] + diz * t0, sz = edgeL[o + 2] + dsz * t0, tz = edgeL[o + 3] + dtz * t0;
      let idx = y * w + xs;
      if (mode === 2) {
        // sky: direction per pixel, two scrolling layers (R_DrawSkyChain)
        const tex = this.skyTex;
        for (let x = xs; x <= xe; x++, idx++, iz += diz) {
          if (1e-6 > zb[idx]) {
            zb[idx] = 1e-6;
            fb[idx] = tex ? skyPixel(tex, view, x, y, time) : 0;
          }
        }
        continue;
      }
      for (let x = xs; x <= xe; x++, idx++, iz += diz, sz += dsz, tz += dtz) {
        if (iz <= zb[idx]) continue;
        zb[idx] = iz;
        const z = 1 / iz;
        let s = sz * z - smin, t = tz * z - tmin;
        if (mode === 1) {
          const ss = s, tt = t;
          s += sin[(tphase + (tt >> 0)) & 255];
          t += sin[(tphase + (ss >> 0)) & 255];
          s = ((s % sw) + sw) % sw; t = ((t % sh) + sh) % sh;
        } else {
          if (s < 0) s = 0; else if (s >= sw) s = sw - 1;
          if (t < 0) t = 0; else if (t >= sh) t = sh - 1;
        }
        fb[idx] = sd[(t | 0) * sw + (s | 0)];
      }
    }
  }

  // ─â”€ alias models (R_AliasDrawModel) ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€
  /**
   * Draw an MDL at origin with Quake angles (pitch as vectoangles gives it:
   * positive up). light: 0..255 from the lightmap below the entity.
   */
  drawAlias(mdl, frameIndex, skin, origin, angles, light, opts = {}) {
    const view = this.view;
    const [pitch, yaw, roll] = angles.map((a) => (a * Math.PI) / 180);
    // AngleVectors(-pitch, yaw, roll) as R_RotateForEntity does
    const sy = Math.sin(yaw), cy = Math.cos(yaw), sp = Math.sin(-pitch), cp = Math.cos(-pitch), sr = Math.sin(roll), cr = Math.cos(roll);
    const F = [cp * cy, cp * sy, -sp];
    const R = [-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp];
    const U = [cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp];
    let frame = mdl.frames[Math.min(Math.max(frameIndex, 0), mdl.frames.length - 1)];
    if (frame.group) frame = frame.group[Math.floor((opts.time ?? 0) * 10) % frame.group.length];
    const verts = frame.verts;
    const n = mdl.numVerts;
    const vf = new Float32Array(n), vr = new Float32Array(n), vu = new Float32Array(n), lv = new Float32Array(n);
    const near = opts.near ?? 4;
    const ex = view.x, ey = view.y, ez = view.z;
    const fwd = view.fwd, right = view.right, up = view.up;
    // the light direction, in Quake: from above and ahead of the viewer
    const ldx = -1, ldy = 0, ldz = 1;
    const ambient = Math.max(light, 8), shade = Math.max(light, 8);   // R_AliasSetupLighting
    let anyNear = false;
    for (let i = 0; i < n; i++) {
      const mx = verts[i * 4] * mdl.scale[0] + mdl.origin[0];
      const my = verts[i * 4 + 1] * mdl.scale[1] + mdl.origin[1];
      const mz = verts[i * 4 + 2] * mdl.scale[2] + mdl.origin[2];
      const wx = origin[0] + F[0] * mx - R[0] * my + U[0] * mz - ex;
      const wy = origin[1] + F[1] * mx - R[1] * my + U[1] * mz - ey;
      const wz = origin[2] + F[2] * mx - R[2] * my + U[2] * mz - ez;
      const f = wx * fwd[0] + wy * fwd[1] + wz * fwd[2];
      if (f < near) anyNear = true;
      vf[i] = f;
      vr[i] = wx * right[0] + wy * right[1] + wz * right[2];
      vu[i] = wx * up[0] + wy * up[1] + wz * up[2];
      const ni = verts[i * 4 + 3] * 3;
      // the normal in world space
      const nx = F[0] * ANORMS[ni] - R[0] * ANORMS[ni + 1] + U[0] * ANORMS[ni + 2];
      const ny = F[1] * ANORMS[ni] - R[1] * ANORMS[ni + 1] + U[1] * ANORMS[ni + 2];
      const nz = F[2] * ANORMS[ni] - R[2] * ANORMS[ni + 1] + U[2] * ANORMS[ni + 2];
      const d = (nx * ldx + ny * ldy + nz * ldz) * 0.7071;
      lv[i] = Math.min(255, ambient + shade * Math.max(0, d));
    }
    const skinData = mdl.skins[Math.min(skin, mdl.skins.length - 1)] ?? mdl.skins[0];
    const tris = mdl.tris, st = mdl.st, skinW = mdl.skinW, skinH = mdl.skinH;
    const depthHack = opts.depthHack ? 3 : 1;
    const transparent = opts.transparent ? 255 : -1;
    const vcx = view.cx, vcy = view.cy, sc = view.scale;
    // a clipped vertex: [f, r, u, s, t, light]
    const proj = (v) => [vcx + (v[1] * sc) / v[0], vcy - (v[2] * sc) / v[0], (1 / v[0]) * depthHack, v[3], v[4], v[5]];
    const drawTri = (A, B, C) => {
      const a = proj(A), b = proj(B), c = proj(C);
      if ((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) <= 0) return;   // back face (MDL winding)
      this.triangle(a[0], a[1], a[2], a[3], a[4], a[5], b[0], b[1], b[2], b[3], b[4], b[5], c[0], c[1], c[2], c[3], c[4], c[5],
        skinData, skinW, skinH, transparent, opts.noZTest, opts.alpha);
    };
    const lerp = (A, B) => {
      const k = (near - A[0]) / (B[0] - A[0]);
      return [near, A[1] + (B[1] - A[1]) * k, A[2] + (B[2] - A[2]) * k, A[3] + (B[3] - A[3]) * k, A[4] + (B[4] - A[4]) * k, A[5] + (B[5] - A[5]) * k];
    };
    for (let t = 0; t < mdl.numTris; t++) {
      const front = tris[t * 4], ia = tris[t * 4 + 1], ib = tris[t * 4 + 2], ic = tris[t * 4 + 3];
      const uv = (v) => {
        let s = st[v * 3 + 1];
        if (!front && st[v * 3]) s += skinW >> 1;
        return [s, st[v * 3 + 2]];
      };
      const [sa, ta] = uv(ia), [sb, tb] = uv(ib), [sc_, tc] = uv(ic);
      const A = [vf[ia], vr[ia], vu[ia], sa, ta, lv[ia]], B = [vf[ib], vr[ib], vu[ib], sb, tb, lv[ib]], C = [vf[ic], vr[ic], vu[ic], sc_, tc, lv[ic]];
      const inA = A[0] >= near, inB = B[0] >= near, inC = C[0] >= near;
      const n = inA + inB + inC;
      if (n === 3) drawTri(A, B, C);
      else if (n === 0) continue;
      else {
        // Sutherland–Hodgman against the near plane: 3 or 4 vertices out
        const inp = [A, B, C], out = [];
        for (let k = 0; k < 3; k++) {
          const P = inp[k], Q = inp[(k + 1) % 3];
          const pin = P[0] >= near, qin = Q[0] >= near;
          if (pin) out.push(P);
          if (pin !== qin) out.push(lerp(P, Q));
        }
        drawTri(out[0], out[1], out[2]);
        if (out.length === 4) drawTri(out[0], out[2], out[3]);
      }
    }
    return anyNear;
  }

  /** A Gouraud-lit, affine-textured triangle with z-test. */
  triangle(x0, y0, iz0, s0, t0, l0, x1, y1, iz1, s1, t1, l1, x2, y2, iz2, s2, t2, l2, tex, tw, th, transparent, noZ, alpha) {
    const { w, h, edgeL, edgeR, fb, zb, colormap } = this;
    const ymin = Math.min(y0, y1, y2), ymax = Math.max(y0, y1, y2);
    const ya = Math.max(0, Math.ceil(ymin - 0.5)), yb = Math.min(h - 1, Math.ceil(ymax - 0.5) - 1);
    if (ya > yb) return;
    for (let y = ya; y <= yb; y++) { edgeL[y * 5] = Infinity; edgeR[y * 5] = -Infinity; }
    const edge = (ax, ay, aiz, as, at, al, bx, by, biz, bs, bt, bl) => {
      if (ay === by) return;
      if (ay > by) { [ax, bx] = [bx, ax]; [ay, by] = [by, ay]; [aiz, biz] = [biz, aiz]; [as, bs] = [bs, as]; [at, bt] = [bt, at]; [al, bl] = [bl, al]; }
      const dy = by - ay;
      const dx = (bx - ax) / dy, diz = (biz - aiz) / dy, ds = (bs - as) / dy, dt = (bt - at) / dy, dl = (bl - al) / dy;
      const ys = Math.max(ya, Math.ceil(ay - 0.5)), ye = Math.min(yb, Math.ceil(by - 0.5) - 1);
      for (let y = ys; y <= ye; y++) {
        const t = y + 0.5 - ay, x = ax + dx * t, o = y * 5;
        if (x < edgeL[o]) { edgeL[o] = x; edgeL[o + 1] = aiz + diz * t; edgeL[o + 2] = as + ds * t; edgeL[o + 3] = at + dt * t; edgeL[o + 4] = al + dl * t; }
        if (x > edgeR[o]) { edgeR[o] = x; edgeR[o + 1] = aiz + diz * t; edgeR[o + 2] = as + ds * t; edgeR[o + 3] = at + dt * t; edgeR[o + 4] = al + dl * t; }
      }
    };
    edge(x0, y0, iz0, s0, t0, l0, x1, y1, iz1, s1, t1, l1);
    edge(x1, y1, iz1, s1, t1, l1, x2, y2, iz2, s2, t2, l2);
    edge(x2, y2, iz2, s2, t2, l2, x0, y0, iz0, s0, t0, l0);
    for (let y = ya; y <= yb; y++) {
      const o = y * 5, xl = edgeL[o], xr = edgeR[o];
      if (xl === Infinity) continue;
      const xs = Math.max(0, Math.ceil(xl - 0.5)), xe = Math.min(w - 1, Math.ceil(xr - 0.5) - 1);
      if (xs > xe) continue;
      const span = xr - xl || 1;
      const diz = (edgeR[o + 1] - edgeL[o + 1]) / span, ds = (edgeR[o + 2] - edgeL[o + 2]) / span;
      const dt = (edgeR[o + 3] - edgeL[o + 3]) / span, dl = (edgeR[o + 4] - edgeL[o + 4]) / span;
      const tt = xs + 0.5 - xl;
      let iz = edgeL[o + 1] + diz * tt, s = edgeL[o + 2] + ds * tt, t = edgeL[o + 3] + dt * tt, l = edgeL[o + 4] + dl * tt;
      let idx = y * w + xs;
      for (let x = xs; x <= xe; x++, idx++, iz += diz, s += ds, t += dt, l += dl) {
        if (!noZ && iz <= zb[idx]) continue;
        if (alpha && ((x + y) & 1)) continue;
        let si = s | 0, ti = t | 0;
        if (si < 0) si = 0; else if (si >= tw) si = tw - 1;
        if (ti < 0) ti = 0; else if (ti >= th) ti = th - 1;
        const c = tex[ti * tw + si];
        if (c === transparent) continue;
        zb[idx] = iz;
        let shade = (255 - l) >> 2;
        if (shade < 0) shade = 0; else if (shade > 63) shade = 63;
        fb[idx] = colormap[(shade << 8) | c];
      }
    }
  }

  // ─â”€ sprites ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─
  drawSprite(spr, frameIndex, origin, light = 255) {
    const view = this.view;
    const fr = spr.frames[Math.min(frameIndex, spr.frames.length - 1)];
    if (!fr) return;
    const wx = origin[0] - view.x, wy = origin[1] - view.y, wz = origin[2] - view.z;
    const f = wx * view.fwd[0] + wy * view.fwd[1] + wz * view.fwd[2];
    if (f < 4) return;
    const r = wx * view.right[0] + wy * view.right[1] + wz * view.right[2];
    const u = wx * view.up[0] + wy * view.up[1] + wz * view.up[2];
    // the frame's corners in view space (vp-parallel billboard)
    const iz = 1 / f, k = view.scale * iz;
    const left = r + fr.ox, right = left + fr.w, top = u + fr.oy, bottom = top - fr.h;
    const x0 = view.cx + left * k, x1 = view.cx + right * k, y0 = view.cy - top * k, y1 = view.cy - bottom * k;
    this.triangle(x0, y0, iz, 0, 0, light, x1, y0, iz, fr.w, 0, light, x1, y1, iz, fr.w, fr.h, light, fr.data, fr.w, fr.h, 255);
    this.triangle(x0, y0, iz, 0, 0, light, x1, y1, iz, fr.w, fr.h, light, x0, y1, iz, 0, fr.h, light, fr.data, fr.w, fr.h, 255);
  }

  // ─â”€ particles (r_part.c, the parts we need) ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€
  spawnParticles(kind, x, y, z, n, dir = [0, 0, 0], color = 0) {
    const now = this.time ?? 0;
    const add = (p) => this.particles.push(p);
    const rnd = () => Math.random() * 2 - 1;
    if (kind === 'explosion') {
      for (let i = 0; i < 128; i++) add({ x: x + rnd() * 16, y: y + rnd() * 16, z: z + rnd() * 16, vx: rnd() * 256, vy: rnd() * 256, vz: rnd() * 256,
        color: (i & 1 ? 111 : 103) + (i % 4), die: now + 4 * Math.random() + 1, type: i & 1 ? 'explode' : 'explode2', ramp: i & 3 });
    } else if (kind === 'lava') {
      for (let i = 0; i < 128; i++) add({ x: x + rnd() * 16, y: y + rnd() * 16, z: z + rnd() * 16, vx: rnd() * 256, vy: rnd() * 256, vz: rnd() * 256,
        color: 224 + (i & 7), die: now + 2 * Math.random() + 1, type: 'grav' });
    } else if (kind === 'teleport') {
      for (let i = -16; i < 16; i += 4) for (let j = -16; j < 16; j += 4) for (let k = -24; k < 32; k += 4) {
        const dl = Math.hypot(j, i, k) || 1;
        const v = 50 + Math.random() * 64;
        add({ x: x + i + Math.random() * 4, y: y + j + Math.random() * 4, z: z + k + Math.random() * 4, vx: (j / dl) * v, vy: (i / dl) * v, vz: (k / dl) * v,
          color: 7 + Math.floor(Math.random() * 8), die: now + 0.2 + Math.random() * 0.1, type: 'slowgrav' });
      }
    } else {
      // gunshot / blood: n particles at the impact
      const scale = n > 130 ? 3 : n > 20 ? 2 : 1;
      for (let i = 0; i < n; i++) {
        add({ x: x + rnd() * 8 * scale, y: y + rnd() * 8 * scale, z: z + rnd() * 8 * scale, vx: dir[0] * 15 + rnd() * 20, vy: dir[1] * 15 + rnd() * 20, vz: dir[2] * 15 + rnd() * 20,
          color: (color & ~7) + Math.floor(Math.random() * 8), die: now + 0.1 * (Math.random() * 5 + 1), type: 'slowgrav' });
      }
    }
  }

  runParticles(dt, time) {
    this.time = time;
    const ps = this.particles;
    const grav = 800 * dt;
    let k = 0;
    for (const p of ps) {
      if (p.die < time) continue;
      p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt;
      switch (p.type) {
        case 'explode': p.ramp += dt * 10; if (p.ramp >= 6) p.die = -1; else p.color = [0x6f, 0x6d, 0x6b, 0x69, 0x67, 0x65][p.ramp | 0]; p.vz -= grav; p.vx += p.vx * dt * 4; p.vy += p.vy * dt * 4; p.vz += p.vz * dt * 4; break;
        case 'explode2': p.ramp += dt * 15; if (p.ramp >= 8) p.die = -1; else p.color = [0x6f, 0x6e, 0x6d, 0x6c, 0x6b, 0x6a, 0x68, 0x66][p.ramp | 0]; p.vz -= grav; p.vx -= p.vx * dt; p.vy -= p.vy * dt; p.vz -= p.vz * dt; break;
        case 'grav': p.vz -= grav; break;
        case 'slowgrav': p.vz -= grav * 0.05; break;
        default: break;
      }
      ps[k++] = p;
    }
    ps.length = k;
  }

  drawParticles() {
    const view = this.view;
    const { fb, zb, w, h } = this;
    for (const p of this.particles) {
      const wx = p.x - view.x, wy = p.y - view.y, wz = p.z - view.z;
      const f = wx * view.fwd[0] + wy * view.fwd[1] + wz * view.fwd[2];
      if (f < 4) continue;
      const iz = 1 / f;
      const x = (view.cx + ((wx * view.right[0] + wy * view.right[1] + wz * view.right[2]) * view.scale) / f) | 0;
      const y = (view.cy - ((wx * view.up[0] + wy * view.up[1] + wz * view.up[2]) * view.scale) / f) | 0;
      const size = f < 200 ? 2 : 1;
      for (let dy = 0; dy < size; dy++) for (let dx = 0; dx < size; dx++) {
        const px = x + dx, py = y + dy;
        if (px < 0 || py < 0 || px >= w || py >= h) continue;
        const idx = py * w + px;
        if (iz > zb[idx]) { zb[idx] = iz; fb[idx] = p.color; }
      }
    }
  }

  // ─â”€ 2D (draw.c) ─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─â”€â”€â”€─
  drawPic(pic, x, y) {
    if (!pic) return;
    const { fb, w, h } = this;
    for (let j = 0; j < pic.h; j++) {
      const py = y + j;
      if (py < 0 || py >= h) continue;
      for (let i = 0; i < pic.w; i++) {
        const px = x + i;
        if (px < 0 || px >= w) continue;
        const c = pic.data[j * pic.w + i];
        if (c !== 255) fb[py * w + px] = c;
      }
    }
  }

  drawChar(conchars, c, x, y) {
    if (c === 32 || !conchars) return;
    const { fb, w, h } = this;
    const cx = (c & 15) * 8, cy = (c >> 4) * 8;
    for (let j = 0; j < 8; j++) {
      const py = y + j;
      if (py < 0 || py >= h) continue;
      for (let i = 0; i < 8; i++) {
        const px = x + i;
        if (px < 0 || px >= w) continue;
        const col = conchars.data[(cy + j) * 128 + cx + i];
        if (col !== 0) fb[py * w + px] = col;
      }
    }
  }

  drawString(conchars, s, x, y, alt = false) {
    for (let i = 0; i < s.length; i++) this.drawChar(conchars, (s.charCodeAt(i) & 127) + (alt ? 128 : 0), x + i * 8, y);
  }

  fillRect(x, y, rw, rh, c) {
    const { fb, w, h } = this;
    for (let j = Math.max(0, y); j < Math.min(h, y + rh); j++) for (let i = Math.max(0, x); i < Math.min(w, x + rw); i++) fb[j * w + i] = c;
  }

  /** Dim a region (the console/menus' fade). */
  fade(x, y, rw, rh) {
    const { fb, w, h, colormap } = this;
    for (let j = Math.max(0, y); j < Math.min(h, y + rh); j++) for (let i = Math.max(0, x); i < Math.min(w, x + rw); i++) fb[j * w + i] = colormap[(40 << 8) | fb[j * w + i]];
  }

  /** Convert palette indices to pixels, with a colour blend (V_UpdatePalette). */
  present(tint = null) {
    const pal = this.palette;
    let p = pal;
    if (tint && tint[3] > 0) {
      p = this.tintPal ?? (this.tintPal = new Uint32Array(256));
      const a = tint[3], ia = 1 - a;
      for (let i = 0; i < 256; i++) {
        const c = pal[i];
        const r = (c & 255) * ia + tint[0] * a, g = ((c >> 8) & 255) * ia + tint[1] * a, b = ((c >> 16) & 255) * ia + tint[2] * a;
        p[i] = (255 << 24) | (b << 16) | (g << 8) | r;
      }
    }
    const { fb, pixels } = this;
    for (let i = 0; i < fb.length; i++) pixels[i] = p[fb[i]];
    this.ctx.putImageData(this.image, 0, 0);
  }
}

/** The +0/+1/… and +a/+b/… frames of an animated texture, from the BSP's miptex list. */
function animSequence(bsp, tex) {
  const main = [], alt = [];
  const base = tex.name.slice(2);
  for (const t of bsp.textures) {
    if (!t || t.name[0] !== '+' || t.name.slice(2) !== base) continue;
    const c = t.name[1];
    if (c >= '0' && c <= '9') main[Number(c)] = t;
    else alt[c.charCodeAt(0) - 97] = t;
  }
  return { main: main.filter(Boolean), alt: alt.filter(Boolean) };
}

/** R_DrawSkyChain's two scrolling layers, mapped by the pixel's direction. */
function skyPixel(tex, view, x, y, time) {
  const kx = (x + 0.5 - view.cx) / view.scale, ky = (view.cy - y - 0.5) / view.scale;
  let dx = view.fwd[0] + view.right[0] * kx + view.up[0] * ky;
  let dy = view.fwd[1] + view.right[1] * kx + view.up[1] * ky;
  let dz = (view.fwd[2] + view.right[2] * kx + view.up[2] * ky) * 3;
  const len = 6 * 63 / Math.sqrt(dx * dx + dy * dy + dz * dz);
  const w = tex.w, h = tex.h, half = w >> 1, mip = tex.mips[0];
  const speed = time * 8;
  let s = ((speed * 2 + dx * len) | 0) & (half - 1), t = ((speed * 2 + dy * len) | 0) & (h - 1);
  const c = mip[t * w + s];
  if (c !== 0) return c;
  s = ((speed + dx * len) | 0) & (half - 1); t = ((speed + dy * len) | 0) & (h - 1);
  return mip[t * w + half + s];
}

/** R_LightPoint: the lightmap value of the floor below a point (for models). */
export function lightPoint(bsp, x, y, z) {
  let best = 255;
  const rec = (node, sx, sy, sz, ex, ey, ez) => {
    if (node < 0) return -1;
    const n = bsp.nodes[node];
    const pl = bsp.planes[n.plane];
    const front = sx * pl.nx + sy * pl.ny + sz * pl.nz - pl.dist;
    const back = ex * pl.nx + ey * pl.ny + ez * pl.nz - pl.dist;
    const side = front < 0 ? 1 : 0;
    if ((back < 0) === (front < 0)) return rec(n.children[side], sx, sy, sz, ex, ey, ez);
    const frac = front / (front - back);
    const mx = sx + (ex - sx) * frac, my = sy + (ey - sy) * frac, mz = sz + (ez - sz) * frac;
    const r = rec(n.children[side], sx, sy, sz, mx, my, mz);
    if (r >= 0) return r;
    if ((back < 0) === side) return -1;
    // check for impact on this node's faces
    for (let i = 0; i < n.numFaces; i++) {
      const f = bsp.faces[n.firstFace + i];
      if (f.sky || f.liquid) continue;
      const ti = bsp.texinfo[f.texinfo];
      const s = mx * ti.s[0] + my * ti.s[1] + mz * ti.s[2] + ti.soff;
      const t = mx * ti.t[0] + my * ti.t[1] + mz * ti.t[2] + ti.toff;
      if (s < f.texturemins[0] || t < f.texturemins[1]) continue;
      const ds = s - f.texturemins[0], dt = t - f.texturemins[1];
      if (ds > f.extents[0] || dt > f.extents[1]) continue;
      if (f.lightofs < 0) return 255;
      const lw = f.lightW;
      const off = f.lightofs + (dt >> 4) * lw + (ds >> 4);
      return bsp.lightdata[off] ?? 0;
    }
    return rec(n.children[side ^ 1], mx, my, mz, ex, ey, ez);
  };
  const r = rec(bsp.models[0].headnode[0], x, y, z, x, y, z - 2048);
  if (r >= 0) best = r;
  return best;
}
