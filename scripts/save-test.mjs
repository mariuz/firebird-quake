// save-test.mjs – save games (sql/save.sql, src/saves.js): E1M1 saved in the middle of play and loaded
// back, in the same session and the way the page does it after a reload (the slot exported, the map
// loaded again with other brush model ids, the slot imported, load_game); the same in QuakeC mode with
// progs.dat's globals, fields and run-time strings; and Host_Savegame_f's refusals.
//
//   node scripts/save-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { exportSave, importSave } from '../src/saves.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const tic = (fwd = 0, fire = 0, yaw = 0) => q1(`SELECT * FROM quake_tic(1, ${fwd}, 0, ${yaw}, 0, ${fire}, 0, 1, 0)`);
const qcTic = (fwd = 0, fire = 0, yaw = 0) => q1(`SELECT * FROM qc_tic(1, ${fwd}, 0, ${yaw}, 0, ${fire}, 0, 1, 0)`);
const refused = async (stmt, like) => { try { await db.exec(stmt); return false; } catch (e) { return e.message.includes(like); } };

// the state a save must bring back: every entity by its model's name (brush model ids change with each
// load of the map), the client, the level's totals and the light styles
const snapshot = async () => JSON.stringify({
  ents: await qa(`SELECT e.id, e.classname, e.x, e.y, e.z, e.vx, e.vy, e.vz, e.yaw, e.health, e.st, e.frame, e.think, e.nextthink, e.solid,
                         e.mv_state, e.enemy_id, e.leaf, m.name model FROM ents e LEFT JOIN models m ON m.id = e.model_id ORDER BY e.id`),
  player: await qa('SELECT * FROM player'),
  game: await qa('SELECT tic, time_, map_name, skill, total_monsters, killed, total_secrets, found_secrets, serverflags, qc_mode FROM game'),
  styles: await qa('SELECT * FROM lightstyles ORDER BY style'),
});
const qcSnapshot = async () => JSON.stringify({
  globals: await qa('SELECT ofs, v FROM qc_globals ORDER BY ofs'),
  fields: await qa('SELECT ent, ofs, v FROM qc_fields ORDER BY ent, ofs'),
  edicts: await qa('SELECT id, free FROM qc_edicts ORDER BY id'),
  strings: await qa('SELECT ofs, s FROM qc_strings WHERE ofs < 0 ORDER BY ofs'),
  vm: await qa('SELECT next_string, sv_time, cmdbuf FROM qc_vm'),
});

// ── the PSQL game ──────────────────────────────────────────────────────────
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
for (let i = 0; i < 20; i++) await tic(1, i === 10 ? 1 : 0);
let r = await tic();
const saved = await snapshot();
const savedPos = { x: r.PX, y: r.PY, z: r.PZ };
await db.exec('EXECUTE PROCEDURE save_game(0)');
let s = await q1('SELECT * FROM saves WHERE slot = 0');
assert(s && s.MAP_NAME === 'e1m1' && s.QC_MODE === 0, `save_game(0) keeps E1M1 at ${s?.TIME_.toFixed(2)} s: "${s?.COMMENT}"`);
assert(/^the Slipgate Complex\s+kills:\s+\d+\/\s*\d+$/.test(s.COMMENT), 'the slot is named as SaveGame_Comment names it: the level and the kills');
const nEnts = (await q1('SELECT COUNT(*) n FROM sv_ents WHERE slot = 0')).N;
assert(nEnts === (await q1('SELECT COUNT(*) n FROM ents')).N && nEnts > 20, `every entity is in sv_ents (${nEnts})`);

// play on: walk, turn, fire; a door, a monster woken; then load
for (let i = 0; i < 40; i++) await tic(1, i % 10 === 0 ? 1 : 0, i < 20 ? 3 : 0);
await db.exec('UPDATE ents SET health = 1 WHERE mtype IS NOT NULL');
assert((await snapshot()) !== saved, 'forty tics later the game has moved on');
await db.exec('EXECUTE PROCEDURE load_game(0)');
assert((await snapshot()) === saved, 'load_game(0) brings back every entity, the client, the totals and the light styles as saved');
r = await tic();
assert(Math.hypot(r.PX - savedPos.x, r.PY - savedPos.y) < 20, `the next tic goes on from the saved spot (${r.PX.toFixed(0)}, ${r.PY.toFixed(0)})`);
const faces = (await qa('SELECT * FROM frame_faces_fast')).length;
assert(faces > 50, `the view is marked again from the saved leaf (${faces} faces)`);
for (let i = 0; i < 10; i++) r = await tic(1);
assert(Math.hypot(r.PX - savedPos.x, r.PY - savedPos.y) > 30, 'and the player walks on');

// as the page does it after a reload: the slot out to the browser's storage as JSON, another level
// played (the brush models get other ids), E1M1 loaded again, the slot back in, load_game
const exported = JSON.stringify(await exportSave(db, 0));
const worldBefore = (await q1('SELECT world_model w FROM game')).W;
await db.exec('EXECUTE PROCEDURE delete_save(0)');
assert(!(await q1('SELECT COUNT(*) n FROM sv_ents WHERE slot = 0')).N, `delete_save empties the slot (the export is ${(exported.length / 1024).toFixed(0)} KB of JSON)`);
await loadMap(db, pak, res, 'e1m2', { skill: 1 });
for (let i = 0; i < 5; i++) await tic(1);
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
const worldNow = (await q1('SELECT world_model w FROM game')).W;
assert(worldNow !== worldBefore, `E1M1's world model is ${worldNow} now, ${worldBefore} when saved`);
await importSave(db, JSON.parse(exported), 5);
await db.exec('EXECUTE PROCEDURE load_game(5)');
assert((await snapshot()) === saved, 'imported into slot 5 and loaded, the game is the saved one, its doors and lifts on this copy of the map');
const doors = await q1(`SELECT COUNT(*) n FROM ents e JOIN models m ON m.id = e.model_id WHERE e.classname = 'func_door' AND m.name LIKE '*%' AND e.model_id >= ${worldNow}`);
assert(doors.N > 0, `the doors' brush models are renumbered to the new map's (${doors.N} doors)`);
const seq = (await q1('SELECT GEN_ID(ent_seq, 0) s FROM rdb$database')).S;
assert(Number(seq) === Number(JSON.parse(exported).meta.ENT_SEQ), 'the edict sequence is back where it was');
for (let i = 0; i < 10; i++) r = await tic(1, i === 5 ? 1 : 0);
assert(r.HEALTH > 0 && Math.hypot(r.PX - savedPos.x, r.PY - savedPos.y) > 30, 'and it plays on');

// Host_Savegame_f's refusals, and a load onto the wrong map
const pe = (await q1('SELECT ent_id e FROM player')).E;
assert(await refused('EXECUTE PROCEDURE save_game(13)', 'slot'), 'slot 13 is refused');
await db.exec(`UPDATE ents SET deadflag = 1, health = 0 WHERE id = ${pe}`);
assert(await refused('EXECUTE PROCEDURE save_game(1)', "Can't savegame with a dead player"), "a dead player can't save");
await db.exec(`UPDATE ents SET deadflag = 0, health = 100 WHERE id = ${pe}; UPDATE game SET intermission = 1, exit_kind = 1`);
assert(await refused('EXECUTE PROCEDURE save_game(1)', "Can't save in intermission"), "nor in the intermission");
assert(await refused('EXECUTE PROCEDURE load_game(1)', 'empty'), 'an empty slot is refused');
await loadMap(db, pak, res, 'e1m2', { skill: 1 });
assert(await refused('EXECUTE PROCEDURE load_game(5)', "load the save's map first"), "a save is loaded only onto its own map");

// ── QuakeC mode ────────────────────────────────────────────────────────────
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await loadProgs(db, pak);
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
for (let i = 0; i < 30; i++) r = await qcTic(1, i === 15 ? 1 : 0);
const qcPos = { x: r.PX, y: r.PY };
const qcSaved = await qcSnapshot();
const qcEnts = await snapshot();
await db.exec('EXECUTE PROCEDURE save_game(2)');
s = await q1('SELECT * FROM saves WHERE slot = 2');
assert(s.QC_MODE === 1 && (await q1('SELECT COUNT(*) n FROM sv_qc_fields WHERE slot = 2')).N > 500, `a QuakeC save keeps progs.dat's state too: "${s.COMMENT}"`);
const qcExported = JSON.stringify(await exportSave(db, 2));
for (let i = 0; i < 40; i++) await qcTic(1, i % 8 === 0 ? 1 : 0, 2);
assert((await qcSnapshot()) !== qcSaved, 'forty QuakeC frames later the VM has moved on');
// the page: the map again, QuakeC mode entered without a spawn, the slot imported, load_game
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await db.exec('EXECUTE PROCEDURE qc_enter');
await importSave(db, JSON.parse(qcExported), 6);
await db.exec('EXECUTE PROCEDURE load_game(6)');
assert((await qcSnapshot()) === qcSaved, 'loaded, the globals, fields, edicts and run-time strings are the saved ones');
assert((await snapshot()) === qcEnts, 'and so are the engine\'s fields of every edict, in ents');
for (let i = 0; i < 20; i++) r = await qcTic(1);
assert(r.HEALTH > 0 && Math.hypot(r.PX - qcPos.x, r.PY - qcPos.y) < 400, `progs.dat plays on from there (${r.PX.toFixed(0)}, ${r.PY.toFixed(0)}, health ${r.HEALTH})`);

// a PSQL save loaded after QuakeC mode leaves QuakeC mode
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await importSave(db, JSON.parse(exported), 0);
await db.exec('EXECUTE PROCEDURE load_game(0)');
assert((await snapshot()) === saved && (await q1('SELECT qc_mode m FROM game')).M === 0, 'the PSQL save loads back over QuakeC mode, in the PSQL game');
assert(await refused('EXECUTE PROCEDURE load_game(6)', 'QuakeC mode'), 'and a QuakeC save needs QuakeC mode');

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all save game checks passed');
process.exit(failed ? 1 : 0);
