import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const res = await loadResources(db, pak); await loadMap(db, pak, res, process.argv[2] ?? 'e1m1');
const mons = (await db.query("SELECT id, mtype, x, y, z FROM ents WHERE mtype IS NOT NULL AND st <> 'cruc' ORDER BY id")).rows;
const head = (await db.query('SELECT m.hull1 h FROM models m JOIN game g ON g.world_model = m.id')).rows[0].H;
for (const m of mons.slice(0, 6)) {
  for (let a = 0; a < 360; a += 45) {
    const d = 160, x = m.X + Math.cos(a * Math.PI / 180) * d, y = m.Y + Math.sin(a * Math.PI / 180) * d, z = m.Z + 24;
    const c = (await db.query(`SELECT hull_contents(1, ${head}, ${x}, ${y}, ${z}) c, point_leaf(${x}, ${y}, ${z}) l FROM rdb$database`)).rows[0];
    if (c.C !== -1 || c.L <= 0) continue;
    const yaw = (a + 180) % 360;
    // can we see it?
    await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw} WHERE id = (SELECT ent_id FROM player)`);
    await db.exec('EXECUTE PROCEDURE link_ent((SELECT ent_id FROM player))');
    const vis = (await db.query(`SELECT visible((SELECT ent_id FROM player), ${m.ID}) v FROM rdb$database`)).rows[0].V;
    if (!vis) continue;
    console.log(`monster ${m.ID} ${m.MTYPE} at ${m.X},${m.Y},${m.Z}: spot --at=${x.toFixed(0)},${y.toFixed(0)},${z.toFixed(0)},${yaw}`);
    break;
  }
}
await db.close(); process.exit(0);
