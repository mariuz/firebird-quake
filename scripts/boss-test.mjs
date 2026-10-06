// boss-test.mjs – the House of Chthon (E1M7) end to end, inside Firebird:
// the rune wakes Chthon, he rises and throws lava, the lightning does
// nothing until both terminals are up, three bolts kill him, and his death
// opens the way out.
//
//   node scripts/boss-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadResources, loadMap, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pakPath = process.env.PAK ?? path.join(root, 'public/pak/pak0.pak');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

const db = new FirebirdBrowser('memory://quake', { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(pakPath).buffer);
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m7', { skill: 1 });

const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const tic = (a = [1, 0, 0, 0, 0, 0, 0, 1, 0]) => q1('SELECT * FROM quake_tic(?,?,?,?,?,?,?,?,?)', a);
const run = async (tics, a) => { let s; for (let i = 0; i < tics; i++) s = await tic(a); return s; };
let pe = (await q1('SELECT ent_id e FROM player')).E;
const teleport = async (x, y, z, yaw) => {
  await db.exec(`UPDATE ents SET x = ${x}, y = ${y}, z = ${z}, yaw = ${yaw}, vx = 0, vy = 0, vz = 0 WHERE id = ${pe}`);
  await db.exec(`EXECUTE PROCEDURE link_ent(${pe})`);
};
const sounds = async (like) => (await q1(`SELECT COUNT(*) n FROM sound_events WHERE snd LIKE '${like}'`)).N;
const boss = () => q1("SELECT id, st, health, model_id, anim, takedamage, solid FROM ents WHERE classname = 'monster_boss'");

// ── 1. the house, before the fight ──────────────────────────────────────
let b = await boss();
assert(b && b.ST === 'asleep' && b.MODEL_ID === null, 'Chthon sleeps in the lava, invisible');
const sigil = await q1("SELECT id, x, y, z, target FROM ents WHERE classname = 'item_sigil'");   // z: where it dropped to
assert(sigil && sigil.TARGET === 't4', 'the rune targets Chthon');
const terms = await qa("SELECT id, targetname, mv_state, CAST(z AS INTEGER) z FROM ents WHERE classname = 'func_door' AND target = 'lightning' ORDER BY id");
assert(terms.length === 2 && terms.every((t) => t.MV_STATE === 1), 'both lightning terminals start down');
const bolt = await q1("SELECT id FROM ents WHERE classname = 'event_lightning'");
assert(!!bolt, 'the event_lightning exists');

// ── 2. the lightning is harmless while the terminals are down ───────────
await db.exec(`EXECUTE PROCEDURE boss_awake(${b.ID})`);
await run(20);
await db.exec(`EXECUTE PROCEDURE event_lightning_fire(${bolt.ID})`);
b = await boss();
assert(b.HEALTH === 3, 'lightning with the terminals down does not hurt Chthon');
assert((await q1('SELECT COUNT(*) n FROM fx_events WHERE kind = 4')).N === 0, 'no bolt was drawn');

// restart cleanly: the real wake-up is the rune
await loadMap(db, pak, res, 'e1m7', { skill: 1 });
pe = (await q1('SELECT ent_id e FROM player')).E;   // a new player entity
b = await boss();
await teleport(sigil.X, sigil.Y, sigil.Z + 48, 0);   // feet above the floor it dropped onto
let s = await run(5);
assert((s.ITEMS & (1 << 28)) !== 0, `picking up the rune gives the sigil (msg "${s.MSG}")`);
b = await boss();
assert(b.ST === 'rise' && b.MODEL_ID !== null, 'the rune wakes Chthon: he rises');
assert((await sounds('boss1/sight1.wav')) > 0 && (await sounds('boss1/out1.wav')) > 0, 'his roar and the lava splash were heard');

// ── 3. he throws lava at the player ─────────────────────────────────────
await teleport(-300, 64, 56, 0);    // the far side of the room, facing him
s = await run(45);
b = await boss();
assert(b.ST !== 'rise' && b.ST !== 'asleep', `after rising he fights (state ${b.ST})`);
let lava = 0;
for (let i = 0; i < 160 && lava === 0; i++) {
  s = await tic();
  lava = (await q1("SELECT COUNT(*) n FROM ents WHERE classname = 'lavaball'")).N;
}
assert(lava > 0, 'Chthon threw a lava ball');
assert((await sounds('boss1/throw.wav')) > 0, 'the throw was heard');
assert((await q1(`SELECT takedamage t FROM ents WHERE classname = 'monster_boss'`)).T === 0, 'weapons cannot hurt him');
// the lava ball must eventually explode (fx 7) and vanish
s = await run(80);
assert((await q1('SELECT COUNT(*) n FROM fx_events WHERE kind = 7')).N > 0, 'a lava ball exploded');

// ── 4. raise both terminals with their floor buttons ────────────────────
const buttons = await qa("SELECT id, target FROM ents WHERE classname = 'func_button' AND target IN ('t12', 't13') ORDER BY id");
assert(buttons.length === 2, `one floor button per terminal on this skill (${buttons.map((x) => x.TARGET).join(', ')})`);
for (const bt of buttons) await db.exec(`EXECUTE PROCEDURE button_fire(${bt.ID}, ${pe})`);
let up = 0;
for (let i = 0; i < 100 && up < 2; i++) {
  await tic();
  up = (await q1("SELECT COUNT(*) n FROM ents WHERE target = 'lightning' AND mv_state = 0")).N;
}
assert(up === 2, 'both terminals rose to their top');

// ── 5. three bolts ──────────────────────────────────────────────────────
const lightningButton = await q1("SELECT id, x + (minx + maxx) / 2 cx, y + (miny + maxy) / 2 cy, z + maxz top FROM ents WHERE classname = 'func_button' AND target = 't14'");
assert(!!lightningButton, 'the lightning button exists');
// the first press is a real one: stand on the button
await teleport(lightningButton.CX, lightningButton.CY, lightningButton.TOP + 30, 0);
let hp = 3;
for (let i = 0; i < 60 && hp === 3; i++) { s = await tic([1, 0.2, 0, 0, 0, 0, 0, 1, 0]); hp = (await boss()).HEALTH; }
assert(hp === 2, `standing on the button fires the bolt: Chthon has ${hp} hits left`);
assert((await q1('SELECT COUNT(*) n FROM fx_events WHERE kind = 4')).N > 0, 'the bolt was drawn between the terminals');
assert((await sounds('boss1/pain.wav')) > 0, 'Chthon screamed');
b = await boss();
assert(b.ST === 'pain' && b.ANIM === 'shocka', `he convulses (${b.ANIM})`);
await teleport(-300, 64, 56, 0);
// the button returns after its wait; press it twice more
for (const want of [1, 0]) {
  let ready = false;
  for (let i = 0; i < 80 && !ready; i++) { await tic(); ready = (await q1(`SELECT mv_state m FROM ents WHERE id = ${lightningButton.ID}`)).M === 1; }
  assert(ready, 'the button came back up');
  await db.exec(`EXECUTE PROCEDURE button_fire(${lightningButton.ID}, ${pe})`);
  await run(3);
  b = await boss();
  assert((b?.HEALTH ?? 0) === want, `bolt: ${want} hit(s) left (state ${b?.ST})`);
}
assert(b.ST === 'die', 'the third bolt kills Chthon');
assert((await sounds('boss1/death.wav')) > 0, 'his death cry was heard');
s = await run(30);
assert(!(await boss()), 'Chthon is gone');
assert(s.KILLED === 1, 'the kill is counted');

// ── 6. his death opens the way out ──────────────────────────────────────
const exits = await qa("SELECT id, mv_state, CAST(z AS INTEGER) z, CAST(x AS INTEGER) x FROM ents WHERE classname = 'func_door' AND targetname = 't9'");
assert(exits.length > 0 && exits.every((d) => d.MV_STATE !== 1), `the t9 doors opened (${exits.map((d) => d.MV_STATE).join(', ')})`);
// and the terminals go back down after their wait
await run(400);
assert((await q1("SELECT COUNT(*) n FROM ents WHERE target = 'lightning' AND mv_state = 1")).N === 2, 'the terminals sank back after 20 s');

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
