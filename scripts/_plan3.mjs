import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const res = await loadResources(db, pak); await loadMap(db, pak, res, 'e1m1');
await db.query('SELECT * FROM quake_tic(1,0,0,0,0,0,0,1,0)');
await db.query('SELECT * FROM frame_faces'); // fills the cache
const t = () => performance.now();
async function time(label, q, n = 5) { const t0 = t(); let r; for (let i = 0; i < n; i++) r = await db.query(q, [], { rowMode: 'array' }); console.log(`${label.padEnd(56)} ${((t() - t0) / n).toFixed(1)} ms ${r.rows.length ? '(' + r.rows.length + ' rows)' : ''}`); return r; }
const v = (await db.query('SELECT * FROM view_setup')).rows[0];
const V = { ex: v.EX, ey: v.EY, ez: v.EZ, fx: v.FX, fy: v.FY, fz: v.FZ, rx: v.RX, ry: v.RY, rz: v.RZ, ux: v.UX, uy: v.UY, uz: v.UZ, nearz: v.NEARZ, kx: v.KX, ky: v.KY, qx: Math.sqrt(1 + v.KX * v.KX), qy: Math.sqrt(1 + v.KY * v.KY) };
const pred = `f.nx * (${V.ex} - v.ox) + f.ny * (${V.ey} - v.oy) + f.nz * (${V.ez} - v.oz) - f.dist > 0
         AND (f.cx + v.ox - ${V.ex}) * ${V.fx} + (f.cy + v.oy - ${V.ey}) * ${V.fy} + (f.cz + v.oz - ${V.ez}) * ${V.fz} + f.radius >= ${V.nearz}
         AND ABS((f.cx + v.ox - ${V.ex}) * ${V.rx} + (f.cy + v.oy - ${V.ey}) * ${V.ry} + (f.cz + v.oz - ${V.ez}) * ${V.rz}) <= ((f.cx + v.ox - ${V.ex}) * ${V.fx} + (f.cy + v.oy - ${V.ey}) * ${V.fy} + (f.cz + v.oz - ${V.ez}) * ${V.fz}) * ${V.kx} + f.radius * ${V.qx}
         AND ABS((f.cx + v.ox - ${V.ex}) * ${V.ux} + (f.cy + v.oy - ${V.ey}) * ${V.uy} + (f.cz + v.oz - ${V.ez}) * ${V.uz}) <= ((f.cx + v.ox - ${V.ex}) * ${V.fx} + (f.cy + v.oy - ${V.ey}) * ${V.fy} + (f.cz + v.oz - ${V.ez}) * ${V.fz}) * ${V.ky} + f.radius * ${V.qy}`;
await time('world-only: current cursor (pred in join), count', `EXECUTE BLOCK RETURNS (n INTEGER) AS DECLARE a INTEGER; BEGIN n = 0; FOR SELECT fv.seq FROM vis_faces v JOIN faces f ON f.id = v.face JOIN face_verts fv ON fv.face = f.id WHERE v.ent_id = 0 AND ${pred} INTO :a DO n = n + 1; SUSPEND; END`);
await time('faces passing pred (no verts)', `SELECT COUNT(*) FROM vis_faces v JOIN faces f ON f.id = v.face WHERE v.ent_id = 0 AND ${pred}`);
await db.exec('CREATE GLOBAL TEMPORARY TABLE sel_faces (face INTEGER NOT NULL PRIMARY KEY, ent_id INTEGER, ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION, nverts INTEGER, sx DOUBLE PRECISION, sy DOUBLE PRECISION, sz DOUBLE PRECISION, soff DOUBLE PRECISION, tx DOUBLE PRECISION, ty DOUBLE PRECISION, tz DOUBLE PRECISION, toff DOUBLE PRECISION) ON COMMIT DELETE ROWS');
await time('two-stage: select into GTT then join verts', `EXECUTE BLOCK RETURNS (n INTEGER) AS DECLARE a INTEGER; BEGIN n = 0; DELETE FROM sel_faces; INSERT INTO sel_faces SELECT f.id, v.ent_id, v.ox, v.oy, v.oz, f.nverts, f.sx, f.sy, f.sz, f.soff, f.tx, f.ty, f.tz, f.toff FROM vis_faces v JOIN faces f ON f.id = v.face WHERE v.ent_id = 0 AND ${pred};
  FOR SELECT fv.seq FROM sel_faces s JOIN face_verts fv ON fv.face = s.face INTO :a DO n = n + 1; SUSPEND; END`);
await time('bmodel marking only', `EXECUTE BLOCK AS DECLARE eid INTEGER; DECLARE emid INTEGER; DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE leafs VARCHAR(200) CHARACTER SET ASCII; DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII = '${v.PVS}'; BEGIN DELETE FROM vis_faces v WHERE v.ent_id <> 0;
  FOR SELECT e.id, e.model_id, e.x, e.y, e.z, e.leafs FROM ents e JOIN models m ON m.id = e.model_id WHERE m.kind = 'B' AND e.model_id <> (SELECT world_model FROM game) INTO eid, emid, ox, oy, oz, leafs DO BEGIN
    vis = 0; p = 2;
    WHILE (p <= CHAR_LENGTH(leafs)) DO BEGIN q = POSITION(',', leafs, p); IF (q = 0) THEN LEAVE; IF (pvs_visible(pvs, CAST(SUBSTRING(leafs FROM p FOR q - p) AS INTEGER)) = 1) THEN BEGIN vis = 1; LEAVE; END p = q + 1; END
    IF (vis = 1) THEN INSERT INTO vis_faces (face, ent_id, ox, oy, oz) SELECT f.id, :eid, :ox, :oy, :oz FROM faces f WHERE f.model_id = :emid;
  END END`);
await time('frame_faces (cached leaf)', 'SELECT * FROM frame_faces');
await time('view_setup', 'SELECT * FROM view_setup');
await db.close(); process.exit(0);
