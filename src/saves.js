// saves.js – a save slot's rows out of Firebird and back in (sql/save.sql does the saving and loading).
//
// The page's database lives in memory, so a save made by save_game would end with the page. exportSave
// reads the slot's rows from the saves and sv_<table> tables into a plain object (what Quake would write
// to sN.sav), which the page keeps in IndexedDB; importSave writes such an object back into the
// sv_ tables, so load_game can restore it after the page has loaded the save's map. Shared by the page
// and scripts/save-test.mjs, like loader.js.

import { SAVED_TABLES } from './loader.js';

export const SAVE_VERSION = 1;
const ROWS_PER_BLOCK = 150;
const BLOCK_BYTES = 256 * 1024;

/** { version, slot, meta: the saves row, tables: { sv_ents: { cols, rows } … } } for a saved slot, or null. */
export async function exportSave(db, slot) {
  const meta = (await db.query('SELECT * FROM saves WHERE slot = ?', [slot], { rowMode: 'object' })).rows[0];
  if (!meta) return null;
  const tables = {};
  for (const t of Object.keys(SAVED_TABLES)) {
    const { rows } = await db.query(`SELECT * FROM sv_${t} WHERE slot = ?`, [slot], { rowMode: 'object' });
    if (!rows.length) continue;
    const cols = Object.keys(rows[0]).filter((c) => c !== 'SLOT');
    tables[t] = { cols, rows: rows.map((r) => cols.map((c) => plain(r[c]))) };
  }
  return { version: SAVE_VERSION, slot, meta: Object.fromEntries(Object.entries(meta).map(([k, v]) => [k, plain(v)])), tables };
}

/** An exported save back into the saves and sv_ tables under `slot` (its own slot by default). */
export async function importSave(db, save, slot = save.slot) {
  if (!save || save.version !== SAVE_VERSION) throw new Error('not a save of this version of Firebird Quake');
  await db.exec(`EXECUTE PROCEDURE delete_save(${Number(slot)})`);
  const m = save.meta;
  const inserts = [`INSERT INTO saves (slot, map_name, comment, qc_mode, skill, time_, world_model, ent_seq) VALUES (${Number(slot)}, ${lit(m.MAP_NAME)}, ${lit(m.COMMENT)}, ${lit(m.QC_MODE)}, ${lit(m.SKILL)}, ${lit(m.TIME_)}, ${lit(m.WORLD_MODEL)}, ${lit(m.ENT_SEQ)});`];
  for (const [t, { cols, rows }] of Object.entries(save.tables)) {
    if (!(t in SAVED_TABLES)) continue;
    const head = `INSERT INTO sv_${t} (slot, ${cols.join(', ')}) VALUES (${Number(slot)}, `;
    for (const r of rows) inserts.push(`${head}${r.map(lit).join(', ')});`);
  }
  await execInserts(db, inserts);
}

/**
 * A save as a file to download ({ name, text }): the exported save with the data set it was made on, since
 * the model ids in its rows are the ones that data set's paks gave.
 */
export function saveFile(save, data) {
  const name = `${String(save.meta.MAP_NAME).trim().toLowerCase()}-s${save.slot}.sav.json`;
  return { name, text: JSON.stringify({ ...save, data }) };
}

/** A downloaded save file's text back into a save for `data`, or an error saying why it cannot load. */
export function readSaveFile(text, data) {
  let save;
  try { save = JSON.parse(text); } catch { throw new Error('not a save file'); }
  if (!save || typeof save !== 'object' || !save.meta || !save.tables) throw new Error('not a save file');
  if (save.version !== SAVE_VERSION) throw new Error('a save of another version of Firebird Quake');
  if (save.data && save.data !== data) throw new Error(`a save made with other game data (${save.data})`);
  delete save.data;
  return save;
}

/** INSERT statements run in EXECUTE BLOCKs: at most 255 table contexts a block, a few hundred KB of text. */
export async function execInserts(db, inserts) {
  let block = [], size = 0;
  const flush = async () => {
    if (block.length) await db.exec(`SET TERM ^ ;\nEXECUTE BLOCK AS BEGIN\n${block.join('\n')}\nEND^\nSET TERM ; ^`);
    block = []; size = 0;
  };
  for (const ins of inserts) {
    if (block.length >= ROWS_PER_BLOCK || size + ins.length > BLOCK_BYTES) await flush();
    block.push(ins); size += ins.length;
  }
  await flush();
}

// what the engine returns, as JSON keeps it: BIGINTs may come back as BigInt, CHARs padded
function plain(v) {
  if (typeof v === 'bigint') return Number(v);
  if (v instanceof Date) return v.toISOString();
  return v;
}

// a value as a PSQL literal (src/demos.js writes its rows with it too)
export function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? exactDouble(v) : 'NULL';
  if (typeof v === 'boolean') return v ? '1' : '0';
  return `'${String(v).replace(/'/g, "''")}'`;
}

// A double that reads back bit for bit. Firebird's text-to-double conversion is not correctly rounded
// (about one value in ten comes back a unit in the last place off, as literal or as parameter), so a
// fraction is written as its exact integer mantissa times a power of two, both of which it converts
// exactly. Integers up to 2^53 are written as they are.
function exactDouble(v) {
  if (Number.isInteger(v) && Math.abs(v) <= 2 ** 53) return String(v);
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, v);
  const hi = dv.getUint32(0), lo = dv.getUint32(4);
  const biased = (hi >>> 20) & 0x7ff;
  let m = BigInt(hi & 0xfffff) * 4294967296n + BigInt(lo);
  let e = biased - 1075;
  if (biased === 0) e = -1074; else m += 1n << 52n;    // subnormals have no implicit bit
  while (m && !(m & 1n)) { m >>= 1n; e++; }
  return `CAST(${v < 0 ? '-' : ''}${m} AS DOUBLE PRECISION) * POWER(2e0, ${e})`;
}

// ── the browser's copy: one IndexedDB record per slot and data set ─────────────────────────────────
const DB_NAME = 'firebird-quake';
const STORE = 'saves';

function openStore() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function request(mode, fn) {
  return openStore().then((idb) => new Promise((resolve, reject) => {
    const tx = idb.transaction(STORE, mode);
    const req = fn(tx.objectStore(STORE));
    tx.oncomplete = () => { idb.close(); resolve(req?.result); };
    tx.onerror = () => { idb.close(); reject(tx.error); };
  }));
}

/** The browser's save slots for a data set (model ids depend on the paks): `${data}/${slot}` keys. */
export const SaveStore = {
  available: () => typeof indexedDB !== 'undefined',
  put: (data, slot, save) => request('readwrite', (s) => s.put(save, `${data}/${slot}`)),
  get: (data, slot) => request('readonly', (s) => s.get(`${data}/${slot}`)),
  /** [12 comments or null] */
  async list(data) {
    const out = new Array(12).fill(null);
    const all = await request('readonly', (s) => s.getAllKeys());
    for (const k of all ?? []) {
      const [d, n] = String(k).split('/');
      if (d !== data || !(Number(n) >= 0 && Number(n) < 12)) continue;
      const save = await SaveStore.get(data, Number(n));
      out[Number(n)] = save?.meta?.COMMENT ?? null;
    }
    return out;
  },
};
