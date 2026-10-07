// qcvm-tic-test.mjs – the page's QuakeC mode, as the page drives it: qc_tic
// returns QUAKE_TIC's row from progs.dat's player, through walking, firing,
// a pickup, a secret and the exit's intermission; then the level change the
// page makes (qc_change_parms, loadMap, qc_begin_map) carries the player's
// ammo and health into E1M2.
//
//   node scripts/qcvm-tic-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';

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
const ms = [];
const qcTic = async (tics = 1, { fwd = 0, side = 0, yaw = 0, pitch = 0, fire = 0, jump = 0, imp = 0 } = {}) => {
  const t0 = performance.now();
  const r = await q1(`SELECT * FROM qc_tic(${tics}, ${fwd}, ${side}, ${yaw}, ${pitch}, ${fire}, ${jump}, 1, ${imp})`);
  ms.push((performance.now() - t0) / tics);
  return r;
};
const box = [-16, -16, -24, 16, 16, 32];
const traceBox = (x1, y1, z1, x2, y2, z2) => q1(`SELECT fraction f, ex, ey, ez FROM trace_move(1, ${box.join(', ')}, ${x1}, ${y1}, ${z1}, ${x2}, ${y2}, ${z2}, 0)`);
const clear = (x, y, z) => q1(`SELECT test_position(1, ${x}, ${y}, ${z}) t FROM rdb$database`).then((r) => r.T === 0);
const place = async (x, y, z) => { await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = 0, vy = 0, vz = 0 WHERE id = 1`); await db.exec('EXECUTE PROCEDURE link_ent(1)'); };
const byClass = (cls) => qa(`SELECT f.ent FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0 WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = '${cls}' ORDER BY f.ent`).then((r) => r.map((x) => x.ENT));
const boxOf = (id) => q1(`SELECT x + minx x0, x + maxx x1, y + miny y0, y + maxy y1, z + minz z0, z + maxz z1 FROM ents WHERE id = ${id}`);
// a standing spot inside an entity's box: its centre, dropped onto the floor
const standIn = async (b) => {
  const cx = (b.X0 + b.X1) / 2, cy = (b.Y0 + b.Y1) / 2;
  for (const [dx, dy] of [[0, 0], [8, 0], [-8, 0], [0, 8], [0, -8], [16, 16], [-16, -16]]) {
    const top = Math.min(b.Z1 + 8, b.Z0 + 120);
    const down = await traceBox(cx + dx, cy + dy, top, cx + dx, cy + dy, b.Z0 - 128);
    if (down.F < 1 && (await clear(cx + dx, cy + dy, down.EZ))) return { x: cx + dx, y: cy + dy, z: down.EZ };
  }
  return null;
};

// ── the PSQL game's row, for its shape ─────────────────────────────────────
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
const psqlRow = await q1('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)');

// ── E1M1 in QuakeC mode, as the page starts it ─────────────────────────────
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
const progs = await loadProgs(db, pak);
if (process.env.QCJIT === 'all') {                 // every function compiled to its own procedure
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`compiled ${jit.compiled.size} functions in ${(jit.ms / 1000).toFixed(1)} s`);
}
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
let r = await qcTic();
assert(JSON.stringify(Object.keys(r)) === JSON.stringify(Object.keys(psqlRow)), `qc_tic returns QUAKE_TIC's ${Object.keys(r).length} columns, in order`);
const spot = await q1("SELECT ox, oy, oz, angle FROM map_ents WHERE classname = 'info_player_start'");
assert(r.HEALTH === 100 && r.SHELLS === 25 && r.WEAPON === 1 && r.ITEMS === 4096 + 256 + 1 && r.ARMORVALUE === 0 && r.DEAD === 0, "progs.dat's player: 100 health, 25 shells, the axe and the shotgun, and IT_SHELLS, the current ammo W_SetCurrentAmmo marks");
assert(Math.abs(r.PX - spot.OX) < 1 && Math.abs(r.PY - spot.OY) < 1 && Math.abs(r.PZ - spot.OZ) < 2 && r.YAW === spot.ANGLE && Math.abs(r.VIEW_Z - r.PZ - 22) < 0.01, `on the start, facing its angle ${spot.ANGLE} (fixangle), the eye 22 up`);
assert(r.MAP_NAME === 'e1m1' && r.LEVEL_MSG === 'the Slipgate Complex' && r.CPRINT === 'the Slipgate Complex', 'the level\'s name in the centre');
assert(r.TOTAL_MONSTERS > 0 && r.KILLED === 0 && r.TOTAL_SECRETS > 0 && r.FOUND_SECRETS === 0 && r.EXIT_KIND === 0, `progs.dat's own counts: ${r.TOTAL_MONSTERS} monsters, ${r.TOTAL_SECRETS} secrets`);
assert(r.LEAF > 0 && r.WATERLEVEL === 0, 'standing in a leaf of the map, dry');

// walking, turning
const y0 = r.PY;
for (let i = 0; i < 4; i++) r = await qcTic(4, { fwd: 1 });
assert(r.PY - y0 > 150, `walking forward (yaw 90, run) for 0.8 s moves ${(r.PY - y0).toFixed(0)} units north`);
r = await qcTic(2, { yaw: 30 });
assert(Math.abs(r.YAW - (spot.ANGLE + 30)) < 1e-6, `turning: yaw ${r.YAW}`);

// firing
let fired = null;
for (let i = 0; i < 3 && !fired; i++) { r = await qcTic(1, { fire: i === 0 ? 1 : 0 }); if (r.SHELLS === 24) fired = r; }
assert(fired && fired.WEAPONFRAME > 0 && fired.PUNCH < 0 && fired.PITCH < 0, `firing: 24 shells, the weapon animates (frame ${fired?.WEAPONFRAME}), the view kicks (${fired?.PUNCH})`);
for (let i = 0; i < 20; i++) r = await qcTic(1);

// a box of shells: the message line and the pickup flash
const shells = (await byClass('item_shells'))[0];
const sb = await boxOf(shells);
const at = await standIn({ ...sb, Z1: sb.Z0 + 32 });
await place(at.x, at.y, at.z);
r = await qcTic(1);
assert(r.SHELLS === 44 && r.MSG === 'You got the shells' && Math.abs(r.BONUS_TIME - r.TIME_) < 0.11, `a pickup: 44 shells, "${r.MSG}" on the message line, the bonus flash at ${r.BONUS_TIME}`);

// a secret: the centre print and the count
let secretFound = null;
for (const s of await byClass('trigger_secret')) {
  const b = await boxOf(s);
  const st = await standIn(b);
  if (!st) continue;
  await place(st.x, st.y, st.z);
  r = await qcTic(1);
  if (r.FOUND_SECRETS === 1) { secretFound = r; break; }
}
assert(secretFound && secretFound.CPRINT === 'You found a secret area!', `a trigger_secret: found ${secretFound?.FOUND_SECRETS} of ${secretFound?.TOTAL_SECRETS}, "${secretFound?.CPRINT}" in the centre`);

// the exit: changelevel_touch, the intermission camera, fire to go on
const exit = (await byClass('trigger_changelevel'))[0];
const eb = await boxOf(exit);
const es = await standIn(eb);
assert(!!es, 'a spot inside the exit trigger');
await place(es.x, es.y, es.z);
r = await qcTic(4);
const camera = await qa("SELECT ox, oy, oz FROM map_ents WHERE classname = 'info_intermission'");
const atCamera = camera.some((c) => Math.abs(c.OX - r.PX) < 1 && Math.abs(c.OY - r.PY) < 1 && Math.abs(c.OZ - r.PZ) < 1);
assert(atCamera && Math.abs(r.VIEW_Z - r.PZ) < 0.01 && r.EXIT_KIND === 0, 'touching the exit: execute_changelevel moves the view to an info_intermission (view_ofs 0) and waits');
assert(r.INTERMISSION === 1 && r.COMPLETED_TIME > 1 && r.COMPLETED_TIME <= r.TIME_, `svc_intermission: the page shows the stats, the level completed at ${r.COMPLETED_TIME?.toFixed(1)} s`);
for (let i = 0; i < 30 && r.EXIT_KIND === 0; i++) r = await qcTic(2);
assert(r.EXIT_KIND === 0, 'nothing happens without a button');
for (let i = 0; i < 6 && r.EXIT_KIND === 0; i++) r = await qcTic(1, { fire: 1 });
assert(r.EXIT_KIND === 1 && r.NEXT_MAP === 'e1m2', `after the wait, fire: ExitIntermission → changelevel("${r.NEXT_MAP}")`);

// ── the level change, as the page makes it ────────────────────────────────
const carried = { shells: r.SHELLS, health: r.HEALTH, items: r.ITEMS };
await db.exec('EXECUTE PROCEDURE qc_change_parms');
await loadMap(db, pak, res, 'e1m2', { skill: 1, newGame: false });
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 1)');
r = await qcTic();
assert(r.MAP_NAME === 'e1m2' && r.LEVEL_MSG === 'Castle of the Damned' && r.EXIT_KIND === 0 && r.TOTAL_MONSTERS > 0, `E1M2 spawned by progs.dat: ${r.TOTAL_MONSTERS} monsters`);
assert(r.SHELLS === carried.shells && r.HEALTH === carried.health && r.WEAPON === 1 && r.ITEMS === carried.items, `SetChangeParms and DecodeLevelParms carry ${r.SHELLS} shells and ${r.HEALTH} health into E1M2`);
assert(r.INTERMISSION === 0 && r.FINALE_TEXT === null && r.CDTRACK === -1, 'the new level starts without an intermission');

// the end of the episode: after E1M7's intermission, ExitIntermission switches the CD track and sends the
// finale's text (staged: the world's model says e1m7, the intermission has begun)
await db.exec("EXECUTE PROCEDURE qc_sf(0, qc_fdef('model'), qc_newstr('maps/e1m7.bsp'))");
await db.exec("EXECUTE PROCEDURE qc_sg(qc_gdef('intermission_running'), 1)");
await db.exec("EXECUTE PROCEDURE qc_run('ExitIntermission', 1)");
r = await qcTic();
const finale = (r.FINALE_TEXT ?? '').split(/\r?\n/);
assert(r.INTERMISSION === 2 && /^As the corpse of the monstrous/.test(finale[0]) && finale.length > 3 && r.CDTRACK === 2,
  `svc_cdtrack ${r.CDTRACK} and svc_finale: "${finale[0]}…" (${finale.length} lines)`);
assert((await q1("SELECT COUNT(*) n FROM qc_log WHERE kind = 'error'")).N === 0, 'no QuakeC errors');

const sorted = [...ms].sort((a, b) => a - b);
console.log(`qc_tic: median ${sorted[sorted.length >> 1].toFixed(0)} ms per tic over ${ms.length} calls`);
await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
