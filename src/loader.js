// loader.js – copy a PAK's models and a BSP into Firebird.
//
// Shared by the browser (src/main.js) and the Node smoke test
// (scripts/sql-smoke.mjs), so CI exercises exactly the SQL the page runs.
//
// Bulk loading: the WASM build binds parameters as text, so each table has a
// generated LOAD_<table> procedure that takes a 30 KB chunk of '|'-separated
// lines and parses it in PSQL. That is 2–3× faster than a block of INSERTs.

import { Bsp, parseVec } from './bsp.js';
import { Mdl, Spr } from './mdl.js';
import { FRAME_LAYOUTS } from './framelayouts.js';
import { Progs } from './progs.js';
import { MONSTERS, LIGHTSTYLES } from './gamedata.js';

const CHUNK = 30000;
export const WORLD_ID_BASE = 0;           // ids below ITEM_ID_BASE are the current map
export const ITEM_ID_BASE = 1000000;      // b_*.bsp boxes: loaded once, kept across maps

// column specs: name:type where type ∈ i (integer) d (double) s (string)
const TABLES = {
  hulls: 'hull:i node:i nx:d ny:d nz:d dist:d c0:i c1:i',
  leaves: 'id:i contents:i minx:d miny:d minz:d maxx:d maxy:d maxz:d first_ms:i num_ms:i ambient:i ambient_sky:i pvs:s',
  marksurfaces: 'id:i face:i',
  faces: 'id:i model_id:i nx:d ny:d nz:d dist:d nverts:i miptex:i sx:d sy:d sz:d soff:d tx:d ty:d tz:d toff:d sky:i liquid:i style0:i cx:d cy:d cz:d radius:d',
  face_verts: 'face:i seq:i x:d y:d z:d',
  miptex: 'id:i name:s w:i h:i',
  models: 'id:i name:s kind:s minx:d miny:d minz:d maxx:d maxy:d maxz:d hull0:i hull1:i hull2:i first_face:i num_faces:i nframes:i flags:i radius:d',
  anims: 'model_id:i anim:s first_frame:i frame_count:i',
  qc_statements: 'id:i op:i a:i b:i c:i',
  qc_functions: 'id:i first_statement:i parm_start:i locals:i name:s file:s numparms:i p0:i p1:i p2:i p3:i p4:i p5:i p6:i p7:i shared:i',
  qc_defs: 'id:i kind:i type_:i ofs:i name:s',
  qc_strings: 'ofs:i s:s',
  qc_globals0: 'ofs:i v:d',
  qc_parmmap: 'fnum:i dst:i src:i',
  map_keys: 'ent:i k:s v:s',
  map_ents: 'id:i classname:s targetname:s target:s killtarget:s model:s ox:d oy:d oz:d angle:d mpitch:d myaw:d mroll:d spawnflags:i message:s wait_:d delay:d speed:d lip:d health:i light:i style:i sounds:i dmg:d height:d count_:i map:s noise:s worldtype:i',
};

const SQL_TYPE = { i: 'INTEGER', d: 'DOUBLE PRECISION', s: 'VARCHAR(8192) CHARACTER SET ASCII' };   // the longest is a leaf's PVS (d_pvs)

/** The LOAD_<table> procedures, generated from the column specs. */
export function loaderSql() {
  let out = 'SET TERM ^ ;\n';
  for (const [table, spec] of Object.entries(TABLES)) {
    const cols = spec.split(' ').map((c) => c.split(':'));
    out += `CREATE OR ALTER PROCEDURE load_${table} (s VARCHAR(32000) CHARACTER SET ASCII) AS\n`;
    out += 'DECLARE p INTEGER = 1; DECLARE q INTEGER; DECLARE e INTEGER; DECLARE len INTEGER; DECLARE f VARCHAR(8192) CHARACTER SET ASCII;\n';
    for (const [name, type] of cols) out += `DECLARE v_${name} ${SQL_TYPE[type]};\n`;
    out += 'BEGIN\n  len = CHAR_LENGTH(s);\n  WHILE (p <= len) DO BEGIN\n';
    out += "    e = POSITION(ASCII_CHAR(10), s, p); IF (e = 0) THEN e = len + 1;\n";
    cols.forEach(([name, type], i) => {
      const last = i === cols.length - 1;
      out += last
        ? `    f = SUBSTRING(s FROM p FOR e - p);\n`
        : `    q = POSITION('|', s, p); f = SUBSTRING(s FROM p FOR q - p); p = q + 1;\n`;
      out += type === 's'
        ? `    v_${name} = NULLIF(f, '');\n`
        : `    v_${name} = CAST(NULLIF(f, '') AS ${SQL_TYPE[type]});\n`;
    });
    out += `    INSERT INTO ${table} (${cols.map((c) => c[0]).join(', ')}) VALUES (${cols.map((c) => ':v_' + c[0]).join(', ')});\n`;
    out += '    p = e + 1;\n  END\nEND^\n';
  }
  return out + 'SET TERM ; ^\n';
}

const num = (v) => (v === null || v === undefined || Number.isNaN(v) ? '' : typeof v === 'number' ? (Number.isInteger(v) ? String(v) : v.toFixed(4)) : String(v));
const str = (v) => (v === null || v === undefined ? '' : String(v).replace(/[|\n\r]/g, ' '));

/** rows: arrays of values in column order. */
export async function bulkLoad(db, table, rows) {
  const lines = rows.map((r) => r.map((v) => (typeof v === 'string' ? str(v) : num(v))).join('|'));
  let chunk = '';
  const flush = async () => {
    if (chunk) await db.query(`EXECUTE PROCEDURE load_${table}(?)`, [chunk]);
    chunk = '';
  };
  for (const line of lines) {
    if (chunk.length + line.length + 1 > CHUNK) await flush();
    chunk += line + '\n';
  }
  await flush();
}

export const SQL_FILES = ['schema', 'physics', 'game', 'weapons', 'monsters', 'render', 'qcvm', 'bots', 'save', 'demo'];

export async function createSchema(db, sql) {
  await db.exec(sql.schema);
  await db.exec(loaderSql());
  for (const f of SQL_FILES.slice(1)) {
    if (f === 'save') await db.exec(await savedTablesSql(db));
    await db.exec(sql[f]);
  }
}

// ── save games (sql/save.sql) ───────────────────────────────────────────────
// The state of a game is these tables' rows; everything else is the map, the pak or progs.dat, which
// a load reads again. Each gets a copy, sv_<table>, with the slot in front of the same columns, and
// save_tables / restore_tables copy a slot's rows across. The QuakeC VM's tables are copied only in
// QuakeC mode (qc = 1); of the string table only the strings made at run time (ftos, vtos, the
// level's names) are the game's.
export const SAVED_TABLES = {
  game: { qc: false, where: '' },
  player: { qc: false, where: '' },
  ents: { qc: false, where: '' },
  lightstyles: { qc: false, where: '' },
  rng: { qc: false, where: '' },
  qc_globals: { qc: true, where: '' },
  qc_fields: { qc: true, where: '' },
  qc_edicts: { qc: true, where: '' },
  qc_strings: { qc: true, where: 'ofs < 0' },
  qc_vm: { qc: true, where: '' },
  qc_saved: { qc: true, where: '' },
  bots: { qc: true, where: '' },
};

/** The sv_ tables and the two copying procedures, generated from the live tables' columns so that a
 *  column added to ents is saved without touching this. Needs the schema in the database. */
export async function savedTablesSql(db) {
  const names = Object.keys(SAVED_TABLES).map((t) => `'${t.toUpperCase()}'`).join(', ');
  const { rows } = await db.query(
    `SELECT TRIM(rf.rdb$relation_name) t, TRIM(rf.rdb$field_name) c, f.rdb$field_type ft, f.rdb$character_length cl, TRIM(cs.rdb$character_set_name) cs
       FROM rdb$relation_fields rf JOIN rdb$fields f ON f.rdb$field_name = rf.rdb$field_source
       LEFT JOIN rdb$character_sets cs ON cs.rdb$character_set_id = f.rdb$character_set_id
      WHERE rf.rdb$relation_name IN (${names}) ORDER BY rf.rdb$relation_name, rf.rdb$field_position`, [], { rowMode: 'object' });
  const TYPES = { 7: 'SMALLINT', 8: 'INTEGER', 16: 'BIGINT', 27: 'DOUBLE PRECISION' };
  const typeOf = (r) => {
    if (TYPES[r.FT]) return TYPES[r.FT];
    if (r.FT === 37 || r.FT === 14) return `${r.FT === 37 ? 'VARCHAR' : 'CHAR'}(${r.CL})${r.CS ? ` CHARACTER SET ${r.CS}` : ''}`;
    throw new Error(`savedTablesSql: ${r.T}.${r.C} has a column type (${r.FT}) the save tables do not know`);
  };
  const cols = new Map();
  for (const r of rows) {
    if (!cols.has(r.T)) cols.set(r.T, []);
    cols.get(r.T).push({ name: r.C, type: typeOf(r) });
  }
  let ddl = '';
  let save = 'SET TERM ^ ;\nCREATE OR ALTER PROCEDURE save_tables (slot SMALLINT, qc SMALLINT)\nAS\nBEGIN\n';
  let restore = 'CREATE OR ALTER PROCEDURE restore_tables (slot SMALLINT, qc SMALLINT)\nAS\nBEGIN\n';
  let drop = 'CREATE OR ALTER PROCEDURE drop_saved (slot SMALLINT)\nAS\nBEGIN\n';
  for (const [table, { qc, where }] of Object.entries(SAVED_TABLES)) {
    const c = cols.get(table.toUpperCase());
    if (!c) throw new Error(`savedTablesSql: no table ${table}`);
    const list = c.map((x) => x.name).join(', ');
    const cond = qc ? 'IF (qc = 1) THEN\n  ' : '';
    ddl += `CREATE TABLE sv_${table} (slot SMALLINT NOT NULL, ${c.map((x) => `${x.name} ${x.type}`).join(', ')});\n`;
    ddl += `CREATE INDEX sv_${table}_slot ON sv_${table} (slot);\n`;
    save += `  DELETE FROM sv_${table} s WHERE s.slot = :slot;\n`;
    save += `  ${cond}INSERT INTO sv_${table} (slot, ${list}) SELECT :slot, ${list} FROM ${table}${where ? ` WHERE ${where}` : ''};\n`;
    restore += `  ${qc ? 'IF (qc = 1) THEN BEGIN\n    ' : ''}DELETE FROM ${table}${where ? ` WHERE ${where}` : ''};\n`;
    restore += `  ${qc ? '  ' : ''}INSERT INTO ${table} (${list}) SELECT ${list} FROM sv_${table} s WHERE s.slot = :slot;${qc ? '\n  END' : ''}\n`;
    drop += `  DELETE FROM sv_${table} s WHERE s.slot = :slot;\n`;
  }
  return `${ddl}${save}END^\n${restore}END^\n${drop}END^\nSET TERM ; ^\n`;
}

/**
 * Resources: everything that does not change between maps – alias models,
 * sprites, the b_*.bsp boxes, monster definitions, light styles.
 * Returns the model registry the JS renderer needs alongside.
 */
export async function loadResources(db, pak, { width = 320, height = 200, fov = 90 } = {}) {
  await db.exec('DELETE FROM anims; DELETE FROM models; DELETE FROM monster_types; DELETE FROM lightstyles; DELETE FROM game; DELETE FROM player; DELETE FROM viewcfg; ' +
    'DELETE FROM face_verts; DELETE FROM faces; DELETE FROM miptex; DELETE FROM hulls; DELETE FROM leaves; DELETE FROM marksurfaces; DELETE FROM ents; DELETE FROM map_ents');

  const res = { models: new Map(), byName: new Map(), bsps: new Map(), nextModel: 1, pak };
  const modelRows = [];
  const animRows = [];

  for (const name of pak.list('progs/', '.mdl')) {
    const m = new Mdl(pak.buffer(name), name);
    const id = res.nextModel++;
    res.models.set(id, { id, name, kind: 'M', mdl: m });
    res.byName.set(name, id);
    modelRows.push([id, name, 'M', null, null, null, null, null, null, null, null, null, null, null, m.numFrames, m.flags, m.radius]);
    for (const a of animationsOf(m, name)) animRows.push([id, a.name, a.first, a.count]);
  }
  for (const name of pak.list('progs/', '.spr')) {
    const s = new Spr(pak.buffer(name), name);
    const id = res.nextModel++;
    res.models.set(id, { id, name, kind: 'S', spr: s });
    res.byName.set(name, id);
    modelRows.push([id, name, 'S', null, null, null, null, null, null, null, null, null, null, null, s.frames.length, 0, s.radius]);
  }
  await bulkLoad(db, 'models', modelRows);
  await bulkLoad(db, 'anims', animRows);

  // the item boxes: small BSPs, loaded once into a high id range
  res.itemBase = ITEM_ID_BASE;
  let base = ITEM_ID_BASE;
  for (const name of pak.list('maps/b_', '.bsp')) {
    const bsp = new Bsp(pak.buffer(name), name);
    const geo = geometryRows(bsp, base, res, { pvs: false });
    base = geo.nextBase;
    res.bsps.set(name, { bsp, faceBase: geo.faceBase, modelIds: geo.modelIds });
    await bulkLoad(db, 'faces', geo.faces);
    await bulkLoad(db, 'face_verts', geo.faceVerts);
    await bulkLoad(db, 'miptex', geo.miptex);
    await bulkLoad(db, 'models', geo.models);
    for (const [mid, info] of geo.modelInfo) res.models.set(mid, info);
    res.byName.set(name, geo.modelIds[0]);
  }

  const styleRows = LIGHTSTYLES.map((p, i) => `INSERT INTO lightstyles (style, pattern) VALUES (${i}, '${p}');`).join('\n');
  await db.exec(`SET TERM ^ ;\nEXECUTE BLOCK AS BEGIN\n${styleRows}\nEND^\nSET TERM ; ^`);
  await loadMonsterTypes(db);
  await db.exec(`INSERT INTO game (id, registered) VALUES (1, ${pak.has('maps/e2m1.bsp') ? 1 : 0}); INSERT INTO player (id) VALUES (1)`);
  await setView(db, width, height, fov);
  return res;
}

async function loadMonsterTypes(db) {
  const lit = (v) => (v === null || v === undefined ? 'DEFAULT' : typeof v === 'number' ? String(v) : `'${String(v).replace(/'/g, "''")}'`);
  const cols = ['name', 'model', 'head_model', 'health', 'hull', 'maxz', 'flags', 'run_speed', 'walk_speed', 'yaw_speed',
    'stand_anim', 'walk_anim', 'run_anim', 'pain_anims', 'death_anims', 'melee_anim', 'melee_frame', 'melee_range', 'melee_dmg',
    'missile_anim', 'missile_frames', 'missile_kind', 'attack_chance', 'pain_chance', 'sight_snd', 'idle_snd', 'pain_snd',
    'death_snd', 'attack_snd', 'melee_snd', 'gib_health', 'drop_item'];
  const body = MONSTERS.map((m) => `INSERT INTO monster_types (${cols.join(', ')}) VALUES (${cols.map((c) => lit(m[c] ?? null)).join(', ')});`).join('\n');
  await db.exec(`SET TERM ^ ;\nEXECUTE BLOCK AS BEGIN\n${body}\nEND^\nSET TERM ; ^`);
}

export async function setView(db, width, height, fov = 90) {
  await db.exec(`UPDATE OR INSERT INTO viewcfg (id, w, h, fov, near_z) VALUES (1, ${width}, ${height}, ${fov}, 4) MATCHING (id)`);
}

/**
 * Rows for one BSP's geometry with ids offset by `base`. Faces, face
 * vertices, marksurfaces, leaves and hull nodes all share the same offset so
 * a map's rows can be deleted with one range predicate.
 */
function geometryRows(bsp, base, res, { pvs = true } = {}) {
  const out = { faces: [], faceVerts: [], miptex: [], models: [], leaves: [], marksurfaces: [], hulls: [], modelIds: [], modelInfo: new Map(), faceBase: base };

  for (let i = 0; i < bsp.textures.length; i++) {
    const t = bsp.textures[i];
    out.miptex.push([base + i, t ? t.name : 'notexture', t ? t.w : 64, t ? t.h : 64]);
  }
  const modelOfFace = new Int32Array(bsp.faces.length).fill(-1);
  bsp.models.forEach((m, mi) => {
    for (let f = m.firstFace; f < m.firstFace + m.numFaces; f++) modelOfFace[f] = mi;
  });
  const modelIds = bsp.models.map(() => res.nextModel++);
  out.modelIds = modelIds;
  bsp.faces.forEach((f, fi) => {
    const pl = bsp.planes[f.plane];
    const sgn = f.side ? -1 : 1;
    const ti = bsp.texinfo[f.texinfo];
    let cx = 0, cy = 0, cz = 0;
    for (const vi of f.verts) { cx += bsp.vertices[vi * 3]; cy += bsp.vertices[vi * 3 + 1]; cz += bsp.vertices[vi * 3 + 2]; }
    cx /= f.verts.length; cy /= f.verts.length; cz /= f.verts.length;
    let rad = 0;
    for (const vi of f.verts) rad = Math.max(rad, Math.hypot(bsp.vertices[vi * 3] - cx, bsp.vertices[vi * 3 + 1] - cy, bsp.vertices[vi * 3 + 2] - cz));
    out.faces.push([base + fi, modelIds[modelOfFace[fi]] ?? modelIds[0], sgn * pl.nx, sgn * pl.ny, sgn * pl.nz, sgn * pl.dist, f.verts.length,
      base + ti.miptex, ti.s[0], ti.s[1], ti.s[2], ti.soff, ti.t[0], ti.t[1], ti.t[2], ti.toff, f.sky ? 1 : 0, f.liquid ? 1 : 0, f.styles[0], cx, cy, cz, rad]);
    f.verts.forEach((vi, k) => {
      out.faceVerts.push([base + fi, k, bsp.vertices[vi * 3], bsp.vertices[vi * 3 + 1], bsp.vertices[vi * 3 + 2]]);
    });
  });
  bsp.models.forEach((m, mi) => {
    const id = modelIds[mi];
    const name = mi === 0 ? bsp.name : `*${mi}`;
    out.models.push([id, name, 'B', m.mins[0], m.mins[1], m.mins[2], m.maxs[0], m.maxs[1], m.maxs[2],
      base + m.headnode[0], base + m.headnode[1], base + m.headnode[2], base + m.firstFace, m.numFaces, 1, 0, 0]);
    out.modelInfo.set(id, { id, name, kind: 'B', bsp, sub: mi, faceBase: base });
  });
  if (pvs) {
    // hull 0: the node tree; leaf children become contents
    bsp.nodes.forEach((n, ni) => {
      const pl = bsp.planes[n.plane];
      const ch = n.children.map((c) => (c >= 0 ? base + c : -(base + (-1 - c)) - 1));
      out.hulls.push([0, base + ni, pl.nx, pl.ny, pl.nz, pl.dist, ch[0], ch[1]]);
    });
    bsp.clipnodes.forEach((n, ni) => {
      const pl = bsp.planes[n.plane];
      const ch = n.children.map((c) => (c >= 0 ? base + c : c));
      out.hulls.push([1, base + ni, pl.nx, pl.ny, pl.nz, pl.dist, ch[0], ch[1]]);
    });
    bsp.leaves.forEach((l, li) => {
      out.leaves.push([base + li, l.contents, ...l.mins, ...l.maxs, base + l.firstMarksurface, l.numMarksurfaces, l.ambient[0], l.ambient[1], bsp.pvsHex[li]]);
    });
    for (let i = 0; i < bsp.marksurfaces.length; i++) out.marksurfaces.push([base + i, base + bsp.marksurfaces[i]]);
  }
  out.nextBase = base + Math.max(bsp.faces.length, bsp.nodes.length, bsp.clipnodes.length, bsp.leaves.length, bsp.marksurfaces.length, bsp.textures.length) + 1;
  return out;
}

const ENT_COLS = ['classname', 'targetname', 'target', 'killtarget', 'model', 'angle', 'spawnflags', 'message', 'wait', 'delay',
  'speed', 'lip', 'health', 'light', 'style', 'sounds', 'dmg', 'height', 'count', 'map', 'noise', 'worldtype'];

/** SV_SpawnServer: replace the current map with `name` from the PAK. */
export async function loadMap(db, pak, res, name, { skill = 1, newGame = true, seed = null } = {}) {
  const bsp = new Bsp(pak.buffer(`maps/${name}.bsp`), `maps/${name}.bsp`);
  await db.exec(`DELETE FROM sound_events; DELETE FROM fx_events; DELETE FROM ents; DELETE FROM map_ents; DELETE FROM map_keys; DELETE FROM vis_faces; DELETE FROM leaf_faces; DELETE FROM leaf_marked; UPDATE viewcfg SET vis_leaf = NULL;
    DELETE FROM face_verts WHERE face < ${ITEM_ID_BASE}; DELETE FROM faces WHERE id < ${ITEM_ID_BASE}; DELETE FROM miptex WHERE id < ${ITEM_ID_BASE};
    DELETE FROM hulls; DELETE FROM leaves; DELETE FROM marksurfaces; DELETE FROM models WHERE kind = 'B' AND id < ${res.itemBase}`);
  // world model ids: previous world models are gone, reuse the registry slots
  for (const [id, m] of [...res.models]) if (m.kind === 'B' && m.faceBase < ITEM_ID_BASE) res.models.delete(id);
  const geo = geometryRows(bsp, WORLD_ID_BASE, res, { pvs: true });
  for (const [mid, info] of geo.modelInfo) res.models.set(mid, info);
  res.world = { bsp, modelIds: geo.modelIds, faceBase: 0 };

  await bulkLoad(db, 'models', geo.models);
  await bulkLoad(db, 'miptex', geo.miptex);
  await bulkLoad(db, 'faces', geo.faces);
  await bulkLoad(db, 'face_verts', geo.faceVerts);
  await bulkLoad(db, 'hulls', geo.hulls);
  await bulkLoad(db, 'leaves', geo.leaves);
  await bulkLoad(db, 'marksurfaces', geo.marksurfaces);

  const entRows = bsp.entities.map((e, i) => {
    const o = parseVec(e.origin);
    const mangle = e.mangle ? parseVec(e.mangle) : [null, null, null];
    const n = (k) => (e[k] === undefined || e[k] === '' ? null : Number(e[k]));
    return [i, e.classname ?? 'unknown', e.targetname ?? null, e.target ?? null, e.killtarget ?? null, e.model ?? null,
      o[0], o[1], o[2], n('angle'), mangle[0], mangle[1], mangle[2], n('spawnflags') ?? 0, e.message ?? null, n('wait'), n('delay'),
      n('speed'), n('lip'), n('health'), n('light'), n('style'), n('sounds'), n('dmg'), n('height'), n('count'), e.map ?? null,
      e.noise ?? null, n('worldtype')];
  });
  await bulkLoad(db, 'map_ents', entRows);
  await bulkLoad(db, 'map_keys', bsp.entities.flatMap((e, i) => Object.entries(e).filter(([k]) => k.length <= 64).map(([k, v]) => [i, k, v])));

  // seed: the random numbers' seed (a demo or a test replays from it), else init_map picks one
  if (seed !== null) await db.exec(`UPDATE rng SET next_seed = ${Math.floor(seed)} WHERE id = 1`);
  await db.exec(`EXECUTE PROCEDURE init_map('${name}', ${geo.modelIds[0]}, ${skill}, ${newGame ? 1 : 0})`);
  return bsp;
}

/** A model's named frame runs. LibreQuake's models name their frames "1", "2"…, but keep Quake's
 *  frame order (progs.dat addresses frames by number), so the id layout for that model applies. */
function animationsOf(mdl, name) {
  const own = mdl.animations();
  const layout = FRAME_LAYOUTS[name.toLowerCase()];
  if (layout && layout[0] === mdl.frames.length && own.every((a) => a.name === 'frame')) return layout[1].map(([anim, first, count]) => ({ name: anim, first, count }));
  return own;
}

/**
 * progs.dat into the QuakeC VM's tables (sql/qcvm.sql), then qc_reset: the global image restored,
 * the world and the player's edicts made, the VM's cached offsets looked up. Returns the parsed Progs.
 */
export async function loadProgs(db, pak, name = 'progs.dat') {
  const progs = new Progs(pak.buffer(name), name);
  await db.exec('DELETE FROM qc_parmmap; DELETE FROM qc_statements; DELETE FROM qc_functions; DELETE FROM qc_defs; DELETE FROM qc_strings; DELETE FROM qc_globals0; DELETE FROM qc_globals; DELETE FROM qc_fields; DELETE FROM qc_edicts; DELETE FROM qc_log; DELETE FROM qc_vm');
  await bulkLoad(db, 'qc_statements', progs.statements);
  await bulkLoad(db, 'qc_functions', progs.functions.map((f) => [f.id, f.first_statement, f.parm_start, f.locals, f.name, f.file, f.numparms, ...f.parms, f.shared]));
  await bulkLoad(db, 'qc_defs', [...progs.globaldefs, ...progs.fielddefs].map((d, i) => [i, d.kind, d.type & 0x7fff, d.ofs, d.name]));
  // the loader turns newlines into spaces: keep QuakeC's newline as the two characters backslash-n, printed back as a newline
  await bulkLoad(db, 'qc_strings', progs.strings.map(([ofs, s]) => [ofs, s.replace(/\n/g, '\\n').replace(/\|/g, '/')]));
  await bulkLoad(db, 'qc_globals0', progs.globals);
  // where each function's parameters go: callee slot ← OFS_PARM0 + 3·i + j (PR_EnterFunction), one MERGE per call
  const parmmap = [];
  for (const f of progs.functions) {
    if (f.first_statement < 0) continue;
    let o = f.parm_start;
    for (let i = 0; i < f.numparms; i++) for (let j = 0; j < f.parms[i]; j++) parmmap.push([f.id, o++, 4 + i * 3 + j]);
  }
  await bulkLoad(db, 'qc_parmmap', parmmap);
  await db.exec('EXECUTE PROCEDURE qc_reset');
  return progs;
}
