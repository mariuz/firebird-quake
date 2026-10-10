-- qcvm.sql – a QuakeC virtual machine in PSQL, part 1: globals, fields, strings and edicts. The rest
-- follows in order: qcbuiltins.sql (pr_cmds.c), qcexec.sql (pr_exec.c), qcserver.sql, qcphysics.sql and
-- qcpage.sql. As a whole: pr_exec.c and pr_cmds.c, and the server's QuakeC half.
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
      -- one column each (an UPDATE of all of them through IIFs cost twice as much); the most written first;
      -- 31..39 are computed from the box
      IF (c = 20) THEN UPDATE ents e SET e.frame = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 1) THEN UPDATE ents e SET e.x = :v WHERE e.id = :ent;
      ELSE IF (c = 2) THEN UPDATE ents e SET e.y = :v WHERE e.id = :ent;
      ELSE IF (c = 3) THEN UPDATE ents e SET e.z = :v WHERE e.id = :ent;
      ELSE IF (c = 4) THEN UPDATE ents e SET e.vx = :v WHERE e.id = :ent;
      ELSE IF (c = 5) THEN UPDATE ents e SET e.vy = :v WHERE e.id = :ent;
      ELSE IF (c = 6) THEN UPDATE ents e SET e.vz = :v WHERE e.id = :ent;
      ELSE IF (c = 19) THEN UPDATE ents e SET e.flags = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 8) THEN UPDATE ents e SET e.yaw = :v WHERE e.id = :ent;
      ELSE IF (c = 7) THEN UPDATE ents e SET e.pitch = :v WHERE e.id = :ent;
      ELSE IF (c = 9) THEN UPDATE ents e SET e.roll = :v WHERE e.id = :ent;
      ELSE IF (c = 41) THEN UPDATE ents e SET e.ideal_yaw = :v WHERE e.id = :ent;
      ELSE IF (c = 28) THEN UPDATE ents e SET e.enemy_id = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 29) THEN UPDATE ents e SET e.goal_id = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 22) THEN UPDATE ents e SET e.effects = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 10) THEN UPDATE ents e SET e.avel_yaw = :v WHERE e.id = :ent;
      ELSE IF (c = 17) THEN UPDATE ents e SET e.solid = CAST(:v AS SMALLINT) WHERE e.id = :ent;
      ELSE IF (c = 18) THEN UPDATE ents e SET e.movetype = CAST(:v AS SMALLINT) WHERE e.id = :ent;
      ELSE IF (c = 24) THEN UPDATE ents e SET e.ltime = :v WHERE e.id = :ent;
      ELSE IF (c = 25) THEN UPDATE ents e SET e.waterlevel = CAST(:v AS SMALLINT) WHERE e.id = :ent;
      ELSE IF (c = 26) THEN UPDATE ents e SET e.watertype = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 27) THEN UPDATE ents e SET e.owner_id = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 21) THEN UPDATE ents e SET e.skin = CAST(:v AS INTEGER) WHERE e.id = :ent;
      ELSE IF (c = 23) THEN UPDATE ents e SET e.model_id = NULLIF(CAST(:v AS INTEGER), 0) WHERE e.id = :ent;
      ELSE IF (c = 42) THEN UPDATE ents e SET e.yaw_speed = :v WHERE e.id = :ent;
      ELSE IF (c = 11) THEN UPDATE ents e SET e.minx = :v WHERE e.id = :ent;
      ELSE IF (c = 12) THEN UPDATE ents e SET e.miny = :v WHERE e.id = :ent;
      ELSE IF (c = 13) THEN UPDATE ents e SET e.minz = :v WHERE e.id = :ent;
      ELSE IF (c = 14) THEN UPDATE ents e SET e.maxx = :v WHERE e.id = :ent;
      ELSE IF (c = 15) THEN UPDATE ents e SET e.maxy = :v WHERE e.id = :ent;
      ELSE IF (c = 16) THEN UPDATE ents e SET e.maxz = :v WHERE e.id = :ent;
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

-- svs.clients[c - 1].active: the clients the server reads moves from and runs, the page's player and the
-- bots of sql/bots.sql. A mod's own bots in other client edicts (FrikBot's) are not: as in NetQuake, the
-- engine leaves them alone and the mod's QuakeC moves them
CREATE OR ALTER FUNCTION qc_client_active (c INTEGER) RETURNS SMALLINT
AS
BEGIN
  RETURN IIF(c = 1 OR EXISTS (SELECT 1 FROM bots b WHERE b.c = :c), 1, 0);
END^

-- more client slots than the player and the bots take (a mod that adds its own bots needs them), up to 16
CREATE OR ALTER PROCEDURE qc_set_maxclients (n INTEGER)
AS
BEGIN
  UPDATE game g SET g.maxclients = MAXVALUE(1 + (SELECT COUNT(*) FROM bots), MINVALUE(:n, 16)) WHERE g.id = 1;
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
  -- the clients' edicts, 1..maxclients, exist from the start, as SV_SpawnServer makes them: in use, with
  -- no classname until a client connects into one (a mod that counts or claims client slots with
  -- nextent, as FrikBot does, finds them); the engine runs only the connected ones (qc_client_active)
  i = 1;
  WHILE (i <= qc_maxclients()) DO BEGIN INSERT INTO qc_edicts (id, free) VALUES (:i, 0); i = i + 1; END
  IF (qc_on() = 1) THEN
  BEGIN
    DELETE FROM ents;
    INSERT INTO ents (id, classname) VALUES (1, 'player');
    INSERT INTO ents (id, classname) SELECT d.id, '' FROM qc_edicts d WHERE d.id >= 2;
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
  DELETE FROM vis_faces; DELETE FROM vis_ents;
  UPDATE viewcfg c SET c.vis_leaf = NULL;
  UPDATE player p SET p.ent_id = 1, p.view_ofs = 22, p.stepz = 0, p.punchangle = 0 WHERE p.id = 1;
END^

CREATE OR ALTER PROCEDURE qc_leave
AS
BEGIN
  UPDATE game g SET g.qc_mode = 0 WHERE g.id = 1;
  DELETE FROM qc_engine_fields;
END^

SET TERM ; ^
