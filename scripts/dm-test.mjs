// dm-test.mjs – deathmatch and coop in QuakeC mode with bots (sql/bots.sql): progs.dat's own rules with
// clients 2.. played by PSQL. E1M1 as a deathmatch: every client on its own info_player_deathmatch, no
// monsters, the bots roaming; a bot that sees the player fights and frags it (progs.dat's obituary),
// the player respawns at a deathmatch spot by pressing fire; the player frags a bot; fraglimit ends the
// level. Then coop: the monsters stay and a bot fights one. Then a deathmatch demo: the bots replay too.
//
//   node scripts/dm-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { exportDemo, DemoPlayer } from '../src/demos.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(pakPath).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://dm', { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
let view = 0;    // the player's view yaw, as qc_tic reports it
const tic = async ({ fwd = 0, yaw = 0, fire = 0 } = {}) => { const r = await q1(`SELECT * FROM qc_tic(1, ${fwd}, 0, ${yaw}, 0, ${fire}, 0, 1, 0)`); view = r.YAW; return r; };
const run = async (n, opts) => { let r; for (let i = 0; i < n; i++) r = await tic(typeof opts === 'function' ? opts(i) : opts); return r; };
const scores = () => qa('SELECT * FROM qc_scores ORDER BY c');
const frags = async (c) => (await scores()).find((s) => s.C === c)?.FRAGS;
const field = (e, f) => q1(`SELECT qc_f(${e}, qc_fdef('${f}')) v FROM rdb$database`).then((r) => r.V);
const setField = (e, f, v) => db.exec(`EXECUTE PROCEDURE qc_sf(${e}, qc_fdef('${f}'), ${v})`);
const pos = (e) => q1(`SELECT x, y, z, yaw FROM ents WHERE id = ${e}`);
const bprints = async () => (await qa("SELECT msg FROM qc_log WHERE kind = 'bprint' ORDER BY id")).map((r) => r.MSG).join('');
const place = async (e, x, y, z) => { await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, vx = 0, vy = 0, vz = 0 WHERE id = ${e}`); await db.exec(`EXECUTE PROCEDURE link_ent(${e})`); };
const clear = (x, y, z) => q1(`SELECT test_position(1, ${x}, ${y}, ${z}) t FROM rdb$database`).then((r) => r.T === 0);
const sees = (x1, y1, z1, x2, y2, z2) => q1(`SELECT fraction f FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, ${x1}, ${y1}, ${z1}, ${x2}, ${y2}, ${z2}, 1)`).then((r) => r.F >= 1);
const turnTo = async (x, y) => { const p = await pos(1); const want = (Math.atan2(y - p.Y, x - p.X) * 180) / Math.PI; let d = want - view; d -= 360 * Math.floor((d + 180) / 360); await tic({ yaw: d }); };
// a clear standing spot at a distance from the player, in sight of it, along the way it looks
async function spotNear(dist) {
  const p = await pos(1);
  for (let a = 0; a < 360; a += 15) {
    const r = ((p.YAW + a) * Math.PI) / 180;
    const x = p.X + Math.cos(r) * dist, y = p.Y + Math.sin(r) * dist;
    if ((await clear(x, y, p.Z)) && (await sees(p.X, p.Y, p.Z + 22, x, y, p.Z + 22))) return { x, y, z: p.Z };
  }
  return null;
}
async function deathmatch(nbots, { coop = 0, fraglimit = 0, seed = 11 } = {}) {
  await db.exec('EXECUTE PROCEDURE qc_leave');
  await loadMap(db, pak, res, 'e1m1', { skill: 1, seed });
  await db.exec(`EXECUTE PROCEDURE qc_setup_server(${coop ? 0 : 1}, ${coop}, ${nbots}, ${fraglimit}, 0)`);
  await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
}

await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await loadProgs(db, pak);

// ── E1M1 as a deathmatch with two bots ──────────────────────────────────────
await deathmatch(2);
let s = await scores();
assert(s.length === 3 && s[1].NAME === 'Grunt' && s[2].NAME === 'Enforcer' && s.every((c) => c.ALIVE === 1 && c.FRAGS === 0),
  `three clients in the game: ${s.map((c) => c.NAME).join(', ')}`);
assert(/Grunt entered the game/.test(await bprints()), 'the bots connect as clients do ("Grunt entered the game")');
const spots = await qa("SELECT ox, oy, oz FROM map_ents WHERE classname = 'info_player_deathmatch'");
const at = await Promise.all([1, 2, 3].map(pos));
const onSpot = at.map((p) => spots.findIndex((o) => Math.hypot(o.OX - p.X, o.OY - p.Y) < 1));   // as spawned, before the first frame
assert(onSpot.every((i) => i >= 0) && new Set(onSpot).size === 3, `each client starts on its own info_player_deathmatch (spots ${onSpot.join(', ')} of ${spots.length})`);
assert((await q1('SELECT COUNT(*) n FROM ents WHERE BIN_AND(flags, 32) <> 0')).N === 0, 'deathmatch has no monsters (their spawn functions remove them)');
await tic();
await run(100);
const moved = await Promise.all([2, 3].map(async (c, i) => { const p = await pos(c); return Math.hypot(p.X - at[c - 1].X, p.Y - at[c - 1].Y); }));
assert(moved.every((d) => d > 100), `the bots roam (${moved.map((d) => d.toFixed(0)).join(' and ')} units in 5 s)`);

// a bot in sight of the player fights it: it turns, fires, hurts it
await setField(3, 'health', 0); await db.exec("UPDATE ents SET solid = 0, x = x + 4000 WHERE id = 3");   // the other bot out of the way
const near = await spotNear(260);
assert(!!near, 'a spot in the open, 260 units from the player');
await place(2, near.x, near.y, near.z);
await db.exec("UPDATE bots SET look_at = 0, enemy = NULL WHERE c = 2");
const hp0 = (await tic()).HEALTH;
const shots0 = (await q1("SELECT MAX(id) m FROM sound_events")).M ?? 0;
let fired = 0, sawPlayer = false, r;
for (let i = 0; i < 80 && !fired; i++) {
  r = await tic();
  sawPlayer ||= (await q1('SELECT enemy FROM bots WHERE c = 2')).ENEMY === 1;
  fired = (await q1(`SELECT COUNT(*) n FROM sound_events WHERE ent_id = 2 AND snd STARTING WITH 'weapons/' AND id > ${shots0}`)).N;
}
assert(sawPlayer, 'the bot sees the player and takes it as its enemy');
assert(fired > 0, `and fires at it (${(await q1(`SELECT FIRST 1 snd FROM sound_events WHERE ent_id = 2 AND snd STARTING WITH 'weapons/' AND id > ${shots0}`))?.SND})`);
r = await run(40);
assert(r.HEALTH < hp0, `the player is hurt (health ${hp0} → ${r.HEALTH})`);
// the player at 1 health: the bot frags it
await setField(1, 'health', 1);
for (let i = 0; i < 120 && r.DEAD === 0; i++) r = await tic();
assert(r.DEAD === 1 && (await frags(2)) === 1, `the bot frags the player (Grunt ${await frags(2)} frag)`);
assert(/player .*Grunt/.test((await bprints()).split('\n').slice(-3).join('\n')), `with progs.dat's obituary: "${(await bprints()).split('\n').filter(Boolean).at(-1)}"`);
// respawn: let go of fire, wait, press it
r = await run(30);
for (let i = 0; i < 40 && r.DEAD === 1; i++) r = await tic({ fire: i % 2 });
const back = await pos(1);
assert(r.DEAD === 0 && r.HEALTH === 100 && r.EXIT_KIND === 0, 'the player respawns by pressing fire, with full health, and the level goes on');
assert(spots.some((o) => Math.hypot(o.OX - back.X, o.OY - back.Y) < 40), 'at a deathmatch spot');

// the player frags the bot: the bot at 1 health, in the player's sights
await setField(1, 'health', 1000);
const n2 = await spotNear(200);
await place(2, n2.x, n2.y, n2.z);
await setField(2, 'health', 1);
for (let i = 0; i < 30 && (await frags(1)) < 1; i++) {
  const b = await pos(2); await turnTo(b.X, b.Y); await tic({ fire: 1 }); await run(3);
  if (process.env.DEBUG) console.log(i, await pos(1), await pos(2), view, await field(2, 'health'), await field(1, 'weapon'), await field(1, 'ammo_shells'), await field(1, 'health'));
}
assert((await frags(1)) === 1, 'the player frags the bot');
let alive2 = 0;
for (let i = 0; i < 100 && !alive2; i++) { await tic(); alive2 = (await field(2, 'health')) > 0 ? 1 : 0; }
assert(alive2 === 1, 'and the bot respawns by itself');

// fraglimit 2: the next frag ends the level (CheckRules → NextLevel → the intermission)
await db.exec('UPDATE game SET fraglimit = 2');
const n3 = await spotNear(200);
await place(2, n3.x, n3.y, n3.z);
await setField(2, 'health', 1);
for (let i = 0; i < 30 && !r.INTERMISSION; i++) { const b = await pos(2); await turnTo(b.X, b.Y); r = await tic({ fire: 1 }); r = await run(3); }
assert(r.INTERMISSION === 1 && (await frags(1)) === 2, `fraglimit 2 reached: the intermission (next map ${r.NEXT_MAP ?? '(after fire)'})`);
const exitAfter = await run(10);
assert(exitAfter.INTERMISSION === 1, 'the bots keep their hands off the buttons in the intermission (it waits for the player)');

// ── coop: the monsters stay, a bot fights them ─────────────────────────────
await deathmatch(1, { coop: 1 });
await run(20);                                   // walkmonster_start_go sets FL_MONSTER a moment after the spawn
const monsters = (await q1('SELECT COUNT(*) n FROM ents WHERE BIN_AND(flags, 32) <> 0 AND solid <> 0')).N;
assert(monsters > 0, `coop keeps the monsters (${monsters})`);
// a grunt with an open spot in sight of it, for the bot
const grunts = (await qa(`SELECT e.id FROM ents e JOIN qc_fields f ON f.ent = e.id AND f.ofs = qc_fdef('classname')
  WHERE qc_str(CAST(f.v AS INTEGER)) = 'monster_army' ORDER BY e.id`)).map((x) => x.ID);
let grunt = null, g = null, gp = null;
for (const id of grunts) {
  g = await pos(id);
  for (const dist of [200, 150, 280]) for (let a = 0; a < 360 && !gp; a += 20) {
    const x = g.X + Math.cos((a * Math.PI) / 180) * dist, y = g.Y + Math.sin((a * Math.PI) / 180) * dist;
    if ((await clear(x, y, g.Z)) && (await sees(x, y, g.Z + 22, g.X, g.Y, g.Z + 10))) gp = { x, y };
  }
  if (gp) { grunt = id; break; }
}
assert(!!gp, `an open spot in sight of a grunt (edict ${grunt})`);
await place(2, gp.x, gp.y, g.Z);
await setField(1, 'flags', 64 + (await field(1, 'flags')));   // the player in god mode, out of it
await db.exec("UPDATE bots SET look_at = 0 WHERE c = 2");
const ghp = await field(grunt, 'health');
let botEnemy = null;
for (let i = 0; i < 100; i++) { await tic(); botEnemy ??= (await q1('SELECT enemy FROM bots WHERE c = 2')).ENEMY; if ((await field(grunt, 'health')) < ghp) break; }
assert(botEnemy === grunt, `the coop bot takes the grunt (edict ${grunt}) as its enemy`);
assert((await field(grunt, 'health')) < ghp, `and shoots it (health ${ghp} → ${await field(grunt, 'health')})`);

// ── a deathmatch demo: the bots replay as well ─────────────────────────────
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: 1 });
await db.exec('EXECUTE PROCEDURE qc_setup_server(1, 0, 2, 0, 0)');
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
await db.exec('EXECUTE PROCEDURE demo_record');
const trail = async () => JSON.stringify(await qa('SELECT id, x, y, z FROM ents WHERE id <= 3 ORDER BY id'));
const rec = [];
for (let i = 0; i < 120; i++) { await tic({ fwd: i % 40 < 25 ? 1 : 0, yaw: i % 30 < 4 ? 5 : 0, fire: i % 9 === 0 ? 1 : 0 }); rec.push(await trail()); }
await db.exec('EXECUTE PROCEDURE demo_stop');
const demo = await exportDemo(db);
assert(demo.deathmatch === 1 && demo.nbots === 2, 'the demo keeps the server\'s rules (deathmatch, 2 bots)');
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'e1m1', { skill: demo.skill, seed: demo.seed });
await db.exec(`EXECUTE PROCEDURE qc_setup_server(${demo.deathmatch}, ${demo.coop}, ${demo.nbots}, ${demo.fraglimit}, ${demo.timelimit})`);
await db.exec(`EXECUTE PROCEDURE qc_begin_map(${demo.skill}, 0)`);
const player = new DemoPlayer(demo);
let same = -1;
for (let i = 0, args; (args = player.next()); i++) {
  await q1('SELECT * FROM qc_tic(?,?,?,?,?,?,?,?,?)', args);
  if (same < 0 && (await trail()) !== rec[i]) same = i;
}
assert(same === -1, `played back, the player and both bots move exactly as recorded (diverged at ${same})`);

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all deathmatch checks passed');
process.exit(failed ? 1 : 0);
