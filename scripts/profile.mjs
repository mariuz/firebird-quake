// profile.mjs – where a QuakeC deathmatch frame goes, measured inside the engine: E1M1 with three bots (every
// function compiled), each named procedure or function copied to <name>_P and replaced by a wrapper that adds
// its time to a prof table (inclusive, so nested ones count in their callers too; the wrappers themselves cost
// a few µs a call, so the numbers run high, and the call counts are exact). Timings taken from JavaScript
// would carry a round trip each.
//
//   npm run profile                                   the default list
//   PROCS=trace_move,trace_hull FUNCS=point_contents npm run profile
//   PROCS=x FUNCS= N=400 npm run profile              no wrappers: the frame's mean and median
//   BOTS=7 npm run profile
//   MODE=psql npm run profile                        the PSQL game's E1M1 instead (its monsters' thinks)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { Pak } from '../src/pak.js';
import { createSchema, loadProgs, loadResources, loadMap, SQL_FILES } from '../src/loader.js';
import { QcJit } from '../src/qcjit.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8').replace(/\r\n/g, '\n')]));
const all = SQL_FILES.map((n) => sql[n]).join('\n');
const pak = new Pak(fs.readFileSync(path.join(root, 'public/pak/pak0.pak')).buffer);
const db = new FirebirdBrowser(`memory://prof${Math.random()}`, { transport: new DirectTransport() });
await createSchema(db, sql);
const res = await loadResources(db, pak);
const psql = process.env.MODE === 'psql';         // the PSQL game's single player E1M1 instead
await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 1 });
if (!psql) {
  const jit = new QcJit(db, await loadProgs(db, pak)); await jit.init(); await jit.compileAll();
  await loadMap(db, pak, res, 'e1m1', { skill: 1, seed: 11 });
  await db.exec(`EXECUTE PROCEDURE qc_setup_server(1, 0, ${process.env.BOTS ?? 3}, 0, 0)`);
  await db.exec('EXECUTE PROCEDURE qc_begin_map(1, 0)');
}
const tic = psql ? (i) => db.query('SELECT * FROM quake_tic(1, 0, 0, 0, 0, 0, 0, 1, 0)')
  : (i) => db.query(`SELECT * FROM qc_tic(1, ${i % 60 < 40 ? 1 : 0}, 0, ${i % 40 < 10 ? 9 : 0}, 0, 0, 0, 1, 0)`);
for (let i = 0; i < 100; i++) await tic(i);

const PROCS = (process.env.PROCS ?? (psql ? 'run_physics,run_pushers,player_think,monster_think,move_step,move_to_goal,walk_move,fly_move,trace_move,link_ent,check_water,set_anim,snd' : 'qc_server_frame,qc_client_think,qc_physics_client,qc_bot_think,nav_mark,walk_move,fly_move,trace_move,link_ent,check_water,qc_touch_triggers,qc_run_think,qc_physics_ent,qc_physics_step,qc_toss,qc_physics_pusher,qc_inv0,qc_inv1,qc_inv2,qc_inv3')).split(',');
const FUNCS = (process.env.FUNCS ?? (psql ? 'point_contents,find_target,visible,check_bottom,test_position,ent_range,rnd' : 'point_contents,bot_sees,nav_clear,test_position,nav_near')).split(',').filter(Boolean);
await db.exec('CREATE TABLE prof (name VARCHAR(63) PRIMARY KEY, ms DOUBLE PRECISION, n INTEGER)');
const ddl = (s) => db.exec(`SET TERM ^ ;\n${s}^\nSET TERM ; ^`);
// a header from the SQL files: the last real definition's "(params) RETURNS (…)" before AS
function header(kind, name) {
  const re = new RegExp(`CREATE OR ALTER ${kind} ${name}\\b\\s*(\\([^]*?\\))?\\s*(RETURNS\\s*(\\([^]*?\\)|[A-Z ]+[A-Z0-9(), ]*?))?\\s*\\n?AS\\b`, 'gi');
  let m, last = null;
  while ((m = re.exec(all))) last = m;
  if (!last) throw new Error(`no header for ${name}`);
  return { params: last[1] ?? '', returns: last[3] ?? '' };
}
const names = (list) => (list.match(/\b([a-z_][a-z0-9_]*)\s+(?:DOUBLE|INTEGER|SMALLINT|VARCHAR|CHAR|BIGINT|d_|TYPE|NUMERIC|TIMESTAMP|BLOB|FLOAT)/gi) ?? []).map((s) => s.split(/\s+/)[0]);
for (const p of PROCS) {
  const src = (await db.query(`SELECT rdb$procedure_source s FROM rdb$procedures WHERE rdb$procedure_name = UPPER('${p}')`)).rows[0]?.S;
  if (!src) { console.log('skip', p); continue; }
  const sel = /\bSUSPEND\b/i.test(src);
  const h = header('PROCEDURE', p);
  const ins = names(h.params), outs = names(h.returns);
  await ddl(`CREATE OR ALTER PROCEDURE ${p}_P ${h.params} ${h.returns ? `RETURNS ${h.returns}` : ''} AS ${src}`);
  await db.exec(`INSERT INTO prof VALUES ('${p}', 0, 0)`);
  await ddl(`CREATE OR ALTER PROCEDURE ${p} ${h.params} ${h.returns ? `RETURNS ${h.returns}` : ''} AS DECLARE t0 TIMESTAMP; BEGIN
  t0 = CAST('NOW' AS TIMESTAMP);
  ${sel ? `FOR SELECT ${outs.length ? outs.join(', ') : '1'} FROM ${p}_P${ins.length ? `(${ins.map((x) => ':' + x).join(', ')})` : ''} ${outs.length ? `INTO ${outs.join(', ')}` : ''} DO BEGIN
    UPDATE prof SET ms = ms + DATEDIFF(MILLISECOND FROM :t0 TO CAST('NOW' AS TIMESTAMP)), n = n + 1 WHERE name = '${p}';
    SUSPEND; EXIT;
  END` : `EXECUTE PROCEDURE ${p}_P${ins.length ? `(${ins.join(', ')})` : ''}${outs.length ? ` RETURNING_VALUES ${outs.join(', ')}` : ''};
  UPDATE prof SET ms = ms + DATEDIFF(MILLISECOND FROM :t0 TO CAST('NOW' AS TIMESTAMP)), n = n + 1 WHERE name = '${p}';`}
END`);
}
for (const f of FUNCS) {
  const src = (await db.query(`SELECT rdb$function_source s FROM rdb$functions WHERE rdb$function_name = UPPER('${f}')`)).rows[0]?.S;
  if (!src) { console.log('skip', f); continue; }
  const h = header('FUNCTION', f);
  const ins = names(h.params);
  await ddl(`CREATE OR ALTER FUNCTION ${f}_P ${h.params} RETURNS ${h.returns} AS ${src}`);
  await db.exec(`INSERT INTO prof VALUES ('${f}', 0, 0)`);
  await ddl(`CREATE OR ALTER FUNCTION ${f} ${h.params} RETURNS ${h.returns} AS DECLARE t0 TIMESTAMP; DECLARE r__ ${h.returns}; BEGIN
  t0 = CAST('NOW' AS TIMESTAMP);
  r__ = ${f}_P(${ins.join(', ')});
  UPDATE prof SET ms = ms + DATEDIFF(MILLISECOND FROM :t0 TO CAST('NOW' AS TIMESTAMP)), n = n + 1 WHERE name = '${f}';
  RETURN r__;
END`);
}
for (let i = 0; i < 20; i++) await tic(i);
await db.exec('UPDATE prof SET ms = 0, n = 0');
const N = Number(process.env.N ?? 200);
const ms = [];
for (let i = 0; i < N; i++) { const t = performance.now(); await tic(i); ms.push(performance.now() - t); }
const wall = ms.reduce((a, b) => a + b) / N;
console.log(`${psql ? 'quake_tic' : 'qc_tic'} wall ${wall.toFixed(2)} ms a frame mean, ${[...ms].sort((a, b) => a - b)[N >> 1].toFixed(2)} median (with the wrappers)`);
for (const r of (await db.query('SELECT name, ms, n FROM prof ORDER BY ms DESC')).rows) {
  console.log(`${r.NAME.padEnd(22)} ${(r.MS / N).toFixed(2).padStart(7)} ms/frame  ${(r.N / N).toFixed(1).padStart(7)} calls/frame  ${(r.N ? (r.MS * 1000 / r.N) : 0).toFixed(0).padStart(6)} µs/call`);
}
await db.close();
