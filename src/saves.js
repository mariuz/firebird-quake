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
  for (let i = 0; i < inserts.length; i += ROWS_PER_BLOCK) {
    await db.exec(`SET TERM ^ ;\nEXECUTE BLOCK AS BEGIN\n${inserts.slice(i, i + ROWS_PER_BLOCK).join('\n')}\nEND^\nSET TERM ; ^`);
  }
}

// what the engine returns, as JSON keeps it: BIGINTs may come back as BigInt, CHARs padded
function plain(v) {
  if (typeof v === 'bigint') return Number(v);
  if (v instanceof Date) return v.toISOString();
  return v;
}

// a value as a PSQL literal; String(number) is the shortest text that reads back as the same double
function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  if (typeof v === 'boolean') return v ? '1' : '0';
  return `'${String(v).replace(/'/g, "''")}'`;
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
