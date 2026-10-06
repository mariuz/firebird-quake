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
const v = (await db.query('SELECT * FROM view_setup')).rows[0];
const mark = `DELETE FROM vis_faces; INSERT INTO vis_faces (face, ent_id, ox, oy, oz) SELECT DISTINCT m.face, 0, 0, 0, 0 FROM leaves l JOIN marksurfaces m ON m.id >= l.first_ms AND m.id < l.first_ms + l.num_ms WHERE l.id > 0 AND BIN_AND(POSITION(SUBSTRING('${v.PVS}' FROM BIN_SHR(l.id - 1, 2) + 1 FOR 1), '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(l.id - 1, 3))) <> 0;`;
// does the join without ORDER BY come out grouped by face with ascending seq?
const r = await db.query(`EXECUTE BLOCK RETURNS (bad INTEGER, n INTEGER, faces INTEGER) AS DECLARE e INTEGER; DECLARE f INTEGER; DECLARE s INTEGER; DECLARE pf INTEGER = -1; DECLARE ps INTEGER = -1; DECLARE x DOUBLE PRECISION; BEGIN bad = 0; n = 0; faces = 0; ${mark}
  FOR SELECT v.ent_id, f.id, fv.seq, fv.x FROM vis_faces v JOIN faces f ON f.id = v.face JOIN face_verts fv ON fv.face = f.id WHERE f.nx * ${v.EX} + f.ny * ${v.EY} + f.nz * ${v.EZ} - f.dist > 0 INTO :e, :f, :s, :x DO BEGIN
    n = n + 1;
    IF (f <> pf) THEN BEGIN faces = faces + 1; IF (s <> 0) THEN bad = bad + 1; END
    ELSE IF (s <> ps + 1) THEN bad = bad + 1;
    pf = f; ps = s;
  END SUSPEND; END`);
console.log('no ORDER BY:', r.rows[0]);
const r2 = await db.query(`EXECUTE BLOCK RETURNS (n INTEGER, d INTEGER) AS BEGIN ${mark} SELECT COUNT(*), COUNT(DISTINCT face) FROM vis_faces INTO n, d; SUSPEND; END`);
console.log('marked', r2.rows[0]);
await db.close(); process.exit(0);
