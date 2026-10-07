// qcjit.js – QuakeC compiled to PSQL: each hot function of progs.dat becomes a stored procedure of
// its own, run by Firebird instead of interpreted statement by statement by qc_exec (sql/qcvm.sql).
//
// The interpreter costs a query and an UPDATE per statement and a few more per call. A compiled
// function keeps its temporaries, locals and parameters in PSQL variables, so most statements become
// assignments of a microsecond; constants (immediates, field offsets, function numbers, named
// constants: every global no statement writes) become literals; OFS_RETURN and the parameter slots
// become variables too, passed as procedure arguments between compiled functions. What other code
// can see stays where it was: the shared globals (self, time, …) in qc_globals, the fields in ents
// and qc_fields, through the same functions the interpreter uses. Jumps become nested labelled
// loops (a block for each forward jump target, a loop for each backward one: qcc's output is
// structured), so control flow costs nothing either.
//
// Firebird in WASM runs no dynamic SQL from PSQL (EXECUTE STATEMENT does nothing), so the DDL is
// sent from here, between frames, and calls through function values (self.th_run(), think) go
// through generated dispatchers qc_inv0..qc_inv8, one per arity, which branch to the compiled
// procedures and fall back to the interpreter. The VM counts every function's calls; compileHot()
// compiles the hottest few that are not compiled yet, then rewrites the dispatchers and flags them,
// after which qc_exec hands those functions to their procedures.
//
//   const jit = new QcJit(db, progs);
//   await jit.init();                       // after loadProgs: the dispatchers emptied
//   await jit.compileHot({ max: 8 });       // after some frames: the hottest functions compiled
//   await jit.compile(ids);                 // or chosen ones

const D = 'DOUBLE PRECISION';

// QuakeC v6 opcodes: what each reads and writes (r: global read, w: written, 3: a vector)
const ARITH = new Set([1, 5, 6, 8, 10, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 62, 63, 64, 65]);
function operands(op, a, b, c) {
  const r = [], w = [];
  const R = (x, n = 1) => { for (let i = 0; i < n; i++) r.push(x + i); };
  const W = (x, n = 1) => { for (let i = 0; i < n; i++) w.push(x + i); };
  if (ARITH.has(op)) { R(a); R(b); W(c); }
  else if (op === 2 || op === 11 || op === 16) { R(a, 3); R(b, 3); W(c); }
  else if (op === 3) { R(a); R(b, 3); W(c, 3); }
  else if (op === 4) { R(a, 3); R(b); W(c, 3); }
  else if (op === 7 || op === 9) { R(a, 3); R(b, 3); W(c, 3); }
  else if (op === 24 || (op >= 26 && op <= 30)) { R(a); R(b); W(c); }
  else if (op === 25) { R(a); R(b); W(c, 3); }
  else if (op === 31 || (op >= 33 && op <= 36)) { R(a); W(b); }
  else if (op === 32) { R(a, 3); W(b, 3); }
  else if (op === 37 || (op >= 39 && op <= 42)) { R(a); R(b); }
  else if (op === 38) { R(a, 3); R(b); }
  else if (op === 43 || op === 0) R(a, 3);
  else if (op === 44 || (op >= 46 && op <= 48)) { R(a); W(c); }
  else if (op === 45) { R(a, 3); W(c); }
  else if (op === 49 || op === 50) R(a);
  else if (op >= 51 && op <= 59) R(a);
  else if (op === 60) { R(a); R(b); }
  else if (op !== 61) throw new Error(`bad opcode ${op}`);
  return { r, w };
}

// the fields qc_enter routes to ents columns (sql/qcvm.sql): read and written through qc_f/qc_sf;
// every other field is a qc_fields row, read and written directly
const ROUTED = [['origin', 3], ['velocity', 3], ['angles', 3], ['avelocity', 1, 1], ['mins', 3], ['maxs', 3], ['solid'], ['movetype'], ['flags'],
  ['frame'], ['skin'], ['effects'], ['modelindex'], ['ltime'], ['waterlevel'], ['watertype'], ['owner'], ['absmin', 3], ['absmax', 3], ['size', 3],
  ['model'], ['enemy'], ['goalentity'], ['ideal_yaw'], ['yaw_speed']];

// a float as a DOUBLE PRECISION literal
function lit(v) {
  if (!Number.isFinite(v)) v = 0;
  let s = String(v);
  if (!/[e.]/i.test(s)) s += 'e0';
  else if (!/e/i.test(s)) s += 'e0';
  return v < 0 ? `(${s})` : s;
}

// a 32-bit FNV-1a of the statements: the procedures of different progs.dat get different names
function tagOf(progs) {
  let h = 0x811c9dc5;
  for (const st of progs.statements) for (let i = 1; i < 5; i++) { h ^= st[i] & 0xffff; h = Math.imul(h, 16777619) >>> 0; }
  return h.toString(16).padStart(8, '0');
}

export class QcJit {
  constructor(db, progs) {
    this.db = db;
    this.progs = progs;
    this.tag = tagOf(progs);
    this.compiled = new Set();       // function numbers with a procedure, in the dispatchers
    this.failed = new Map();         // function number → why it is not compiled
    this.ms = 0;                     // time spent compiling
    this.vars = new Map();           // function number → the slots its procedure keeps in variables
    this.analyse();
  }

  name(f) { return `QCF_${this.tag}_${f}`; }

  // the whole program once: which globals are written, which function each belongs to
  analyse() {
    const p = this.progs, ng = p.globals.length;
    this.image = new Float64Array(ng);
    for (const [i, v] of p.globals) this.image[i] = v;
    this.written = new Uint8Array(ng);
    this.owner = new Int32Array(ng).fill(-1);          // -1 nobody, -2 several functions, else the one
    this.body = new Map();                              // function → [first, last] statement
    // a function runs up to the next one (qcc ends each with OP_DONE; FTEQCC also returns with it midway)
    const starts = [...new Set(p.functions.filter((f) => f.first_statement > 0).map((f) => f.first_statement))].sort((x, y) => x - y);
    const next = new Map(starts.map((s, i) => [s, (starts[i + 1] ?? p.statements.length) - 1]));
    for (const f of p.functions) {
      if (f.first_statement <= 0) continue;
      const s = next.get(f.first_statement);
      this.body.set(f.id, [f.first_statement, s]);
      for (let i = f.first_statement; i <= s; i++) {
        const [, op, a, b, c] = p.statements[i];
        const { r, w } = operands(op, a, b, c);
        for (const g of [...r, ...w]) this.owner[g] = this.owner[g] === -1 || this.owner[g] === f.id ? f.id : -2;
        for (const g of w) this.written[g] = 1;
      }
    }
    this.endSys = p.globalByName('end_sys_globals') ?? 92;
    // the globals some function reads before writing: they carry values between functions
    this.carried = new Set();
    for (const f of this.body.keys()) for (const g of this.liveness(f)[0]) this.carried.add(g);
    this.routed = new Set();
    for (const [n, len = 1, skip = 0] of ROUTED) {
      const o = p.fieldByName(n);
      if (o !== undefined) for (let i = skip; i < skip + len; i++) this.routed.add(o + i);
    }
  }

  // the globals (from end_sys_globals on) live before each statement of function f: read later
  // without being written first on some path from there
  liveness(fid) {
    const st = this.progs.statements;
    const [first, last] = this.body.get(fid);
    const n = last - first + 1;
    const ops = [], succ = [];
    for (let s = first; s <= last; s++) {
      const [, op, a, b, c] = st[s];
      const { r, w } = operands(op, a, b, c);
      ops.push({ r: r.filter((g) => g >= this.endSys), w });
      succ.push(op === 0 || op === 43 ? [] : op === 61 ? [s + a] : op === 49 || op === 50 ? [s + 1, s + b] : [s + 1]);
    }
    const liveIn = Array.from({ length: n }, () => new Set());
    for (let changed = true; changed;) {
      changed = false;
      for (let i = n - 1; i >= 0; i--) {
        const out = new Set();
        for (const t of succ[i]) if (t >= first && t <= last) for (const g of liveIn[t - first]) out.add(g);
        for (const g of ops[i].w) out.delete(g);
        for (const g of ops[i].r) out.add(g);
        if (out.size !== liveIn[i].size) { liveIn[i] = out; changed = true; }
      }
    }
    return liveIn;
  }

  // PSQL source of function f's procedure: structured, or else (flow that does not nest, such as
  // FTEQCC's switch) a loop over its basic blocks; throws when it cannot be compiled
  source(fid) {
    try { return this.generate(fid, false); } catch (e) {
      if (!/nest|into a loop|left open/.test(e.message)) throw e;
      return this.generate(fid, true);
    }
  }

  generate(fid, machine) {
    const p = this.progs, f = p.functions[fid];
    const [first, last] = this.body.get(fid) ?? [];
    if (first === undefined) throw new Error('not a QuakeC function');
    const st = p.statements;

    // parameters: slot → argument index (three arguments a parameter, as OFS_PARM0 + 3·i + j)
    const params = new Map();
    let o = f.parm_start;
    for (let i = 0; i < f.numparms; i++) for (let j = 0; j < f.parms[i]; j++) params.set(o++, i * 3 + j);

    // control flow: successors, jump targets
    const succ = (s) => {
      const [, op, a, b] = st[s];
      if (op === 0 || op === 43) return [];
      if (op === 61) return [s + a];
      if (op === 49 || op === 50) return [s + 1, s + b];
      return [s + 1];
    };
    const fwd = new Map(), back = new Map();      // target → sources
    for (let s = first; s <= last; s++) {
      const [, op, a, b] = st[s];
      const t = op === 61 ? s + a : op === 49 || op === 50 ? s + b : null;
      if (t === null) continue;
      if (t < first || t > last) throw new Error(`jump out of the function at ${s}`);
      const m = t > s ? fwd : back;
      if (!m.has(t)) m.set(t, []);
      m.get(t).push(s);
    }

    // which slots become variables: those this function alone uses, unless it reads one before writing
    // it (a QuakeC local keeps its value between calls); and any other that no function reads before
    // writing (so it never carries a value from one function to another: FTEQCC shares its temporaries
    // between functions) and that is not live across a call here
    const live = this.liveness(fid);
    const across = new Set();
    for (let i = first; i < last; i++) if (st[i][1] >= 51 && st[i][1] <= 59) for (const g of live[i + 1 - first]) across.add(g);
    // a function whose locals overlap others' (FTEQCC) gets its range saved and restored around every
    // activation by the VM, so whatever it writes there is its own
    const mine = new Set();
    if (f.shared) for (let s = first; s <= last; s++) { const [, op, a, b, c] = st[s]; for (const g of operands(op, a, b, c).w) if (g >= f.parm_start && g < f.parm_start + f.locals) mine.add(g); }
    const private_ = (g) => mine.has(g) || (g >= this.endSys && this.written[g] && !live[0].has(g)
      && (this.owner[g] === fid || (!this.carried.has(g) && !across.has(g))));

    const kind = (g) => {
      if (g >= 1 && g <= 27) return 'reg';
      if (params.has(g)) return 'var';
      if (g === 0 || (g >= this.endSys && !this.written[g])) return 'const';
      if (private_(g)) return 'var';
      return 'mem';
    };

    // regions: a loop from each backward target to its last jump back, a block ending at each forward
    // target and starting early enough that all of them nest
    const regions = [], opens = new Map();
    if (!machine) {
    for (const [h, srcs] of back) regions.push({ kind: 'L', start: h, end: Math.max(...srcs), label: `L${h}` });
    // a loop may end later than its last jump back (falling off its end leaves it), so overlapping
    // loops nest by stretching the outer one
    for (let changed = true; changed;) {
      changed = false;
      for (const x of regions) for (const y of regions) if (x !== y && x.start < y.start && y.start <= x.end && x.end < y.end) { x.end = y.end; changed = true; }
    }
    const blocks = [];
    for (const [t, srcs] of fwd) blocks.push({ kind: 'B', start: Math.min(...srcs), end: t - 1, label: `B${t}` });
    regions.push(...blocks);
    for (let changed = true; changed;) {
      changed = false;
      for (const b of blocks) for (const r of regions) {
        if (r === b) continue;
        if (r.start < b.start && b.start <= r.end && r.end < b.end) { b.start = r.start; changed = true; }
        else if (r.kind === 'L' && b.start < r.start && r.start <= b.end && b.end < r.end) throw new Error('a jump into a loop');
      }
    }
    for (const r of regions) { if (!opens.has(r.start)) opens.set(r.start, []); opens.get(r.start).push(r); }
    for (const list of opens.values()) list.sort((x, y) => y.end - x.end || (x.kind === 'B' ? -1 : 1));
    }
    const target = new Set([...fwd.keys(), ...back.keys()]);
    // the basic blocks' first statements (the loop over blocks)
    const leaders = new Set([first, ...target]);
    for (let i = first; i < last; i++) if ([0, 43, 49, 50, 61].includes(st[i][1])) leaders.add(i + 1);

    // code
    const out = [];
    const regs = new Set([1, 2, 3]), vars = new Set(), mems = new Set();
    let cache = new Set();                     // globals read into m<ofs> since the last join or call
    let addr = new Map();                      // a slot holding ent * 4096 + field: the field, when known
    const emit = (line) => out.push(line);
    const rd = (g) => {
      switch (kind(g)) {
        case 'reg': regs.add(g); return `r${g}`;
        case 'var': vars.add(g); return `v${g}`;
        case 'const': return lit(this.image[g]);
        default:
          mems.add(g);
          if (!cache.has(g)) { emit(`m${g} = qc_g(${g});`); cache.add(g); }
          return `m${g}`;
      }
    };
    const wr = (g, expr) => {
      addr.delete(g);
      switch (kind(g)) {
        case 'reg': regs.add(g); emit(`r${g} = ${expr};`); break;
        case 'var': vars.add(g); emit(`v${g} = ${expr};`); break;
        case 'const': throw new Error(`a write to constant ${g}`);
        default: mems.add(g); emit(`m${g} = ${expr}; EXECUTE PROCEDURE qc_sgu(${g}, m${g});`); cache.add(g);
      }
    };
    const int = (e) => `CAST(${e} AS INTEGER)`;
    const fieldOf = (g) => kind(g) === 'const' ? Math.round(this.image[g]) : null;
    const load = (ent, fo, fexpr) => fo !== null && !this.routed.has(fo) ? `qc_fq(${ent}, ${fo})` : `qc_f(${ent}, ${fo ?? fexpr})`;
    const store = (ent, fo, fexpr, v) => fo !== null && !this.routed.has(fo) ? `EXECUTE PROCEDURE qc_sfq(${ent}, ${fo}, ${v});` : `EXECUTE PROCEDURE qc_sf(${ent}, ${fo ?? fexpr}, ${v});`;
    const jump = (s, t) => (machine ? `BEGIN pc_ = ${t}; CONTINUE M; END` : t > s ? `LEAVE B${t};` : `CONTINUE L${t};`);
    // is OFS_RETURN read after statement s before the next call overwrites it?
    const returnUsed = (s) => {
      for (let i = s + 1; i <= last; i++) {
        if (target.has(i)) return true;                 // reached from elsewhere too: assume so
        const [, op, a, b, c] = st[i];
        const { r, w } = operands(op, a, b, c);
        if (r.some((g) => g >= 1 && g <= 3)) return true;
        if (op === 0 || op === 43 || (op >= 51 && op <= 59)) return false;
        if (op === 49 || op === 50 || op === 61) return true;
        if ([1, 2, 3].every((g) => w.includes(g))) return false;
      }
      return false;
    };
    const args = (k) => Array.from({ length: 3 * k }, (_, i) => { regs.add(4 + i); return `, r${4 + i}`; }).join('');

    const stack = [];
    for (let s = first; s <= last; s++) {
      if (target.has(s) || (machine && leaders.has(s))) { cache = new Set(); addr = new Map(); }
      if (machine && leaders.has(s)) {
        if (s === first) { emit('M: WHILE (1 = 1) DO BEGIN'); emit(`n_ = n_ + 1; IF (n_ > 5000000) THEN EXCEPTION qc_error 'runaway loop in ${f.name}';`); }
        else emit(`pc_ = ${s}; END`);
        emit(`IF (pc_ = ${s}) THEN BEGIN`);
      }
      for (const r of opens.get(s) ?? []) {
        if (stack.length && r.end > stack[stack.length - 1].end) throw new Error('regions do not nest');
        stack.push(r);
        emit(`${r.label}: WHILE (1 = 1) DO BEGIN`);
        if (r.kind === 'L') emit(`n_ = n_ + 1; IF (n_ > 5000000) THEN EXCEPTION qc_error 'runaway loop in ${f.name}';`);
      }
      const [, op, a, b, c] = st[s];
      if (op === 1) wr(c, `${rd(a)} * ${rd(b)}`);
      else if (op === 5) { const x = rd(a), y = rd(b); wr(c, `IIF(${y} = 0, 0, ${x} / ${y})`); }
      else if (op === 6) wr(c, `${rd(a)} + ${rd(b)}`);
      else if (op === 8) wr(c, `${rd(a)} - ${rd(b)}`);
      else if (op === 10 || op === 13 || op === 14) wr(c, `IIF(${rd(a)} = ${rd(b)}, 1, 0)`);
      else if (op === 15 || op === 18 || op === 19) wr(c, `IIF(${rd(a)} <> ${rd(b)}, 1, 0)`);
      else if (op === 20) wr(c, `IIF(${rd(a)} <= ${rd(b)}, 1, 0)`);
      else if (op === 21) wr(c, `IIF(${rd(a)} >= ${rd(b)}, 1, 0)`);
      else if (op === 22) wr(c, `IIF(${rd(a)} < ${rd(b)}, 1, 0)`);
      else if (op === 23) wr(c, `IIF(${rd(a)} > ${rd(b)}, 1, 0)`);
      else if (op === 62) wr(c, `IIF(${rd(a)} <> 0 AND ${rd(b)} <> 0, 1, 0)`);
      else if (op === 63) wr(c, `IIF(${rd(a)} <> 0 OR ${rd(b)} <> 0, 1, 0)`);
      else if (op === 64) wr(c, `BIN_AND(${int(rd(a))}, ${int(rd(b))})`);
      else if (op === 65) wr(c, `BIN_OR(${int(rd(a))}, ${int(rd(b))})`);
      else if (op === 12) wr(c, `IIF(qc_str(${int(rd(a))}) = qc_str(${int(rd(b))}), 1, 0)`);
      else if (op === 17) wr(c, `IIF(qc_str(${int(rd(a))}) = qc_str(${int(rd(b))}), 0, 1)`);
      else if (op === 44 || op === 47 || op === 48) wr(c, `IIF(${rd(a)} = 0, 1, 0)`);
      else if (op === 46) { const x = rd(a); wr(c, `IIF(${x} = 0 OR qc_str(${int(x)}) = '', 1, 0)`); }
      else if (op === 45) wr(c, `IIF(${rd(a)} = 0 AND ${rd(a + 1)} = 0 AND ${rd(a + 2)} = 0, 1, 0)`);
      else if (op === 2) wr(c, `${rd(a)} * ${rd(b)} + ${rd(a + 1)} * ${rd(b + 1)} + ${rd(a + 2)} * ${rd(b + 2)}`);
      else if (op === 11) wr(c, `IIF(${rd(a)} = ${rd(b)} AND ${rd(a + 1)} = ${rd(b + 1)} AND ${rd(a + 2)} = ${rd(b + 2)}, 1, 0)`);
      else if (op === 16) wr(c, `IIF(${rd(a)} = ${rd(b)} AND ${rd(a + 1)} = ${rd(b + 1)} AND ${rd(a + 2)} = ${rd(b + 2)}, 0, 1)`);
      else if (op === 3 || op === 4 || op === 7 || op === 9 || op === 32) {
        // vectors: the three results computed before any is stored (the operands may overlap)
        const e = [0, 1, 2].map((i) => op === 3 ? `${rd(a)} * ${rd(b + i)}` : op === 4 ? `${rd(a + i)} * ${rd(b)}`
          : op === 7 ? `${rd(a + i)} + ${rd(b + i)}` : op === 9 ? `${rd(a + i)} - ${rd(b + i)}` : rd(a + i));
        const dst = op === 32 ? b : c;
        e.forEach((x, i) => emit(`t${i} = ${x};`));
        for (let i = 0; i < 3; i++) wr(dst + i, `t${i}`);
      }
      else if (op === 31 || (op >= 33 && op <= 36)) wr(b, rd(a));
      else if (op === 24 || (op >= 26 && op <= 29)) wr(c, load(int(rd(a)), fieldOf(b), int(rd(b))));
      else if (op === 25) {
        const ent = int(rd(a)), fo = fieldOf(b), fx = int(rd(b));
        const e = [0, 1, 2].map((i) => load(ent, fo === null ? null : fo + i, `${fx} + ${i}`));
        e.forEach((x, i) => emit(`t${i} = ${x};`));
        for (let i = 0; i < 3; i++) wr(c + i, `t${i}`);
      }
      else if (op === 30) {
        const fo = fieldOf(b);
        wr(c, `${int(rd(a))} * 4096 + ${fo ?? int(rd(b))}`);
        if (fo !== null && kind(c) !== 'mem') addr.set(c, fo);
      }
      else if (op === 37 || (op >= 39 && op <= 42)) {
        const ptr = int(rd(b)), fo = addr.get(b) ?? null;
        emit(store(`${ptr} / 4096`, fo, `MOD(${ptr}, 4096)`, rd(a)));
      }
      else if (op === 38) {
        const ptr = int(rd(b)), fo = addr.get(b) ?? null;
        for (let i = 0; i < 3; i++) emit(store(`${ptr} / 4096`, fo === null ? null : fo + i, `MOD(${ptr}, 4096) + ${i}`, rd(a + i)));
      }
      else if (op === 43 || op === 0) {
        emit(`o0 = ${rd(a)}; o1 = ${rd(a + 1)}; o2 = ${rd(a + 2)}; EXIT;`);
      }
      else if (op === 49) emit(`IF (${rd(a)} <> 0) THEN ${jump(s, s + b)}`);
      else if (op === 50) emit(`IF (${rd(a)} = 0) THEN ${jump(s, s + b)}`);
      else if (op === 61) emit(jump(s, s + a));
      else if (op === 60) emit(`EXECUTE PROCEDURE qc_state(${rd(a)}, ${rd(b)});`);
      else if (op >= 51 && op <= 59) {
        const nargs = op - 51;
        if (kind(a) === 'const') {
          const fn = Math.round(this.image[a]), callee = p.functions[fn];
          if (!callee || fn === 0) emit(`EXCEPTION qc_error 'NULL function call in ${f.name}';`);
          else if (callee.first_statement < 0) {
            const num = -callee.first_statement;
            if (nargs > 0) emit(`EXECUTE PROCEDURE qc_setp${nargs}(${args(nargs).slice(2)});`);
            if (num === 32 || num === 67) emit('EXECUTE PROCEDURE qc_depth(d + 1);');
            emit(`EXECUTE PROCEDURE qc_builtin(${num}, ${fn});`);
            if (returnUsed(s)) emit('EXECUTE PROCEDURE qc_ret RETURNING_VALUES r1, r2, r3;');
          } else if (this.compiled.has(fn)) {              // (itself, recursively: through the dispatcher)
            emit(`EXECUTE PROCEDURE ${this.name(fn)}(d + 1${args(callee.numparms)}) RETURNING_VALUES r1, r2, r3;`);
          } else {
            emit(`EXECUTE PROCEDURE qc_inv${callee.numparms}(d + 1, ${fn}${args(callee.numparms)}) RETURNING_VALUES r1, r2, r3;`);
          }
        } else {
          const fx = int(rd(a));
          emit(`EXECUTE PROCEDURE qc_inv${nargs}(d + 1, ${fx}${args(nargs)}) RETURNING_VALUES r1, r2, r3;`);
        }
        cache = new Set(); addr = new Map();
      }
      else throw new Error(`opcode ${op} at ${s}`);
      while (stack.length && stack[stack.length - 1].end === s) {
        const r = stack.pop();
        emit(`LEAVE ${r.label}; END`);
      }
    }
    if (stack.length) throw new Error('regions left open');
    if (machine) { emit('END'); emit('LEAVE M; END'); }

    this.vars.set(fid, new Set([...vars, ...params.keys()]));
    const sig = Array.from({ length: 3 * f.numparms }, (_, i) => `, a${i} ${D}`).join('');
    const decl = [`DECLARE n_ INTEGER = 0;`, ...(machine ? [`DECLARE pc_ INTEGER = ${first};`] : []), `DECLARE t0 ${D}; DECLARE t1 ${D}; DECLARE t2 ${D};`];
    for (const g of [...regs].sort((x, y) => x - y)) decl.push(`DECLARE r${g} ${D} = 0;`);
    for (const g of [...new Set([...vars, ...params.keys()])].sort((x, y) => x - y)) decl.push(`DECLARE v${g} ${D} = ${params.has(g) ? `a${params.get(g)}` : 0};`);
    for (const g of [...mems].sort((x, y) => x - y)) decl.push(`DECLARE m${g} ${D};`);
    return `CREATE OR ALTER PROCEDURE ${this.name(fid)} (d INTEGER${sig})
RETURNS (o0 ${D}, o1 ${D}, o2 ${D})
AS
${decl.join('\n')}
BEGIN
-- ${f.name} (${f.file}), statements ${first}..${last}
o0 = 0; o1 = 0; o2 = 0;
IF (d > 64) THEN EXCEPTION qc_error 'stack overflow';
${out.join('\n')}
END`;
  }

  async ddl(src) { await this.db.exec(`SET TERM ^ ;\n${src}^\nSET TERM ; ^`); }

  // the dispatchers (those of these arities), with a branch to every compiled procedure of their arity
  async dispatchers(arities = [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
    const byArity = Array.from({ length: 9 }, () => []);
    for (const f of this.compiled) byArity[this.progs.functions[f].numparms].push(f);
    for (const k of new Set(arities)) {
      const ids = byArity[k].sort((x, y) => x - y);
      const a = Array.from({ length: 3 * k }, (_, i) => `a${i}`);
      const call = (f) => `IF (f = ${f}) THEN BEGIN EXECUTE PROCEDURE ${this.name(f)}(d${a.map((x) => ', ' + x).join('')}) RETURNING_VALUES o0, o1, o2; EXIT; END`;
      const tree = (lo, hi, ind) => {
        if (hi - lo <= 4) return ids.slice(lo, hi).map((f) => ind + call(f)).join('\n');
        const mid = (lo + hi) >> 1;
        return `${ind}IF (f < ${ids[mid]}) THEN\n${ind}BEGIN\n${tree(lo, mid, ind + '  ')}\n${ind}END\n${ind}ELSE\n${ind}BEGIN\n${tree(mid, hi, ind + '  ')}\n${ind}END`;
      };
      await this.ddl(`CREATE OR ALTER PROCEDURE qc_inv${k} (d INTEGER, f INTEGER${a.map((x) => `, ${x} ${D}`).join('')}) RETURNS (o0 ${D}, o1 ${D}, o2 ${D})
AS
DECLARE n INTEGER;
BEGIN
${ids.length ? tree(0, ids.length, '  ') : ''}
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
${k ? `  EXECUTE PROCEDURE qc_setp${k}(${a.join(', ')});\n` : ''}  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END`);
    }
  }

  // a fresh progs.dat: nothing compiled for it yet
  async init() {
    this.compiled.clear();
    await this.dispatchers();
  }

  // compile these functions (those that cannot be are flagged -1 and left to the interpreter)
  async compile(ids) {
    const t0 = performance.now();
    const done = [], bad = [];
    for (const f of ids) {
      if (this.compiled.has(f) || this.failed.has(f) || !this.body.has(f)) continue;
      let src;
      try { src = this.source(f); } catch (e) { this.failed.set(f, e.message); bad.push(f); continue; }
      try { await this.ddl(src); } catch (e) { this.failed.set(f, e.message.split('\n').slice(-3).join(' ')); bad.push(f); continue; }
      this.compiled.add(f);
      done.push(f);
    }
    if (done.length) await this.dispatchers(done.map((f) => this.progs.functions[f].numparms));
    if (done.length) await this.db.exec(`UPDATE qc_functions SET compiled = 1 WHERE id IN (${done.join(', ')})`);
    if (bad.length) await this.db.exec(`UPDATE qc_functions SET compiled = -1 WHERE id IN (${bad.join(', ')})`);
    this.ms += performance.now() - t0;
    return done.length;
  }

  // every QuakeC function (some 2000: about ten seconds)
  async compileAll() { return this.compile([...this.body.keys()]); }

  // the hottest functions not compiled yet: called at least `min` times, at most `max` of them
  async compileHot({ min = 3, max = 8 } = {}) {
    const r = await this.db.query(`SELECT FIRST ${max} id FROM qc_functions WHERE compiled = 0 AND first_statement > 0 AND calls >= ${min} ORDER BY calls DESC`);
    const ids = r.rows.map((x) => x.ID);
    return ids.length ? this.compile(ids) : 0;
  }
}
