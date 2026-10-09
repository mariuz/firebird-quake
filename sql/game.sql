-- game.sql – progs.dat, in PSQL. Part 1: the forward declarations, the utilities and the entity
-- helpers that the rest builds on; movers.sql, triggers.sql, items.sql, combat.sql and spawn.sql
-- follow it, then weapons.sql (the player's tic) and monsters.sql (the AI and the per-tic driver).

SET TERM ^ ;

-- forward declarations (signatures must not change)
CREATE OR ALTER PROCEDURE t_damage (targ INTEGER, inflictor INTEGER, attacker INTEGER, damage INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE use_targets (eid INTEGER, activator INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE monster_die (eid INTEGER, attacker INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE monster_pain (eid INTEGER, attacker INTEGER, damage INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE found_target (eid INTEGER, enemy INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE teleport_touch (trig INTEGER, other INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE door_fire (eid INTEGER, activator INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE plat_go_down (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE plat_go_up (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE trigger_fire (eid INTEGER, activator INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE counter_use (eid INTEGER, activator INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE spikeshooter_fire (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE boss_awake (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE event_lightning_fire (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE changelevel (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE secret_use (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE button_fire (eid INTEGER, activator INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE train_next (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE t_radius_damage (inflictor INTEGER, attacker INTEGER, damage INTEGER, ignore INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE monster_think (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE player_fire (btn SMALLINT) AS BEGIN END^
-- the QuakeC VM's callbacks (sql/qcvm.sql): SV_Impact and a pusher's .blocked, in QuakeC mode
CREATE OR ALTER PROCEDURE qc_impact (e1 INTEGER, e2 INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_blocked (eid INTEGER, other INTEGER) AS BEGIN END^

-- ── utilities ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE snd (eid INTEGER, chan SMALLINT, name VARCHAR(64), vol DOUBLE PRECISION, attn DOUBLE PRECISION)
AS
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE tic INTEGER;
BEGIN
  IF (name IS NULL) THEN EXIT;
  name = TRIM(name);   -- IIF/CASE over literals of different lengths pads the shorter one
  SELECT e.x + (e.minx + e.maxx) / 2, e.y + (e.miny + e.maxy) / 2, e.z + (e.minz + e.maxz) / 2 FROM ents e WHERE e.id = :eid INTO x, y, z;
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  INSERT INTO sound_events (id, tic, ent_id, chan, snd, vol, attn, x, y, z)
    VALUES (NEXT VALUE FOR sound_seq, :tic, :eid, :chan, :name, :vol, :attn, :x, :y, :z);
END^

CREATE OR ALTER PROCEDURE snd_at (x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION, name VARCHAR(64), vol DOUBLE PRECISION, attn DOUBLE PRECISION)
AS
DECLARE tic INTEGER;
BEGIN
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  INSERT INTO sound_events (id, tic, ent_id, chan, snd, vol, attn, x, y, z)
    VALUES (NEXT VALUE FOR sound_seq, :tic, NULL, 0, TRIM(:name), :vol, :attn, :x, :y, :z);
END^

CREATE OR ALTER PROCEDURE fx (kind SMALLINT, x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION, n INTEGER)
AS
DECLARE tic INTEGER;
BEGIN
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  INSERT INTO fx_events (id, tic, kind, x, y, z, x2, y2, z2, n) VALUES (NEXT VALUE FOR fx_seq, :tic, :kind, :x, :y, :z, :x2, :y2, :z2, :n);
END^

CREATE OR ALTER PROCEDURE cprint (msg VARCHAR(200))
AS
BEGIN
  UPDATE player p SET p.cprint = :msg, p.cprint_time = (SELECT g.time_ FROM game g WHERE g.id = 1) + 2 WHERE p.id = 1;
END^

CREATE OR ALTER PROCEDURE sprint (msg VARCHAR(200))
AS
BEGIN
  UPDATE player p SET p.msg = :msg, p.msg_time = (SELECT g.time_ FROM game g WHERE g.id = 1) + 3 WHERE p.id = 1;
END^

CREATE OR ALTER FUNCTION now_ () RETURNS DOUBLE PRECISION
AS
DECLARE t DOUBLE PRECISION;
BEGIN
  SELECT g.time_ FROM game g WHERE g.id = 1 INTO t;
  RETURN t;
END^

-- skill 3: monsters attack without the wait SUB_AttackFinished gives them, and flinch at most every 5 s
CREATE OR ALTER FUNCTION nightmare () RETURNS SMALLINT
AS
BEGIN
  RETURN IIF((SELECT g.skill FROM game g WHERE g.id = 1) = 3, 1, 0);
END^

CREATE OR ALTER FUNCTION player_ent () RETURNS INTEGER
AS
DECLARE e INTEGER;
BEGIN
  SELECT p.ent_id FROM player p WHERE p.id = 1 INTO e;
  RETURN e;
END^

CREATE OR ALTER FUNCTION model_by_name (name VARCHAR(64)) RETURNS INTEGER
AS
DECLARE id INTEGER;
BEGIN
  SELECT FIRST 1 m.id FROM models m WHERE m.name = :name ORDER BY m.id DESC INTO id;
  RETURN id;
END^

CREATE OR ALTER FUNCTION vlen (x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION) RETURNS DOUBLE PRECISION
AS
BEGIN
  RETURN SQRT(x * x + y * y + z * z);
END^

CREATE OR ALTER FUNCTION vectoyaw (x DOUBLE PRECISION, y DOUBLE PRECISION) RETURNS DOUBLE PRECISION
AS
DECLARE a DOUBLE PRECISION;
BEGIN
  IF (x = 0 AND y = 0) THEN RETURN 0;
  a = ATAN2(y, x) * 57.29577951308232e0;
  IF (a < 0) THEN a = a + 360;
  RETURN a;
END^

CREATE OR ALTER FUNCTION anglemod (a DOUBLE PRECISION) RETURNS DOUBLE PRECISION
AS
BEGIN
  RETURN a - 360 * FLOOR(a / 360);
END^

-- the distance between two entities' boxes, classified as Quake's range()
CREATE OR ALTER FUNCTION ent_range (a INTEGER, b INTEGER) RETURNS INTEGER
AS
DECLARE d DOUBLE PRECISION;
BEGIN
  SELECT vlen(e1.x + (e1.minx + e1.maxx) / 2 - e2.x - (e2.minx + e2.maxx) / 2,
              e1.y + (e1.miny + e1.maxy) / 2 - e2.y - (e2.miny + e2.maxy) / 2,
              e1.z + (e1.minz + e1.maxz) / 2 - e2.z - (e2.minz + e2.maxz) / 2)
    FROM ents e1 CROSS JOIN ents e2 WHERE e1.id = :a AND e2.id = :b INTO d;
  IF (d IS NULL) THEN RETURN 3;
  RETURN CASE WHEN d < 120 THEN 0 WHEN d < 500 THEN 1 WHEN d < 1000 THEN 2 ELSE 3 END;
END^

-- visible(): a clear line between the eyes, not crossing a water surface
CREATE OR ALTER FUNCTION visible (a INTEGER, b INTEGER) RETURNS SMALLINT
AS
DECLARE x1 DOUBLE PRECISION; DECLARE y1 DOUBLE PRECISION; DECLARE z1 DOUBLE PRECISION;
DECLARE x2 DOUBLE PRECISION; DECLARE y2 DOUBLE PRECISION; DECLARE z2 DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
BEGIN
  SELECT e.x, e.y, e.z + IIF(e.classname = 'player', 22, e.maxz - 8) FROM ents e WHERE e.id = :a INTO x1, y1, z1;
  SELECT e.x, e.y, e.z + IIF(e.classname = 'player', 22, e.maxz - 8) FROM ents e WHERE e.id = :b INTO x2, y2, z2;
  IF (x1 IS NULL OR x2 IS NULL) THEN RETURN 0;
  EXECUTE PROCEDURE trace_move(NULL, 0, 0, 0, 0, 0, 0, x1, y1, z1, x2, y2, z2, 1)
    RETURNING_VALUES f, ex, ey, ez, nx, ny, nz, als, sts, io, iw, hit;
  IF (io = 1 AND iw = 1) THEN RETURN 0;
  RETURN IIF(f = 1, 1, 0);
END^

CREATE OR ALTER FUNCTION infront (a INTEGER, b INTEGER) RETURNS SMALLINT
AS
DECLARE d DOUBLE PRECISION;
BEGIN
  SELECT (COS(e1.yaw * 0.0174532925e0) * (e2.x - e1.x) + SIN(e1.yaw * 0.0174532925e0) * (e2.y - e1.y))
         / MAXVALUE(1e-3, vlen(e2.x - e1.x, e2.y - e1.y, 0))
    FROM ents e1 CROSS JOIN ents e2 WHERE e1.id = :a AND e2.id = :b INTO d;
  RETURN IIF(d > 0.3e0, 1, 0);
END^

-- ── entities ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE spawn_ent (cls VARCHAR(40), x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION)
RETURNS (id INTEGER)
AS
BEGIN
  id = NEXT VALUE FOR ent_seq;
  INSERT INTO ents (id, classname, x, y, z) VALUES (:id, :cls, :x, :y, :z);
  SUSPEND;
END^

CREATE OR ALTER PROCEDURE remove_ent (eid INTEGER)
AS
BEGIN
  DELETE FROM ents e WHERE e.id = :eid;
  UPDATE ents e SET e.enemy_id = NULL WHERE e.enemy_id = :eid;
END^

-- setmodel(): for brush models also setsize() from the model's bounds
CREATE OR ALTER PROCEDURE set_model (eid INTEGER, name VARCHAR(64))
AS
DECLARE mid INTEGER; DECLARE kind CHAR(1);
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE d DOUBLE PRECISION; DECLARE e_ DOUBLE PRECISION; DECLARE f DOUBLE PRECISION;
BEGIN
  SELECT FIRST 1 m.id, m.kind, m.minx, m.miny, m.minz, m.maxx, m.maxy, m.maxz FROM models m WHERE m.name = :name ORDER BY m.id DESC
    INTO mid, kind, a, b, c, d, e_, f;
  IF (mid IS NULL) THEN
  BEGIN
    UPDATE ents e SET e.model_id = NULL WHERE e.id = :eid;
    EXIT;
  END
  IF (kind = 'B') THEN
    UPDATE ents e SET e.model_id = :mid, e.minx = :a, e.miny = :b, e.minz = :c, e.maxx = :d, e.maxy = :e_, e.maxz = :f WHERE e.id = :eid;
  ELSE
    UPDATE ents e SET e.model_id = :mid WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE set_size (eid INTEGER, a DOUBLE PRECISION, b DOUBLE PRECISION, c DOUBLE PRECISION,
  d DOUBLE PRECISION, e_ DOUBLE PRECISION, f DOUBLE PRECISION)
AS
BEGIN
  UPDATE ents e SET e.minx = :a, e.miny = :b, e.minz = :c, e.maxx = :d, e.maxy = :e_, e.maxz = :f WHERE e.id = :eid;
END^

-- SetMovedir: angle -1 up, -2 down, else a yaw
CREATE OR ALTER PROCEDURE movedir (angle DOUBLE PRECISION) RETURNS (dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION)
AS
BEGIN
  dx = 0; dy = 0; dz = 0;
  IF (angle = -1) THEN dz = 1;
  ELSE IF (angle = -2) THEN dz = -1;
  ELSE
  BEGIN
    dx = COS(COALESCE(angle, 0) * 0.0174532925e0);
    dy = SIN(COALESCE(angle, 0) * 0.0174532925e0);
  END
  SUSPEND;
END^

-- droptofloor(): settle an item or monster onto the ground below
CREATE OR ALTER PROCEDURE drop_to_floor (eid INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
BEGIN
  SELECT e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz FROM ents e WHERE e.id = :eid
    INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz;
  EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, px, py, pz, px, py, pz - 256, 1)
    RETURNING_VALUES f, ex, ey, ez, nx, ny, nz, als, sts, io, iw, hit;
  IF (f < 1 AND als = 0) THEN
    UPDATE ents e SET e.z = :ez, e.flags = BIN_OR(e.flags, 512) WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
END^

-- SUB_CalcMove: start moving a pusher toward a destination
CREATE OR ALTER PROCEDURE calc_move (eid INTEGER, tx DOUBLE PRECISION, ty DOUBLE PRECISION, tz DOUBLE PRECISION,
  spd DOUBLE PRECISION, done VARCHAR(24))
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION; DECLARE lt DOUBLE PRECISION;
DECLARE len DOUBLE PRECISION; DECLARE tt DOUBLE PRECISION;
BEGIN
  SELECT e.x, e.y, e.z, e.ltime FROM ents e WHERE e.id = :eid INTO px, py, pz, lt;
  len = vlen(tx - px, ty - py, tz - pz);
  IF (spd <= 0) THEN spd = 100;
  tt = len / spd;
  IF (tt < 0.1e0) THEN
  BEGIN
    UPDATE ents e SET e.vx = 0, e.vy = 0, e.vz = 0, e.dstx = :tx, e.dsty = :ty, e.dstz = :tz,
           e.mv_done = :done, e.mv_time = :lt + 0.1e0, e.nextthink = NULL, e.think = NULL WHERE e.id = :eid;
    EXIT;
  END
  UPDATE ents e SET e.vx = (:tx - :px) / :tt, e.vy = (:ty - :py) / :tt, e.vz = (:tz - :pz) / :tt,
         e.dstx = :tx, e.dsty = :ty, e.dstz = :tz, e.mv_done = :done, e.mv_time = :lt + :tt, e.nextthink = NULL, e.think = NULL
   WHERE e.id = :eid;
END^

SET TERM ; ^
