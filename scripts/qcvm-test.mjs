// qcvm-test.mjs – the QuakeC VM in PSQL runs the real progs.dat: pure
// functions, builtins, the calling convention with locals and recursion,
// entity fields through OP_ADDRESS/OP_STOREP/OP_LOAD, strings, and
// worldspawn with its light styles.
//
//   node scripts/qcvm-test.mjs            (PAK=path/to/pak0.pak for another progs.dat)

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
let t0 = performance.now();
const progs = await loadProgs(db, pak);
if (process.env.QCJIT === 'all') {                 // every function compiled to its own procedure
  const jit = new QcJit(db, progs);
  await jit.init();
  await jit.compileAll();
  console.log(`compiled ${jit.compiled.size} functions in ${(jit.ms / 1000).toFixed(1)} s`);
}
console.log(`progs.dat loaded in ${(performance.now() - t0).toFixed(0)} ms`);
const q1 = (s, p = []) => db.query(s, p).then((r) => r.rows[0]);
const qa = (s, p = []) => db.query(s, p).then((r) => r.rows);
const g = (ofs) => q1(`SELECT qc_g(${ofs}) v FROM rdb$database`).then((r) => r.V);
const setg = (ofs, v) => db.exec(`EXECUTE PROCEDURE qc_sg(${ofs}, ${v})`);
const call = (name) => db.exec(`EXECUTE PROCEDURE qc_call(qc_fn('${name}'))`);
const run = (name, self = 0) => db.exec(`EXECUTE PROCEDURE qc_run('${name}', ${self})`);
const steps = () => q1('SELECT steps FROM qc_vm').then((r) => Number(r.STEPS));
const fld = (ent, name) => q1(`SELECT qc_f(${ent ?? -1}, qc_fdef('${name}')) v FROM rdb$database`).then((r) => r.V);
const str = (ofs) => q1(`SELECT qc_str(${ofs}) s FROM rdb$database`).then((r) => r.S);
const log = (kind) => qa(`SELECT msg FROM qc_log WHERE kind = '${kind}' ORDER BY id`).then((r) => r.map((x) => x.MSG));

// ── loaded ────────────────────────────────────────────────────────────────
const n = await q1('SELECT (SELECT COUNT(*) FROM qc_statements) s, (SELECT COUNT(*) FROM qc_functions) f, (SELECT COUNT(*) FROM qc_defs WHERE kind = 0) g, (SELECT COUNT(*) FROM qc_defs WHERE kind = 1) e, (SELECT COUNT(*) FROM qc_strings) st, (SELECT COUNT(*) FROM qc_globals) gl FROM rdb$database');
assert(n.S === progs.statements.length && n.F === progs.functions.length, `progs.dat version 6, crc ${progs.crc}: ${n.S} statements, ${n.F} functions`);
assert(n.G === progs.globaldefs.length && n.E === progs.fielddefs.length, `${n.G} global and ${n.E} field definitions`);
assert(n.ST === progs.strings.length && n.GL === progs.globals.length, `${n.ST} strings, ${n.GL} globals`);
assert((await str(0)) === '' && (await q1("SELECT qc_fn('main') f FROM rdb$database")).F > 0, 'main() is a function');
const vm = await q1('SELECT * FROM qc_vm');
assert(vm.G_SELF > 0 && vm.G_TIME > 0 && vm.F_ORIGIN >= 0 && vm.F_NEXTTHINK > 0, `the VM knows self (${vm.G_SELF}), time (${vm.G_TIME}), .origin (${vm.F_ORIGIN}), .nextthink (${vm.F_NEXTTHINK})`);

// ── pure QuakeC ───────────────────────────────────────────────────────────
// float(float v) anglemod = { while (v >= 360) v = v - 360; while (v < 0) v = v + 360; return v; }
await setg(4, 370); await call('anglemod');
assert((await g(1)) === 10, 'anglemod(370) = 10');
await setg(4, -10); await call('anglemod');
assert((await g(1)) === 350, 'anglemod(-10) = 350 (loops, comparisons, locals)');
await setg(4, 725); await call('anglemod');
assert((await g(1)) === 5, 'anglemod(725) = 5');
assert((await q1('SELECT depth FROM qc_vm')).DEPTH === 0, 'the call depth is back to 0');

// builtins through the function table: vectoyaw is #13, vlen #12
await setg(4, 0); await setg(5, 1); await setg(6, 0); await call('vectoyaw');
assert(Math.abs((await g(1)) - 90) < 1e-4, `vectoyaw((0 1 0)) = ${await g(1)}, a builtin`);
await setg(4, 3); await setg(5, 4); await setg(6, 0); await call('vlen');
assert((await g(1)) === 5, 'vlen((3 4 0)) = 5');
// float() crandom = { return 2 * (random() - 0.5); }
let lo = 1, hi = -1;
for (let i = 0; i < 10; i++) { await call('crandom'); const v = await g(1); lo = Math.min(lo, v); hi = Math.max(hi, v); }
assert(lo >= -1 && hi <= 1 && hi - lo > 0.1, `crandom() in [-1, 1] (${lo.toFixed(2)}..${hi.toFixed(2)})`);
// makevectors: v_forward for yaw 90 is (0 1 0)
await setg(4, 0); await setg(5, 90); await setg(6, 0); await call('makevectors');
assert(Math.abs((await g(vm.G_VFWD)) - 0) < 1e-6 && Math.abs((await g(vm.G_VFWD + 1)) - 1) < 1e-6, 'makevectors((0 90 0)) sets v_forward = (0 1 0)');

// ── main(): prints ────────────────────────────────────────────────────────
await run('main');
assert((await log('dprint')).some((m) => /main function/.test(m)), `main() printed "${(await log('dprint')).join('|')}"`);

// ── globals and entity fields ─────────────────────────────────────────────
// void() SetNewParms = { parm1 = IT_SHOTGUN | IT_AXE; parm2 = 100; parm3 = 0; parm4 = 25; parm5..9 = 0; }
await run('SetNewParms');
const parm = async (i) => g((await q1(`SELECT qc_gdef('parm${i}') o FROM rdb$database`)).O);
assert((await parm(1)) === 4097 && (await parm(2)) === 100 && (await parm(4)) === 25, 'SetNewParms: parm1 = IT_SHOTGUN|IT_AXE, parm2 = 100, parm4 = 25 (global stores)');
// void() DecodeLevelParms = { if (serverflags) { if (world.model == "maps/start.bsp") SetNewParms(); } self.items = parm1; self.health = parm2; … }
const e = (await q1('SELECT qc_spawn() e FROM rdb$database')).E;
assert(e >= 2, `spawn() made edict ${e}`);
await run('DecodeLevelParms', e);
assert((await fld(e, 'items')) === 4097 && (await fld(e, 'health')) === 100 && (await fld(e, 'ammo_shells')) === 25, 'DecodeLevelParms(self): .items, .health, .ammo_shells stored through OP_ADDRESS/OP_STOREP');
// void() InitBodyQue: four spawned "bodyque" entities chained through .owner
await run('InitBodyQue');
const bodies = (await qa("SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'bodyque'")).map((r) => r.ENT);
assert(bodies.length === 4, `InitBodyQue spawned ${bodies.length} bodyque entities (spawn, string fields, OP_LOAD_ENT)`);
const owner1 = bodies.length ? await fld(bodies[0], 'owner') : null;
assert(bodies.includes(owner1) && owner1 !== bodies[0], 'and chained them through .owner');
// info_null removes self
const e2 = (await q1('SELECT qc_spawn() e FROM rdb$database')).E;
await run('info_null', e2);
assert((await q1(`SELECT free FROM qc_edicts WHERE id = ${e2}`)).FREE === 1, 'info_null: remove(self) frees the edict');
// ftos / vtos make strings
await setg(4, 12.5); await call('ftos');
assert((await str(await g(1))) === '12.5', `ftos(12.5) = "${await str(await g(1))}"`);
await setg(4, 1); await setg(5, 2); await setg(6, 3); await call('vtos');
assert((await str(await g(1))) === "'1.0 2.0 3.0'", `vtos((1 2 3)) = ${await str(await g(1))}`);

// ── worldspawn: precaches, light styles, world fields ─────────────────────
await db.exec('EXECUTE PROCEDURE qc_reset');
await setg((await q1("SELECT qc_gdef('world') o FROM rdb$database")).O, 0);
t0 = performance.now();
const s0 = await steps();
await run('worldspawn', 0);
const dt = performance.now() - t0, ds = (await steps()) - s0;
const ls = await qa('SELECT style, pattern FROM lightstyles WHERE style < 12 ORDER BY style');
assert(ls.length >= 11 && ls[0].PATTERN.trim() === 'm' && /^mmnmmommommnonmmonqnmmo$/.test(ls[1].PATTERN.trim()), `worldspawn set the light styles (0 = "${ls[0].PATTERN.trim()}", 1 = "${ls[1].PATTERN.trim()}")`);
assert((await log('error')).length === 0, 'with no builtin missing');
console.log(`worldspawn: ${ds} statements in ${dt.toFixed(0)} ms (${(dt / ds * 1000).toFixed(0)} µs per statement)`);


// ── E1M1 spawned through its QuakeC spawn functions, then five frames of thinks ─
const res = await loadResources(db, pak);
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
const engineEnts = (await q1("SELECT COUNT(*) n FROM ents WHERE classname <> 'player'")).N;
const mapEnts = (await q1('SELECT COUNT(*) n FROM map_ents')).N;
await db.exec('EXECUTE PROCEDURE qc_reset');
t0 = performance.now();
const sp = await q1('SELECT * FROM qc_spawn_map(1, 1.0)');
const spawnMs = performance.now() - t0;
const live = (await q1('SELECT COUNT(*) n FROM qc_edicts WHERE free = 0')).N;
const errs = await log('error');
console.log(`qc_spawn_map: ${sp.SPAWNED} spawned, ${sp.SKIPPED} skipped, ${sp.FAILED} failed, ${live} edicts live, in ${(spawnMs / 1000).toFixed(1)} s (${await steps()} statements so far)`);
assert(sp.FAILED === 0 && errs.length === 0, `every spawn function ran`);
for (const m of errs.slice(0, 6)) console.log('   ', m);
assert(sp.SPAWNED + sp.SKIPPED === mapEnts, `${mapEnts} map entities: ${sp.SPAWNED} spawned by QuakeC, ${sp.SKIPPED} dropped by skill or without a function`);
assert(live > 100 && Math.abs(live - engineEnts) < engineEnts * 0.6, `${live} edicts stay (lights and other decoration remove themselves); the PSQL game keeps ${engineEnts}`);
const wmsg = await str(await fld(0, 'message'));
assert(wmsg === 'the Slipgate Complex', `worldspawn's message is "${wmsg}"`);
const hist = await qa("SELECT qc_str(CAST(f.v AS INTEGER)) c, COUNT(*) n FROM qc_fields f JOIN qc_edicts d ON d.id = f.ent AND d.free = 0 WHERE f.ofs = qc_fdef('classname') GROUP BY 1 ORDER BY 2 DESC");
console.log('   live:', hist.map((h) => `${h.C.trim()} ${h.N}`).join(', '));
const fname = async (v) => (await q1(`SELECT name FROM qc_functions WHERE id = ${v ?? -1}`))?.NAME;
const door = (await qa("SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'door' ORDER BY f.ent"))[0]?.ENT;   // func_door renames itself "door"
assert(door && (await fld(door, 'movetype')) === 7 && (await str(await fld(door, 'model'))).startsWith('*') && (await fld(door, 'size')) > 0, `a func_door became a "door", MOVETYPE_PUSH, with its brush model "${await str(await fld(door, 'model'))}" and the size from the model (${await fld(door, 'size')} wide)`);
assert((await fname(await fld(door, 'use'))) === 'door_use' && (await fname(await fld(door, 'blocked'))) === 'door_blocked', 'with .use = door_use and .blocked = door_blocked');
const army = (await qa("SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'monster_army'"))[0]?.ENT;
assert(army && (await fname(await fld(army, 'think'))) === 'walkmonster_start_go' && (await fld(army, 'nextthink')) > 0 && (await fld(army, 'health')) === 30, 'a monster_army waits for walkmonster_start_go (nextthink a random fraction, due next frame) with 30 health');
const item = (await qa("SELECT f.ent FROM qc_fields f WHERE f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'item_shells'"))[0]?.ENT;
assert(item && (await fname(await fld(item, 'think'))) === 'PlaceItem' && (await fname(await fld(item, 'touch'))) === 'ammo_touch', 'an item_shells waits for PlaceItem, with .touch = ammo_touch');
const lights = await qa("SELECT d.id, qc_f(d.id, qc_fdef('targetname')) tn FROM qc_edicts d WHERE d.free = 0 AND EXISTS (SELECT 1 FROM qc_fields f WHERE f.ent = d.id AND f.ofs = qc_fdef('classname') AND qc_str(CAST(f.v AS INTEGER)) = 'light')");
assert(lights.every((l) => l.TN !== 0), `untargeted lights removed themselves; ${lights.length} targeted ones stay`);
t0 = performance.now();
let thought = 0;
for (let i = 1; i <= 5; i++) { const fr = await q1(`SELECT * FROM qc_frame(${(1 + i * 0.1).toFixed(1)}, 0.1)`); thought += fr.THOUGHT; assert(fr.FAILED === 0, `frame ${i}: ${fr.THOUGHT} thinks, none failed`); }
console.log(`5 frames: ${thought} thinks in ${(performance.now() - t0).toFixed(0)} ms (${await steps()} statements in all)`);
assert((await fld(item, 'solid')) === 1 && (await fld(item, 'nextthink')) === 0, 'PlaceItem ran: the shells are SOLID_TRIGGER and think no more');
const armyThink = await fname(await fld(army, 'think'));
assert(/^army_stand/.test(armyThink) && (await fld(army, 'frame')) >= 0 && (await fld(army, 'takedamage')) === 2 && (await fld(army, 'yaw_speed')) === 20, `walkmonster_start_go ran: the grunt stands (think ${armyThink}, OP_STATE), takes damage, yaw speed 20`);
assert((await fld(door, 'nextthink')) === 0 && (await fld(door, 'owner')) >= 0, 'LinkDoors ran for the doors');
assert((await log('error')).length === 0, 'no builtin missing in five frames of thinks');

// ── the player through QuakeC: connect, fire, pick up, cheat ─────────────
await db.exec('EXECUTE PROCEDURE qc_client_connect(1.6)');
const start = await q1("SELECT ox, oy, oz FROM map_ents WHERE classname = 'info_player_start'");
assert((await str(await fld(1, 'classname'))) === 'player' && (await fld(1, 'health')) === 100 && (await fld(1, 'max_health')) === 100 && (await fld(1, 'movetype')) === 3 && (await fld(1, 'solid')) === 3, 'PutClientInServer: the client is a "player" with 100 health, MOVETYPE_WALK, SOLID_SLIDEBOX');
assert(Math.abs((await fld(1, 'origin')) - start.OX) < 1 && Math.abs((await fld(1, 'origin')) - start.OX) < 1 && Math.abs((await fld(1, 'origin_z') ?? 0) - 0) >= 0, 'standing on the info_player_start');
const porg = [await fld(1, 'origin'), await q1("SELECT qc_f(1, qc_fdef('origin') + 1) v FROM rdb$database").then((r) => r.V), await q1("SELECT qc_f(1, qc_fdef('origin') + 2) v FROM rdb$database").then((r) => r.V)];
assert(Math.abs(porg[0] - start.OX) < 1 && Math.abs(porg[1] - start.OY) < 1 && Math.abs(porg[2] - start.OZ - 1) < 1, `at the info_player_start (${porg.map((v) => v.toFixed(0)).join(' ')}), one unit up`);
assert((await fld(1, 'weapon')) === 1 && (await str(await fld(1, 'weaponmodel'))) === 'progs/v_shot.mdl' && (await fld(1, 'ammo_shells')) === 25 && (await fld(1, 'currentammo')) === 25, 'W_SetCurrentAmmo: the shotgun with 25 shells');
assert((await str(await fld(1, 'model'))) === 'progs/player.mdl' && (await fld(1, 'view_ofs_z') ?? 22) === 22, 'the player model');
assert((await log('bprint')).join('').includes('entered the game'), `ClientConnect: "${(await log('bprint')).join('').trim()}"`);
assert((await fname(await fld(1, 'think'))) === 'player_stand2' || /^player_stand/.test(await fname(await fld(1, 'think'))), 'player_stand1 ran (OP_STATE)');
// fire: PlayerPreThink, PlayerPostThink → W_WeaponFrame → W_Attack → W_FireShotgun → FireBullets → traceline
await db.exec('EXECUTE PROCEDURE qc_player_frame(1.7, 0.1, 0, 90, 1, 0, 0)');
assert((await fld(1, 'ammo_shells')) === 24 && (await fld(1, 'currentammo')) === 24 && (await fld(1, 'punchangle')) === -2, 'a frame with fire down: W_FireShotgun took a shell and kicked the view');
assert((await log('sound')).some((m) => /guncock/.test(m)), 'with the shotgun sound');
assert((await fld(1, 'attack_finished')) > 1.7 && (await fld(1, 'weaponframe')) >= 1, 'attack_finished set, the weapon animates');
assert((await fname(await fld(1, 'think'))) && /^player_shot/.test(await fname(await fld(1, 'think'))), `the player's own animation is ${await fname(await fld(1, 'think'))}`);
// the shells on the floor: ammo_touch(other = player)
await db.exec(`EXECUTE PROCEDURE qc_touch(${item}, 1)`);
assert((await fld(1, 'ammo_shells')) === 44, 'touching an item_shells box gives 20 shells (ammo_touch, bound_other_ammo)');
assert((await log('sprint')).join('').includes('You got the shells'), `and says "${(await log('sprint')).join('').trim().split('\n').pop()}"`);
assert((await fld(item, 'solid')) === 0 && (await str(await fld(item, 'model'))) === '', 'the box is gone from the floor (model cleared, SOLID_NOT)');
assert((await log('cmd')).some((m) => /bf/.test(m)), 'with the pickup flash (stuffcmd "bf")');
// impulse 9: CheatCommand, once attack_finished (2.4, the shotgun's 0.7 s) has passed, since W_WeaponFrame holds impulses until then
await db.exec('EXECUTE PROCEDURE qc_player_frame(1.8, 0.1, 0, 90, 0, 0, 9)');
assert((await fld(1, 'impulse')) === 9 && (await fld(1, 'weapon')) === 1, "an impulse during the shotgun's recovery waits");
await db.exec('EXECUTE PROCEDURE qc_player_frame(2.5, 0.1, 0, 90, 0, 0, 0)');
assert((await fld(1, 'weapon')) === 32 && (await fld(1, 'ammo_rockets')) === 100 && ((await fld(1, 'items')) & 64) !== 0 && (await str(await fld(1, 'weaponmodel'))) === 'progs/v_rock2.mdl', 'impulse 9: every weapon, 100 rockets, the rocket launcher in hand');
assert((await fld(1, 'impulse')) === 0, 'the impulse is consumed');
assert((await log('error')).length === 0, 'no builtin missing for the player');
console.log(`${await steps()} statements in all`);

await db.close();
console.log(failed ? `${failed} FAILED` : 'all good');
process.exit(failed ? 1 : 0);
