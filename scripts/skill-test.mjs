// skill-test.mjs – the skills, nightmare included: the start map's halls (trigger_setskill) set the skill
// the next level is spawned with, as Quake's do; on skill 3 monsters attack without the wait
// SUB_AttackFinished gives them and flinch at most every five seconds (T_Damage); QuakeC's localcmd
// "skill N" sets it in QuakeC mode.
//
//   node scripts/skill-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, loadProgs, SQL_FILES } from '../src/loader.js';

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
const tic = (a = [1, 0, 0, 0, 0, 0, 0, 1, 0]) => q1('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a);
const run = async (n) => { let s; for (let i = 0; i < n; i++) s = await tic(); return s; };

// ── the start map's halls ────────────────────────────────────────────────
await loadMap(db, pak, res, 'start', { skill: 1 });
const pe = (await q1('SELECT ent_id e FROM player')).E;
const halls = await qa("SELECT id, TRIM(message) msg, (minx + maxx) / 2 cx, (miny + maxy) / 2 cy, minz, maxz FROM ents WHERE classname = 'trigger_setskill' ORDER BY id");
assert(halls.length >= 4, `the start map has its skill halls: ${halls.map((h) => h.MSG).join(', ')}`);
for (const h of halls) {
  await db.exec(`UPDATE ents SET x = ${h.CX}, y = ${h.CY}, z = ${Math.min(h.MINZ + 25, h.MAXZ - 1)}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
  const r = await tic();
  assert(r.SKILL === Number(h.MSG), `walking into the hall of skill ${h.MSG} sets the skill to ${r.SKILL}`);
}

// ── nightmare: no wait before attacking, no flinching for five seconds ────
const knightOn = async (skill) => {
  await loadMap(db, pak, res, 'e1m1', { skill });
  await db.exec(`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL`);
  await db.exec(`UPDATE ents SET flags = BIN_OR(flags, 64) WHERE id = (SELECT ent_id FROM player)`);   // god mode
  await tic();
  const id = (await q1("SELECT id FROM spawn_monster('knight', 160)")).ID;
  await db.exec(`EXECUTE PROCEDURE found_target(${id}, (SELECT ent_id FROM player))`);
  return id;
};
const st = (id) => q1(`SELECT st, attack_finished af, pain_finished pf, health FROM ents WHERE id = ${id}`);
const hurtTwice = async (id) => {
  await db.exec(`EXECUTE PROCEDURE t_damage(${id}, 0, (SELECT ent_id FROM player), 1)`);
  const first = (await st(id)).ST;
  await run(30);                                     // 1.5 s: the pain animation is over
  await db.exec(`EXECUTE PROCEDURE t_damage(${id}, 0, (SELECT ent_id FROM player), 1)`);
  return [first, (await st(id)).ST];
};
let k = await knightOn(1);
const now = (await tic()).TIME_;
assert((await st(k)).AF > now, `on normal, a monster that finds its target waits before the first attack (attack_finished ${(await st(k)).AF.toFixed(2)} > ${now.toFixed(2)})`);
const normal = await hurtTwice(k);
assert(normal[0] === 'pain' && normal[1] === 'pain', `on normal, two hits 1.5 s apart make it flinch twice (${normal.join(', ')})`);

k = await knightOn(3);
let r = await tic();
assert(r.SKILL === 3, 'skill 3 is nightmare');
assert((await st(k)).AF <= r.TIME_, `on nightmare, no wait before the first attack (SUB_AttackFinished does nothing): attack_finished ${(await st(k)).AF}`);
const nm = await hurtTwice(k);
assert(nm[0] === 'pain' && nm[1] !== 'pain', `on nightmare, it flinches once, then not again for five seconds (${nm.join(', ')})`);
assert((await st(k)).PF > r.TIME_ + 3, 'pain_finished is five seconds ahead');

// ── QuakeC mode: trigger_setskill's localcmd ─────────────────────────────
await loadMap(db, pak, res, 'start', { skill: 1 });
await loadProgs(db, pak);
for (const part of ['skill ', '3', '\\n']) {
  await db.exec(`EXECUTE PROCEDURE qc_sg(4, qc_newstr('${part}'))`);
  await db.exec('EXECUTE PROCEDURE qc_builtin(46, 0)');
}
r = await q1('SELECT skill FROM game');
assert(r.SKILL === 3, `localcmd("skill "), localcmd("3"), localcmd("\\n"): the console sets skill ${r.SKILL}`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
