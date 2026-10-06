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
const J = (r) => console.log(JSON.stringify(r));
J((await db.query("SELECT id, classname, CAST(x+minx AS INTEGER) x0, CAST(x+maxx AS INTEGER) x1, CAST(y+miny AS INTEGER) y0, CAST(y+maxy AS INTEGER) y1, CAST(z+minz AS INTEGER) z0, CAST(z+maxz AS INTEGER) z1, model_id, solid FROM ents WHERE solid = 4 AND y + maxy >= 540 AND y + miny <= 600 AND x + maxx >= -50 AND x + minx <= 200")).rows);
J((await db.query("SELECT * FROM trace_move(NULL, 0,0,0,0,0,0, 160, 576, 72, 0, 576, 46, 1)")).rows[0]);
J((await db.query("SELECT * FROM trace_move(NULL, 0,0,0,0,0,0, 160, 576, 72, 0, 576, 46, 0)")).rows[0]);
const d = (await db.query("SELECT e.id, e.model_id, m.hull0, m.hull1, m.minx, m.maxx FROM ents e JOIN models m ON m.id = e.model_id WHERE e.solid = 4 AND e.y + e.maxy >= 540 AND e.y + e.miny <= 600 AND e.x + e.maxx >= -50 AND e.x + e.minx <= 200 ROWS 1")).rows[0];
J(d);
if (d) {
  J((await db.query(`SELECT * FROM trace_hull(0, ${d.HULL0}, 0, 0, 0, 160, 576, 72, 0, 576, 46)`)).rows[0]);
  J((await db.query(`SELECT hull_contents(0, ${d.HULL0}, 40, 576, 60) c FROM rdb$database`)).rows[0]);
  J((await db.query(`SELECT * FROM hulls WHERE hull = 0 AND node = ${d.HULL0}`)).rows[0]);
}
await db.close(); process.exit(0);
