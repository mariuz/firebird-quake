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

CREATE OR ALTER FUNCTION qc_str (ofs INTEGER) RETURNS VARCHAR(2048) CHARACTER SET ASCII AS BEGIN RETURN ''; END^   -- defined below

-- A field of an edict. In QuakeC mode (qc_engine_fields filled by qc_enter) the engine's own fields
-- of every edict but the world live in its ents row; everything else is a qc_fields row.
CREATE OR ALTER FUNCTION qc_f (ent INTEGER, ofs INTEGER) RETURNS DOUBLE PRECISION
AS
DECLARE c SMALLINT; DECLARE v DOUBLE PRECISION;
BEGIN
  IF (ent > 0) THEN
  BEGIN
    SELECT m.col FROM qc_engine_fields m WHERE m.ofs = :ofs INTO c;
    IF (c IS NOT NULL AND c <> 40) THEN
    BEGIN
      SELECT CASE :c
          WHEN 1 THEN e.x WHEN 2 THEN e.y WHEN 3 THEN e.z WHEN 4 THEN e.vx WHEN 5 THEN e.vy WHEN 6 THEN e.vz
          WHEN 7 THEN e.pitch WHEN 8 THEN e.yaw WHEN 9 THEN e.roll WHEN 10 THEN e.avel_yaw
          WHEN 11 THEN e.minx WHEN 12 THEN e.miny WHEN 13 THEN e.minz WHEN 14 THEN e.maxx WHEN 15 THEN e.maxy WHEN 16 THEN e.maxz
          WHEN 17 THEN e.solid WHEN 18 THEN e.movetype WHEN 19 THEN e.flags WHEN 20 THEN e.frame WHEN 21 THEN e.skin WHEN 22 THEN e.effects
          WHEN 23 THEN COALESCE(e.model_id, 0) WHEN 24 THEN e.ltime WHEN 25 THEN e.waterlevel WHEN 26 THEN e.watertype WHEN 27 THEN COALESCE(e.owner_id, 0)
          WHEN 28 THEN COALESCE(e.enemy_id, 0) WHEN 29 THEN COALESCE(e.goal_id, 0) WHEN 41 THEN e.ideal_yaw WHEN 42 THEN e.yaw_speed
          -- SV_LinkEdict's absolute box: items grow by 15 sideways, everything else by 1
          WHEN 31 THEN e.x + e.minx - IIF(BIN_AND(e.flags, 256) <> 0, 15, 1) WHEN 32 THEN e.y + e.miny - IIF(BIN_AND(e.flags, 256) <> 0, 15, 1) WHEN 33 THEN e.z + e.minz - 1
          WHEN 34 THEN e.x + e.maxx + IIF(BIN_AND(e.flags, 256) <> 0, 15, 1) WHEN 35 THEN e.y + e.maxy + IIF(BIN_AND(e.flags, 256) <> 0, 15, 1) WHEN 36 THEN e.z + e.maxz + 1
          WHEN 37 THEN e.maxx - e.minx WHEN 38 THEN e.maxy - e.miny WHEN 39 THEN e.maxz - e.minz
        END FROM ents e WHERE e.id = :ent INTO v;
      RETURN COALESCE(v, 0);
    END
  END
  RETURN COALESCE((SELECT f.v FROM qc_fields f WHERE f.ent = :ent AND f.ofs = :ofs), 0);
END^

CREATE OR ALTER PROCEDURE qc_sf (ent INTEGER, ofs INTEGER, v DOUBLE PRECISION)
AS
DECLARE c SMALLINT;
BEGIN
  IF (ent > 0) THEN
  BEGIN
    SELECT m.col FROM qc_engine_fields m WHERE m.ofs = :ofs INTO c;
    IF (c = 40) THEN                                -- .model: the server sends only entities with a model string
      UPDATE ents e SET e.model_id = IIF(qc_str(CAST(:v AS INTEGER)) = '', NULL,
                                         COALESCE((SELECT FIRST 1 m.id FROM models m WHERE m.name = qc_str(CAST(:v AS INTEGER))), e.model_id))
        WHERE e.id = :ent;
    ELSE IF (c IS NOT NULL) THEN
    BEGIN
      IF (c < 30 OR c > 40) THEN                    -- 31..39 are computed from the box
        UPDATE ents e SET
          e.x = IIF(:c = 1, :v, e.x), e.y = IIF(:c = 2, :v, e.y), e.z = IIF(:c = 3, :v, e.z),
          e.vx = IIF(:c = 4, :v, e.vx), e.vy = IIF(:c = 5, :v, e.vy), e.vz = IIF(:c = 6, :v, e.vz),
          e.pitch = IIF(:c = 7, :v, e.pitch), e.yaw = IIF(:c = 8, :v, e.yaw), e.roll = IIF(:c = 9, :v, e.roll), e.avel_yaw = IIF(:c = 10, :v, e.avel_yaw),
          e.minx = IIF(:c = 11, :v, e.minx), e.miny = IIF(:c = 12, :v, e.miny), e.minz = IIF(:c = 13, :v, e.minz),
          e.maxx = IIF(:c = 14, :v, e.maxx), e.maxy = IIF(:c = 15, :v, e.maxy), e.maxz = IIF(:c = 16, :v, e.maxz),
          e.solid = IIF(:c = 17, CAST(:v AS SMALLINT), e.solid), e.movetype = IIF(:c = 18, CAST(:v AS SMALLINT), e.movetype),
          e.flags = IIF(:c = 19, CAST(:v AS INTEGER), e.flags), e.frame = IIF(:c = 20, CAST(:v AS INTEGER), e.frame),
          e.skin = IIF(:c = 21, CAST(:v AS INTEGER), e.skin), e.effects = IIF(:c = 22, CAST(:v AS INTEGER), e.effects),
          e.model_id = IIF(:c = 23, NULLIF(CAST(:v AS INTEGER), 0), e.model_id), e.ltime = IIF(:c = 24, :v, e.ltime),
          e.waterlevel = IIF(:c = 25, CAST(:v AS SMALLINT), e.waterlevel), e.watertype = IIF(:c = 26, CAST(:v AS INTEGER), e.watertype),
          e.owner_id = IIF(:c = 27, CAST(:v AS INTEGER), e.owner_id),
          e.enemy_id = IIF(:c = 28, CAST(:v AS INTEGER), e.enemy_id), e.goal_id = IIF(:c = 29, CAST(:v AS INTEGER), e.goal_id),
          e.ideal_yaw = IIF(:c = 41, :v, e.ideal_yaw), e.yaw_speed = IIF(:c = 42, :v, e.yaw_speed)
        WHERE e.id = :ent;
      EXIT;
    END
  END
  UPDATE OR INSERT INTO qc_fields (ent, ofs, v) VALUES (:ent, :ofs, :v) MATCHING (ent, ofs);
END^

-- ── what compiled QuakeC calls (src/qcjit.js): globals that exist, fields that are not the engine's ──

CREATE OR ALTER PROCEDURE qc_sgu (ofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = :v WHERE g.ofs = :ofs;
END^

CREATE OR ALTER FUNCTION qc_fq (ent INTEGER, ofs INTEGER) RETURNS DOUBLE PRECISION
AS
BEGIN
  RETURN COALESCE((SELECT f.v FROM qc_fields f WHERE f.ent = :ent AND f.ofs = :ofs), 0);
END^

CREATE OR ALTER PROCEDURE qc_sfq (ent INTEGER, ofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  UPDATE OR INSERT INTO qc_fields (ent, ofs, v) VALUES (:ent, :ofs, :v) MATCHING (ent, ofs);
END^

-- OFS_RETURN, after a builtin or an interpreted function
CREATE OR ALTER PROCEDURE qc_ret RETURNS (o0 DOUBLE PRECISION, o1 DOUBLE PRECISION, o2 DOUBLE PRECISION)
AS
BEGIN
  SELECT MAX(IIF(g.ofs = 1, g.v, NULL)), MAX(IIF(g.ofs = 2, g.v, NULL)), MAX(IIF(g.ofs = 3, g.v, NULL))
    FROM qc_globals g WHERE g.ofs BETWEEN 1 AND 3 INTO o0, o1, o2;
END^

-- the depth a builtin that calls back into QuakeC (walkmove, movetogoal) runs at
CREATE OR ALTER PROCEDURE qc_depth (d INTEGER)
AS
BEGIN
  UPDATE qc_vm v SET v.depth = :d WHERE v.id = 1;
END^

-- OP_STATE: self's nextthink to time + 0.1, its frame and think
CREATE OR ALTER PROCEDURE qc_state (fr DOUBLE PRECISION, th DOUBLE PRECISION)
AS
DECLARE g_self INTEGER; DECLARE g_time INTEGER; DECLARE f_nt INTEGER; DECLARE f_think INTEGER; DECLARE f_frame INTEGER; DECLARE e INTEGER;
BEGIN
  SELECT v.g_self, v.g_time, v.f_nextthink, v.f_think, v.f_frame FROM qc_vm v WHERE v.id = 1 INTO g_self, g_time, f_nt, f_think, f_frame;
  e = CAST(qc_g(g_self) AS INTEGER);
  EXECUTE PROCEDURE qc_sf(e, f_nt, qc_g(g_time) + 0.1e0);
  EXECUTE PROCEDURE qc_sf(e, f_frame, fr);
  EXECUTE PROCEDURE qc_sf(e, f_think, th);
END^

-- n parameters into OFS_PARM0.. (three slots each), for a builtin or an interpreted function
CREATE OR ALTER PROCEDURE qc_setp1 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 END
    WHERE g.ofs BETWEEN 4 AND 6;
END^

CREATE OR ALTER PROCEDURE qc_setp2 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 END
    WHERE g.ofs BETWEEN 4 AND 9;
END^

CREATE OR ALTER PROCEDURE qc_setp3 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 END
    WHERE g.ofs BETWEEN 4 AND 12;
END^

CREATE OR ALTER PROCEDURE qc_setp4 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 WHEN 13 THEN :a9 WHEN 14 THEN :a10 WHEN 15 THEN :a11 END
    WHERE g.ofs BETWEEN 4 AND 15;
END^

CREATE OR ALTER PROCEDURE qc_setp5 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 WHEN 13 THEN :a9 WHEN 14 THEN :a10 WHEN 15 THEN :a11 WHEN 16 THEN :a12 WHEN 17 THEN :a13 WHEN 18 THEN :a14 END
    WHERE g.ofs BETWEEN 4 AND 18;
END^

CREATE OR ALTER PROCEDURE qc_setp6 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 WHEN 13 THEN :a9 WHEN 14 THEN :a10 WHEN 15 THEN :a11 WHEN 16 THEN :a12 WHEN 17 THEN :a13 WHEN 18 THEN :a14 WHEN 19 THEN :a15 WHEN 20 THEN :a16 WHEN 21 THEN :a17 END
    WHERE g.ofs BETWEEN 4 AND 21;
END^

CREATE OR ALTER PROCEDURE qc_setp7 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 WHEN 13 THEN :a9 WHEN 14 THEN :a10 WHEN 15 THEN :a11 WHEN 16 THEN :a12 WHEN 17 THEN :a13 WHEN 18 THEN :a14 WHEN 19 THEN :a15 WHEN 20 THEN :a16 WHEN 21 THEN :a17 WHEN 22 THEN :a18 WHEN 23 THEN :a19 WHEN 24 THEN :a20 END
    WHERE g.ofs BETWEEN 4 AND 24;
END^

CREATE OR ALTER PROCEDURE qc_setp8 (a0 DOUBLE PRECISION, a1 DOUBLE PRECISION, a2 DOUBLE PRECISION, a3 DOUBLE PRECISION, a4 DOUBLE PRECISION, a5 DOUBLE PRECISION, a6 DOUBLE PRECISION, a7 DOUBLE PRECISION, a8 DOUBLE PRECISION, a9 DOUBLE PRECISION, a10 DOUBLE PRECISION, a11 DOUBLE PRECISION, a12 DOUBLE PRECISION, a13 DOUBLE PRECISION, a14 DOUBLE PRECISION, a15 DOUBLE PRECISION, a16 DOUBLE PRECISION, a17 DOUBLE PRECISION, a18 DOUBLE PRECISION, a19 DOUBLE PRECISION, a20 DOUBLE PRECISION, a21 DOUBLE PRECISION, a22 DOUBLE PRECISION, a23 DOUBLE PRECISION)
AS
BEGIN
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN 4 THEN :a0 WHEN 5 THEN :a1 WHEN 6 THEN :a2 WHEN 7 THEN :a3 WHEN 8 THEN :a4 WHEN 9 THEN :a5 WHEN 10 THEN :a6 WHEN 11 THEN :a7 WHEN 12 THEN :a8 WHEN 13 THEN :a9 WHEN 14 THEN :a10 WHEN 15 THEN :a11 WHEN 16 THEN :a12 WHEN 17 THEN :a13 WHEN 18 THEN :a14 WHEN 19 THEN :a15 WHEN 20 THEN :a16 WHEN 21 THEN :a17 WHEN 22 THEN :a18 WHEN 23 THEN :a19 WHEN 24 THEN :a20 WHEN 25 THEN :a21 WHEN 26 THEN :a22 WHEN 27 THEN :a23 END
    WHERE g.ofs BETWEEN 4 AND 27;
END^

-- is the VM in QuakeC mode (it owns ents)?
CREATE OR ALTER FUNCTION qc_on () RETURNS SMALLINT
AS
BEGIN
  RETURN IIF(EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.qc_mode = 1), 1, 0);
END^

-- a string by offset: its own row, or the tail of the string that contains it (QC shares suffixes)
CREATE OR ALTER FUNCTION qc_str (ofs INTEGER) RETURNS VARCHAR(2048) CHARACTER SET ASCII
AS
DECLARE o INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII;
BEGIN
  IF (ofs IS NULL OR ofs = 0) THEN RETURN '';
  SELECT q.ofs, q.s FROM qc_strings q WHERE q.ofs = :ofs INTO o, s;                  -- most are whole strings
  IF (o IS NOT NULL) THEN RETURN COALESCE(s, '');
  SELECT FIRST 1 q.ofs, q.s FROM qc_strings q WHERE q.ofs <= :ofs ORDER BY q.ofs DESC INTO o, s;   -- by the descending index
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

CREATE OR ALTER PROCEDURE qc_msg (s VARCHAR(1024))
AS
DECLARE cur VARCHAR(1024); DECLARE mt DOUBLE PRECISION; DECLARE now DOUBLE PRECISION;
BEGIN
  s = REPLACE(s, '\n', ASCII_CHAR(10));
  SELECT p.msg, p.msg_time FROM player p WHERE p.id = 1 INTO cur, mt;
  now = (SELECT g.time_ FROM game g WHERE g.id = 1);
  IF (cur IS NULL OR mt <= now OR RIGHT(cur, 1) = ASCII_CHAR(10)) THEN cur = s; ELSE cur = cur || s;
  UPDATE player p SET p.msg = SUBSTRING(:cur FROM 1 FOR 200), p.msg_time = :now + 3 WHERE p.id = 1;
END^

-- ── edicts ───────────────────────────────────────────────────────────────

-- svs.maxclients: edicts 1..maxclients are the clients (the page's player, then the bots)
CREATE OR ALTER FUNCTION qc_maxclients RETURNS INTEGER
AS
BEGIN
  RETURN COALESCE((SELECT g.maxclients FROM game g WHERE g.id = 1), 1);
END^

CREATE OR ALTER FUNCTION qc_spawn () RETURNS INTEGER
AS
DECLARE e INTEGER; DECLARE mc INTEGER;
BEGIN
  mc = qc_maxclients();
  SELECT FIRST 1 d.id FROM qc_edicts d WHERE d.free = 1 AND d.id > :mc ORDER BY d.id INTO e;
  IF (e IS NULL) THEN
  BEGIN
    SELECT MAXVALUE(COALESCE(MAX(d.id), 0), :mc) + 1 FROM qc_edicts d INTO e;
    INSERT INTO qc_edicts (id, free) VALUES (:e, 0);
  END
  ELSE
  BEGIN
    UPDATE qc_edicts d SET d.free = 0 WHERE d.id = :e;
    DELETE FROM qc_fields f WHERE f.ent = :e;
  END
  IF (qc_on() = 1) THEN
  BEGIN
    DELETE FROM ents x WHERE x.id = :e;
    INSERT INTO ents (id, classname) VALUES (:e, 'qc');
  END
  RETURN e;
END^

CREATE OR ALTER PROCEDURE qc_free (ent INTEGER)
AS
BEGIN
  IF (ent <= 0) THEN EXIT;
  UPDATE qc_edicts d SET d.free = 1 WHERE d.id = :ent;
  DELETE FROM qc_fields f WHERE f.ent = :ent;
  IF (qc_on() = 1) THEN DELETE FROM ents x WHERE x.id = :ent;
END^

-- the global image restored, the world and the player's edicts, the VM's cached offsets
CREATE OR ALTER PROCEDURE qc_reset
AS
DECLARE i INTEGER;
BEGIN
  DELETE FROM qc_globals;
  INSERT INTO qc_globals (ofs, v) SELECT g.ofs, g.v FROM qc_globals0 g;
  DELETE FROM qc_strings q WHERE q.ofs < 0;
  DELETE FROM qc_fields;
  DELETE FROM qc_edicts;
  DELETE FROM qc_localstack;
  DELETE FROM qc_eyeleaf;
  DELETE FROM qc_log;
  UPDATE qc_functions f SET f.active = 0 WHERE f.active <> 0;   -- the calls and compiled flags stay: the procedures do
  INSERT INTO qc_edicts (id, free) VALUES (0, 0);     -- world
  INSERT INTO qc_edicts (id, free) VALUES (1, 0);     -- the player
  -- the bots' client edicts, free until they join (qc_client_join_n)
  i = 2;
  WHILE (i <= qc_maxclients()) DO BEGIN INSERT INTO qc_edicts (id, free) VALUES (:i, 1); i = i + 1; END
  IF (qc_on() = 1) THEN
  BEGIN
    DELETE FROM ents;
    INSERT INTO ents (id, classname) VALUES (1, 'player');
  END
  DELETE FROM qc_vm;
  INSERT INTO qc_vm (id, g_self, g_other, g_world, g_time, g_frametime, g_vfwd, g_vup, g_vright,
    g_trace_allsolid, g_trace_startsolid, g_trace_fraction, g_trace_endpos, g_trace_plane_normal, g_trace_plane_dist, g_trace_ent, g_trace_inopen, g_trace_inwater,
    f_origin, f_mins, f_maxs, f_size, f_absmin, f_absmax, f_model, f_modelindex, f_classname, f_chain, f_angles, f_ideal_yaw, f_yaw_speed, f_nextthink, f_think, f_frame)
  VALUES (1, qc_gdef('self'), qc_gdef('other'), qc_gdef('world'), qc_gdef('time'), qc_gdef('frametime'), qc_gdef('v_forward'), qc_gdef('v_up'), qc_gdef('v_right'),
    qc_gdef('trace_allsolid'), qc_gdef('trace_startsolid'), qc_gdef('trace_fraction'), qc_gdef('trace_endpos'), qc_gdef('trace_plane_normal'), qc_gdef('trace_plane_dist'), qc_gdef('trace_ent'), qc_gdef('trace_inopen'), qc_gdef('trace_inwater'),
    qc_fdef('origin'), qc_fdef('mins'), qc_fdef('maxs'), qc_fdef('size'), qc_fdef('absmin'), qc_fdef('absmax'), qc_fdef('model'), qc_fdef('modelindex'), qc_fdef('classname'), qc_fdef('chain'), qc_fdef('angles'), qc_fdef('ideal_yaw'), qc_fdef('yaw_speed'), qc_fdef('nextthink'), qc_fdef('think'), qc_fdef('frame'));
  UPDATE qc_vm v SET v.f_touch = qc_fdef('touch'), v.f_blocked = qc_fdef('blocked'), v.f_v_angle = qc_fdef('v_angle'), v.f_avelocity = qc_fdef('avelocity'),
    v.f_gravity = qc_fdef('gravity'), v.f_teleport_time = qc_fdef('teleport_time'), v.f_punchangle = qc_fdef('punchangle'),
    v.f_groundentity = qc_fdef('groundentity'), v.f_view_ofs = qc_fdef('view_ofs'), v.f_health = qc_fdef('health')
  WHERE v.id = 1;
END^

CREATE OR ALTER PROCEDURE qc_route (ofs INTEGER, col SMALLINT)
AS
BEGIN
  IF (ofs IS NOT NULL) THEN UPDATE OR INSERT INTO qc_engine_fields (ofs, col) VALUES (:ofs, :col) MATCHING (ofs);
END^

-- QuakeC mode: the VM owns ents. The engine's fields are routed to ents columns, the PSQL game's
-- entities are wiped (the map's geometry stays), and the camera follows edict 1.
CREATE OR ALTER PROCEDURE qc_enter
AS
DECLARE o INTEGER;
BEGIN
  IF (NOT EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.world_model IS NOT NULL)) THEN EXCEPTION qc_error 'QuakeC mode needs a loaded map';
  UPDATE game g SET g.qc_mode = 1 WHERE g.id = 1;
  DELETE FROM qc_engine_fields;
  o = qc_fdef('origin');    EXECUTE PROCEDURE qc_route(o, 1); EXECUTE PROCEDURE qc_route(o + 1, 2); EXECUTE PROCEDURE qc_route(o + 2, 3);
  o = qc_fdef('velocity');  EXECUTE PROCEDURE qc_route(o, 4); EXECUTE PROCEDURE qc_route(o + 1, 5); EXECUTE PROCEDURE qc_route(o + 2, 6);
  o = qc_fdef('angles');    EXECUTE PROCEDURE qc_route(o, 7); EXECUTE PROCEDURE qc_route(o + 1, 8); EXECUTE PROCEDURE qc_route(o + 2, 9);
  o = qc_fdef('avelocity'); EXECUTE PROCEDURE qc_route(o + 1, 10);
  o = qc_fdef('mins');      EXECUTE PROCEDURE qc_route(o, 11); EXECUTE PROCEDURE qc_route(o + 1, 12); EXECUTE PROCEDURE qc_route(o + 2, 13);
  o = qc_fdef('maxs');      EXECUTE PROCEDURE qc_route(o, 14); EXECUTE PROCEDURE qc_route(o + 1, 15); EXECUTE PROCEDURE qc_route(o + 2, 16);
  EXECUTE PROCEDURE qc_route(qc_fdef('solid'), 17); EXECUTE PROCEDURE qc_route(qc_fdef('movetype'), 18); EXECUTE PROCEDURE qc_route(qc_fdef('flags'), 19);
  EXECUTE PROCEDURE qc_route(qc_fdef('frame'), 20); EXECUTE PROCEDURE qc_route(qc_fdef('skin'), 21); EXECUTE PROCEDURE qc_route(qc_fdef('effects'), 22);
  EXECUTE PROCEDURE qc_route(qc_fdef('modelindex'), 23); EXECUTE PROCEDURE qc_route(qc_fdef('ltime'), 24);
  EXECUTE PROCEDURE qc_route(qc_fdef('waterlevel'), 25); EXECUTE PROCEDURE qc_route(qc_fdef('watertype'), 26); EXECUTE PROCEDURE qc_route(qc_fdef('owner'), 27);
  o = qc_fdef('absmin');    EXECUTE PROCEDURE qc_route(o, 31); EXECUTE PROCEDURE qc_route(o + 1, 32); EXECUTE PROCEDURE qc_route(o + 2, 33);
  o = qc_fdef('absmax');    EXECUTE PROCEDURE qc_route(o, 34); EXECUTE PROCEDURE qc_route(o + 1, 35); EXECUTE PROCEDURE qc_route(o + 2, 36);
  o = qc_fdef('size');      EXECUTE PROCEDURE qc_route(o, 37); EXECUTE PROCEDURE qc_route(o + 1, 38); EXECUTE PROCEDURE qc_route(o + 2, 39);
  EXECUTE PROCEDURE qc_route(qc_fdef('model'), 40);
  EXECUTE PROCEDURE qc_route(qc_fdef('enemy'), 28); EXECUTE PROCEDURE qc_route(qc_fdef('goalentity'), 29);
  EXECUTE PROCEDURE qc_route(qc_fdef('ideal_yaw'), 41); EXECUTE PROCEDURE qc_route(qc_fdef('yaw_speed'), 42);
  EXECUTE PROCEDURE qc_reset;
  DELETE FROM vis_faces;
  UPDATE viewcfg c SET c.vis_leaf = NULL;
  UPDATE player p SET p.ent_id = 1, p.view_ofs = 22, p.stepz = 0, p.punchangle = 0 WHERE p.id = 1;
END^

CREATE OR ALTER PROCEDURE qc_leave
AS
BEGIN
  UPDATE game g SET g.qc_mode = 0 WHERE g.id = 1;
  DELETE FROM qc_engine_fields;
END^

-- ── builtins (pr_cmds.c) ────────────────────────────────────────────────
-- Parameters sit at OFS_PARM0 = 4, PARM1 = 7, … (three slots each); the result goes to OFS_RETURN = 1.

CREATE OR ALTER PROCEDURE qc_call (fnum INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_touch_triggers (e INTEGER) AS BEGIN END^

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
DECLARE gself INTEGER; DECLARE oself DOUBLE PRECISION; DECLARE ok SMALLINT; DECLARE pv VARCHAR(2048) CHARACTER SET ASCII;
DECLARE bx DOUBLE PRECISION; DECLARE by_ DOUBLE PRECISION; DECLARE bz DOUBLE PRECISION; DECLARE best DOUBLE PRECISION; DECLARE bent INTEGER;
DECLARE tst SMALLINT; DECLARE tty SMALLINT; DECLARE tn SMALLINT; DECLARE th INTEGER;
DECLARE cc INTEGER; DECLARE mcl INTEGER; DECLARE kk INTEGER;
BEGIN
  SELECT v.g_self, v.f_origin, v.f_mins, v.f_maxs, v.f_size, v.f_absmin, v.f_absmax, v.g_vfwd, v.g_vup, v.g_vright, v.f_chain
    FROM qc_vm v WHERE v.id = 1 INTO gself, vm_fo, vm_mi, vm_ma, vm_sz, vm_amin, vm_amax, vm_fwd, vm_up, vm_right, vm_chain;
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
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
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
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
  END
  ELSE IF (n = 4) THEN                              -- setsize(e, mins, maxs)
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, vm_mi, qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 1, qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 2, qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_ma, qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 1, qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 2, qc_g(12));
    EXECUTE PROCEDURE qc_sf(e, vm_sz, qc_g(10) - qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 1, qc_g(11) - qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 2, qc_g(12) - qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amin, qc_f(e, vm_fo) + qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 1, qc_f(e, vm_fo + 1) + qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 2, qc_f(e, vm_fo + 2) + qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amax, qc_f(e, vm_fo) + qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 1, qc_f(e, vm_fo + 1) + qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 2, qc_f(e, vm_fo + 2) + qc_g(12));
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
  END
  ELSE IF (n = 6) THEN BEGIN END                    -- break
  ELSE IF (n = 7) THEN EXECUTE PROCEDURE qc_sg(1, rnd());                                            -- random()
  ELSE IF (n = 8) THEN                              -- sound(e, channel, sample, volume, attenuation): logged, and played in QuakeC mode
  BEGIN
    EXECUTE PROCEDURE qc_print('sound', TRIM(qc_ftos(qc_g(4))) || ' ' || TRIM(qc_ftos(qc_g(7))) || ' ' || qc_str(CAST(qc_g(10) AS INTEGER)) || ' ' || TRIM(qc_ftos(qc_g(13))) || ' ' || TRIM(qc_ftos(qc_g(16))));
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE snd(CAST(qc_g(4) AS INTEGER), CAST(qc_g(7) AS SMALLINT), SUBSTRING(qc_str(CAST(qc_g(10) AS INTEGER)) FROM 1 FOR 64), qc_g(13), qc_g(16));
  END
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
  ELSE IF (n = 16) THEN                             -- traceline(v1, v2, nomonsters, forent): the world, and in QuakeC mode the entities too
  BEGIN
    frac = 1; ex = qc_g(7); ey = qc_g(8); ez = qc_g(9); nx = 0; ny = 0; nz = 0; hit = 0; alls = 0; starts = 0; inw = 0;
    wm = (SELECT g.world_model FROM game g WHERE g.id = 1);
    IF (qc_on() = 1) THEN
      SELECT t.fraction, t.ex, t.ey, t.ez, t.nx, t.ny, t.nz, t.allsolid, t.startsolid, t.inwater, t.hit_ent
        FROM trace_move(CAST(qc_g(13) AS INTEGER), 0, 0, 0, 0, 0, 0, qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9), CAST(qc_g(10) AS SMALLINT)) t
        INTO frac, ex, ey, ez, nx, ny, nz, alls, starts, inw, hit;
    ELSE IF (wm IS NOT NULL) THEN
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
  ELSE IF (n = 17) THEN                             -- checkclient(): the client, if the caller's eye is in the PVS of the client's eye
  BEGIN
    c = 0;
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(gself) AS INTEGER);
      SELECT v.f_health, v.f_view_ofs, v.check_time, v.check_pvs, v.sv_time, v.check_client FROM qc_vm v WHERE v.id = 1
        INTO head, mid, a, pv, b, cc;
      -- PF_newcheckclient: every 0.1 s the next client in turn that is in the game and alive, and its eye's PVS
      IF (a IS NULL OR b - a >= 0.1e0 OR b < a) THEN
      BEGIN
        mcl = qc_maxclients(); kk = 0; i = COALESCE(cc, mcl); cc = NULL; pv = NULL;
        WHILE (kk < mcl) DO
        BEGIN
          i = MOD(i, mcl) + 1; kk = kk + 1;
          IF (EXISTS (SELECT 1 FROM ents d JOIN qc_edicts q ON q.id = d.id AND q.free = 0 WHERE d.id = :i AND BIN_AND(d.flags, 128) = 0) AND qc_fq(i, head) > 0) THEN
          BEGIN cc = i; LEAVE; END
        END
        IF (cc IS NOT NULL) THEN
          SELECT l.pvs FROM ents d JOIN leaves l ON l.id = point_leaf(d.x + qc_fq(:cc, :mid), d.y + qc_fq(:cc, :mid + 1), d.z + qc_fq(:cc, :mid + 2))
           WHERE d.id = :cc INTO pv;
        UPDATE qc_vm v SET v.check_time = :b, v.check_pvs = :pv, v.check_client = :cc WHERE v.id = 1;
      END
      IF (cc IS NOT NULL AND pv IS NOT NULL AND qc_fq(cc, head) > 0) THEN
      BEGIN
        -- the caller's eye, and its leaf: kept while it stands there (a waiting monster asks every think)
        SELECT d.x + COALESCE(MAX(IIF(f.ofs = :mid, f.v, NULL)), 0), d.y + COALESCE(MAX(IIF(f.ofs = :mid + 1, f.v, NULL)), 0), d.z + COALESCE(MAX(IIF(f.ofs = :mid + 2, f.v, NULL)), 0)
          FROM ents d LEFT JOIN qc_fields f ON f.ent = d.id AND f.ofs BETWEEN :mid AND :mid + 2 WHERE d.id = :e GROUP BY d.x, d.y, d.z INTO bx, by_, bz;
        IF (bx IS NOT NULL) THEN
        BEGIN
          wm = NULL;
          SELECT k.leaf FROM qc_eyeleaf k WHERE k.ent = :e AND k.x = :bx AND k.y = :by_ AND k.z = :bz INTO wm;
          IF (wm IS NULL) THEN
          BEGIN
            wm = point_leaf(bx, by_, bz);
            UPDATE OR INSERT INTO qc_eyeleaf (ent, x, y, z, leaf) VALUES (:e, :bx, :by_, :bz, :wm) MATCHING (ent);
          END
          IF (pvs_visible(pv, wm) = 1) THEN c = cc;
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n = 18) THEN                             -- find(start, field, match)
  BEGIN
    s = qc_str(CAST(qc_g(10) AS INTEGER)); i = CAST(qc_g(7) AS INTEGER); c = 0;
    FOR SELECT d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id INTO e DO
      IF (qc_str(CAST(qc_f(e, i) AS INTEGER)) = s) THEN BEGIN c = e; LEAVE; END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n IN (19, 20, 68, 75, 76, 77)) THEN EXECUTE PROCEDURE qc_sg(1, qc_g(4));                  -- precache_*: nothing to do
  ELSE IF (n = 21 OR n = 46) THEN                   -- stuffcmd(client, s), localcmd(s): "bf" is the pickup flash
  BEGIN
    s = qc_str(CAST(qc_g(IIF(n = 21, 7, 4)) AS INTEGER));
    EXECUTE PROCEDURE qc_print('cmd', s);
    IF (qc_on() = 1 AND s STARTING WITH 'bf' AND (n = 46 OR CAST(qc_g(4) AS INTEGER) = 1)) THEN UPDATE player p SET p.bonus_time = (SELECT g.time_ FROM game g WHERE g.id = 1) WHERE p.id = 1;
    -- localcmd: the console buffer, a line at a time (QuakeC's newline is the two characters backslash-n);
    -- "skill N" is what trigger_setskill sends, read by cvar("skill") from the next frame on
    IF (n = 46) THEN
    BEGIN
      UPDATE qc_vm v SET v.cmdbuf = SUBSTRING(v.cmdbuf || :s FROM 1 FOR 256) WHERE v.id = 1 RETURNING v.cmdbuf INTO s2;
      i = POSITION('\n', s2);
      IF (i > 0) THEN
      BEGIN
        s = TRIM(SUBSTRING(s2 FROM 1 FOR i - 1));
        UPDATE qc_vm v SET v.cmdbuf = SUBSTRING(:s2 FROM :i + 2) WHERE v.id = 1;
        IF (s SIMILAR TO 'skill [0-3]') THEN UPDATE game g SET g.skill = CAST(SUBSTRING(:s FROM 7) AS SMALLINT) WHERE g.id = 1;
      END
    END
  END
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
  ELSE IF (n = 23) THEN                             -- bprint(s): everyone's message line
  BEGIN
    EXECUTE PROCEDURE qc_print('bprint', qc_str(CAST(qc_g(4) AS INTEGER)));
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE qc_msg(qc_str(CAST(qc_g(4) AS INTEGER)));
  END
  ELSE IF (n = 24) THEN                             -- sprint(client, s)
  BEGIN
    EXECUTE PROCEDURE qc_print('sprint', qc_str(CAST(qc_g(7) AS INTEGER)));
    IF (qc_on() = 1 AND CAST(qc_g(4) AS INTEGER) = 1) THEN EXECUTE PROCEDURE qc_msg(qc_str(CAST(qc_g(7) AS INTEGER)));
  END
  ELSE IF (n = 25) THEN EXECUTE PROCEDURE qc_print('dprint', qc_str(CAST(qc_g(4) AS INTEGER)));
  ELSE IF (n = 26) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_ftos(qc_g(4))));                     -- ftos
  ELSE IF (n = 27) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_vtos(qc_g(4), qc_g(5), qc_g(6))));    -- vtos
  ELSE IF (n IN (28, 29, 30)) THEN BEGIN END         -- coredump, traceon, traceoff
  ELSE IF (n = 31) THEN EXECUTE PROCEDURE qc_print('eprint', 'edict ' || qc_ftos(qc_g(4)));
  ELSE IF (n = 32 AND qc_on() = 1) THEN            -- walkmove(yaw, dist): SV_movestep, touching triggers
  BEGIN
    oself = qc_g(gself); e = CAST(oself AS INTEGER); a = qc_g(4) * 0.0174532925e0; b = qc_g(7);
    ok = 0;
    IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e AND BIN_AND(d.flags, 515) <> 0)) THEN
    BEGIN
      ok = move_step(e, COS(a) * b, SIN(a) * b, 0);
      IF (ok = 1) THEN EXECUTE PROCEDURE qc_touch_triggers(e);
      EXECUTE PROCEDURE qc_sg(gself, oself);
    END
    EXECUTE PROCEDURE qc_sg(1, ok);
  END
  ELSE IF (n = 32) THEN                             -- walkmove(yaw, dist): the step, unchecked
  BEGIN
    e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER); a = qc_g(4) * 0.0174532925e0; b = qc_g(7);
    EXECUTE PROCEDURE qc_sf(e, vm_fo, qc_f(e, vm_fo) + COS(a) * b); EXECUTE PROCEDURE qc_sf(e, vm_fo + 1, qc_f(e, vm_fo + 1) + SIN(a) * b);
    EXECUTE PROCEDURE qc_sg(1, 1);
  END
  ELSE IF (n = 34) THEN                             -- droptofloor(): down to 256 units onto what is below
  BEGIN
    IF (qc_on() = 0) THEN EXECUTE PROCEDURE qc_sg(1, 1);
    ELSE
    BEGIN
      e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER);
      SELECT d.x, d.y, d.z, d.minx, d.miny, d.minz, d.maxx, d.maxy, d.maxz FROM ents d WHERE d.id = :e INTO x, y, z, a, b, c, nx, ny, nz;
      SELECT t.fraction, t.ex, t.ey, t.ez, t.allsolid, t.hit_ent FROM trace_move(:e, :a, :b, :c, :nx, :ny, :nz, :x, :y, :z, :x, :y, :z - 256, 0) t
        INTO frac, ex, ey, ez, alls, hit;
      IF (frac = 1 OR alls = 1) THEN EXECUTE PROCEDURE qc_sg(1, 0);
      ELSE
      BEGIN
        UPDATE ents d SET d.x = :ex, d.y = :ey, d.z = :ez, d.flags = BIN_OR(d.flags, 512) WHERE d.id = :e;
        EXECUTE PROCEDURE link_ent(e);
        EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_groundentity FROM qc_vm v WHERE v.id = 1), hit);
        EXECUTE PROCEDURE qc_sg(1, 1);
      END
    END
  END
  ELSE IF (n = 35) THEN                             -- lightstyle(style, value)
    UPDATE OR INSERT INTO lightstyles (style, pattern) VALUES (CAST(qc_g(4) AS INTEGER), qc_str(CAST(qc_g(7) AS INTEGER))) MATCHING (style);
  ELSE IF (n = 36) THEN EXECUTE PROCEDURE qc_sg(1, IIF(qc_g(4) > 0, FLOOR(qc_g(4) + 0.5e0), CEIL(qc_g(4) - 0.5e0)));   -- rint
  ELSE IF (n = 37) THEN EXECUTE PROCEDURE qc_sg(1, FLOOR(qc_g(4)));
  ELSE IF (n = 38) THEN EXECUTE PROCEDURE qc_sg(1, CEIL(qc_g(4)));
  ELSE IF (n = 40) THEN                             -- checkbottom(e): SV_CheckBottom, every corner on something
  BEGIN
    ok = 1;
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(4) AS INTEGER);
      SELECT d.x + d.minx, d.y + d.miny, d.z + d.minz, d.x + d.maxx, d.y + d.maxy FROM ents d WHERE d.id = :e INTO x, y, z, a, b;
      IF (point_contents(x, y, z - 1) <> -2 OR point_contents(x, b, z - 1) <> -2 OR point_contents(a, y, z - 1) <> -2 OR point_contents(a, b, z - 1) <> -2) THEN
      BEGIN
        -- the real check: the middle's floor within a step below, and no corner more than a step below it
        SELECT t.fraction, t.ez FROM trace_move(:e, 0, 0, 0, 0, 0, 0, (:x + :a) / 2, (:y + :b) / 2, :z, (:x + :a) / 2, (:y + :b) / 2, :z - 36, 1) t INTO frac, cur;
        IF (frac = 1) THEN ok = 0;
        ELSE
        BEGIN
          best = cur;
          FOR SELECT IIF(r.k < 2, :x, :a), IIF(MOD(r.k, 2) = 0, :y, :b) FROM (SELECT 0 k FROM rdb$database UNION ALL SELECT 1 FROM rdb$database UNION ALL SELECT 2 FROM rdb$database UNION ALL SELECT 3 FROM rdb$database) r INTO bx, by_ DO
          BEGIN
            SELECT t.fraction, t.ez FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :bx, :by_, :z, :bx, :by_, :z - 36, 1) t INTO frac, ideal;
            IF (frac < 1 AND ideal > best) THEN best = ideal;
            IF (frac = 1 OR cur - ideal > 18) THEN ok = 0;
          END
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, ok);
  END
  ELSE IF (n = 41) THEN                             -- pointcontents(v)
    EXECUTE PROCEDURE qc_sg(1, IIF(EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.world_model IS NOT NULL), point_contents(qc_g(4), qc_g(5), qc_g(6)), -1));
  ELSE IF (n = 43) THEN EXECUTE PROCEDURE qc_sg(1, ABS(qc_g(4)));
  ELSE IF (n = 44) THEN                             -- aim(e, speed): PF_aim, straight ahead unless a target is within the autoaim cone
  BEGIN
    a = qc_g(vm_fwd); b = qc_g(vm_fwd + 1); c = qc_g(vm_fwd + 2);
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(4) AS INTEGER);
      SELECT d.x, d.y, d.z + 20 FROM ents d WHERE d.id = :e INTO x, y, z;
      i = qc_fdef('takedamage');
      SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :x + :a * 2048, :y + :b * 2048, :z + :c * 2048, 0) t INTO hit;
      IF (hit IS NULL OR hit = 0 OR qc_f(hit, i) <> 2) THEN
      BEGIN
        best = 0.93e0; bent = 0;
        FOR SELECT d.id, d.x + (d.minx + d.maxx) * 0.5e0, d.y + (d.miny + d.maxy) * 0.5e0, d.z + (d.minz + d.maxz) * 0.5e0 FROM ents d
             WHERE d.id <> :e AND d.solid <> 0 AND qc_f(d.id, :i) = 2 INTO hit, bx, by_, bz DO
        BEGIN
          mv = SQRT((bx - x) * (bx - x) + (by_ - y) * (by_ - y) + (bz - z) * (bz - z));
          IF (mv = 0) THEN CONTINUE;
          cur = ((bx - x) * a + (by_ - y) * b + (bz - z) * c) / mv;
          IF (cur < best) THEN CONTINUE;
          SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :bx, :by_, :bz, 0) t INTO th;
          IF (th = hit) THEN BEGIN best = cur; bent = hit; END
        END
        IF (bent > 0) THEN
        BEGIN
          SELECT d.x - :x, d.y - :y, d.z - (:z - 20) FROM ents d WHERE d.id = :bent INTO bx, by_, bz;
          mv = bx * a + by_ * b + bz * c;
          bx = a * mv; by_ = b * mv;
          mv = SQRT(bx * bx + by_ * by_ + bz * bz);
          IF (mv > 0) THEN BEGIN a = bx / mv; b = by_ / mv; c = bz / mv; END
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, a); EXECUTE PROCEDURE qc_sg(2, b); EXECUTE PROCEDURE qc_sg(3, c);
  END
  ELSE IF (n = 45) THEN                             -- cvar(name)
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER));
    EXECUTE PROCEDURE qc_sg(1, CASE s WHEN 'skill' THEN COALESCE((SELECT g.skill FROM game g WHERE g.id = 1), 1) WHEN 'sv_gravity' THEN COALESCE((SELECT g.gravity FROM game g WHERE g.id = 1), 800) WHEN 'sv_maxspeed' THEN 320 WHEN 'sv_friction' THEN 4 WHEN 'sv_accelerate' THEN 10 WHEN 'sv_stopspeed' THEN 100 WHEN 'sv_nostep' THEN 0 WHEN 'registered' THEN COALESCE((SELECT g.registered FROM game g WHERE g.id = 1), 0)
      WHEN 'deathmatch' THEN COALESCE((SELECT g.deathmatch FROM game g WHERE g.id = 1), 0) WHEN 'coop' THEN COALESCE((SELECT g.coop FROM game g WHERE g.id = 1), 0)
      WHEN 'fraglimit' THEN COALESCE((SELECT g.fraglimit FROM game g WHERE g.id = 1), 0) WHEN 'timelimit' THEN COALESCE((SELECT g.timelimit FROM game g WHERE g.id = 1), 0)
      ELSE 0 END);
  END
  ELSE IF (n = 47) THEN                             -- nextent(e)
    EXECUTE PROCEDURE qc_sg(1, COALESCE((SELECT FIRST 1 d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id), 0));
  ELSE IF (n = 48) THEN                             -- particle(org, dir, color, count): blood is colour 73
  BEGIN
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE fx(IIF(qc_g(10) = 73, 3, 1), qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9), CAST(qc_g(13) AS INTEGER));
  END
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
  ELSE IF (n BETWEEN 52 AND 59) THEN               -- WriteByte … WriteEntity: temp entities (as fx_events), and the client messages the page shows
  BEGIN
    IF (qc_on() = 1) THEN
    BEGIN
      SELECT v.te_state, v.te_type, v.te_n FROM qc_vm v WHERE v.id = 1 INTO tst, tty, tn;
      IF (n = 52 AND tst = 0 AND qc_g(7) = 23) THEN UPDATE qc_vm v SET v.te_state = 1 WHERE v.id = 1;     -- SVC_TEMPENTITY
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 30) THEN                                                   -- SVC_INTERMISSION: the stats
        UPDATE game g SET g.intermission = 1, g.completed_time = (SELECT v.sv_time FROM qc_vm v WHERE v.id = 1) WHERE g.id = 1;
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 31) THEN                                                   -- SVC_FINALE: a string follows
      BEGIN
        UPDATE qc_vm v SET v.te_state = 10 WHERE v.id = 1;
        UPDATE game g SET g.intermission = 2, g.finale_text = '', g.completed_time = IIF(g.intermission = 0, (SELECT v.sv_time FROM qc_vm v WHERE v.id = 1), g.completed_time) WHERE g.id = 1;
      END
      ELSE IF (n = 58 AND tst = 10) THEN                                                                   -- the finale's text
      BEGIN
        UPDATE game g SET g.finale_text = SUBSTRING(REPLACE(qc_str(CAST(qc_g(7) AS INTEGER)), '\n', ASCII_CHAR(10)) FROM 1 FOR 1024) WHERE g.id = 1;
        UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
      END
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 32) THEN UPDATE qc_vm v SET v.te_state = 11 WHERE v.id = 1;   -- SVC_CDTRACK: the track, then the loop track
      ELSE IF (n = 52 AND tst = 11) THEN
      BEGIN
        UPDATE game g SET g.cdtrack = CAST(qc_g(7) AS SMALLINT) WHERE g.id = 1;
        UPDATE qc_vm v SET v.te_state = 12 WHERE v.id = 1;
      END
      ELSE IF (n = 52 AND tst = 12) THEN UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
      ELSE IF (n = 52 AND tst = 1) THEN UPDATE qc_vm v SET v.te_state = 2, v.te_type = CAST(qc_g(7) AS SMALLINT), v.te_n = 0 WHERE v.id = 1;
      ELSE IF (n = 56 AND tst = 2) THEN
      BEGIN
        UPDATE qc_vm v SET v.te_c0 = IIF(:tn = 0, qc_g(7), v.te_c0), v.te_c1 = IIF(:tn = 1, qc_g(7), v.te_c1), v.te_c2 = IIF(:tn = 2, qc_g(7), v.te_c2),
                           v.te_c3 = IIF(:tn = 3, qc_g(7), v.te_c3), v.te_c4 = IIF(:tn = 4, qc_g(7), v.te_c4), v.te_c5 = IIF(:tn = 5, qc_g(7), v.te_c5),
                           v.te_n = v.te_n + 1 WHERE v.id = 1;
        IF (tn + 1 = IIF(tty IN (5, 6, 9), 6, 3)) THEN
        BEGIN
          -- TE_SPIKE, SUPERSPIKE, WIZSPIKE, KNIGHTSPIKE: a spike hit; GUNSHOT: a puff; EXPLOSION; TAREXPLOSION; the LIGHTNINGs: a beam; LAVASPLASH; TELEPORT
          SELECT v.te_c0, v.te_c1, v.te_c2, v.te_c3, v.te_c4, v.te_c5 FROM qc_vm v WHERE v.id = 1 INTO x, y, z, a, b, c;
          IF (tty IN (5, 6, 9)) THEN EXECUTE PROCEDURE fx(4, x, y, z, a, b, c, 0);
          ELSE EXECUTE PROCEDURE fx(CASE tty WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 8 WHEN 10 THEN 7 WHEN 11 THEN 5 ELSE 6 END, x, y, z, 0, 0, 0, 0);
          UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
        END
      END
      ELSE IF (n = 52 AND tst = 2) THEN UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;    -- a byte where a coordinate was due: give up
    END
  END
  ELSE IF (n = 67) THEN                             -- movetogoal(dist): SV_MoveToGoal (step towards the goal, or a new chase direction)
  BEGIN
    IF (qc_on() = 1) THEN
    BEGIN
      oself = qc_g(gself); e = CAST(oself AS INTEGER);
      IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e AND BIN_AND(d.flags, 515) <> 0)) THEN
      BEGIN
        EXECUTE PROCEDURE move_to_goal(e, qc_g(4));
        IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN EXECUTE PROCEDURE qc_touch_triggers(e);
        EXECUTE PROCEDURE qc_sg(gself, oself);
      END
    END
  END
  ELSE IF (n = 69) THEN                             -- makestatic(e): drawn from now on as a static entity, the edict freed
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    -- SV_MakeStatic_f's baseline: the model, frame, skin, origin and angles, in an ents row of their own above the
    -- edicts (not solid, never thinks), which the renderer draws like any other
    IF (qc_on() = 1) THEN
      INSERT INTO ents (id, classname, model_id, frame, skin, effects, x, y, z, pitch, yaw, roll, solid, movetype, leaf, leafs)
      SELECT 500000 + GEN_ID(ent_seq, 1), 'static', d.model_id, d.frame, d.skin, d.effects, d.x, d.y, d.z, d.pitch, d.yaw, d.roll, 0, 0, d.leaf, d.leafs
        FROM ents d WHERE d.id = :e AND d.model_id IS NOT NULL;
    EXECUTE PROCEDURE qc_free(e);
  END
  ELSE IF (n = 70) THEN                             -- changelevel(map): the first one counts (svs.changelevel_issued)
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER));
    EXECUTE PROCEDURE qc_print('changelevel', s);
    IF (qc_on() = 1) THEN UPDATE game g SET g.next_map = SUBSTRING(:s FROM 1 FOR 32), g.exit_kind = 1 WHERE g.id = 1 AND g.exit_kind = 0;
  END
  ELSE IF (n = 72) THEN                             -- cvar_set(name, value): sv_gravity is the one the progs set
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER)); s2 = qc_str(CAST(qc_g(7) AS INTEGER));
    EXECUTE PROCEDURE qc_print('cvar_set', s || ' ' || s2);
    IF (s = 'sv_gravity') THEN UPDATE game g SET g.gravity = CAST(:s2 AS DOUBLE PRECISION) WHERE g.id = 1;
  END
  ELSE IF (n = 73) THEN                             -- centerprint(client, s)
  BEGIN
    EXECUTE PROCEDURE qc_print('centerprint', qc_str(CAST(qc_g(7) AS INTEGER)));
    IF (qc_on() = 1 AND CAST(qc_g(4) AS INTEGER) = 1) THEN EXECUTE PROCEDURE cprint(SUBSTRING(REPLACE(qc_str(CAST(qc_g(7) AS INTEGER)), '\n', ASCII_CHAR(10)) FROM 1 FOR 200));
  END
  ELSE IF (n = 74) THEN EXECUTE PROCEDURE qc_print('ambientsound', qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 78) THEN BEGIN END                    -- setspawnparms
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

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
DECLARE wt DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE sp DOUBLE PRECISION; DECLARE lp DOUBLE PRECISION; DECLARE hl INTEGER; DECLARE li INTEGER; DECLARE st INTEGER; DECLARE so INTEGER; DECLARE dm DOUBLE PRECISION; DECLARE hg DOUBLE PRECISION; DECLARE cn INTEGER; DECLARE wtype INTEGER;
DECLARE dmatch SMALLINT;
DECLARE kk VARCHAR(64); DECLARE kv VARCHAR(2048) CHARACTER SET ASCII; DECLARE ktp SMALLINT; DECLARE kofs INTEGER; DECLARE kp1 INTEGER; DECLARE kp2 INTEGER;
BEGIN
  spawned = 0; failed = 0; skipped = 0;
  skillbit = CASE skill WHEN 0 THEN 256 WHEN 1 THEN 512 ELSE 1024 END;
  dmatch = COALESCE((SELECT g.deathmatch FROM game g WHERE g.id = 1), 0);
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
    -- ED_LoadFromFile: in deathmatch only NOT_DEATHMATCH (2048) drops an entity, else the skill's bit
    IF (cls <> 'worldspawn' AND BIN_AND(sf, IIF(:dmatch <> 0, 2048, skillbit)) <> 0) THEN BEGIN skipped = skipped + 1; CONTINUE; END
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
    -- ED_ParseEpair for every other key that names a field: a string, a float, a vector, a function
    -- (keys starting with _ are the compiler's, and an entity field cannot be written in a map)
    FOR SELECT k.k, k.v, d.type_, d.ofs FROM map_keys k JOIN qc_defs d ON d.kind = 1 AND d.name = k.k
         WHERE k.ent = :mid AND k.k NOT STARTING WITH '_' AND k.k NOT IN ('classname', 'targetname', 'target', 'killtarget', 'model', 'message', 'map',
               'noise', 'origin', 'angle', 'angles', 'mangle', 'spawnflags', 'wait', 'delay', 'speed', 'lip', 'health', 'light', 'style', 'sounds', 'dmg',
               'height', 'count', 'worldtype')
          INTO kk, kv, ktp, kofs DO
    BEGIN
      IF (ktp = 1) THEN EXECUTE PROCEDURE qc_set_str(e, kofs, kv);
      ELSE IF (ktp = 2) THEN EXECUTE PROCEDURE qc_set_num(e, kofs, CAST(TRIM(kv) AS DOUBLE PRECISION));
      ELSE IF (ktp = 3) THEN
      BEGIN
        kv = TRIM(kv) || ' 0 0'; kp1 = POSITION(' ', kv); kp2 = POSITION(' ', kv, kp1 + 1);
        EXECUTE PROCEDURE qc_set_num(e, kofs, CAST(SUBSTRING(kv FROM 1 FOR kp1 - 1) AS DOUBLE PRECISION));
        EXECUTE PROCEDURE qc_set_num(e, kofs + 1, CAST(SUBSTRING(kv FROM kp1 + 1 FOR kp2 - kp1 - 1) AS DOUBLE PRECISION));
        EXECUTE PROCEDURE qc_set_num(e, kofs + 2, CAST(SUBSTRING(kv FROM kp2 + 1 FOR POSITION(' ', kv || ' ', kp2 + 1) - kp2 - 1) AS DOUBLE PRECISION));
      END
      ELSE IF (ktp = 6) THEN EXECUTE PROCEDURE qc_set_num(e, kofs, COALESCE(qc_fn(TRIM(kv)), 0));
    WHEN ANY DO
      EXECUTE PROCEDURE qc_print('dprint', 'Can''t parse ' || kk || ' "' || SUBSTRING(kv FROM 1 FOR 60) || '" of map entity ' || mid);
    END
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

-- a client in edict c (1 is the page's player, 2 and up the bots, sql/bots.sql): SetNewParms for a new game
-- (carry = 0; otherwise the parms carried over are in the globals already), ClientConnect, PutClientInServer
CREATE OR ALTER PROCEDURE qc_client_join_n (c INTEGER, t DOUBLE PRECISION, carry SMALLINT, name VARCHAR(32))
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE f INTEGER;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_other, 0);
  UPDATE OR INSERT INTO qc_edicts (id, free) VALUES (:c, 0) MATCHING (id);
  DELETE FROM qc_fields x WHERE x.ent = :c;
  IF (qc_on() = 1) THEN
  BEGIN
    DELETE FROM ents x WHERE x.id = :c;
    INSERT INTO ents (id, classname) VALUES (:c, 'player');
  END
  EXECUTE PROCEDURE qc_set_str(c, qc_fdef('netname'), name);
  EXECUTE PROCEDURE qc_sg(g_self, c);
  IF (carry = 0) THEN
  BEGIN
    f = qc_fn('SetNewParms'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  END
  EXECUTE PROCEDURE qc_sg(g_self, c);
  f = qc_fn('ClientConnect'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, c);
  f = qc_fn('PutClientInServer'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

CREATE OR ALTER PROCEDURE qc_client_join (t DOUBLE PRECISION, carry SMALLINT)
AS
BEGIN
  EXECUTE PROCEDURE qc_client_join_n(1, t, carry, 'player');
END^

CREATE OR ALTER PROCEDURE qc_client_connect (t DOUBLE PRECISION)
AS
BEGIN
  EXECUTE PROCEDURE qc_client_join(t, 0);
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


-- ── the server's physics on QuakeC edicts (sv_phys.c, sv_user.c), in QuakeC mode ──

-- SV_Impact: both sides' touch, when they are solid. Called by the physics through impact().
CREATE OR ALTER PROCEDURE qc_impact (e1 INTEGER, e2 INTEGER)
AS
DECLARE f INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE f_touch INTEGER; DECLARE svt DOUBLE PRECISION;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time, v.f_touch, v.sv_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, f_touch, svt;
  EXECUTE PROCEDURE qc_sg(g_time, svt);
  IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :e1 AND e.solid <> 0)) THEN
  BEGIN
    f = CAST(qc_f(e1, f_touch) AS INTEGER);
    IF (f <> 0) THEN BEGIN EXECUTE PROCEDURE qc_sg(g_self, e1); EXECUTE PROCEDURE qc_sg(g_other, e2); EXECUTE PROCEDURE qc_call(f); END
  END
  IF (e2 > 0 AND EXISTS (SELECT 1 FROM ents e WHERE e.id = :e2 AND e.solid <> 0)) THEN
  BEGIN
    f = CAST(qc_f(e2, f_touch) AS INTEGER);
    IF (f <> 0) THEN BEGIN EXECUTE PROCEDURE qc_sg(g_self, e2); EXECUTE PROCEDURE qc_sg(g_other, e1); EXECUTE PROCEDURE qc_call(f); END
  END
END^

-- a pusher's .blocked, called by push_move() through mover_blocked()
CREATE OR ALTER PROCEDURE qc_blocked (eid INTEGER, other INTEGER)
AS
DECLARE f INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE svt DOUBLE PRECISION;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time, v.sv_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, svt;
  f = CAST(qc_f(eid, (SELECT v.f_blocked FROM qc_vm v WHERE v.id = 1)) AS INTEGER);
  IF (f = 0) THEN EXIT;
  EXECUTE PROCEDURE qc_sg(g_time, svt); EXECUTE PROCEDURE qc_sg(g_self, eid); EXECUTE PROCEDURE qc_sg(g_other, other);
  EXECUTE PROCEDURE qc_call(f);
END^

-- SV_TouchLinks: every trigger whose absolute box meets the entity's gets touched by it
CREATE OR ALTER PROCEDURE qc_touch_triggers (e INTEGER)
AS
DECLARE x0 DOUBLE PRECISION; DECLARE y0 DOUBLE PRECISION; DECLARE z0 DOUBLE PRECISION;
DECLARE x1 DOUBLE PRECISION; DECLARE y1 DOUBLE PRECISION; DECLARE z1 DOUBLE PRECISION;
DECLARE sol SMALLINT; DECLARE tr INTEGER; DECLARE f INTEGER;
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE f_touch INTEGER; DECLARE svt DOUBLE PRECISION;
BEGIN
  SELECT d.solid, d.x + d.minx - IIF(BIN_AND(d.flags, 256) <> 0, 15, 1), d.y + d.miny - IIF(BIN_AND(d.flags, 256) <> 0, 15, 1), d.z + d.minz - 1,
         d.x + d.maxx + IIF(BIN_AND(d.flags, 256) <> 0, 15, 1), d.y + d.maxy + IIF(BIN_AND(d.flags, 256) <> 0, 15, 1), d.z + d.maxz + 1
    FROM ents d WHERE d.id = :e INTO sol, x0, y0, z0, x1, y1, z1;
  IF (sol IS NULL OR sol = 0) THEN EXIT;
  SELECT v.g_self, v.g_other, v.g_time, v.f_touch, v.sv_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, f_touch, svt;
  FOR SELECT t.id FROM ents t
       WHERE t.solid = 1 AND t.id <> :e
         AND t.x + t.maxx + IIF(BIN_AND(t.flags, 256) <> 0, 15, 1) >= :x0 AND t.x + t.minx - IIF(BIN_AND(t.flags, 256) <> 0, 15, 1) <= :x1
         AND t.y + t.maxy + IIF(BIN_AND(t.flags, 256) <> 0, 15, 1) >= :y0 AND t.y + t.miny - IIF(BIN_AND(t.flags, 256) <> 0, 15, 1) <= :y1
         AND t.z + t.maxz + 1 >= :z0 AND t.z + t.minz - 1 <= :z1
       ORDER BY t.id
       INTO tr DO
  BEGIN
    IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN EXIT;              -- removed by an earlier touch
    IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :tr AND d.solid = 1)) THEN CONTINUE;
    f = CAST(qc_f(tr, f_touch) AS INTEGER);
    IF (f = 0) THEN CONTINUE;
    UPDATE qc_globals g SET g.v = CASE g.ofs WHEN :g_time THEN :svt WHEN :g_self THEN :tr ELSE :e END WHERE g.ofs IN (:g_time, :g_self, :g_other);
    EXECUTE PROCEDURE qc_call(f);
  END
END^

-- SV_RunThink: the think, if it is due in this frame, at its own time; alive = 0 if it removed itself
CREATE OR ALTER PROCEDURE qc_run_think (e INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
RETURNS (alive SMALLINT)
AS
DECLARE nt DOUBLE PRECISION; DECLARE f INTEGER;
DECLARE f_nt INTEGER; DECLARE f_think INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER;
BEGIN
  alive = 1;
  SELECT v.f_nextthink, v.f_think, v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO f_nt, f_think, g_self, g_other, g_time;
  -- nextthink and think are never the engine's columns: both from qc_fields at once
  SELECT COALESCE(MAX(IIF(q.ofs = :f_nt, q.v, NULL)), 0), CAST(COALESCE(MAX(IIF(q.ofs = :f_think, q.v, NULL)), 0) AS INTEGER)
    FROM qc_fields q WHERE q.ent = :e AND q.ofs IN (:f_nt, :f_think) INTO nt, f;
  IF (nt <= 0 OR nt > t + dt + 1e-6) THEN EXIT;
  IF (nt < t) THEN nt = t;
  UPDATE qc_fields q SET q.v = 0 WHERE q.ent = :e AND q.ofs = :f_nt;
  -- time, self and other in one statement
  UPDATE qc_globals g SET g.v = CASE g.ofs WHEN :g_time THEN :nt WHEN :g_self THEN :e ELSE 0 END WHERE g.ofs IN (:g_time, :g_self, :g_other);
  IF (f <> 0) THEN EXECUTE PROCEDURE qc_call(f);
  alive = IIF(EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = :e AND d.free = 0), 1, 0);
END^

-- SV_CheckVelocity
CREATE OR ALTER PROCEDURE qc_clamp_velocity (e INTEGER)
AS
BEGIN
  UPDATE ents d SET d.vx = MAXVALUE(-2000, MINVALUE(2000, d.vx)), d.vy = MAXVALUE(-2000, MINVALUE(2000, d.vy)), d.vz = MAXVALUE(-2000, MINVALUE(2000, d.vz))
    WHERE d.id = :e AND (ABS(d.vx) > 2000 OR ABS(d.vy) > 2000 OR ABS(d.vz) > 2000);
END^

-- SV_AddGravity, with the entity's own gravity scale (0 = 1)
CREATE OR ALTER PROCEDURE qc_add_gravity (e INTEGER, dt DOUBLE PRECISION)
AS
DECLARE gs DOUBLE PRECISION;
BEGIN
  gs = qc_f(e, (SELECT v.f_gravity FROM qc_vm v WHERE v.id = 1));
  IF (gs = 0) THEN gs = 1;
  UPDATE ents d SET d.vz = d.vz - :gs * (SELECT g.gravity FROM game g WHERE g.id = 1) * :dt WHERE d.id = :e;
END^

-- SV_Physics_Pusher: the move runs on the pusher's own clock (ltime), and so does its think
CREATE OR ALTER PROCEDURE qc_physics_pusher (e INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
AS
DECLARE oldlt DOUBLE PRECISION; DECLARE lt DOUBLE PRECISION; DECLARE thinktime DOUBLE PRECISION; DECLARE movetime DOUBLE PRECISION; DECLARE f INTEGER;
DECLARE f_nt INTEGER; DECLARE f_think INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER;
BEGIN
  SELECT v.f_nextthink, v.f_think, v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO f_nt, f_think, g_self, g_other, g_time;
  SELECT d.ltime FROM ents d WHERE d.id = :e INTO oldlt;
  thinktime = qc_f(e, f_nt);
  IF (thinktime < oldlt + dt) THEN
  BEGIN
    movetime = thinktime - oldlt;
    IF (movetime < 0) THEN movetime = 0;
  END
  ELSE movetime = dt;
  IF (movetime > 0) THEN EXECUTE PROCEDURE push_move(e, movetime);
  SELECT d.ltime FROM ents d WHERE d.id = :e INTO lt;
  IF (lt IS NULL) THEN EXIT;
  IF (thinktime > oldlt AND thinktime <= lt + 1e-6) THEN
  BEGIN
    EXECUTE PROCEDURE qc_sf(e, f_nt, 0);
    f = CAST(qc_f(e, f_think) AS INTEGER);
    EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_self, e); EXECUTE PROCEDURE qc_sg(g_other, 0);
    IF (f <> 0) THEN EXECUTE PROCEDURE qc_call(f);
  END
END^

-- SV_Physics_Toss for TOSS, BOUNCE, FLY and FLYMISSILE (after the think)
CREATE OR ALTER PROCEDURE qc_toss (e INTEGER, dt DOUBLE PRECISION)
AS
DECLARE mt SMALLINT; DECLARE fl INTEGER;
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE hit INTEGER; DECLARE cb SMALLINT;
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE fav INTEGER;
BEGIN
  SELECT d.movetype, d.flags FROM ents d WHERE d.id = :e INTO mt, fl;
  IF (mt IS NULL OR BIN_AND(fl, 512) <> 0) THEN EXIT;
  EXECUTE PROCEDURE qc_clamp_velocity(e);
  IF (mt IN (6, 10)) THEN EXECUTE PROCEDURE qc_add_gravity(e, dt);
  fav = (SELECT v.f_avelocity FROM qc_vm v WHERE v.id = 1);
  UPDATE ents d SET d.pitch = d.pitch + qc_f(:e, :fav) * :dt, d.yaw = d.yaw + d.avel_yaw * :dt, d.roll = d.roll + qc_f(:e, :fav + 2) * :dt WHERE d.id = :e;
  SELECT d.vx, d.vy, d.vz FROM ents d WHERE d.id = :e INTO vx, vy, vz;
  EXECUTE PROCEDURE push_entity(e, vx * dt, vy * dt, vz * dt) RETURNING_VALUES f, nx, ny, nz, als, sts, hit;   -- impact() runs the touches
  IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN EXIT;
  EXECUTE PROCEDURE link_ent(e);
  EXECUTE PROCEDURE qc_touch_triggers(e);
  IF (f = 1 OR NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN EXIT;
  -- the touch may have changed the velocity and the movetype: use them as they are now
  SELECT d.movetype, d.vx, d.vy, d.vz FROM ents d WHERE d.id = :e INTO mt, vx, vy, vz;
  EXECUTE PROCEDURE clip_velocity(vx, vy, vz, nx, ny, nz, IIF(mt = 10, 1.5e0, 1)) RETURNING_VALUES ox, oy, oz, cb;
  IF (nz > 0.7e0 AND (oz < 60 OR mt <> 10)) THEN
  BEGIN
    UPDATE ents d SET d.flags = BIN_OR(d.flags, 512), d.vx = 0, d.vy = 0, d.vz = 0, d.avel_yaw = 0 WHERE d.id = :e;
    EXECUTE PROCEDURE qc_sf(e, fav, 0); EXECUTE PROCEDURE qc_sf(e, fav + 2, 0);
    EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_groundentity FROM qc_vm v WHERE v.id = 1), hit);
  END
  ELSE UPDATE ents d SET d.vx = :ox, d.vy = :oy, d.vz = :oz WHERE d.id = :e;
END^

-- SV_Physics_Step: monsters fall when nothing holds them, then think
CREATE OR ALTER PROCEDURE qc_physics_step (e INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
AS
DECLARE fl INTEGER; DECLARE vz DOUBLE PRECISION; DECLARE hitsound SMALLINT; DECLARE blk SMALLINT; DECLARE hit INTEGER; DECLARE alive SMALLINT;
BEGIN
  SELECT d.flags, d.vz FROM ents d WHERE d.id = :e INTO fl, vz;
  IF (BIN_AND(fl, 515) = 0) THEN                    -- not FL_ONGROUND, FL_FLY or FL_SWIM
  BEGIN
    hitsound = IIF(vz < (SELECT g.gravity FROM game g WHERE g.id = 1) * -0.1e0, 1, 0);
    EXECUTE PROCEDURE qc_add_gravity(e, dt);
    EXECUTE PROCEDURE qc_clamp_velocity(e);
    EXECUTE PROCEDURE fly_move(e, dt) RETURNING_VALUES blk, hit;
    IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN
    BEGIN
      EXECUTE PROCEDURE link_ent(e);
      EXECUTE PROCEDURE qc_touch_triggers(e);
      IF (hitsound = 1 AND EXISTS (SELECT 1 FROM ents d WHERE d.id = :e AND BIN_AND(d.flags, 512) <> 0)) THEN
        EXECUTE PROCEDURE snd(e, 0, 'demon/dland2.wav', 1, 1);
    END
  END
  EXECUTE PROCEDURE qc_run_think(e, t, dt) RETURNING_VALUES alive;
END^

-- SV_ClientThink (sv_user.c): the input into the client's fields, its view angles, and its movement
-- intent: ground friction and acceleration, air acceleration, or swimming
CREATE OR ALTER PROCEDURE qc_client_think (c INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION, fmove DOUBLE PRECISION, smove DOUBLE PRECISION, upmove DOUBLE PRECISION,
  pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, impulse SMALLINT)
AS
DECLARE mt SMALLINT; DECLARE fl INTEGER; DECLARE wl SMALLINT; DECLARE onground SMALLINT;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE fpa INTEGER; DECLARE a0 DOUBLE PRECISION; DECLARE a1 DOUBLE PRECISION; DECLARE a2 DOUBLE PRECISION; DECLARE len DOUBLE PRECISION; DECLARE len2 DOUBLE PRECISION;
DECLARE ap DOUBLE PRECISION; DECLARE ay DOUBLE PRECISION; DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION;
DECLARE wx DOUBLE PRECISION; DECLARE wy DOUBLE PRECISION; DECLARE wz DOUBLE PRECISION; DECLARE ws DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION;
DECLARE speed DOUBLE PRECISION; DECLARE newspeed DOUBLE PRECISION; DECLARE control DOUBLE PRECISION; DECLARE friction DOUBLE PRECISION;
DECLARE cur DOUBLE PRECISION; DECLARE addspeed DOUBLE PRECISION; DECLARE accelspeed DOUBLE PRECISION; DECLARE wishspd DOUBLE PRECISION;
DECLARE tf DOUBLE PRECISION; DECLARE va INTEGER;
BEGIN
  IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :c) OR NOT EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = :c AND d.free = 0)) THEN EXIT;
  -- SV_ReadClientMove: the buttons, the impulse, the view angles
  EXECUTE PROCEDURE qc_sf(c, qc_fdef('button0'), fire);
  EXECUTE PROCEDURE qc_sf(c, qc_fdef('button2'), jump);
  IF (impulse <> 0) THEN EXECUTE PROCEDURE qc_sf(c, qc_fdef('impulse'), impulse);
  va = (SELECT v.f_v_angle FROM qc_vm v WHERE v.id = 1);
  EXECUTE PROCEDURE qc_sf(c, va, pitch); EXECUTE PROCEDURE qc_sf(c, va + 1, yaw); EXECUTE PROCEDURE qc_sf(c, va + 2, 0);
  SELECT d.movetype, d.flags, d.waterlevel, d.x, d.y, d.z, d.minz, d.vx, d.vy, d.vz FROM ents d WHERE d.id = :c INTO mt, fl, wl, px, py, pz, mnz, vx, vy, vz;
  IF (mt = 0) THEN EXIT;
  onground = IIF(BIN_AND(fl, 512) <> 0, 1, 0);
  -- DropPunchAngle
  fpa = (SELECT v.f_punchangle FROM qc_vm v WHERE v.id = 1);
  a0 = qc_f(c, fpa); a1 = qc_f(c, fpa + 1); a2 = qc_f(c, fpa + 2);
  len = SQRT(a0 * a0 + a1 * a1 + a2 * a2);
  IF (len > 0) THEN
  BEGIN
    len2 = MAXVALUE(0, len - 10 * dt);
    EXECUTE PROCEDURE qc_sf(c, fpa, a0 * len2 / len); EXECUTE PROCEDURE qc_sf(c, fpa + 1, a1 * len2 / len); EXECUTE PROCEDURE qc_sf(c, fpa + 2, a2 * len2 / len);
  END
  IF (qc_f(c, (SELECT v.f_health FROM qc_vm v WHERE v.id = 1)) <= 0) THEN EXIT;
  -- the body turns with the view; the model's pitch is a third of it
  UPDATE ents d SET d.pitch = -:pitch / 3, d.yaw = :yaw, d.roll = 0 WHERE d.id = :c;
  IF (wl >= 2 AND mt <> 8) THEN
  BEGIN
    -- SV_WaterMove: the full view direction, drifting down without input
    ap = pitch * 0.0174532925e0; ay = yaw * 0.0174532925e0;
    fx = COS(ap) * COS(ay); fy = COS(ap) * SIN(ay); fz = -SIN(ap); rx = SIN(ay); ry = -COS(ay);
    wx = fx * fmove + rx * smove; wy = fy * fmove + ry * smove; wz = fz * fmove;
    IF (fmove = 0 AND smove = 0 AND upmove = 0) THEN wz = wz - 60; ELSE wz = wz + upmove;
    ws = SQRT(wx * wx + wy * wy + wz * wz);
    IF (ws > 320) THEN BEGIN wx = wx * 320 / ws; wy = wy * 320 / ws; wz = wz * 320 / ws; ws = 320; END
    ws = ws * 0.7e0;
    speed = SQRT(vx * vx + vy * vy + vz * vz);
    IF (speed > 0) THEN
    BEGIN
      newspeed = MAXVALUE(0, speed - dt * speed * 4);
      vx = vx * newspeed / speed; vy = vy * newspeed / speed; vz = vz * newspeed / speed;
    END
    ELSE newspeed = 0;
    IF (ws > 0) THEN
    BEGIN
      addspeed = ws - newspeed;
      IF (addspeed > 0) THEN
      BEGIN
        len = SQRT(wx * wx + wy * wy + wz * wz);
        accelspeed = MINVALUE(addspeed, 10 * ws * dt);
        vx = vx + accelspeed * wx / len; vy = vy + accelspeed * wy / len; vz = vz + accelspeed * wz / len;
      END
    END
  END
  ELSE
  BEGIN
    -- SV_AirMove: the body's angles (pitch a third of the view's), the wish velocity flat
    IF (t < qc_f(c, (SELECT v.f_teleport_time FROM qc_vm v WHERE v.id = 1)) AND fmove < 0) THEN fmove = 0;
    ap = -pitch / 3 * 0.0174532925e0; ay = yaw * 0.0174532925e0;
    fx = COS(ap) * COS(ay); fy = COS(ap) * SIN(ay); rx = SIN(ay); ry = -COS(ay);
    wx = fx * fmove + rx * smove; wy = fy * fmove + ry * smove; wz = IIF(mt <> 3, upmove, 0);
    ws = SQRT(wx * wx + wy * wy + wz * wz);
    IF (ws > 0) THEN BEGIN dx = wx / ws; dy = wy / ws; dz = wz / ws; END ELSE BEGIN dx = 0; dy = 0; dz = 0; END
    IF (ws > 320) THEN BEGIN wx = wx * 320 / ws; wy = wy * 320 / ws; wz = wz * 320 / ws; ws = 320; END
    IF (mt = 8) THEN BEGIN vx = wx; vy = wy; vz = wz; END
    ELSE IF (onground = 1) THEN
    BEGIN
      -- SV_UserFriction: double friction at an edge
      speed = SQRT(vx * vx + vy * vy);
      IF (speed > 0) THEN
      BEGIN
        SELECT r.fraction FROM trace_move(:c, 0, 0, 0, 0, 0, 0, :px + :vx / :speed * 16, :py + :vy / :speed * 16, :pz + :mnz,
                                             :px + :vx / :speed * 16, :py + :vy / :speed * 16, :pz + :mnz - 34, 1) r INTO tf;
        friction = IIF(tf = 1, 8, 4);
        control = IIF(speed < 100, 100, speed);
        newspeed = MAXVALUE(0, speed - dt * control * friction) / speed;
        vx = vx * newspeed; vy = vy * newspeed; vz = vz * newspeed;
      END
      -- SV_Accelerate
      cur = vx * dx + vy * dy + vz * dz;
      addspeed = ws - cur;
      IF (addspeed > 0) THEN
      BEGIN
        accelspeed = MINVALUE(addspeed, 10 * dt * ws);
        vx = vx + accelspeed * dx; vy = vy + accelspeed * dy; vz = vz + accelspeed * dz;
      END
    END
    ELSE
    BEGIN
      -- SV_AirAccelerate: at most 30 units/s of wish, but the push of the full wish speed
      wishspd = MINVALUE(30, ws);
      cur = vx * dx + vy * dy + vz * dz;
      addspeed = wishspd - cur;
      IF (addspeed > 0) THEN
      BEGIN
        accelspeed = MINVALUE(addspeed, 10 * ws * dt);
        vx = vx + accelspeed * dx; vy = vy + accelspeed * dy; vz = vz + accelspeed * dz;
      END
    END
  END
  UPDATE ents d SET d.vx = :vx, d.vy = :vy, d.vz = :vz WHERE d.id = :c;
END^

-- SV_Physics_Client: PlayerPreThink, the think, gravity unless swimming or water-jumping, the walk with
-- its step, the triggers touched, PlayerPostThink
CREATE OR ALTER PROCEDURE qc_physics_client (c INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
AS
DECLARE f INTEGER; DECLARE mt SMALLINT; DECLARE fl INTEGER; DECLARE alive SMALLINT; DECLARE wl SMALLINT; DECLARE wt INTEGER;
DECLARE blk SMALLINT; DECLARE hit INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER;
BEGIN
  IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :c) OR NOT EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = :c AND d.free = 0)) THEN EXIT;
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_self, c); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPreThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_clamp_velocity(c);
  SELECT d.movetype FROM ents d WHERE d.id = :c INTO mt;
  IF (mt = 3) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(c, t, dt) RETURNING_VALUES alive;
    IF (alive = 0) THEN EXIT;
    EXECUTE PROCEDURE check_water(c) RETURNING_VALUES wl, wt;
    UPDATE ents d SET d.waterlevel = :wl, d.watertype = :wt WHERE d.id = :c;
    SELECT d.flags FROM ents d WHERE d.id = :c INTO fl;
    IF (wl <= 1 AND BIN_AND(fl, 2048) = 0) THEN EXECUTE PROCEDURE qc_add_gravity(c, dt);
    EXECUTE PROCEDURE walk_move(c, dt);
  END
  ELSE IF (mt IN (6, 10)) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(c, t, dt) RETURNING_VALUES alive;
    IF (alive = 1) THEN EXECUTE PROCEDURE qc_toss(c, dt);
  END
  ELSE IF (mt = 5) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(c, t, dt) RETURNING_VALUES alive;
    EXECUTE PROCEDURE fly_move(c, dt) RETURNING_VALUES blk, hit;
  END
  ELSE IF (mt = 8) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(c, t, dt) RETURNING_VALUES alive;
    UPDATE ents d SET d.x = d.x + d.vx * :dt, d.y = d.y + d.vy * :dt, d.z = d.z + d.vz * :dt WHERE d.id = :c;
  END
  ELSE EXECUTE PROCEDURE qc_run_think(c, t, dt) RETURNING_VALUES alive;
  IF (NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :c)) THEN EXIT;
  EXECUTE PROCEDURE link_ent(c);
  IF (mt <> 8) THEN EXECUTE PROCEDURE qc_touch_triggers(c);
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_self, c); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPostThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

-- one edict's physics, by movetype (SV_Physics' switch)
CREATE OR ALTER PROCEDURE qc_physics_ent (e INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
AS
DECLARE mt SMALLINT; DECLARE alive SMALLINT; DECLARE fav INTEGER;
BEGIN
  IF (e >= 1 AND e <= qc_maxclients()) THEN BEGIN EXECUTE PROCEDURE qc_physics_client(e, t, dt); EXIT; END
  SELECT d.movetype FROM ents d WHERE d.id = :e INTO mt;
  IF (e = 0 OR mt IS NULL OR mt IN (0, 3)) THEN EXECUTE PROCEDURE qc_run_think(e, t, dt) RETURNING_VALUES alive;
  ELSE IF (mt = 7) THEN EXECUTE PROCEDURE qc_physics_pusher(e, t, dt);
  ELSE IF (mt = 4) THEN EXECUTE PROCEDURE qc_physics_step(e, t, dt);
  ELSE IF (mt IN (5, 6, 9, 10)) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(e, t, dt) RETURNING_VALUES alive;
    IF (alive = 1) THEN EXECUTE PROCEDURE qc_toss(e, dt);
  END
  ELSE IF (mt = 8) THEN
  BEGIN
    EXECUTE PROCEDURE qc_run_think(e, t, dt) RETURNING_VALUES alive;
    IF (alive = 1) THEN
    BEGIN
      fav = (SELECT v.f_avelocity FROM qc_vm v WHERE v.id = 1);
      UPDATE ents d SET d.x = d.x + d.vx * :dt, d.y = d.y + d.vy * :dt, d.z = d.z + d.vz * :dt,
                        d.pitch = d.pitch + qc_f(:e, :fav) * :dt, d.yaw = d.yaw + d.avel_yaw * :dt, d.roll = d.roll + qc_f(:e, :fav + 2) * :dt WHERE d.id = :e;
      EXECUTE PROCEDURE link_ent(e);
    END
  END
  ELSE EXECUTE PROCEDURE qc_run_think(e, t, dt) RETURNING_VALUES alive;
END^

-- a bot's move for the frame (sql/bots.sql): what SV_ReadClientMove would read from its connection
CREATE OR ALTER PROCEDURE qc_bot_think (c INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
RETURNS (fmove DOUBLE PRECISION, smove DOUBLE PRECISION, upmove DOUBLE PRECISION, pitch DOUBLE PRECISION, yaw DOUBLE PRECISION,
         fire SMALLINT, jump SMALLINT, impulse SMALLINT)
AS BEGIN END^

-- A server frame in QuakeC mode (Host_ServerFrame): the client's move, StartFrame, then every edict's
-- physics in edict order, from time t for dt seconds. The client's input: forward, side and up move
-- (Quake units per second, 400 forward when running), the view pitch and yaw, fire, jump, the impulse.
-- An edict whose QuakeC raises is logged and skipped for the frame.
CREATE OR ALTER PROCEDURE qc_server_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION, fmove DOUBLE PRECISION, smove DOUBLE PRECISION, upmove DOUBLE PRECISION,
  pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, impulse SMALLINT)
RETURNS (ran INTEGER, failed INTEGER)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE g_ft INTEGER; DECLARE f_nt INTEGER; DECLARE f INTEGER;
DECLARE e INTEGER; DECLARE last INTEGER; DECLARE fpa INTEGER;
DECLARE mc INTEGER; DECLARE c INTEGER; DECLARE bf DOUBLE PRECISION; DECLARE bs DOUBLE PRECISION; DECLARE bu DOUBLE PRECISION;
DECLARE bp DOUBLE PRECISION; DECLARE byw DOUBLE PRECISION; DECLARE bfi SMALLINT; DECLARE bj SMALLINT; DECLARE bi SMALLINT;
BEGIN
  ran = 0; failed = 0;
  IF (qc_on() = 0) THEN EXCEPTION qc_error 'qc_server_frame needs QuakeC mode (qc_enter)';
  UPDATE qc_vm v SET v.sv_time = :t WHERE v.id = 1;
  UPDATE game g SET g.tic = g.tic + 1, g.time_ = :t WHERE g.id = 1;
  SELECT v.g_self, v.g_other, v.g_time, v.g_frametime, v.f_nextthink FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, g_ft, f_nt;
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_ft, dt);
  BEGIN
    EXECUTE PROCEDURE qc_client_think(1, t, dt, fmove, smove, upmove, pitch, yaw, fire, jump, impulse);
  WHEN ANY DO
    EXECUTE PROCEDURE qc_print('error', 'client think failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
  END
  -- SV_RunClients for the bots: each one's move from qc_bot_think, as if read from its connection
  mc = qc_maxclients();
  c = 2;
  WHILE (c <= mc) DO
  BEGIN
    IF (EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = :c AND d.free = 0)) THEN
    BEGIN
      bf = 0; bs = 0; bu = 0; bp = 0; byw = 0; bfi = 0; bj = 0; bi = 0;
      SELECT b.fmove, b.smove, b.upmove, b.pitch, b.yaw, b.fire, b.jump, b.impulse FROM qc_bot_think(:c, :t, :dt) b INTO bf, bs, bu, bp, byw, bfi, bj, bi;
      EXECUTE PROCEDURE qc_client_think(c, t, dt, bf, bs, bu, bp, byw, bfi, bj, bi);
    WHEN ANY DO
      EXECUTE PROCEDURE qc_print('error', 'bot ' || c || ' think failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
    END
    c = c + 1;
  END
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_self, 0); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('StartFrame');
  IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  -- the edicts that may have something to do: the world and the client, a pending think, a moving
  -- pusher, anything flying, anything falling
  last = -1;
  WHILE (1 = 1) DO
  BEGIN
    e = NULL;
    SELECT FIRST 1 d.id FROM qc_edicts d
      WHERE d.free = 0 AND d.id > :last AND (
        d.id <= :mc
        OR EXISTS (SELECT 1 FROM qc_fields n WHERE n.ent = d.id AND n.ofs = :f_nt AND n.v > 0 AND n.v <= :t + :dt + 1e-6)
        OR EXISTS (SELECT 1 FROM ents x JOIN qc_fields n ON n.ent = x.id AND n.ofs = :f_nt AND n.v > 0 WHERE x.id = d.id AND x.movetype = 7)
        OR EXISTS (SELECT 1 FROM ents x WHERE x.id = d.id AND (
             (x.movetype IN (7, 5, 9, 8) AND (x.vx <> 0 OR x.vy <> 0 OR x.vz <> 0))
          OR (x.movetype IN (6, 10) AND BIN_AND(x.flags, 512) = 0)
          OR (x.movetype = 4 AND BIN_AND(x.flags, 515) = 0))))
      ORDER BY d.id INTO e;
    IF (e IS NULL) THEN LEAVE;
    last = e;
    BEGIN
      EXECUTE PROCEDURE qc_physics_ent(e, t, dt);
      ran = ran + 1;
    WHEN ANY DO
    BEGIN
      failed = failed + 1;
      UPDATE qc_vm v SET v.depth = 0 WHERE v.id = 1;
      DELETE FROM qc_localstack;
      EXECUTE PROCEDURE qc_print('error', 'edict ' || e || ' failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
    END
    END
  END
  -- the camera: the view pitch and the punch
  fpa = (SELECT v.f_punchangle FROM qc_vm v WHERE v.id = 1);
  UPDATE player p SET p.pitch = :pitch, p.punchangle = qc_f(1, :fpa) WHERE p.id = 1;
  EXECUTE PROCEDURE qc_sg(g_time, t + dt);
  SUSPEND;
END^


-- ── the page in QuakeC mode: a level, its change, and a tic shaped like QUAKE_TIC's ──

-- SV_SaveSpawnparms: SetChangeParms on the client, its parms and serverflags kept for the next level
CREATE OR ALTER PROCEDURE qc_change_parms
AS
DECLARE f INTEGER; DECLARE i INTEGER; DECLARE o INTEGER;
BEGIN
  DELETE FROM qc_saved;
  EXECUTE PROCEDURE qc_sg((SELECT v.g_self FROM qc_vm v WHERE v.id = 1), 1);
  f = qc_fn('SetChangeParms');
  IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  i = 1;
  WHILE (i <= 16) DO
  BEGIN
    o = qc_gdef('parm' || i);
    IF (o IS NOT NULL) THEN INSERT INTO qc_saved (ofs, v) VALUES (:o, qc_g(:o));
    i = i + 1;
  END
  o = qc_gdef('serverflags');
  IF (o IS NOT NULL) THEN INSERT INTO qc_saved (ofs, v) VALUES (:o, qc_g(:o));
END^

-- A level in QuakeC mode, after loadMap has loaded its geometry: QuakeC mode entered (the globals reset),
-- the carried parms and serverflags restored (carry = 1) or a new game's, mapname and world.model set,
-- the map spawned by its spawn functions at time 1, and the client put in.
CREATE OR ALTER PROCEDURE qc_begin_map (skill SMALLINT, carry SMALLINT)
AS
DECLARE o INTEGER; DECLARE v DOUBLE PRECISION; DECLARE mn VARCHAR(32); DECLARE a INTEGER; DECLARE b INTEGER; DECLARE c INTEGER;
BEGIN
  IF (carry = 0) THEN DELETE FROM qc_saved;
  EXECUTE PROCEDURE qc_enter;
  FOR SELECT s.ofs, s.v FROM qc_saved s INTO o, v DO EXECUTE PROCEDURE qc_sg(o, v);
  mn = (SELECT g.map_name FROM game g WHERE g.id = 1);
  EXECUTE PROCEDURE qc_sg(qc_gdef('mapname'), qc_newstr(mn));
  -- SV_SpawnServer: the deathmatch and coop globals come from the server's rules
  EXECUTE PROCEDURE qc_sg(qc_gdef('deathmatch'), (SELECT g.deathmatch FROM game g WHERE g.id = 1));
  EXECUTE PROCEDURE qc_sg(qc_gdef('coop'), (SELECT g.coop FROM game g WHERE g.id = 1));
  EXECUTE PROCEDURE qc_sf(0, qc_fdef('model'), qc_newstr('maps/' || mn || '.bsp'));
  UPDATE game g SET g.time_ = 1.0, g.tic = 0, g.next_map = NULL, g.exit_kind = 0, g.intermission = 0, g.completed_time = 0, g.finale_text = NULL, g.cdtrack = -1 WHERE g.id = 1;
  UPDATE player p SET p.msg = NULL, p.msg_time = 0, p.cprint = NULL, p.cprint_time = 0, p.bonus_time = -10, p.dmg_time = -10,
                      p.dmg_take = 0, p.dmg_save = 0, p.pitch = 0, p.punchangle = 0, p.view_ofs = 22, p.stepz = 0 WHERE p.id = 1;
  SELECT r.spawned, r.failed, r.skipped FROM qc_spawn_map(:skill, 1.0) r INTO a, b, c;
  EXECUTE PROCEDURE qc_client_join(1.0, carry);
  -- the bots come in after the player, as clients connecting (sql/bots.sql)
  FOR SELECT b.c, b.name FROM bots b WHERE b.c <= qc_maxclients() ORDER BY b.c INTO a, mn DO
  BEGIN
    UPDATE bots b SET b.yaw = NULL, b.enemy = NULL, b.goal = NULL, b.look_at = 0, b.turn = 0, b.stuck = 0, b.lastx = NULL WHERE b.c = :a;
    EXECUTE PROCEDURE qc_client_join_n(a, 1.0, 0, mn);
  END
  -- the level's name, as the PSQL game shows it
  UPDATE player p SET p.cprint = (SELECT g.level_msg FROM game g WHERE g.id = 1), p.cprint_time = 3 WHERE p.id = 1;
END^

-- QUAKE_TIC for QuakeC mode: the same input and the same row. Each tic is a 0.05 s server frame; the view
-- angles are the client's own (svc_setangle when the progs set fixangle: spawning, teleporting, the
-- intermission camera), the row is read from the client's QuakeC fields, and the damage the client
-- took is handed over once (SV_WriteClientdataToMessage) and cleared.
CREATE OR ALTER PROCEDURE qc_tic (
  tics INTEGER, fwd DOUBLE PRECISION, side DOUBLE PRECISION, yaw_d DOUBLE PRECISION, pitch_d DOUBLE PRECISION,
  fire SMALLINT, jump SMALLINT, run SMALLINT, imp SMALLINT)
RETURNS (
  tic INTEGER, time_ DOUBLE PRECISION, health INTEGER, armorvalue INTEGER, armortype DOUBLE PRECISION,
  shells INTEGER, nails INTEGER, rockets INTEGER, cells INTEGER, items INTEGER, weapon INTEGER, weaponframe INTEGER,
  px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION, yaw DOUBLE PRECISION, pitch DOUBLE PRECISION,
  view_z DOUBLE PRECISION, punch DOUBLE PRECISION,
  msg VARCHAR(200), cprint VARCHAR(200), dmg_take INTEGER, dmg_save INTEGER, dmg_time DOUBLE PRECISION, bonus_time DOUBLE PRECISION,
  dead SMALLINT, exit_kind SMALLINT, next_map VARCHAR(32), killed INTEGER, total_monsters INTEGER,
  found_secrets INTEGER, total_secrets INTEGER, waterlevel SMALLINT, watertype INTEGER, map_name VARCHAR(32),
  level_msg VARCHAR(80), invincible SMALLINT, quad SMALLINT, invisible SMALLINT, suit SMALLINT, leaf INTEGER,
  amb_water INTEGER, amb_sky INTEGER, finale SMALLINT,
  intermission SMALLINT, completed_time DOUBLE PRECISION, finale_text VARCHAR(1024), cdtrack SMALLINT, skill SMALLINT)
AS
DECLARE i INTEGER = 0; DECLARE t DOUBLE PRECISION; DECLARE r INTEGER; DECLARE fl INTEGER;
DECLARE vyaw DOUBLE PRECISION; DECLARE vpitch DOUBLE PRECISION; DECLARE va INTEGER; DECLARE fa INTEGER;
DECLARE fdt INTEGER; DECLARE fds INTEGER; DECLARE vo DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE demo_note(tics, fwd, side, yaw_d, pitch_d, fire, jump, run, imp);
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  DELETE FROM sound_events s WHERE s.tic < :tic - 40;
  DELETE FROM fx_events f WHERE f.tic < :tic - 40;
  -- SV_CleanupEnts: a muzzle flash lasts the frame it was sent in (the page lights it once)
  UPDATE ents e SET e.effects = BIN_AND(e.effects, BIN_NOT(2)) WHERE BIN_AND(e.effects, 2) <> 0;
  va = (SELECT v.f_v_angle FROM qc_vm v WHERE v.id = 1);
  fa = qc_fdef('fixangle');
  vyaw = qc_f(1, va + 1);
  vpitch = (SELECT p.pitch FROM player p WHERE p.id = 1);
  WHILE (i < tics) DO
  BEGIN
    IF (qc_f(1, fa) <> 0) THEN                      -- svc_setangle: the view takes the body's angles
    BEGIN
      SELECT e.pitch, e.yaw FROM ents e WHERE e.id = 1 INTO vpitch, vyaw;
      EXECUTE PROCEDURE qc_sf(1, fa, 0);
    END
    vyaw = vyaw + yaw_d / tics;
    vpitch = MAXVALUE(-70, MINVALUE(80, vpitch + pitch_d / tics));
    t = (SELECT g.time_ FROM game g WHERE g.id = 1);
    SELECT x.ran FROM qc_server_frame(:t, 0.05e0, :fwd * IIF(:run = 1, 400, 200), :side * IIF(:run = 1, 700, 350), 0,
                                      :vpitch, :vyaw, :fire, :jump, IIF(:i = 0, :imp, 0)) x INTO r;
    UPDATE game g SET g.time_ = :t + 0.05e0 WHERE g.id = 1;
    i = i + 1;
  END
  -- the eye: view_ofs, and the damage handed over once
  vo = qc_f(1, qc_fdef('view_ofs') + 2);
  fdt = qc_fdef('dmg_take'); fds = qc_fdef('dmg_save');
  dmg_take = CAST(qc_f(1, fdt) AS INTEGER); dmg_save = CAST(qc_f(1, fds) AS INTEGER);
  SELECT g.time_ FROM game g WHERE g.id = 1 INTO time_;
  IF (dmg_take <> 0 OR dmg_save <> 0) THEN
  BEGIN
    UPDATE player p SET p.dmg_time = :time_ WHERE p.id = 1;
    EXECUTE PROCEDURE qc_sf(1, fdt, 0); EXECUTE PROCEDURE qc_sf(1, fds, 0);
  END
  UPDATE player p SET p.view_ofs = :vo WHERE p.id = 1;
  SELECT g.tic, CAST(qc_f(1, qc_fdef('health')) AS INTEGER), CAST(qc_f(1, qc_fdef('armorvalue')) AS INTEGER), qc_f(1, qc_fdef('armortype')),
         CAST(qc_f(1, qc_fdef('ammo_shells')) AS INTEGER), CAST(qc_f(1, qc_fdef('ammo_nails')) AS INTEGER),
         CAST(qc_f(1, qc_fdef('ammo_rockets')) AS INTEGER), CAST(qc_f(1, qc_fdef('ammo_cells')) AS INTEGER),
         CAST(qc_f(1, qc_fdef('items')) AS INTEGER), CAST(qc_f(1, qc_fdef('weapon')) AS INTEGER), CAST(qc_f(1, qc_fdef('weaponframe')) AS INTEGER),
         e.x, e.y, e.z, :vyaw, p.pitch + p.punchangle, e.z + :vo, p.punchangle,
         IIF(p.msg_time > g.time_, TRIM(TRAILING ASCII_CHAR(10) FROM p.msg), NULL), IIF(p.cprint_time > g.time_, p.cprint, NULL),
         p.dmg_time, p.bonus_time, IIF(qc_f(1, qc_fdef('deadflag')) > 0, 1, 0), g.exit_kind, g.next_map,
         CAST(qc_g(qc_gdef('killed_monsters')) AS INTEGER), CAST(qc_g(qc_gdef('total_monsters')) AS INTEGER),
         CAST(qc_g(qc_gdef('found_secrets')) AS INTEGER), CAST(qc_g(qc_gdef('total_secrets')) AS INTEGER),
         e.waterlevel, e.watertype, g.map_name, g.level_msg, g.finale, e.leaf, COALESCE(l.ambient, 0), COALESCE(l.ambient_sky, 0),
         g.intermission, g.completed_time, g.finale_text, g.cdtrack, g.skill
    FROM game g CROSS JOIN player p JOIN ents e ON e.id = 1 LEFT JOIN leaves l ON l.id = e.leaf
   WHERE g.id = 1 AND p.id = 1
    INTO tic, health, armorvalue, armortype, shells, nails, rockets, cells, items, weapon, weaponframe,
         px, py, pz, yaw, pitch, view_z, punch, msg, cprint, dmg_time, bonus_time, dead, exit_kind, next_map,
         killed, total_monsters, found_secrets, total_secrets, waterlevel, watertype, map_name, level_msg, finale, leaf, amb_water, amb_sky,
         intermission, completed_time, finale_text, cdtrack, skill;
  invincible = IIF(BIN_AND(items, 1048576) <> 0, 1, 0); quad = IIF(BIN_AND(items, 4194304) <> 0, 1, 0);
  invisible = IIF(BIN_AND(items, 524288) <> 0, 1, 0); suit = IIF(BIN_AND(items, 2097152) <> 0, 1, 0);
  SUSPEND;
END^

SET TERM ; ^
