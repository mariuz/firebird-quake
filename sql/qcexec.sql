-- qcexec.sql – the QuakeC interpreter (pr_exec.c): qc_exec runs a function's statements, qc_call enters
-- one, and the dispatchers qc_inv0..8 that src/qcjit.js rewrites as functions get compiled.

SET TERM ^ ;

-- ── the interpreter (pr_exec.c) ─────────────────────────────────────────

-- PR_ExecuteProgram. qc_exec runs function fnum at call depth `depth` and returns how many statements ran,
-- nested calls included. Every global exists, so a statement is one query (the opcode with both operand
-- values, by joins) and one UPDATE; the locals are saved and restored as sets, the parameters copied by one
-- MERGE from qc_parmmap. A builtin that can call back into QuakeC (walkmove, movetogoal: the triggers they
-- touch) finds the depth in qc_vm, set just before it runs.
CREATE OR ALTER PROCEDURE qc_exec (fnum INTEGER, depth INTEGER) RETURNS (n INTEGER) AS BEGIN n = 0; END^
CREATE OR ALTER PROCEDURE qc_inv0 (d INTEGER, f INTEGER) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv1 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv2 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv3 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv4 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv5 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv6 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv7 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_inv8 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION, a21 DOUBLE PRECISION, a22 DOUBLE PRECISION, a23 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION) AS BEGIN END^

CREATE OR ALTER PROCEDURE qc_exec (fnum INTEGER, depth INTEGER)
RETURNS (n INTEGER)
AS
DECLARE first INTEGER; DECLARE pstart INTEGER; DECLARE nlocals INTEGER;
DECLARE pc INTEGER; DECLARE op SMALLINT; DECLARE a INTEGER; DECLARE b INTEGER; DECLARE c INTEGER;
DECLARE va DOUBLE PRECISION; DECLARE vb DOUBLE PRECISION; DECLARE x DOUBLE PRECISION; DECLARE k INTEGER; DECLARE act INTEGER;
DECLARE e INTEGER; DECLARE o INTEGER; DECLARE addr INTEGER;
DECLARE g_self INTEGER; DECLARE g_time INTEGER; DECLARE f_nt INTEGER; DECLARE f_think INTEGER; DECLARE f_frame INTEGER;
DECLARE comp SMALLINT; DECLARE shr SMALLINT;
DECLARE p0 DOUBLE PRECISION; DECLARE p1 DOUBLE PRECISION; DECLARE p2 DOUBLE PRECISION; DECLARE p3 DOUBLE PRECISION; DECLARE p4 DOUBLE PRECISION; DECLARE p5 DOUBLE PRECISION;
DECLARE p6 DOUBLE PRECISION; DECLARE p7 DOUBLE PRECISION; DECLARE p8 DOUBLE PRECISION; DECLARE p9 DOUBLE PRECISION; DECLARE p10 DOUBLE PRECISION; DECLARE p11 DOUBLE PRECISION;
DECLARE p12 DOUBLE PRECISION; DECLARE p13 DOUBLE PRECISION; DECLARE p14 DOUBLE PRECISION; DECLARE p15 DOUBLE PRECISION; DECLARE p16 DOUBLE PRECISION; DECLARE p17 DOUBLE PRECISION;
DECLARE p18 DOUBLE PRECISION; DECLARE p19 DOUBLE PRECISION; DECLARE p20 DOUBLE PRECISION; DECLARE p21 DOUBLE PRECISION; DECLARE p22 DOUBLE PRECISION; DECLARE p23 DOUBLE PRECISION;
BEGIN
  n = 0;
  -- the function, one more call of it, and one more activation (builtins and compiled functions are not counted)
  UPDATE qc_functions f SET f.active = f.active + IIF(f.first_statement >= 0 AND f.compiled < 1, 1, 0), f.calls = f.calls + 1 WHERE f.id = :fnum
    RETURNING f.first_statement, f.parm_start, f.locals, f.numparms, f.active, f.compiled, f.shared INTO first, pstart, nlocals, k, act, comp, shr;
  IF (first IS NULL) THEN EXCEPTION qc_error 'call of function #' || fnum || ', which does not exist';
  IF (comp = 1) THEN                                -- compiled: its procedure, through the dispatcher of its arity
  BEGIN
    IF (k > 0) THEN
      SELECT MAX(IIF(g.ofs = 4, g.v, NULL)), MAX(IIF(g.ofs = 5, g.v, NULL)), MAX(IIF(g.ofs = 6, g.v, NULL)), MAX(IIF(g.ofs = 7, g.v, NULL)),
             MAX(IIF(g.ofs = 8, g.v, NULL)), MAX(IIF(g.ofs = 9, g.v, NULL)), MAX(IIF(g.ofs = 10, g.v, NULL)), MAX(IIF(g.ofs = 11, g.v, NULL)),
             MAX(IIF(g.ofs = 12, g.v, NULL)), MAX(IIF(g.ofs = 13, g.v, NULL)), MAX(IIF(g.ofs = 14, g.v, NULL)), MAX(IIF(g.ofs = 15, g.v, NULL)),
             MAX(IIF(g.ofs = 16, g.v, NULL)), MAX(IIF(g.ofs = 17, g.v, NULL)), MAX(IIF(g.ofs = 18, g.v, NULL)), MAX(IIF(g.ofs = 19, g.v, NULL)),
             MAX(IIF(g.ofs = 20, g.v, NULL)), MAX(IIF(g.ofs = 21, g.v, NULL)), MAX(IIF(g.ofs = 22, g.v, NULL)), MAX(IIF(g.ofs = 23, g.v, NULL)),
             MAX(IIF(g.ofs = 24, g.v, NULL)), MAX(IIF(g.ofs = 25, g.v, NULL)), MAX(IIF(g.ofs = 26, g.v, NULL)), MAX(IIF(g.ofs = 27, g.v, NULL))
        FROM qc_globals g WHERE g.ofs BETWEEN 4 AND 3 + 3 * :k
        INTO p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21, p22, p23;
    IF (k = 0) THEN EXECUTE PROCEDURE qc_inv0(depth, fnum) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 1) THEN EXECUTE PROCEDURE qc_inv1(depth, fnum, p0, p1, p2) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 2) THEN EXECUTE PROCEDURE qc_inv2(depth, fnum, p0, p1, p2, p3, p4, p5) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 3) THEN EXECUTE PROCEDURE qc_inv3(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 4) THEN EXECUTE PROCEDURE qc_inv4(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 5) THEN EXECUTE PROCEDURE qc_inv5(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 6) THEN EXECUTE PROCEDURE qc_inv6(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16, p17) RETURNING_VALUES x, va, vb;
    ELSE IF (k = 7) THEN EXECUTE PROCEDURE qc_inv7(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16, p17, p18, p19, p20) RETURNING_VALUES x, va, vb;
    ELSE EXECUTE PROCEDURE qc_inv8(depth, fnum, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21, p22, p23) RETURNING_VALUES x, va, vb;
    UPDATE qc_globals g SET g.v = COALESCE(CASE g.ofs WHEN 1 THEN :x WHEN 2 THEN :va ELSE :vb END, 0) WHERE g.ofs BETWEEN 1 AND 3;
    EXIT;
  END
  IF (first < 0) THEN                               -- a builtin
  BEGIN
    IF (first IN (-32, -67)) THEN UPDATE qc_vm v SET v.depth = :depth WHERE v.id = 1;
    EXECUTE PROCEDURE qc_builtin(-first, fnum);
    EXIT;
  END
  IF (depth > 64) THEN EXCEPTION qc_error 'stack overflow';
  -- PR_EnterFunction: the locals saved (only when the function is already running further up the stack,
  -- or when other functions' locals overlap its own, as FTEQCC lays them out), the parameters copied in
  IF (nlocals > 0 AND (act > 1 OR shr = 1)) THEN
    INSERT INTO qc_localstack (depth, ofs, v) SELECT :depth, g.ofs, g.v FROM qc_globals g WHERE g.ofs >= :pstart AND g.ofs < :pstart + :nlocals;
  IF (k > 0) THEN
    MERGE INTO qc_globals g
      USING (SELECT m.dst, s.v FROM qc_parmmap m JOIN qc_globals s ON s.ofs = m.src WHERE m.fnum = :fnum) p ON g.ofs = p.dst
      WHEN MATCHED THEN UPDATE SET g.v = p.v;
  pc = first;
  WHILE (1 = 1) DO
  BEGIN
    va = NULL; vb = NULL;
    SELECT s.op, s.a, s.b, s.c, ga.v, gb.v FROM qc_statements s
      LEFT JOIN qc_globals ga ON ga.ofs = s.a LEFT JOIN qc_globals gb ON gb.ofs = s.b
     WHERE s.id = :pc INTO op, a, b, c, va, vb;
    IF (op IS NULL) THEN EXCEPTION qc_error 'ran off the end of the statements at ' || pc;
    pc = pc + 1; n = n + 1;
    IF (n > 5000000) THEN EXCEPTION qc_error 'runaway loop (' || n || ' statements)';
    -- the common ones first
    IF (op IN (31, 33, 34, 35, 36)) THEN UPDATE qc_globals g SET g.v = :va WHERE g.ofs = :b;                                   -- OP_STORE_F/S/ENT/FLD/FNC
    ELSE IF (op IN (24, 26, 27, 28, 29)) THEN UPDATE qc_globals g SET g.v = qc_f(CAST(:va AS INTEGER), CAST(:vb AS INTEGER)) WHERE g.ofs = :c;   -- OP_LOAD_*: b holds the field
    ELSE IF (op = 30) THEN UPDATE qc_globals g SET g.v = CAST(:va AS INTEGER) * 4096 + CAST(:vb AS INTEGER) WHERE g.ofs = :c;   -- OP_ADDRESS
    ELSE IF (op = 50) THEN BEGIN IF (va = 0) THEN pc = pc + b - 1; END                                                          -- OP_IFNOT
    ELSE IF (op = 49) THEN BEGIN IF (va <> 0) THEN pc = pc + b - 1; END                                                         -- OP_IF
    ELSE IF (op = 61) THEN pc = pc + a - 1;                                                                                     -- OP_GOTO
    ELSE IF (op IN (37, 39, 40, 41, 42)) THEN                                                                                   -- OP_STOREP_F/S/ENT/FLD/FNC
    BEGIN addr = CAST(vb AS INTEGER); EXECUTE PROCEDURE qc_sf(addr / 4096, MOD(addr, 4096), va); END
    ELSE IF (op BETWEEN 51 AND 59) THEN                                                                                         -- OP_CALL0..8
    BEGIN
      e = CAST(va AS INTEGER);
      IF (e = 0) THEN EXCEPTION qc_error 'NULL function call at statement ' || (pc - 1);
      EXECUTE PROCEDURE qc_exec(e, depth + 1) RETURNING_VALUES k;
      n = n + k;
    END
    ELSE IF (op = 43 OR op = 0) THEN                                                                                            -- OP_RETURN, OP_DONE
    BEGIN
      SELECT MAX(IIF(r.ofs = :a, r.v, NULL)), MAX(IIF(r.ofs = :a + 1, r.v, NULL)), MAX(IIF(r.ofs = :a + 2, r.v, NULL))
        FROM qc_globals r WHERE r.ofs BETWEEN :a AND :a + 2 INTO x, va, vb;    -- read all three first: the source may overlap 1..3
      UPDATE qc_globals g SET g.v = COALESCE(CASE g.ofs WHEN 1 THEN :x WHEN 2 THEN :va ELSE :vb END, 0) WHERE g.ofs BETWEEN 1 AND 3;
      LEAVE;
    END
    ELSE IF (op = 6) THEN UPDATE qc_globals g SET g.v = :va + :vb WHERE g.ofs = :c;                                            -- OP_ADD_F
    ELSE IF (op = 8) THEN UPDATE qc_globals g SET g.v = :va - :vb WHERE g.ofs = :c;                                            -- OP_SUB_F
    ELSE IF (op = 1) THEN UPDATE qc_globals g SET g.v = :va * :vb WHERE g.ofs = :c;                                            -- OP_MUL_F
    ELSE IF (op = 5) THEN UPDATE qc_globals g SET g.v = IIF(:vb = 0, 0, :va / :vb) WHERE g.ofs = :c;                          -- OP_DIV_F
    ELSE IF (op IN (10, 13, 14)) THEN UPDATE qc_globals g SET g.v = IIF(:va = :vb, 1, 0) WHERE g.ofs = :c;                    -- OP_EQ_F/E/FNC
    ELSE IF (op IN (15, 18, 19)) THEN UPDATE qc_globals g SET g.v = IIF(:va <> :vb, 1, 0) WHERE g.ofs = :c;                   -- OP_NE_F/E/FNC
    ELSE IF (op = 20) THEN UPDATE qc_globals g SET g.v = IIF(:va <= :vb, 1, 0) WHERE g.ofs = :c;                              -- OP_LE
    ELSE IF (op = 21) THEN UPDATE qc_globals g SET g.v = IIF(:va >= :vb, 1, 0) WHERE g.ofs = :c;                              -- OP_GE
    ELSE IF (op = 22) THEN UPDATE qc_globals g SET g.v = IIF(:va < :vb, 1, 0) WHERE g.ofs = :c;                               -- OP_LT
    ELSE IF (op = 23) THEN UPDATE qc_globals g SET g.v = IIF(:va > :vb, 1, 0) WHERE g.ofs = :c;                               -- OP_GT
    ELSE IF (op IN (44, 47, 48)) THEN UPDATE qc_globals g SET g.v = IIF(:va = 0, 1, 0) WHERE g.ofs = :c;                      -- OP_NOT_F/ENT/FNC
    ELSE IF (op = 62) THEN UPDATE qc_globals g SET g.v = IIF(:va <> 0 AND :vb <> 0, 1, 0) WHERE g.ofs = :c;                   -- OP_AND
    ELSE IF (op = 63) THEN UPDATE qc_globals g SET g.v = IIF(:va <> 0 OR :vb <> 0, 1, 0) WHERE g.ofs = :c;                    -- OP_OR
    ELSE IF (op = 64) THEN UPDATE qc_globals g SET g.v = BIN_AND(CAST(:va AS INTEGER), CAST(:vb AS INTEGER)) WHERE g.ofs = :c;   -- OP_BITAND
    ELSE IF (op = 65) THEN UPDATE qc_globals g SET g.v = BIN_OR(CAST(:va AS INTEGER), CAST(:vb AS INTEGER)) WHERE g.ofs = :c;    -- OP_BITOR
    -- vectors: three slots
    ELSE IF (op = 32) THEN                                                                                                      -- OP_STORE_V
      UPDATE qc_globals g SET g.v = COALESCE((SELECT r.v FROM qc_globals r WHERE r.ofs = :a + g.ofs - :b), 0) WHERE g.ofs BETWEEN :b AND :b + 2;
    ELSE IF (op = 25) THEN                                                                                                      -- OP_LOAD_V
    BEGIN
      e = CAST(va AS INTEGER); o = CAST(vb AS INTEGER);
      UPDATE qc_globals g SET g.v = qc_f(:e, :o + g.ofs - :c) WHERE g.ofs BETWEEN :c AND :c + 2;
    END
    ELSE IF (op = 38) THEN                                                                                                      -- OP_STOREP_V
    BEGIN
      addr = CAST(vb AS INTEGER); e = addr / 4096; o = MOD(addr, 4096);
      EXECUTE PROCEDURE qc_sf(e, o, va); EXECUTE PROCEDURE qc_sf(e, o + 1, qc_g(a + 1)); EXECUTE PROCEDURE qc_sf(e, o + 2, qc_g(a + 2));
    END
    ELSE IF (op = 7) THEN UPDATE qc_globals g SET g.v = (SELECT r.v FROM qc_globals r WHERE r.ofs = :a + g.ofs - :c) + (SELECT r.v FROM qc_globals r WHERE r.ofs = :b + g.ofs - :c) WHERE g.ofs BETWEEN :c AND :c + 2;   -- OP_ADD_V
    ELSE IF (op = 9) THEN UPDATE qc_globals g SET g.v = (SELECT r.v FROM qc_globals r WHERE r.ofs = :a + g.ofs - :c) - (SELECT r.v FROM qc_globals r WHERE r.ofs = :b + g.ofs - :c) WHERE g.ofs BETWEEN :c AND :c + 2;   -- OP_SUB_V
    ELSE IF (op = 3) THEN UPDATE qc_globals g SET g.v = :va * (SELECT r.v FROM qc_globals r WHERE r.ofs = :b + g.ofs - :c) WHERE g.ofs BETWEEN :c AND :c + 2;   -- OP_MUL_FV
    ELSE IF (op = 4) THEN UPDATE qc_globals g SET g.v = (SELECT r.v FROM qc_globals r WHERE r.ofs = :a + g.ofs - :c) * :vb WHERE g.ofs BETWEEN :c AND :c + 2;   -- OP_MUL_VF
    ELSE IF (op = 2) THEN                                                                                                       -- OP_MUL_V (dot)
    BEGIN
      SELECT SUM(x.v * y.v) FROM qc_globals x JOIN qc_globals y ON y.ofs = x.ofs - :a + :b WHERE x.ofs BETWEEN :a AND :a + 2 INTO x;
      UPDATE qc_globals g SET g.v = :x WHERE g.ofs = :c;
    END
    ELSE IF (op IN (11, 16)) THEN                                                                                               -- OP_EQ_V, OP_NE_V
    BEGIN
      k = (SELECT COUNT(*) FROM qc_globals x JOIN qc_globals y ON y.ofs = x.ofs - :a + :b WHERE x.ofs BETWEEN :a AND :a + 2 AND x.v = y.v);
      UPDATE qc_globals g SET g.v = IIF(:op = 11, IIF(:k = 3, 1, 0), IIF(:k = 3, 0, 1)) WHERE g.ofs = :c;
    END
    ELSE IF (op = 45) THEN                                                                                                      -- OP_NOT_V
      UPDATE qc_globals g SET g.v = IIF(EXISTS (SELECT 1 FROM qc_globals x WHERE x.ofs BETWEEN :a AND :a + 2 AND x.v <> 0), 0, 1) WHERE g.ofs = :c;
    -- strings
    ELSE IF (op = 12) THEN UPDATE qc_globals g SET g.v = IIF(qc_str(CAST(:va AS INTEGER)) = qc_str(CAST(:vb AS INTEGER)), 1, 0) WHERE g.ofs = :c;   -- OP_EQ_S
    ELSE IF (op = 17) THEN UPDATE qc_globals g SET g.v = IIF(qc_str(CAST(:va AS INTEGER)) = qc_str(CAST(:vb AS INTEGER)), 0, 1) WHERE g.ofs = :c;   -- OP_NE_S
    ELSE IF (op = 46) THEN UPDATE qc_globals g SET g.v = IIF(:va = 0 OR qc_str(CAST(:va AS INTEGER)) = '', 1, 0) WHERE g.ofs = :c;                  -- OP_NOT_S
    ELSE IF (op = 60) THEN                                                                                                      -- OP_STATE
    BEGIN
      IF (g_self IS NULL) THEN
        SELECT v.g_self, v.g_time, v.f_nextthink, v.f_think, v.f_frame FROM qc_vm v WHERE v.id = 1 INTO g_self, g_time, f_nt, f_think, f_frame;
      e = CAST(qc_g(g_self) AS INTEGER);
      EXECUTE PROCEDURE qc_sf(e, f_nt, qc_g(g_time) + 0.1e0);
      EXECUTE PROCEDURE qc_sf(e, f_frame, va);
      EXECUTE PROCEDURE qc_sf(e, f_think, vb);
    END
    ELSE EXCEPTION qc_error 'bad opcode ' || op || ' at statement ' || (pc - 1);
  END
  -- PR_LeaveFunction: the locals back
  IF (nlocals > 0 AND (act > 1 OR shr = 1)) THEN
  BEGIN
    MERGE INTO qc_globals g USING (SELECT l.ofs, l.v FROM qc_localstack l WHERE l.depth = :depth) l ON g.ofs = l.ofs
      WHEN MATCHED THEN UPDATE SET g.v = l.v;
    DELETE FROM qc_localstack l WHERE l.depth = :depth;
  END
  UPDATE qc_functions f SET f.active = f.active - 1 WHERE f.id = :fnum;
END^

-- a call from the engine (or from a builtin calling back into QuakeC): one level above the current depth
CREATE OR ALTER PROCEDURE qc_call (fnum INTEGER)
AS
DECLARE d INTEGER; DECLARE k INTEGER;
BEGIN
  SELECT v.depth FROM qc_vm v WHERE v.id = 1 INTO d;
  EXECUTE PROCEDURE qc_exec(fnum, COALESCE(d, 0) + 1) RETURNING_VALUES k;
  UPDATE qc_vm v SET v.steps = v.steps + :k, v.depth = :d WHERE v.id = 1;
END^

-- The dispatchers: a call of function f with k parameters (the compiled code's dynamic calls, through
-- fields such as self.th_run, and its calls of functions not compiled yet; the interpreter's calls of
-- compiled functions). src/qcjit.js rewrites them as functions get compiled, with a branch to each
-- compiled procedure of that arity; what is not compiled falls through to the interpreter.
CREATE OR ALTER PROCEDURE qc_inv0 (d INTEGER, f INTEGER) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv1 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp1(a0, a1, a2);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv2 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp2(a0, a1, a2, a3, a4, a5);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv3 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp3(a0, a1, a2, a3, a4, a5, a6, a7, a8);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv4 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp4(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv5 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp5(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv6 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp6(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv7 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp7(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

CREATE OR ALTER PROCEDURE qc_inv8 (d INTEGER, f INTEGER, a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION, a21 DOUBLE PRECISION, a22 DOUBLE PRECISION, a23 DOUBLE PRECISION) RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
DECLARE n INTEGER;
BEGIN
  IF (f = 0) THEN EXCEPTION qc_error 'NULL function call';
  EXECUTE PROCEDURE qc_setp8(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23);
  EXECUTE PROCEDURE qc_exec(f, d) RETURNING_VALUES n;
  EXECUTE PROCEDURE qc_ret RETURNING_VALUES o0, o1, o2;
END^

-- a function by name, with self (0 = world) and other set
CREATE OR ALTER PROCEDURE qc_run (name VARCHAR(64), self_ INTEGER)
AS
DECLARE f INTEGER;
BEGIN
  f = qc_fn(name);
  IF (f IS NULL) THEN EXCEPTION qc_error 'no function ' || name;
  EXECUTE PROCEDURE qc_sg((SELECT v.g_self FROM qc_vm v WHERE v.id = 1), COALESCE(self_, 0));
  EXECUTE PROCEDURE qc_call(f);
END^

SET TERM ; ^
