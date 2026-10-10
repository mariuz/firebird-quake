// image-test.mjs – the schema image (scripts/build.mjs): createSchema run once, the database dumped
// (dumpDataDir) and opened again from the bytes (loadDataDir), as the page opens the build's
// schema-<hash>.fdb.gz instead of compiling the PSQL. The reopened database must play as the one built in
// place: E1M1 loaded into each with the same seed, the same tics give the same rows and the same frame.
//
//   node scripts/image-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

let t = performance.now();
const built = new FirebirdBrowser(`memory://built${Math.random()}`, { transport: new DirectTransport() });
await createSchema(built, sql);
const buildMs = performance.now() - t;
const image = await built.dumpDataDir();
t = performance.now();
const opened = new FirebirdBrowser(`memory://opened${Math.random()}`, { transport: new DirectTransport(), loadDataDir: image });
const procs = (await opened.query('SELECT COUNT(*) n FROM rdb$procedures WHERE COALESCE(rdb$system_flag, 0) = 0')).rows[0].N;
const openMs = performance.now() - t;
const builtProcs = (await built.query('SELECT COUNT(*) n FROM rdb$procedures WHERE COALESCE(rdb$system_flag, 0) = 0')).rows[0].N;
assert(procs === builtProcs && procs > 100, `the image (${(image.length / 1048576).toFixed(1)} MB) opens with every procedure (${procs}), in ${openMs.toFixed(0)} ms against ${buildMs.toFixed(0)} ms to build the schema`);

const play = async (db) => {
  const res = await loadResources(db, pak);
  await loadMap(db, pak, res, 'e1m1', { seed: 7 });
  const rows = [];
  for (let i = 0; i < 40; i++) {
    const r = (await db.query(`SELECT * FROM quake_tic(1, ${i > 10 ? 1 : 0}, 0, ${i > 25 ? 4 : 0}, 0, ${i === 30 ? 1 : 0}, 0, 1, 0)`)).rows[0];
    rows.push([r.TIC, r.PX, r.PY, r.PZ, r.YAW, r.HEALTH, r.SHELLS]);
  }
  const faces = (await db.query('SELECT * FROM frame_faces_fast', [], { rowMode: 'array' })).rows;
  const ents = (await db.query('SELECT id, x, y, z, frame FROM ents ORDER BY id', [], { rowMode: 'array' })).rows;
  return JSON.stringify({ rows, faces, ents });
};
const a = await play(built), b = await play(opened);
assert(a === b, 'E1M1 in each, the same 40 tics: the same rows, the same entities, the same frame query');
await built.close();
await opened.close();

console.log(failed ? `${failed} failure(s)` : 'all image checks passed');
process.exit(failed ? 1 : 0);
