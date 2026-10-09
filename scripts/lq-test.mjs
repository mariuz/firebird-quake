// lq-test.mjs – LibreQuake's levels (the free game data, `npm run fetch-librequake`). Every level of
// LibreQuake lite: it loads, the player stands on the floor of an open leaf at full health, its
// monsters are there, and each exit names a map the pak has (but one, lq_e0m2's dangling
// "e0-level-trans") and ends the level when fired. Then lq_e0m7's boss trap, the trigger_hurt test:
// two buttons count down a trigger_counter that sinks the vore's pillar into the lava, where a
// trigger_hurt of 50000 kills it through its 3000 armour; in the PSQL game and in QuakeC mode, where
// the boss's armorvalue comes from its map keys (ED_ParseEpair, map_keys). Then lq_e0m4's light_globe,
// drawn in both modes (makestatic keeps a static entity drawn in QuakeC mode).
//
//   node scripts/lq-test.mjs                (LQ=… for another LibreQuake pak0.pak)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lqPath = process.env.LQ ?? path.join(root, 'public/pak/lq1/pak0.pak');
if (!fs.existsSync(lqPath)) { console.log(`${lqPath} is missing: npm run fetch-librequake`); process.exit(1); }
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
const pak = new Pak(fs.readFileSync(lqPath).buffer);

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://lq', { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const tic = (fn = 'quake_tic') => q1(`SELECT * FROM ${fn}(1, 0, 0, 0, 0, 0, 0, 1, 0)`);
// the one exit that leads nowhere: lq_e0m2's second trigger_changelevel names a map lite does not ship
const DANGLING = new Set(['lq_e0m2:e0-level-trans']);

// ── every level ──────────────────────────────────────────────────────────────
const levels = pak.mapNames().filter((m) => m === 'start' || /^lq_e\dm\d$/.test(m));
for (const name of levels) {
  await loadMap(db, pak, res, name, { skill: 1, seed: 3 });
  let r;
  for (let i = 0; i < 20; i++) r = await tic();
  const pe = (await q1('SELECT ent_id e FROM player')).E;
  const p = await q1(`SELECT flags, (SELECT contents FROM leaves l WHERE l.id = e.leaf) c FROM ents e WHERE e.id = ${pe}`);
  const monsters = (await q1('SELECT COUNT(*) n FROM ents WHERE mtype IS NOT NULL')).N;
  const exits = await qa("SELECT id, map FROM ents WHERE classname = 'trigger_changelevel' ORDER BY id");
  const missing = exits.filter((x) => !pak.has(`maps/${String(x.MAP).toLowerCase()}.bsp`) && !DANGLING.has(`${name}:${x.MAP}`));
  const msg = (await q1('SELECT level_msg m FROM game')).M ?? '';
  if (process.env.DEBUG) console.log(name, { health: r.HEALTH, flags: p.FLAGS, contents: p.C, monsters, exits: exits.length, missing });
  // on the floor of an open leaf, or swimming (lq_e0m1 starts in water)
  assert(r.HEALTH === 100 && (((p.FLAGS & 512) !== 0 && p.C === -1) || p.C === -3) && monsters > 0 && exits.length > 0 && missing.length === 0,
    `${name.padEnd(8)} "${msg}": ${p.C === -3 ? 'starts in water' : 'stands on the floor'} at full health, ${monsters} monsters, exits to ${exits.map((x) => x.MAP).join(', ')}`);
  // the first exit that leads somewhere ends the level there
  const out = exits.find((x) => !DANGLING.has(`${name}:${x.MAP}`));
  await db.exec(`EXECUTE PROCEDURE changelevel(${out.ID})`);
  r = await tic();
  assert(r.EXIT_KIND === 1 && r.NEXT_MAP === out.MAP && r.INTERMISSION === 1, `${name.padEnd(8)} its exit ends the level for ${out.MAP}, with the intermission`);
}

// ── lq_e0m7's boss trap, in the PSQL game ───────────────────────────────────
async function staged(mode) {
  await db.exec('EXECUTE PROCEDURE qc_leave');
  await loadMap(db, pak, res, 'lq_e0m7', { skill: 1, seed: 9 });
  if (mode === 'qc') await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
}
await staged('psql');
const boss = (await q1("SELECT id FROM ents WHERE targetname = 'boss'")).ID;
const pillar = (await q1("SELECT id, z FROM ents WHERE targetname = 'terminator'"));
const buttons = (await qa("SELECT id FROM ents WHERE classname = 'func_button' AND target = 'terminator_counter' ORDER BY id")).map((b) => b.ID);
assert(boss && pillar && buttons.length === 2, `the vore (edict ${boss}) on its pillar, two buttons to sink it`);
const pe = (await q1('SELECT ent_id e FROM player')).E;
await db.exec(`EXECUTE PROCEDURE button_fire(${buttons[0]}, ${pe})`);
for (let i = 0; i < 40; i++) await tic();
assert((await q1(`SELECT z FROM ents WHERE id = ${pillar.ID}`)).Z === pillar.Z, 'one button: the counter waits, the pillar stays');
await db.exec(`EXECUTE PROCEDURE button_fire(${buttons[1]}, ${pe})`);
const killed0 = (await tic()).KILLED;
let b, r;
for (let i = 0; i < 400; i++) { r = await tic(); b = await q1(`SELECT health, z, st FROM ents WHERE id = ${boss}`); if (b.HEALTH <= 0) break; }
const sunk = (await q1(`SELECT z FROM ents WHERE id = ${pillar.ID}`)).Z;
assert(sunk < pillar.Z - 50, `the second button: the pillar sinks (${(pillar.Z - sunk).toFixed(0)} units)`);
assert(b.HEALTH <= 0 && r.KILLED === killed0 + 1, `the vore goes down with it into the trigger_hurt and dies (z ${b.Z.toFixed(0)}, kills ${killed0} → ${r.KILLED})`);
const weak = await qa("SELECT e.dmg FROM ents e WHERE e.classname = 'trigger_hurt' ORDER BY e.dmg");
assert(weak.map((x) => x.DMG).join() === '0,0,50000', `the trap's other trigger_hurts are dmg 0.1, nothing on integer health (${weak.map((x) => x.DMG).join(', ')})`);

// ── and in QuakeC mode, the boss with its armour ─────────────────────────────
await loadProgs(db, pak);
await staged('qc');
const qcEnt = async (field, value) => (await q1(`SELECT FIRST 1 f.ent FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0
  WHERE f.ofs = qc_fdef('${field}') AND qc_str(CAST(f.v AS INTEGER)) = '${value}' ORDER BY f.ent`))?.ENT;
const qboss = await qcEnt('targetname', 'boss');
const qpillar = await qcEnt('targetname', 'terminator');
const qbuttons = (await qa(`SELECT f.ent FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0
  WHERE f.ofs = qc_fdef('target') AND qc_str(CAST(f.v AS INTEGER)) = 'terminator_counter' ORDER BY f.ent`)).map((x) => x.ENT);
const fq = async (e, f) => (await q1(`SELECT qc_f(${e}, qc_fdef('${f}')) v FROM rdb$database`)).V;
assert((await fq(qboss, 'armorvalue')) === 3000 && (await fq(qboss, 'armortype')) === 1, 'QuakeC mode: the vore has the armour its map keys give it (armorvalue 3000, armortype 1)');
const dmgs = (await qa(`SELECT qc_f(f.ent, qc_fdef('dmg')) d FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'trigger_hurt' ORDER BY 1`)).map((x) => x.D);
assert(dmgs.length === 3 && Math.abs(dmgs[0] - 0.1) < 1e-6 && dmgs[2] === 50000, `the trigger_hurts' dmg as written (${dmgs.join(', ')})`);
// a button pressed as the player's use would: self the button, activator the player, its use function
const press = (e) => db.exec(`SET TERM ^ ;
EXECUTE BLOCK AS DECLARE f INTEGER; BEGIN
  EXECUTE PROCEDURE qc_sg(qc_gdef('activator'), 1); EXECUTE PROCEDURE qc_sg(qc_gdef('other'), 1); EXECUTE PROCEDURE qc_sg(qc_gdef('self'), ${e});
  f = CAST(qc_f(${e}, qc_fdef('use')) AS INTEGER);
  EXECUTE PROCEDURE qc_call(f);
END^
SET TERM ; ^`);
const z0 = (await q1(`SELECT z FROM ents WHERE id = ${qpillar}`)).Z;
await press(qbuttons[0]);
for (let i = 0; i < 20; i++) await tic('qc_tic');
await press(qbuttons[1]);
let qh;
for (let i = 0; i < 400; i++) { await tic('qc_tic'); qh = await fq(qboss, 'health'); if (qh <= 0) break; }
const qz = (await q1(`SELECT z FROM ents WHERE id = ${qpillar}`)).Z;
assert(qz < z0 - 50 && qh <= 0, `QuakeC mode: both buttons sink the pillar (${(z0 - qz).toFixed(0)} units) and the trigger_hurt kills the armoured vore (health ${qh})`);
assert(/bossdeath|boss/.test(JSON.stringify(await qa("SELECT kind, msg FROM qc_log WHERE kind = 'error'"))) === false, 'with no QuakeC errors');

// ── lq_e0m4's light_globe, and makestatic in QuakeC mode ────────────────────
const drawn = (name) => q1(`SELECT COUNT(*) n FROM ents e JOIN models m ON m.id = e.model_id WHERE m.name = '${name}'`).then((x) => x.N);
await db.exec('EXECUTE PROCEDURE qc_leave');
await loadMap(db, pak, res, 'lq_e0m4', { skill: 1, seed: 2 });
assert((await drawn('progs/s_light.spr')) === 1, 'lq_e0m4: the light_globe is its s_light sprite (the PSQL game)');
const torchesPsql = await drawn('progs/flame.mdl');
await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
const statics = (await q1("SELECT COUNT(*) n FROM ents WHERE classname = 'static'")).N;
assert((await drawn('progs/s_light.spr')) === 1 && (await drawn('progs/flame.mdl')) === torchesPsql && statics > 0,
  `QuakeC mode: makestatic keeps what it makes static drawn (${statics} statics: the globe and ${torchesPsql} torches, as in the PSQL game)`);

await db.close();
console.log(failed ? `${failed} failure(s)` : 'all LibreQuake checks passed');
process.exit(failed ? 1 : 0);
