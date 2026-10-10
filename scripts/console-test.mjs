// console-test.mjs – the console and the key bindings (src/console.js, src/binds.js) and the console's game
// commands (sql/host.sql: host_cmd.c's god, notarget, noclip, give, kill), each in the PSQL game and in
// QuakeC mode: god keeps a rocket at the feet from hurting, noclip walks through the wall in front,
// give hands over a weapon, cells and health, kill kills.
//
//   node scripts/console-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { Console, tokenize, splitCommands } from '../src/console.js';
import { Bindings, keyName, DEFAULT_BINDS } from '../src/binds.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };

// ── the console's parsing, its commands, its keys ────────────────────────
assert(JSON.stringify(tokenize('bind  k "say hello there" x')) === '["bind","k","say hello there","x"]', 'tokenize: words at spaces, a quoted phrase one word');
assert(JSON.stringify(splitCommands('god; give h 200 ;echo "a;b"')) === '["god","give h 200","echo \\"a;b\\""]', 'commands on a line split at ; outside quotes');
{
  const ran = [];
  const con = new Console({ commands: {
    god: { help: '', run: () => { ran.push('god'); return 'godmode ON'; } },
    echo: { help: '', run: (a, c, raw) => raw },
    give: { help: '', run: (a) => { ran.push(a.join(',')); } },
  } });
  con.toggle(true);
  for (const ch of 'god;give h 200') con.key(ch === ' ' ? 'Space' : ch === ';' ? 'Semicolon' : `Key${ch.toUpperCase()}`, ch);
  con.key('Enter');
  await new Promise((r) => setTimeout(r, 0));
  assert(ran.join('|') === 'god|h,200' && con.lines.includes(']god;give h 200') && con.lines.includes('godmode ON'), 'typed and Enter: both commands run, the line and the answer printed');
  con.key('ArrowUp');
  assert(con.input === 'god;give h 200', '↑ brings the line back');
  con.input = 'ec'; con.key('Tab');
  assert(con.input === 'echo ', 'Tab completes a command name');
  await con.execute('nosuch');
  assert(con.lines.at(-1) === 'Unknown command "nosuch"', 'an unknown command says so');
  con.key('Backquote');
  assert(!con.active, '` puts the console away');
}
{
  const b = new Bindings();
  assert(keyName('KeyW') === 'w' && keyName('ControlRight') === 'ctrl' && keyName('ArrowUp') === 'uparrow' && keyName('Digit7') === '7' && keyName('F6') === 'f6', "keys have Quake's names");
  b.key('w', true); b.key('uparrow', true); b.key('w', false);
  assert(b.down('+forward'), '+forward stays held while either of its keys is down');
  b.key('uparrow', false);
  assert(!b.down('+forward'), 'and lets go when both are up');
  assert(b.key('7', true) === 'impulse 7' && b.key('7', false) === null, 'a command binding runs once, on the key going down');
  b.set('k', 'god');
  assert(b.key('k', true) === 'god' && JSON.parse(JSON.stringify(b)).k === 'god', 'bind k god: kept in the saved bindings');
  assert(JSON.stringify(b.keysFor('+attack').sort()) === '["ctrl","f","mouse1"]' && DEFAULT_BINDS['`'] === 'toggleconsole', 'the defaults: ctrl, f and mouse1 attack, ` brings the console');
}

// ── the game commands in both logics ─────────────────────────────────────
const db = new FirebirdBrowser(`memory://con${Math.random()}`, { transport: new DirectTransport() });
await createSchema(db, sql);
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const res = await loadResources(db, pak);
const q1 = (s) => db.query(s).then((r) => r.rows[0]);
const host = async (cmd, a1 = '', a2 = '') => (await db.query('SELECT msg FROM host_cmd(?, ?, ?)', [cmd, a1, a2])).rows[0].MSG;
let progsLoaded = false;
for (const mode of ['psql', 'qc']) {
  const qc = mode === 'qc';
  await db.exec('EXECUTE PROCEDURE qc_leave');
  await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 3 });
  if (qc) {
    if (!progsLoaded) { await loadProgs(db, pak); progsLoaded = true; }
    await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
  }
  const label = qc ? 'QuakeC mode' : 'the PSQL game';
  const tic = (o = {}) => q1(`SELECT * FROM ${qc ? 'qc_tic' : 'quake_tic'}(1, ${o.f ?? 0}, 0, ${o.yaw ?? 0}, ${o.pitch ?? 0}, ${o.fire ?? 0}, 0, 1, ${o.imp ?? 0})`);
  const pe = qc ? 1 : (await q1('SELECT ent_id e FROM player')).E;
  for (let i = 0; i < 10; i++) await tic();

  // god: a rocket at the feet does nothing
  assert(await host('god') === 'godmode ON', `${label}: god says godmode ON`);
  await tic({ imp: 9 });
  for (let i = 0; i < 12; i++) await tic({ imp: i === 0 ? 7 : 0 });
  await tic({ pitch: 80, fire: 1 });
  let s = null;
  for (let i = 0; i < 12; i++) s = await tic();
  assert(s.HEALTH === 100, `${label}: in god mode a rocket at the feet leaves 100 health (${s.HEALTH})`);
  assert(await host('god') === 'godmode OFF', `${label}: god again, godmode OFF`);
  await tic({ pitch: -80 });
  assert(await host('notarget') === 'notarget ON' && ((await q1(`SELECT flags f FROM ents WHERE id = ${pe}`)).F & 128) !== 0, `${label}: notarget sets FL_NOTARGET`);
  await host('notarget');

  // noclip: through the wall ahead
  const p = await q1(`SELECT x, y, z, yaw FROM ents WHERE id = ${pe}`);
  let yaw = null, dist = 0;
  for (let a = 0; a < 360 && yaw === null; a += 15) {
    const r = await q1(`SELECT fraction f FROM trace_move(${pe}, 0, 0, 0, 0, 0, 0, ${p.X}, ${p.Y}, ${p.Z}, ${p.X + Math.cos(a * Math.PI / 180) * 400}, ${p.Y + Math.sin(a * Math.PI / 180) * 400}, ${p.Z}, 1)`);
    if (r.F < 0.4) { yaw = a; dist = r.F * 400; }
  }
  let turn = ((yaw - p.YAW) % 360 + 540) % 360 - 180;
  await tic({ yaw: turn, pitch: 0 });
  assert(await host('noclip') === 'noclip ON', `${label}: noclip says noclip ON`);
  for (let i = 0; i < 30; i++) await tic({ f: 1 });
  const q = await q1(`SELECT x, y, movetype mt FROM ents WHERE id = ${pe}`);
  const went = (q.X - p.X) * Math.cos(yaw * Math.PI / 180) + (q.Y - p.Y) * Math.sin(yaw * Math.PI / 180);
  assert(q.MT === 8 && went > dist + 64, `${label}: noclip walks ${went.toFixed(0)} units on, through the wall ${dist.toFixed(0)} away`);
  assert(await host('noclip') === 'noclip OFF' && (await q1(`SELECT movetype mt FROM ents WHERE id = ${pe}`)).MT === 3, `${label}: noclip again: MOVETYPE_WALK`);

  // give
  await host('give', 'c', '77'); await host('give', 'h', '250'); await host('give', '8');
  s = await tic();
  assert(s.CELLS === 77 && s.HEALTH >= 249 && (s.ITEMS & 64) !== 0, `${label}: give c 77, give h 250, give 8: cells ${s.CELLS}, health ${s.HEALTH}, the thunderbolt`);

  // kill: the PSQL game dies past god mode; progs.dat's ClientKill respawns, which in single player sends
  // localcmd("restart"): the level again
  await host('god');
  await host('kill');
  for (let i = 0; i < 5; i++) s = await tic();
  if (qc) assert(s.EXIT_KIND === 3, `${label}: kill runs ClientKill, whose respawn restarts the level in single player (exit_kind ${s.EXIT_KIND})`);
  else {
    assert(s.DEAD === 1 && s.HEALTH <= 0, `${label}: kill kills, god mode or not (health ${s.HEALTH})`);
    assert((await host('kill')).startsWith("Can't suicide"), `${label}: kill when dead: Can't suicide`);
  }
}
await db.close();

console.log(failed ? `${failed} failure(s)` : 'all console checks passed');
process.exit(failed ? 1 : 0);
