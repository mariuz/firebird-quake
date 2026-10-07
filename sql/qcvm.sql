-- qcvm.sql – a QuakeC virtual machine in PSQL: pr_exec.c and pr_cmds.c.
--
-- progs.dat is loaded into qc_statements, qc_functions, qc_defs, qc_strings and qc_globals0 by
-- src/loader.js (loadProgs). QC_CALL(f) is PR_ExecuteProgram: it enters a function (saves its locals
-- on qc_localstack, copies the parameters from OFS_PARM0.. into the locals), runs its statements with
-- one branch per opcode, and recurses for OP_CALL; a function whose first_statement is negative is a
-- builtin, dispatched by QC_BUILTIN. Globals and entity fields are rows (qc_globals, qc_fields);
-- an entity reference is the edict number; an address made by OP_ADDRESS is ent * 4096 + field.
-- Strings are offsets into qc_strings, negative for strings made at run time.
--
--   SELECT qc_fn('anglemod') FROM rdb$database;          -- a function's number
--   EXECUTE PROCEDURE qc_sg(4, 370);                     -- OFS_PARM0
--   EXECUTE PROCEDURE qc_call(qc_fn('anglemod'));        -- run it
--   SELECT qc_g(1) FROM rdb$database;                    -- OFS_RETURN
--   EXECUTE PROCEDURE qc_run('worldspawn', 0);           -- by name, with self
--   SELECT * FROM qc_log;                                -- what it printed

SET TERM ^ ;

-- ── globals, fields, strings ─────────────────────────────────────────────

CREATE OR ALTER FUNCTION qc_g (ofs INTEGER) RETURNS DOUBLE PRECISION
AS
BEGIN
  RETURN COALESCE((SELECT g.v FROM qc_globals g WHERE g.ofs = :ofs), 0);
END^

CREATE OR ALTER PROCEDURE qc_sg (ofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  UPDATE OR INSERT INTO qc_globals (ofs, v) VALUES (:ofs, :v) MATCHING (ofs);
END^

CREATE OR ALTER FUNCTION qc_f (ent INTEGER, ofs INTEGER) RETURNS DOUBLE PRECISION
AS
BEGIN
  RETURN COALESCE((SELECT f.v FROM qc_fields f WHERE f.ent = :ent AND f.ofs = :ofs), 0);
END^

CREATE OR ALTER PROCEDURE qc_sf (ent INTEGER, ofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  UPDATE OR INSERT INTO qc_fields (ent, ofs, v) VALUES (:ent, :ofs, :v) MATCHING (ent, ofs);
END^

-- a string by offset: its own row, or the tail of the string that contains it (QC shares suffixes)
CREATE OR ALTER FUNCTION qc_str (ofs INTEGER) RETURNS VARCHAR(2048) CHARACTER SET ASCII
AS
DECLARE o INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII;
BEGIN
  IF (ofs IS NULL OR ofs = 0) THEN RETURN '';
  SELECT FIRST 1 q.ofs, q.s FROM qc_strings q WHERE q.ofs <= :ofs ORDER BY q.ofs DESC INTO o, s;
  IF (o IS NULL) THEN RETURN '';
  s = COALESCE(s, '');
  IF (o = ofs) THEN RETURN s;
  IF (ofs < 0) THEN RETURN '';
  IF (ofs - o <= CHAR_LENGTH(s)) THEN RETURN SUBSTRING(s FROM ofs - o + 1);
  RETURN '';
END^

CREATE OR ALTER FUNCTION qc_newstr (s VARCHAR(2048) CHARACTER SET ASCII) RETURNS INTEGER
AS
DECLARE n INTEGER;
BEGIN
  SELECT v.next_string FROM qc_vm v WHERE v.id = 1 INTO n;
  INSERT INTO qc_strings (ofs, s) VALUES (:n, :s);
  UPDATE qc_vm v SET v.next_string = v.next_string - 1 WHERE v.id = 1;
  RETURN n;
END^

CREATE OR ALTER FUNCTION qc_gdef (name VARCHAR(64)) RETURNS INTEGER
AS
BEGIN
  RETURN (SELECT FIRST 1 d.ofs FROM qc_defs d WHERE d.kind = 0 AND d.name = :name);
END^

CREATE OR ALTER FUNCTION qc_fdef (name VARCHAR(64)) RETURNS INTEGER
AS
BEGIN
  RETURN (SELECT FIRST 1 d.ofs FROM qc_defs d WHERE d.kind = 1 AND d.name = :name);
END^

CREATE OR ALTER FUNCTION qc_fn (name VARCHAR(64)) RETURNS INTEGER
AS
BEGIN
  RETURN (SELECT FIRST 1 f.id FROM qc_functions f WHERE f.name = :name);
END^

-- Quake's ftos: an integer prints as such, anything else as %5.1f
CREATE OR ALTER FUNCTION qc_ftos (f DOUBLE PRECISION) RETURNS VARCHAR(64)
AS
BEGIN
  IF (f = TRUNC(f)) THEN RETURN TRIM(CAST(CAST(f AS BIGINT) AS VARCHAR(32)));
  RETURN TRIM(CAST(CAST(f AS NUMERIC(18, 1)) AS VARCHAR(32)));
END^

CREATE OR ALTER FUNCTION qc_vtos (x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION) RETURNS VARCHAR(100)
AS
BEGIN
  RETURN '''' || TRIM(CAST(CAST(x AS NUMERIC(18, 1)) AS VARCHAR(32))) || ' ' || TRIM(CAST(CAST(y AS NUMERIC(18, 1)) AS VARCHAR(32))) || ' ' || TRIM(CAST(CAST(z AS NUMERIC(18, 1)) AS VARCHAR(32))) || '''';
END^

CREATE OR ALTER PROCEDURE qc_print (kind VARCHAR(16), msg VARCHAR(1024))
AS
BEGIN
  INSERT INTO qc_log (kind, msg) VALUES (:kind, REPLACE(:msg, '\n', ASCII_CHAR(10)));
END^

-- ── edicts ───────────────────────────────────────────────────────────────

CREATE OR ALTER FUNCTION qc_spawn () RETURNS INTEGER
AS
DECLARE e INTEGER;
BEGIN
  SELECT FIRST 1 d.id FROM qc_edicts d WHERE d.free = 1 AND d.id > 1 ORDER BY d.id INTO e;
  IF (e IS NULL) THEN
  BEGIN
    SELECT COALESCE(MAX(d.id), 1) + 1 FROM qc_edicts d INTO e;
    INSERT INTO qc_edicts (id, free) VALUES (:e, 0);
  END
  ELSE
  BEGIN
    UPDATE qc_edicts d SET d.free = 0 WHERE d.id = :e;
    DELETE FROM qc_fields f WHERE f.ent = :e;
  END
  RETURN e;
END^

CREATE OR ALTER PROCEDURE qc_free (ent INTEGER)
AS
BEGIN
  IF (ent <= 0) THEN EXIT;
  UPDATE qc_edicts d SET d.free = 1 WHERE d.id = :ent;
  DELETE FROM qc_fields f WHERE f.ent = :ent;
END^

-- the global image restored, the world and the player's edicts, the VM's cached offsets
CREATE OR ALTER PROCEDURE qc_reset
AS
BEGIN
  DELETE FROM qc_globals;
  INSERT INTO qc_globals (ofs, v) SELECT g.ofs, g.v FROM qc_globals0 g;
  DELETE FROM qc_strings q WHERE q.ofs < 0;
  DELETE FROM qc_fields;
  DELETE FROM qc_edicts;
  DELETE FROM qc_localstack;
  DELETE FROM qc_log;
  INSERT INTO qc_edicts (id, free) VALUES (0, 0);     -- world
  INSERT INTO qc_edicts (id, free) VALUES (1, 0);     -- the player (maxclients = 1)
  DELETE FROM qc_vm;
  INSERT INTO qc_vm (id, g_self, g_other, g_world, g_time, g_frametime, g_vfwd, g_vup, g_vright,
    g_trace_allsolid, g_trace_startsolid, g_trace_fraction, g_trace_endpos, g_trace_plane_normal, g_trace_plane_dist, g_trace_ent, g_trace_inopen, g_trace_inwater,
    f_origin, f_mins, f_maxs, f_size, f_absmin, f_absmax, f_model, f_modelindex, f_classname, f_chain, f_angles, f_ideal_yaw, f_yaw_speed, f_nextthink, f_think, f_frame)
  VALUES (1, qc_gdef('self'), qc_gdef('other'), qc_gdef('world'), qc_gdef('time'), qc_gdef('frametime'), qc_gdef('v_forward'), qc_gdef('v_up'), qc_gdef('v_right'),
    qc_gdef('trace_allsolid'), qc_gdef('trace_startsolid'), qc_gdef('trace_fraction'), qc_gdef('trace_endpos'), qc_gdef('trace_plane_normal'), qc_gdef('trace_plane_dist'), qc_gdef('trace_ent'), qc_gdef('trace_inopen'), qc_gdef('trace_inwater'),
    qc_fdef('origin'), qc_fdef('mins'), qc_fdef('maxs'), qc_fdef('size'), qc_fdef('absmin'), qc_fdef('absmax'), qc_fdef('model'), qc_fdef('modelindex'), qc_fdef('classname'), qc_fdef('chain'), qc_fdef('angles'), qc_fdef('ideal_yaw'), qc_fdef('yaw_speed'), qc_fdef('nextthink'), qc_fdef('think'), qc_fdef('frame'));
END^

-- ── builtins (pr_cmds.c) ────────────────────────────────────────────────
-- Parameters sit at OFS_PARM0 = 4, PARM1 = 7, … (three slots each); the result goes to OFS_RETURN = 1.

CREATE OR ALTER PROCEDURE qc_call (fnum INTEGER) AS BEGIN END^

CREATE OR ALTER PROCEDURE qc_builtin (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION;
DECLARE e INTEGER; DECLARE i INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII; DECLARE s2 VARCHAR(2048) CHARACTER SET ASCII;
DECLARE sp DOUBLE PRECISION; DECLARE cp DOUBLE PRECISION; DECLARE sy DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE sr DOUBLE PRECISION; DECLARE cr DOUBLE PRECISION;
DECLARE vm_fo INTEGER; DECLARE vm_mi INTEGER; DECLARE vm_ma INTEGER; DECLARE vm_sz INTEGER; DECLARE vm_amin INTEGER; DECLARE vm_amax INTEGER;
DECLARE vm_fwd INTEGER; DECLARE vm_up INTEGER; DECLARE vm_right INTEGER; DECLARE vm_chain INTEGER;
DECLARE frac DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE hit INTEGER; DECLARE alls SMALLINT; DECLARE starts SMALLINT; DECLARE inw SMALLINT;
DECLARE head INTEGER; DECLARE wm INTEGER; DECLARE mid INTEGER;
DECLARE cur DOUBLE PRECISION; DECLARE ideal DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION; DECLARE mv DOUBLE PRECISION;
BEGIN
  SELECT v.f_origin, v.f_mins, v.f_maxs, v.f_size, v.f_absmin, v.f_absmax, v.g_vfwd, v.g_vup, v.g_vright, v.f_chain
    FROM qc_vm v WHERE v.id = 1 INTO vm_fo, vm_mi, vm_ma, vm_sz, vm_amin, vm_amax, vm_fwd, vm_up, vm_right, vm_chain;
  IF (n = 1) THEN                                   -- makevectors(angles)
  BEGIN
    a = qc_g(4) * 0.0174532925e0; b = qc_g(5) * 0.0174532925e0; c = qc_g(6) * 0.0174532925e0;   -- pitch, yaw, roll
    sp = SIN(a); cp = COS(a); sy = SIN(b); cy = COS(b); sr = SIN(c); cr = COS(c);
    EXECUTE PROCEDURE qc_sg(vm_fwd, cp * cy); EXECUTE PROCEDURE qc_sg(vm_fwd + 1, cp * sy); EXECUTE PROCEDURE qc_sg(vm_fwd + 2, -sp);
    EXECUTE PROCEDURE qc_sg(vm_right, -sr * sp * cy + cr * sy); EXECUTE PROCEDURE qc_sg(vm_right + 1, -sr * sp * sy - cr * cy); EXECUTE PROCEDURE qc_sg(vm_right + 2, -sr * cp);
    EXECUTE PROCEDURE qc_sg(vm_up, cr * sp * cy + sr * sy); EXECUTE PROCEDURE qc_sg(vm_up + 1, cr * sp * sy - sr * cy); EXECUTE PROCEDURE qc_sg(vm_up + 2, cr * cp);
  END
  ELSE IF (n = 2) THEN                              -- setorigin(e, org)
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, vm_fo, qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_fo + 1, qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_fo + 2, qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amin, qc_g(7) + qc_f(e, vm_mi)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 1, qc_g(8) + qc_f(e, vm_mi + 1)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 2, qc_g(9) + qc_f(e, vm_mi + 2));
    EXECUTE PROCEDURE qc_sf(e, vm_amax, qc_g(7) + qc_f(e, vm_ma)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 1, qc_g(8) + qc_f(e, vm_ma + 1)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 2, qc_g(9) + qc_f(e, vm_ma + 2));
  END
  ELSE IF (n = 3) THEN                              -- setmodel(e, model): the model's bounds when it is loaded
  BEGIN
    e = CAST(qc_g(4) AS INTEGER); s = qc_str(CAST(qc_g(7) AS INTEGER));
    EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_model FROM qc_vm v WHERE v.id = 1), qc_g(7));
    mid = (SELECT FIRST 1 m.id FROM models m WHERE m.name = :s);
    EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_modelindex FROM qc_vm v WHERE v.id = 1), COALESCE(mid, IIF(s = '', 0, 1)));
    x = NULL;
    IF (mid IS NOT NULL) THEN SELECT m.minx, m.miny, m.minz, m.maxx, m.maxy, m.maxz FROM models m WHERE m.id = :mid INTO x, y, z, ex, ey, ez;
    IF (x IS NOT NULL) THEN                        -- brush models carry their bounds; alias models get theirs from setsize
    BEGIN
      EXECUTE PROCEDURE qc_sf(e, vm_mi, x); EXECUTE PROCEDURE qc_sf(e, vm_mi + 1, y); EXECUTE PROCEDURE qc_sf(e, vm_mi + 2, z);
      EXECUTE PROCEDURE qc_sf(e, vm_ma, ex); EXECUTE PROCEDURE qc_sf(e, vm_ma + 1, ey); EXECUTE PROCEDURE qc_sf(e, vm_ma + 2, ez);
      EXECUTE PROCEDURE qc_sf(e, vm_sz, ex - x); EXECUTE PROCEDURE qc_sf(e, vm_sz + 1, ey - y); EXECUTE PROCEDURE qc_sf(e, vm_sz + 2, ez - z);
    END
  END
  ELSE IF (n = 4) THEN                              -- setsize(e, mins, maxs)
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, vm_mi, qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 1, qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 2, qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_ma, qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 1, qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 2, qc_g(12));
    EXECUTE PROCEDURE qc_sf(e, vm_sz, qc_g(10) - qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 1, qc_g(11) - qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 2, qc_g(12) - qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amin, qc_f(e, vm_fo) + qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 1, qc_f(e, vm_fo + 1) + qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 2, qc_f(e, vm_fo + 2) + qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amax, qc_f(e, vm_fo) + qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 1, qc_f(e, vm_fo + 1) + qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 2, qc_f(e, vm_fo + 2) + qc_g(12));
  END
  ELSE IF (n = 6) THEN BEGIN END                    -- break
  ELSE IF (n = 7) THEN EXECUTE PROCEDURE qc_sg(1, RAND());                                            -- random()
  ELSE IF (n = 8) THEN                              -- sound(e, channel, sample, volume, attenuation)
    EXECUTE PROCEDURE qc_print('sound', TRIM(qc_ftos(qc_g(4))) || ' ' || TRIM(qc_ftos(qc_g(7))) || ' ' || qc_str(CAST(qc_g(10) AS INTEGER)) || ' ' || TRIM(qc_ftos(qc_g(13))) || ' ' || TRIM(qc_ftos(qc_g(16))));
  ELSE IF (n = 9) THEN                              -- normalize(v)
  BEGIN
    a = SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5) + qc_g(6) * qc_g(6));
    IF (a = 0) THEN BEGIN EXECUTE PROCEDURE qc_sg(1, 0); EXECUTE PROCEDURE qc_sg(2, 0); EXECUTE PROCEDURE qc_sg(3, 0); END
    ELSE BEGIN EXECUTE PROCEDURE qc_sg(1, qc_g(4) / a); EXECUTE PROCEDURE qc_sg(2, qc_g(5) / a); EXECUTE PROCEDURE qc_sg(3, qc_g(6) / a); END
  END
  ELSE IF (n = 10 OR n = 11) THEN                   -- error(s), objerror(s)
  BEGIN
    EXECUTE PROCEDURE qc_print('error', qc_str(CAST(qc_g(4) AS INTEGER)));
    EXCEPTION qc_error qc_str(CAST(qc_g(4) AS INTEGER));
  END
  ELSE IF (n = 12) THEN EXECUTE PROCEDURE qc_sg(1, SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5) + qc_g(6) * qc_g(6)));   -- vlen
  ELSE IF (n = 13) THEN                             -- vectoyaw(v)
  BEGIN
    IF (qc_g(4) = 0 AND qc_g(5) = 0) THEN a = 0;
    ELSE BEGIN a = ATAN2(qc_g(5), qc_g(4)) * 57.2957795e0; IF (a < 0) THEN a = a + 360; END
    EXECUTE PROCEDURE qc_sg(1, a);
  END
  ELSE IF (n = 14) THEN EXECUTE PROCEDURE qc_sg(1, qc_spawn());                                        -- spawn()
  ELSE IF (n = 15) THEN EXECUTE PROCEDURE qc_free(CAST(qc_g(4) AS INTEGER));                           -- remove(e)
  ELSE IF (n = 16) THEN                             -- traceline(v1, v2, nomonsters, forent): against the loaded world, if any
  BEGIN
    frac = 1; ex = qc_g(7); ey = qc_g(8); ez = qc_g(9); nx = 0; ny = 0; nz = 0; hit = 0; alls = 0; starts = 0; inw = 0;
    wm = (SELECT g.world_model FROM game g WHERE g.id = 1);
    IF (wm IS NOT NULL) THEN
    BEGIN
      SELECT m.hull0 FROM models m WHERE m.id = :wm INTO head;
      SELECT t.fraction, t.ex, t.ey, t.ez, t.nx, t.ny, t.nz, t.allsolid, t.startsolid, t.inwater
        FROM trace_hull(0, :head, 0, 0, 0, qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9)) t
        INTO frac, ex, ey, ez, nx, ny, nz, alls, starts, inw;
    END
    SELECT v.g_trace_allsolid, v.g_trace_startsolid, v.g_trace_fraction, v.g_trace_endpos, v.g_trace_plane_normal, v.g_trace_plane_dist, v.g_trace_ent, v.g_trace_inopen, v.g_trace_inwater
      FROM qc_vm v WHERE v.id = 1 INTO a, b, c, x, y, z, e, i, sp;
    EXECUTE PROCEDURE qc_sg(CAST(a AS INTEGER), alls); EXECUTE PROCEDURE qc_sg(CAST(b AS INTEGER), starts); EXECUTE PROCEDURE qc_sg(CAST(c AS INTEGER), frac);
    EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER), ex); EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER) + 1, ey); EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER) + 2, ez);
    EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER), nx); EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER) + 1, ny); EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER) + 2, nz);
    EXECUTE PROCEDURE qc_sg(CAST(z AS INTEGER), nx * ex + ny * ey + nz * ez);
    EXECUTE PROCEDURE qc_sg(e, hit); EXECUTE PROCEDURE qc_sg(i, IIF(frac < 1, 1, 0)); EXECUTE PROCEDURE qc_sg(CAST(sp AS INTEGER), inw);
  END
  ELSE IF (n = 17) THEN EXECUTE PROCEDURE qc_sg(1, 0);                                                  -- checkclient(): nobody
  ELSE IF (n = 18) THEN                             -- find(start, field, match)
  BEGIN
    s = qc_str(CAST(qc_g(10) AS INTEGER)); i = CAST(qc_g(7) AS INTEGER); c = 0;
    FOR SELECT d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id INTO e DO
      IF (qc_str(CAST(qc_f(e, i) AS INTEGER)) = s) THEN BEGIN c = e; LEAVE; END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n IN (19, 20, 68, 75, 76, 77)) THEN EXECUTE PROCEDURE qc_sg(1, qc_g(4));                  -- precache_*: nothing to do
  ELSE IF (n = 21 OR n = 46) THEN EXECUTE PROCEDURE qc_print('cmd', qc_str(CAST(qc_g(IIF(n = 21, 7, 4)) AS INTEGER)));   -- stuffcmd, localcmd
  ELSE IF (n = 22) THEN                             -- findradius(org, rad): a chain through .chain
  BEGIN
    a = qc_g(7); c = 0; hit = 0;
    FOR SELECT d.id FROM qc_edicts d WHERE d.free = 0 ORDER BY d.id DESC INTO e DO
    BEGIN
      x = qc_f(e, vm_fo) + (qc_f(e, vm_mi) + qc_f(e, vm_ma)) * 0.5e0 - qc_g(4);
      y = qc_f(e, vm_fo + 1) + (qc_f(e, vm_mi + 1) + qc_f(e, vm_ma + 1)) * 0.5e0 - qc_g(5);
      z = qc_f(e, vm_fo + 2) + (qc_f(e, vm_mi + 2) + qc_f(e, vm_ma + 2)) * 0.5e0 - qc_g(6);
      IF (SQRT(x * x + y * y + z * z) <= a) THEN BEGIN EXECUTE PROCEDURE qc_sf(e, vm_chain, c); c = e; END
    END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n = 23) THEN EXECUTE PROCEDURE qc_print('bprint', qc_str(CAST(qc_g(4) AS INTEGER)));
  ELSE IF (n = 24) THEN EXECUTE PROCEDURE qc_print('sprint', qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 25) THEN EXECUTE PROCEDURE qc_print('dprint', qc_str(CAST(qc_g(4) AS INTEGER)));
  ELSE IF (n = 26) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_ftos(qc_g(4))));                     -- ftos
  ELSE IF (n = 27) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_vtos(qc_g(4), qc_g(5), qc_g(6))));    -- vtos
  ELSE IF (n IN (28, 29, 30)) THEN BEGIN END         -- coredump, traceon, traceoff
  ELSE IF (n = 31) THEN EXECUTE PROCEDURE qc_print('eprint', 'edict ' || qc_ftos(qc_g(4)));
  ELSE IF (n = 32) THEN                             -- walkmove(yaw, dist): the step, unchecked
  BEGIN
    e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER); a = qc_g(4) * 0.0174532925e0; b = qc_g(7);
    EXECUTE PROCEDURE qc_sf(e, vm_fo, qc_f(e, vm_fo) + COS(a) * b); EXECUTE PROCEDURE qc_sf(e, vm_fo + 1, qc_f(e, vm_fo + 1) + SIN(a) * b);
    EXECUTE PROCEDURE qc_sg(1, 1);
  END
  ELSE IF (n = 34) THEN EXECUTE PROCEDURE qc_sg(1, 1);                                                  -- droptofloor(): stays put
  ELSE IF (n = 35) THEN                             -- lightstyle(style, value)
    UPDATE OR INSERT INTO lightstyles (style, pattern) VALUES (CAST(qc_g(4) AS INTEGER), qc_str(CAST(qc_g(7) AS INTEGER))) MATCHING (style);
  ELSE IF (n = 36) THEN EXECUTE PROCEDURE qc_sg(1, IIF(qc_g(4) > 0, FLOOR(qc_g(4) + 0.5e0), CEIL(qc_g(4) - 0.5e0)));   -- rint
  ELSE IF (n = 37) THEN EXECUTE PROCEDURE qc_sg(1, FLOOR(qc_g(4)));
  ELSE IF (n = 38) THEN EXECUTE PROCEDURE qc_sg(1, CEIL(qc_g(4)));
  ELSE IF (n = 40) THEN EXECUTE PROCEDURE qc_sg(1, 1);                                                  -- checkbottom
  ELSE IF (n = 41) THEN                             -- pointcontents(v)
    EXECUTE PROCEDURE qc_sg(1, IIF(EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.world_model IS NOT NULL), point_contents(qc_g(4), qc_g(5), qc_g(6)), -1));
  ELSE IF (n = 43) THEN EXECUTE PROCEDURE qc_sg(1, ABS(qc_g(4)));
  ELSE IF (n = 44) THEN                             -- aim(e, speed): straight ahead
  BEGIN EXECUTE PROCEDURE qc_sg(1, qc_g(vm_fwd)); EXECUTE PROCEDURE qc_sg(2, qc_g(vm_fwd + 1)); EXECUTE PROCEDURE qc_sg(3, qc_g(vm_fwd + 2)); END
  ELSE IF (n = 45) THEN                             -- cvar(name)
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER));
    EXECUTE PROCEDURE qc_sg(1, CASE s WHEN 'skill' THEN COALESCE((SELECT g.skill FROM game g WHERE g.id = 1), 1) WHEN 'sv_gravity' THEN 800 WHEN 'sv_maxspeed' THEN 320 WHEN 'sv_friction' THEN 4 WHEN 'sv_accelerate' THEN 10 WHEN 'sv_stopspeed' THEN 100 WHEN 'sv_nostep' THEN 0 WHEN 'registered' THEN COALESCE((SELECT g.registered FROM game g WHERE g.id = 1), 0) ELSE 0 END);
  END
  ELSE IF (n = 47) THEN                             -- nextent(e)
    EXECUTE PROCEDURE qc_sg(1, COALESCE((SELECT FIRST 1 d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id), 0));
  ELSE IF (n = 48) THEN EXECUTE PROCEDURE qc_print('particle', qc_vtos(qc_g(4), qc_g(5), qc_g(6)));
  ELSE IF (n = 49) THEN                             -- changeyaw(): self.angles_y towards ideal_yaw by yaw_speed
  BEGIN
    e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER);
    SELECT v.f_angles, v.f_ideal_yaw, v.f_yaw_speed FROM qc_vm v WHERE v.id = 1 INTO i, hit, head;
    cur = MOD(CAST(qc_f(e, i + 1) * 65536 / 360 AS BIGINT), 65536) * 360.0e0 / 65536; ideal = qc_f(e, hit); spd = qc_f(e, head);
    IF (cur <> ideal) THEN
    BEGIN
      mv = ideal - cur;
      IF (ideal > cur) THEN BEGIN IF (mv >= 180) THEN mv = mv - 360; END
      ELSE BEGIN IF (mv <= -180) THEN mv = mv + 360; END
      IF (mv > 0) THEN BEGIN IF (mv > spd) THEN mv = spd; END
      ELSE BEGIN IF (mv < -spd) THEN mv = -spd; END
      EXECUTE PROCEDURE qc_sf(e, i + 1, MOD(CAST((cur + mv) * 65536 / 360 AS BIGINT), 65536) * 360.0e0 / 65536);
    END
  END
  ELSE IF (n = 51) THEN                             -- vectoangles(v)
  BEGIN
    IF (qc_g(5) = 0 AND qc_g(4) = 0) THEN BEGIN b = 0; a = IIF(qc_g(6) > 0, 90, 270); END
    ELSE
    BEGIN
      b = ATAN2(qc_g(5), qc_g(4)) * 57.2957795e0; IF (b < 0) THEN b = b + 360;
      a = ATAN2(qc_g(6), SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5))) * 57.2957795e0; IF (a < 0) THEN a = a + 360;
    END
    EXECUTE PROCEDURE qc_sg(1, a); EXECUTE PROCEDURE qc_sg(2, b); EXECUTE PROCEDURE qc_sg(3, 0);
  END
  ELSE IF (n BETWEEN 52 AND 59) THEN BEGIN END       -- WriteByte … WriteEntity: no network
  ELSE IF (n = 67) THEN BEGIN END                    -- movetogoal
  ELSE IF (n = 69) THEN EXECUTE PROCEDURE qc_free(CAST(qc_g(4) AS INTEGER));                           -- makestatic
  ELSE IF (n = 70) THEN EXECUTE PROCEDURE qc_print('changelevel', qc_str(CAST(qc_g(4) AS INTEGER)));
  ELSE IF (n = 72) THEN EXECUTE PROCEDURE qc_print('cvar_set', qc_str(CAST(qc_g(4) AS INTEGER)) || ' ' || qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 73) THEN EXECUTE PROCEDURE qc_print('centerprint', qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 74) THEN EXECUTE PROCEDURE qc_print('ambientsound', qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 78) THEN BEGIN END                    -- setspawnparms
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- ── the interpreter (pr_exec.c) ─────────────────────────────────────────

CREATE OR ALTER PROCEDURE qc_call (fnum INTEGER)
AS
DECLARE first INTEGER; DECLARE pstart INTEGER; DECLARE nlocals INTEGER; DECLARE nparms INTEGER;
DECLARE p0 SMALLINT; DECLARE p1 SMALLINT; DECLARE p2 SMALLINT; DECLARE p3 SMALLINT; DECLARE p4 SMALLINT; DECLARE p5 SMALLINT; DECLARE p6 SMALLINT; DECLARE p7 SMALLINT;
DECLARE depth INTEGER; DECLARE i INTEGER; DECLARE j INTEGER; DECLARE o INTEGER; DECLARE psz SMALLINT;
DECLARE pc INTEGER; DECLARE op SMALLINT; DECLARE a INTEGER; DECLARE b INTEGER; DECLARE c INTEGER;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE w DOUBLE PRECISION;
DECLARE e INTEGER; DECLARE addr INTEGER; DECLARE steps BIGINT; DECLARE maxs BIGINT;
DECLARE g_self INTEGER; DECLARE g_time INTEGER; DECLARE f_nt INTEGER; DECLARE f_think INTEGER; DECLARE f_frame INTEGER;
BEGIN
  SELECT f.first_statement, f.parm_start, f.locals, f.numparms, f.p0, f.p1, f.p2, f.p3, f.p4, f.p5, f.p6, f.p7
    FROM qc_functions f WHERE f.id = :fnum INTO first, pstart, nlocals, nparms, p0, p1, p2, p3, p4, p5, p6, p7;
  IF (first IS NULL) THEN EXCEPTION qc_error 'call of function #' || fnum || ', which does not exist';
  IF (first < 0) THEN                               -- a builtin
  BEGIN
    EXECUTE PROCEDURE qc_builtin(-first, fnum);
    EXIT;
  END
  SELECT v.depth, v.steps, v.max_steps, v.g_self, v.g_time, v.f_nextthink, v.f_think, v.f_frame FROM qc_vm v WHERE v.id = 1
    INTO depth, steps, maxs, g_self, g_time, f_nt, f_think, f_frame;
  depth = depth + 1;
  IF (depth > 64) THEN EXCEPTION qc_error 'stack overflow';
  UPDATE qc_vm v SET v.depth = :depth WHERE v.id = 1;
  -- PR_EnterFunction: save the locals, copy the parameters in
  i = 0;
  WHILE (i < nlocals) DO BEGIN INSERT INTO qc_localstack (depth, ofs, v) VALUES (:depth, :pstart + :i, qc_g(:pstart + :i)); i = i + 1; END
  o = pstart; i = 0;
  WHILE (i < nparms) DO
  BEGIN
    psz = CASE i WHEN 0 THEN p0 WHEN 1 THEN p1 WHEN 2 THEN p2 WHEN 3 THEN p3 WHEN 4 THEN p4 WHEN 5 THEN p5 WHEN 6 THEN p6 ELSE p7 END;
    j = 0;
    WHILE (j < psz) DO BEGIN EXECUTE PROCEDURE qc_sg(o, qc_g(4 + i * 3 + j)); o = o + 1; j = j + 1; END
    i = i + 1;
  END
  pc = first;
  WHILE (1 = 1) DO
  BEGIN
    SELECT s.op, s.a, s.b, s.c FROM qc_statements s WHERE s.id = :pc INTO op, a, b, c;
    IF (op IS NULL) THEN EXCEPTION qc_error 'ran off the end of the statements at ' || pc;
    pc = pc + 1; steps = steps + 1;
    IF (steps > maxs) THEN BEGIN UPDATE qc_vm v SET v.steps = :steps WHERE v.id = 1; EXCEPTION qc_error 'runaway loop (' || steps || ' statements)'; END
    -- the common ones first
    IF (op = 31 OR op = 33 OR op = 34 OR op = 35 OR op = 36) THEN EXECUTE PROCEDURE qc_sg(b, qc_g(a));                        -- OP_STORE_F/S/ENT/FLD/FNC
    ELSE IF (op = 32) THEN BEGIN EXECUTE PROCEDURE qc_sg(b, qc_g(a)); EXECUTE PROCEDURE qc_sg(b + 1, qc_g(a + 1)); EXECUTE PROCEDURE qc_sg(b + 2, qc_g(a + 2)); END   -- OP_STORE_V
    ELSE IF (op = 24 OR op = 26 OR op = 27 OR op = 28 OR op = 29) THEN EXECUTE PROCEDURE qc_sg(c, qc_f(CAST(qc_g(a) AS INTEGER), CAST(qc_g(b) AS INTEGER)));   -- OP_LOAD_F/S/ENT/FLD/FNC: b holds the field
    ELSE IF (op = 25) THEN BEGIN e = CAST(qc_g(a) AS INTEGER); o = CAST(qc_g(b) AS INTEGER); EXECUTE PROCEDURE qc_sg(c, qc_f(e, o)); EXECUTE PROCEDURE qc_sg(c + 1, qc_f(e, o + 1)); EXECUTE PROCEDURE qc_sg(c + 2, qc_f(e, o + 2)); END   -- OP_LOAD_V
    ELSE IF (op = 30) THEN EXECUTE PROCEDURE qc_sg(c, CAST(qc_g(a) AS INTEGER) * 4096 + CAST(qc_g(b) AS INTEGER));           -- OP_ADDRESS: b holds the field
    ELSE IF (op = 37 OR op = 39 OR op = 40 OR op = 41 OR op = 42) THEN                                                        -- OP_STOREP_F/S/ENT/FLD/FNC
    BEGIN addr = CAST(qc_g(b) AS INTEGER); EXECUTE PROCEDURE qc_sf(addr / 4096, MOD(addr, 4096), qc_g(a)); END
    ELSE IF (op = 38) THEN                                                                                                   -- OP_STOREP_V
    BEGIN
      addr = CAST(qc_g(b) AS INTEGER); e = addr / 4096; o = MOD(addr, 4096);
      EXECUTE PROCEDURE qc_sf(e, o, qc_g(a)); EXECUTE PROCEDURE qc_sf(e, o + 1, qc_g(a + 1)); EXECUTE PROCEDURE qc_sf(e, o + 2, qc_g(a + 2));
    END
    ELSE IF (op = 49) THEN BEGIN IF (qc_g(a) <> 0) THEN pc = pc + b - 1; END                                                 -- OP_IF
    ELSE IF (op = 50) THEN BEGIN IF (qc_g(a) = 0) THEN pc = pc + b - 1; END                                                  -- OP_IFNOT
    ELSE IF (op = 61) THEN pc = pc + a - 1;                                                                                  -- OP_GOTO
    ELSE IF (op BETWEEN 51 AND 59) THEN                                                                                      -- OP_CALL0..8
    BEGIN
      e = CAST(qc_g(a) AS INTEGER);
      IF (e = 0) THEN EXCEPTION qc_error 'NULL function call at statement ' || (pc - 1);
      UPDATE qc_vm v SET v.steps = :steps WHERE v.id = 1;
      EXECUTE PROCEDURE qc_call(e);
      SELECT v.steps FROM qc_vm v WHERE v.id = 1 INTO steps;
    END
    ELSE IF (op = 43 OR op = 0) THEN                                                                                         -- OP_RETURN, OP_DONE
    BEGIN
      EXECUTE PROCEDURE qc_sg(1, qc_g(a)); EXECUTE PROCEDURE qc_sg(2, qc_g(a + 1)); EXECUTE PROCEDURE qc_sg(3, qc_g(a + 2));
      LEAVE;
    END
    ELSE IF (op = 1) THEN EXECUTE PROCEDURE qc_sg(c, qc_g(a) * qc_g(b));                                                     -- OP_MUL_F
    ELSE IF (op = 2) THEN EXECUTE PROCEDURE qc_sg(c, qc_g(a) * qc_g(b) + qc_g(a + 1) * qc_g(b + 1) + qc_g(a + 2) * qc_g(b + 2));   -- OP_MUL_V (dot)
    ELSE IF (op = 3) THEN BEGIN x = qc_g(a); EXECUTE PROCEDURE qc_sg(c, x * qc_g(b)); EXECUTE PROCEDURE qc_sg(c + 1, x * qc_g(b + 1)); EXECUTE PROCEDURE qc_sg(c + 2, x * qc_g(b + 2)); END   -- OP_MUL_FV
    ELSE IF (op = 4) THEN BEGIN x = qc_g(b); EXECUTE PROCEDURE qc_sg(c, qc_g(a) * x); EXECUTE PROCEDURE qc_sg(c + 1, qc_g(a + 1) * x); EXECUTE PROCEDURE qc_sg(c + 2, qc_g(a + 2) * x); END   -- OP_MUL_VF
    ELSE IF (op = 5) THEN BEGIN x = qc_g(b); EXECUTE PROCEDURE qc_sg(c, IIF(x = 0, 0, qc_g(a) / x)); END                   -- OP_DIV_F
    ELSE IF (op = 6) THEN EXECUTE PROCEDURE qc_sg(c, qc_g(a) + qc_g(b));                                                     -- OP_ADD_F
    ELSE IF (op = 7) THEN BEGIN EXECUTE PROCEDURE qc_sg(c, qc_g(a) + qc_g(b)); EXECUTE PROCEDURE qc_sg(c + 1, qc_g(a + 1) + qc_g(b + 1)); EXECUTE PROCEDURE qc_sg(c + 2, qc_g(a + 2) + qc_g(b + 2)); END   -- OP_ADD_V
    ELSE IF (op = 8) THEN EXECUTE PROCEDURE qc_sg(c, qc_g(a) - qc_g(b));                                                     -- OP_SUB_F
    ELSE IF (op = 9) THEN BEGIN EXECUTE PROCEDURE qc_sg(c, qc_g(a) - qc_g(b)); EXECUTE PROCEDURE qc_sg(c + 1, qc_g(a + 1) - qc_g(b + 1)); EXECUTE PROCEDURE qc_sg(c + 2, qc_g(a + 2) - qc_g(b + 2)); END   -- OP_SUB_V
    ELSE IF (op = 10 OR op = 13 OR op = 14) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = qc_g(b), 1, 0));                  -- OP_EQ_F/E/FNC
    ELSE IF (op = 11) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = qc_g(b) AND qc_g(a + 1) = qc_g(b + 1) AND qc_g(a + 2) = qc_g(b + 2), 1, 0));   -- OP_EQ_V
    ELSE IF (op = 12) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_str(CAST(qc_g(a) AS INTEGER)) = qc_str(CAST(qc_g(b) AS INTEGER)), 1, 0));   -- OP_EQ_S
    ELSE IF (op = 15 OR op = 18 OR op = 19) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) <> qc_g(b), 1, 0));                 -- OP_NE_F/E/FNC
    ELSE IF (op = 16) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = qc_g(b) AND qc_g(a + 1) = qc_g(b + 1) AND qc_g(a + 2) = qc_g(b + 2), 0, 1));   -- OP_NE_V
    ELSE IF (op = 17) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_str(CAST(qc_g(a) AS INTEGER)) = qc_str(CAST(qc_g(b) AS INTEGER)), 0, 1));   -- OP_NE_S
    ELSE IF (op = 20) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) <= qc_g(b), 1, 0));                                        -- OP_LE
    ELSE IF (op = 21) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) >= qc_g(b), 1, 0));                                        -- OP_GE
    ELSE IF (op = 22) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) < qc_g(b), 1, 0));                                         -- OP_LT
    ELSE IF (op = 23) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) > qc_g(b), 1, 0));                                         -- OP_GT
    ELSE IF (op = 44 OR op = 47 OR op = 48) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = 0, 1, 0));                        -- OP_NOT_F/ENT/FNC
    ELSE IF (op = 45) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = 0 AND qc_g(a + 1) = 0 AND qc_g(a + 2) = 0, 1, 0));      -- OP_NOT_V
    ELSE IF (op = 46) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) = 0 OR qc_str(CAST(qc_g(a) AS INTEGER)) = '', 1, 0));     -- OP_NOT_S
    ELSE IF (op = 60) THEN                                                                                                   -- OP_STATE
    BEGIN
      e = CAST(qc_g(g_self) AS INTEGER);
      EXECUTE PROCEDURE qc_sf(e, f_nt, qc_g(g_time) + 0.1e0);
      EXECUTE PROCEDURE qc_sf(e, f_frame, qc_g(a));
      EXECUTE PROCEDURE qc_sf(e, f_think, qc_g(b));
    END
    ELSE IF (op = 62) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) <> 0 AND qc_g(b) <> 0, 1, 0));                            -- OP_AND
    ELSE IF (op = 63) THEN EXECUTE PROCEDURE qc_sg(c, IIF(qc_g(a) <> 0 OR qc_g(b) <> 0, 1, 0));                             -- OP_OR
    ELSE IF (op = 64) THEN EXECUTE PROCEDURE qc_sg(c, BIN_AND(CAST(qc_g(a) AS INTEGER), CAST(qc_g(b) AS INTEGER)));        -- OP_BITAND
    ELSE IF (op = 65) THEN EXECUTE PROCEDURE qc_sg(c, BIN_OR(CAST(qc_g(a) AS INTEGER), CAST(qc_g(b) AS INTEGER)));         -- OP_BITOR
    ELSE EXCEPTION qc_error 'bad opcode ' || op || ' at statement ' || (pc - 1);
  END
  -- PR_LeaveFunction: the locals back
  FOR SELECT l.ofs, l.v FROM qc_localstack l WHERE l.depth = :depth INTO o, x DO EXECUTE PROCEDURE qc_sg(o, x);
  DELETE FROM qc_localstack l WHERE l.depth = :depth;
  UPDATE qc_vm v SET v.depth = :depth - 1, v.steps = :steps WHERE v.id = 1;
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


-- ── the map's entities, spawned by their QuakeC functions (ED_LoadFromFile) ─

CREATE OR ALTER PROCEDURE qc_set_str (ent INTEGER, fofs INTEGER, s VARCHAR(2048) CHARACTER SET ASCII)
AS
BEGIN
  IF (s IS NULL OR s = '' OR fofs IS NULL) THEN EXIT;
  EXECUTE PROCEDURE qc_sf(ent, fofs, qc_newstr(s));
END^

CREATE OR ALTER PROCEDURE qc_set_num (ent INTEGER, fofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  IF (v IS NULL OR fofs IS NULL) THEN EXIT;
  EXECUTE PROCEDURE qc_sf(ent, fofs, v);
END^

-- Every map_ents row (less those the skill or deathmatch flags drop) becomes an edict with its keys
-- in the fields the progs declare, then its classname's function runs with self set. worldspawn is
-- edict 0. A spawn function that raises loses its edict and leaves a row in qc_log.
CREATE OR ALTER PROCEDURE qc_spawn_map (skill SMALLINT, t DOUBLE PRECISION)
RETURNS (spawned INTEGER, failed INTEGER, skipped INTEGER)
AS
DECLARE mid INTEGER; DECLARE cls VARCHAR(40); DECLARE sf INTEGER; DECLARE e INTEGER; DECLARE f INTEGER; DECLARE skillbit INTEGER;
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER;
DECLARE f_cls INTEGER; DECLARE f_tn INTEGER; DECLARE f_tg INTEGER; DECLARE f_kt INTEGER; DECLARE f_model INTEGER; DECLARE f_org INTEGER; DECLARE f_ang INTEGER;
DECLARE f_sf INTEGER; DECLARE f_msg INTEGER; DECLARE f_wait INTEGER; DECLARE f_delay INTEGER; DECLARE f_speed INTEGER; DECLARE f_lip INTEGER; DECLARE f_health INTEGER;
DECLARE f_light INTEGER; DECLARE f_style INTEGER; DECLARE f_sounds INTEGER; DECLARE f_dmg INTEGER; DECLARE f_height INTEGER; DECLARE f_count INTEGER; DECLARE f_map INTEGER; DECLARE f_noise INTEGER; DECLARE f_wt INTEGER;
DECLARE tn VARCHAR(40); DECLARE tg VARCHAR(40); DECLARE kt VARCHAR(40); DECLARE mdl VARCHAR(40); DECLARE msg VARCHAR(200); DECLARE mp VARCHAR(32); DECLARE nz VARCHAR(64);
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE ang DOUBLE PRECISION; DECLARE mp_ DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mr DOUBLE PRECISION;
DECLARE wt DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE sp DOUBLE PRECISION; DECLARE lp DOUBLE PRECISION; DECLARE hl INTEGER; DECLARE li INTEGER; DECLARE st INTEGER; DECLARE so INTEGER; DECLARE dm INTEGER; DECLARE hg DOUBLE PRECISION; DECLARE cn INTEGER; DECLARE wtype INTEGER;
BEGIN
  spawned = 0; failed = 0; skipped = 0;
  skillbit = CASE skill WHEN 0 THEN 256 WHEN 1 THEN 512 ELSE 1024 END;
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  f_cls = qc_fdef('classname'); f_tn = qc_fdef('targetname'); f_tg = qc_fdef('target'); f_kt = qc_fdef('killtarget'); f_model = qc_fdef('model');
  f_org = qc_fdef('origin'); f_ang = qc_fdef('angles'); f_sf = qc_fdef('spawnflags'); f_msg = qc_fdef('message'); f_wait = qc_fdef('wait'); f_delay = qc_fdef('delay');
  f_speed = qc_fdef('speed'); f_lip = qc_fdef('lip'); f_health = qc_fdef('health'); f_light = qc_fdef('light_lev'); f_style = qc_fdef('style'); f_sounds = qc_fdef('sounds');
  f_dmg = qc_fdef('dmg'); f_height = qc_fdef('height'); f_count = qc_fdef('count'); f_map = qc_fdef('map'); f_noise = qc_fdef('noise'); f_wt = qc_fdef('worldtype');
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_other, 0);
  FOR SELECT m.id, m.classname, m.spawnflags, m.targetname, m.target, m.killtarget, m.model, m.ox, m.oy, m.oz, m.angle, m.mpitch, m.myaw, m.mroll,
             m.message, m.wait_, m.delay, m.speed, m.lip, m.health, m.light, m.style, m.sounds, m.dmg, m.height, m.count_, m.map, m.noise, m.worldtype
      FROM map_ents m ORDER BY IIF(m.classname = 'worldspawn', 0, 1), m.id
      INTO mid, cls, sf, tn, tg, kt, mdl, ox, oy, oz, ang, mp_, my, mr, msg, wt, dl, sp, lp, hl, li, st, so, dm, hg, cn, mp, nz, wtype DO
  BEGIN
    IF (cls <> 'worldspawn' AND BIN_AND(sf, skillbit) <> 0) THEN BEGIN skipped = skipped + 1; CONTINUE; END
    f = qc_fn(cls);
    IF (f IS NULL) THEN
    BEGIN
      EXECUTE PROCEDURE qc_print('dprint', 'No spawn function for: ' || cls);
      skipped = skipped + 1;
      CONTINUE;
    END
    e = IIF(cls = 'worldspawn', 0, qc_spawn());
    EXECUTE PROCEDURE qc_set_str(e, f_cls, cls);
    EXECUTE PROCEDURE qc_set_str(e, f_tn, tn); EXECUTE PROCEDURE qc_set_str(e, f_tg, tg); EXECUTE PROCEDURE qc_set_str(e, f_kt, kt);
    EXECUTE PROCEDURE qc_set_str(e, f_model, mdl); EXECUTE PROCEDURE qc_set_str(e, f_msg, msg); EXECUTE PROCEDURE qc_set_str(e, f_map, mp); EXECUTE PROCEDURE qc_set_str(e, f_noise, nz);
    EXECUTE PROCEDURE qc_set_num(e, f_org, ox); EXECUTE PROCEDURE qc_set_num(e, f_org + 1, oy); EXECUTE PROCEDURE qc_set_num(e, f_org + 2, oz);
    IF (ang IS NOT NULL) THEN EXECUTE PROCEDURE qc_set_num(e, f_ang + 1, ang);               -- "angle" is angles '0 angle 0'
    IF (mp_ IS NOT NULL) THEN BEGIN EXECUTE PROCEDURE qc_set_num(e, f_ang, mp_); EXECUTE PROCEDURE qc_set_num(e, f_ang + 1, my); EXECUTE PROCEDURE qc_set_num(e, f_ang + 2, mr); END
    EXECUTE PROCEDURE qc_set_num(e, f_sf, sf);
    EXECUTE PROCEDURE qc_set_num(e, f_wait, wt); EXECUTE PROCEDURE qc_set_num(e, f_delay, dl); EXECUTE PROCEDURE qc_set_num(e, f_speed, sp); EXECUTE PROCEDURE qc_set_num(e, f_lip, lp);
    EXECUTE PROCEDURE qc_set_num(e, f_health, hl); EXECUTE PROCEDURE qc_set_num(e, f_light, li); EXECUTE PROCEDURE qc_set_num(e, f_style, st); EXECUTE PROCEDURE qc_set_num(e, f_sounds, so);
    EXECUTE PROCEDURE qc_set_num(e, f_dmg, dm); EXECUTE PROCEDURE qc_set_num(e, f_height, hg); EXECUTE PROCEDURE qc_set_num(e, f_count, cn); EXECUTE PROCEDURE qc_set_num(e, f_wt, wtype);
    EXECUTE PROCEDURE qc_sg(g_self, e);
    BEGIN
      EXECUTE PROCEDURE qc_call(f);
      spawned = spawned + 1;
    WHEN ANY DO
    BEGIN
      failed = failed + 1;
      UPDATE qc_vm v SET v.depth = 0 WHERE v.id = 1;
      DELETE FROM qc_localstack;
      EXECUTE PROCEDURE qc_print('error', 'spawn of ' || cls || ' (map entity ' || mid || ') failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
      IF (e > 0) THEN EXECUTE PROCEDURE qc_free(e);
    END
    END
  END
  SUSPEND;
END^

-- ── a server frame (SV_Physics, the QuakeC half): StartFrame, then every think that is due ──
CREATE OR ALTER PROCEDURE qc_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION)
RETURNS (thought INTEGER, failed INTEGER)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE g_ft INTEGER; DECLARE f_nt INTEGER; DECLARE f_think INTEGER;
DECLARE e INTEGER; DECLARE nt DOUBLE PRECISION; DECLARE f INTEGER; DECLARE last INTEGER;
BEGIN
  thought = 0; failed = 0;
  SELECT v.g_self, v.g_other, v.g_time, v.g_frametime, v.f_nextthink, v.f_think FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, g_ft, f_nt, f_think;
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_ft, dt);
  EXECUTE PROCEDURE qc_sg(g_self, 0); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('StartFrame');
  IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  -- the thinks due in this frame, in edict order; a think may spawn or free others, so walk by id
  last = -1;
  WHILE (1 = 1) DO
  BEGIN
    e = NULL;
    SELECT FIRST 1 d.id FROM qc_edicts d JOIN qc_fields n ON n.ent = d.id AND n.ofs = :f_nt
      WHERE d.free = 0 AND d.id > :last AND n.v > 0 AND n.v <= :t + 0.0005 ORDER BY d.id INTO e;
    IF (e IS NULL) THEN LEAVE;
    last = e;
    nt = qc_f(e, f_nt);
    f = CAST(qc_f(e, f_think) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, f_nt, 0);
    IF (f = 0) THEN CONTINUE;
    EXECUTE PROCEDURE qc_sg(g_time, nt);            -- the think runs at its own time, as SV_RunThink does
    EXECUTE PROCEDURE qc_sg(g_self, e); EXECUTE PROCEDURE qc_sg(g_other, 0);
    BEGIN
      EXECUTE PROCEDURE qc_call(f);
      thought = thought + 1;
    WHEN ANY DO
    BEGIN
      failed = failed + 1;
      UPDATE qc_vm v SET v.depth = 0 WHERE v.id = 1;
      DELETE FROM qc_localstack;
      EXECUTE PROCEDURE qc_print('error', 'think of edict ' || e || ' (' || COALESCE((SELECT q.name FROM qc_functions q WHERE q.id = :f), '?') || ') failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
    END
    END
  END
  EXECUTE PROCEDURE qc_sg(g_time, t);
  SUSPEND;
END^


-- ── the client (sv_main.c, sv_user.c: the QuakeC half) ───────────────────

-- a touch delivered: self = e, other = o, e.touch()
CREATE OR ALTER PROCEDURE qc_touch (e INTEGER, o INTEGER)
AS
DECLARE f INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER;
BEGIN
  f = CAST(qc_f(e, qc_fdef('touch')) AS INTEGER);
  IF (f = 0) THEN EXIT;
  SELECT v.g_self, v.g_other FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other;
  EXECUTE PROCEDURE qc_sg(g_self, e); EXECUTE PROCEDURE qc_sg(g_other, o);
  EXECUTE PROCEDURE qc_call(f);
END^

-- a new game's client in edict 1: SetNewParms (a fresh game's parms), ClientConnect, PutClientInServer
CREATE OR ALTER PROCEDURE qc_client_connect (t DOUBLE PRECISION)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE f INTEGER;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_other, 0);
  UPDATE qc_edicts d SET d.free = 0 WHERE d.id = 1;
  DELETE FROM qc_fields x WHERE x.ent = 1;
  EXECUTE PROCEDURE qc_set_str(1, qc_fdef('netname'), 'player');
  EXECUTE PROCEDURE qc_sg(g_self, 1);
  f = qc_fn('SetNewParms'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, 1);
  f = qc_fn('ClientConnect'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, 1);
  f = qc_fn('PutClientInServer'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

-- the client's frame: the input into the fields, PlayerPreThink, (the engine's movement goes here), PlayerPostThink
CREATE OR ALTER PROCEDURE qc_player_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION, pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, impulse SMALLINT)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE g_ft INTEGER; DECLARE f INTEGER; DECLARE va INTEGER;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time, v.g_frametime FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, g_ft;
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_ft, dt);
  EXECUTE PROCEDURE qc_sf(1, qc_fdef('button0'), fire);
  EXECUTE PROCEDURE qc_sf(1, qc_fdef('button2'), jump);
  IF (impulse <> 0) THEN EXECUTE PROCEDURE qc_sf(1, qc_fdef('impulse'), impulse);
  va = qc_fdef('v_angle');
  EXECUTE PROCEDURE qc_sf(1, va, pitch); EXECUTE PROCEDURE qc_sf(1, va + 1, yaw); EXECUTE PROCEDURE qc_sf(1, va + 2, 0);
  EXECUTE PROCEDURE qc_sg(g_self, 1); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPreThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, 1); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPostThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

SET TERM ; ^
