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
await db.query('SELECT * FROM quake_tic(1,0,0,180,0,0,0,1,0)');
const t = () => performance.now();
async function time(label, q, n = 5) { const t0 = t(); let r; for (let i = 0; i < n; i++) r = await db.query(q, [], { rowMode: 'array' }); console.log(`${label.padEnd(50)} ${((t() - t0) / n).toFixed(1)} ms ${r.rows.length ? '(' + r.rows.length + ' rows)' : ''}`); return r; }
const D = `DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION; DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION; DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION; DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION; DECLARE w INTEGER; DECLARE h INTEGER; DECLARE sc DOUBLE PRECISION; DECLARE nearz DOUBLE PRECISION; DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII; DECLARE vleaf INTEGER; DECLARE cur INTEGER; DECLARE eid INTEGER; DECLARE emid INTEGER; DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE leafs VARCHAR(200) CHARACTER SET ASCII; DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE world INTEGER;`;
const VS = `EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;`;
await time('frame_faces (wall)', 'SELECT * FROM frame_faces');
await time('empty block', 'EXECUTE BLOCK AS BEGIN END');
await time('block: view_setup', `EXECUTE BLOCK AS ${D} BEGIN ${VS} END`);
await time('block: view_setup + cache check', `EXECUTE BLOCK AS ${D} BEGIN ${VS} SELECT c.vis_leaf FROM viewcfg c WHERE c.id = 1 INTO cur; IF (cur IS DISTINCT FROM vleaf) THEN cur = 1; ELSE DELETE FROM vis_faces v WHERE v.ent_id <> 0; END`);
await time('block: + bmodel marking', `EXECUTE BLOCK AS ${D} BEGIN ${VS} SELECT g.world_model FROM game g WHERE g.id = 1 INTO world; DELETE FROM vis_faces v WHERE v.ent_id <> 0;
  FOR SELECT e.id, e.model_id, e.x, e.y, e.z, e.leafs FROM ents e JOIN models m ON m.id = e.model_id WHERE m.kind = 'B' AND e.model_id <> :world INTO eid, emid, ox, oy, oz, leafs DO BEGIN
    vis = 0; IF (leafs IS NULL OR pvs = '') THEN vis = 1; ELSE BEGIN p = 2;
    WHILE (p <= CHAR_LENGTH(leafs)) DO BEGIN q = POSITION(',', leafs, p); IF (q = 0) THEN LEAVE; IF (pvs_visible(pvs, CAST(SUBSTRING(leafs FROM p FOR q - p) AS INTEGER)) = 1) THEN BEGIN vis = 1; LEAVE; END p = q + 1; END END
    IF (vis = 1) THEN INSERT INTO vis_faces (face, ent_id, ox, oy, oz) SELECT f.id, :eid, :ox, :oy, :oz FROM faces f WHERE f.model_id = :emid;
  END END`);
await time('block: cursor count only (no pred)', `EXECUTE BLOCK RETURNS (n INTEGER) AS DECLARE a INTEGER; BEGIN n = 0; FOR SELECT fv.seq FROM vis_faces v JOIN faces f ON f.id = v.face JOIN face_verts fv ON fv.face = f.id INTO :a DO n = n + 1; SUSPEND; END`);
await time('vis_faces count', 'SELECT COUNT(*) FROM vis_faces');
await db.close(); process.exit(0);
