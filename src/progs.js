// progs.js – progs.dat (QuakeC bytecode, version 6) parsed into rows for the
// QuakeC VM that runs in PSQL (sql/qcvm.sql): statements, functions, global
// and field definitions, the string table split at its NULs, and the initial
// global image typed by the definitions (floats, or integers for strings,
// entities, fields and functions).

import { cstr } from './pak.js';

export const QC_TYPES = { 0: 'void', 1: 'string', 2: 'float', 3: 'vector', 4: 'entity', 5: 'field', 6: 'function', 7: 'pointer' };

export class Progs {
  constructor(buffer, name = 'progs.dat') {
    const dv = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    this.name = name;
    this.version = dv.getInt32(0, true);
    if (this.version !== 6) throw new Error(`${name}: progs version ${this.version}, expected 6`);
    this.crc = dv.getInt32(4, true);
    const sec = (i) => ({ ofs: dv.getInt32(8 + i * 8, true), num: dv.getInt32(12 + i * 8, true) });
    const st = sec(0), gd = sec(1), fd = sec(2), fn = sec(3), ss = sec(4), gl = sec(5);
    this.entityfields = dv.getInt32(56, true);

    this.statements = [];
    for (let i = 0; i < st.num; i++) {
      const p = st.ofs + i * 8;
      this.statements.push([i, dv.getUint16(p, true), dv.getInt16(p + 2, true), dv.getInt16(p + 4, true), dv.getInt16(p + 6, true)]);
    }
    const defs = (s, kind) => {
      const out = [];
      for (let i = 0; i < s.num; i++) {
        const p = s.ofs + i * 8;
        out.push({ kind, type: dv.getUint16(p, true), ofs: dv.getUint16(p + 2, true), name: cstr(bytes, ss.ofs + dv.getInt32(p + 4, true), 64) });
      }
      return out;
    };
    this.globaldefs = defs(gd, 0);
    this.fielddefs = defs(fd, 1);
    this.functions = [];
    for (let i = 0; i < fn.num; i++) {
      const p = fn.ofs + i * 36;
      const parms = [];
      for (let j = 0; j < 8; j++) parms.push(bytes[p + 28 + j]);
      this.functions.push({
        id: i, first_statement: dv.getInt32(p, true), parm_start: dv.getInt32(p + 4, true), locals: dv.getInt32(p + 8, true),
        name: cstr(bytes, ss.ofs + dv.getInt32(p + 16, true), 64), file: cstr(bytes, ss.ofs + dv.getInt32(p + 20, true), 64),
        numparms: dv.getInt32(p + 24, true), parms,
      });
    }
    // strings: one row per NUL-terminated string, keyed by its offset (QC refers to a string by offset;
    // a reference into the middle of a string resolves by the preceding row in SQL)
    this.strings = [];
    let start = 0;
    for (let i = 0; i < ss.num; i++) {
      if (bytes[ss.ofs + i] === 0) {
        this.strings.push([start, cstr(bytes, ss.ofs + start, i - start)]);
        start = i + 1;
      }
    }
    // the global image: which slots hold integers (string/entity/field/function references) is known
    // from the definitions; the rest are floats (temps and float immediates)
    const isInt = new Uint8Array(gl.num);
    for (const d of this.globaldefs) {
      const t = d.type & 0x7fff;
      if (t === 1 || t === 4 || t === 5 || t === 6 || t === 7) isInt[d.ofs] = 1;
      else if (t === 2) isInt[d.ofs] = 0;
      else if (t === 3) isInt[d.ofs] = isInt[d.ofs + 1] = isInt[d.ofs + 2] = 0;
    }
    this.globals = [];
    for (let i = 0; i < gl.num; i++) {
      const p = gl.ofs + i * 4;
      const f = dv.getFloat32(p, true), n = dv.getInt32(p, true);
      let v;
      if (isInt[i]) v = n;
      else if (Number.isFinite(f) && (f === 0 || Math.abs(f) >= 1e-30)) v = f;
      else v = n;                       // an untyped slot whose bits are not a sane float: an integer
      if (v !== 0) this.globals.push([i, v]);
    }
  }

  globalByName(name) { return this.globaldefs.find((d) => d.name === name)?.ofs; }
  fieldByName(name) { return this.fielddefs.find((d) => d.name === name)?.ofs; }
  functionByName(name) { return this.functions.find((f) => f.name === name)?.id; }
}
