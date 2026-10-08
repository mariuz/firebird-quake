-- game.sql – progs.dat, in PSQL. Part 1: utilities, spawning, movers,
-- triggers, items, damage and weapons. monsters.sql has the AI and the
-- per-tic driver.

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

-- ── doors (doors.qc) ──────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE door_go_down (eid INTEGER)
AS
DECLARE mid INTEGER; DECLARE n2 VARCHAR(64); DECLARE spd DOUBLE PRECISION; DECLARE mh INTEGER;
BEGIN
  SELECT e.noise2, e.speed, e.max_health FROM ents e WHERE e.id = :eid INTO n2, spd, mh;
  EXECUTE PROCEDURE snd(eid, 0, n2, 1, 1);
  UPDATE ents e SET e.mv_state = 3, e.health = IIF(e.max_health > 0, e.max_health, e.health),
         e.takedamage = IIF(e.max_health > 0, 1, e.takedamage) WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p1x FROM ents e WHERE e.id = :eid), (SELECT e.p1y FROM ents e WHERE e.id = :eid),
    (SELECT e.p1z FROM ents e WHERE e.id = :eid), spd, 'door_hit_bottom');
END^

CREATE OR ALTER PROCEDURE door_go_up (eid INTEGER)
AS
DECLARE n2 VARCHAR(64); DECLARE spd DOUBLE PRECISION; DECLARE st SMALLINT;
BEGIN
  SELECT e.noise2, e.speed, e.mv_state FROM ents e WHERE e.id = :eid INTO n2, spd, st;
  IF (st = 2) THEN EXIT;                         -- already going up
  IF (st = 0) THEN                               -- reset top wait time
  BEGIN
    UPDATE ents e SET e.nextthink = e.ltime + e.wait_, e.think = 'door_go_down' WHERE e.id = :eid AND e.wait_ >= 0;
    EXIT;
  END
  EXECUTE PROCEDURE snd(eid, 0, n2, 1, 1);
  UPDATE ents e SET e.mv_state = 2 WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p2x FROM ents e WHERE e.id = :eid), (SELECT e.p2y FROM ents e WHERE e.id = :eid),
    (SELECT e.p2z FROM ents e WHERE e.id = :eid), spd, 'door_hit_top');
  EXECUTE PROCEDURE use_targets(eid, player_ent());
END^

CREATE OR ALTER PROCEDURE door_hit_top (eid INTEGER)
AS
DECLARE n1 VARCHAR(64);
BEGIN
  SELECT e.noise1 FROM ents e WHERE e.id = :eid INTO n1;
  EXECUTE PROCEDURE snd(eid, 0, n1, 1, 1);
  UPDATE ents e SET e.mv_state = 0 WHERE e.id = :eid;
  UPDATE ents e SET e.nextthink = e.ltime + e.wait_, e.think = 'door_go_down' WHERE e.id = :eid AND e.wait_ >= 0;
END^

CREATE OR ALTER PROCEDURE door_hit_bottom (eid INTEGER)
AS
DECLARE n1 VARCHAR(64);
BEGIN
  SELECT e.noise1 FROM ents e WHERE e.id = :eid INTO n1;
  EXECUTE PROCEDURE snd(eid, 0, n1, 1, 1);
  UPDATE ents e SET e.mv_state = 1 WHERE e.id = :eid;
END^

-- door_fire: fire the whole linked group
CREATE OR ALTER PROCEDURE door_fire (eid INTEGER, activator INTEGER)
AS
DECLARE master INTEGER; DECLARE d INTEGER; DECLARE st SMALLINT; DECLARE sf INTEGER; DECLARE items INTEGER;
BEGIN
  SELECT COALESCE(e.linked_id, e.id), e.spawnflags, e.items FROM ents e WHERE e.id = :eid INTO master, sf, items;
  IF (items <> 0) THEN EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise3 FROM ents e WHERE e.id = :eid), 1, 1);
  UPDATE ents e SET e.message = NULL WHERE COALESCE(e.linked_id, e.id) = :master;   -- no more messages
  SELECT e.mv_state FROM ents e WHERE e.id = :master INTO st;
  IF (BIN_AND(sf, 32) <> 0 AND st IN (0, 2)) THEN         -- DOOR_TOGGLE: close
  BEGIN
    FOR SELECT e.id FROM ents e WHERE COALESCE(e.linked_id, e.id) = :master AND e.classname = 'func_door' INTO d DO
      EXECUTE PROCEDURE door_go_down(d);
    EXIT;
  END
  FOR SELECT e.id FROM ents e WHERE COALESCE(e.linked_id, e.id) = :master AND e.classname = 'func_door' INTO d DO
    EXECUTE PROCEDURE door_go_up(d);
END^

-- door_touch by the player: key doors and message doors
CREATE OR ALTER PROCEDURE door_touch (eid INTEGER, other INTEGER)
AS
DECLARE items INTEGER; DECLARE msg VARCHAR(200); DECLARE af DOUBLE PRECISION; DECLARE pitems INTEGER; DECLARE wt SMALLINT;
DECLARE master INTEGER; DECLARE tn VARCHAR(40); DECLARE hp INTEGER;
BEGIN
  IF (other <> player_ent()) THEN EXIT;
  SELECT COALESCE(e.linked_id, e.id) FROM ents e WHERE e.id = :eid INTO master;
  SELECT e.items, e.message, e.attack_finished, e.targetname, e.max_health FROM ents e WHERE e.id = :master INTO items, msg, af, tn, hp;
  IF (af > now_()) THEN EXIT;
  UPDATE ents e SET e.attack_finished = now_() + 2 WHERE e.id = :master;
  IF (msg IS NOT NULL AND msg <> '') THEN
  BEGIN
    EXECUTE PROCEDURE cprint(msg);
    EXECUTE PROCEDURE snd(other, 2, 'misc/talk.wav', 1, 1);
  END
  IF (items = 0) THEN EXIT;                       -- plain doors open from their trigger field
  SELECT p.items FROM player p WHERE p.id = 1 INTO pitems;
  SELECT g.world_type FROM game g WHERE g.id = 1 INTO wt;
  IF (BIN_AND(pitems, items) <> items) THEN
  BEGIN
    IF (BIN_AND(items, 131072) <> 0) THEN
      EXECUTE PROCEDURE cprint(CASE wt WHEN 2 THEN 'You need the silver keycard' WHEN 1 THEN 'You need the silver runekey' ELSE 'You need the silver key' END);
    ELSE
      EXECUTE PROCEDURE cprint(CASE wt WHEN 2 THEN 'You need the gold keycard' WHEN 1 THEN 'You need the gold runekey' ELSE 'You need the gold key' END);
    EXECUTE PROCEDURE snd(other, 2, (SELECT e.noise3 FROM ents e WHERE e.id = :master), 1, 1);
    EXIT;
  END
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(:items)) WHERE p.id = 1;
  UPDATE ents e SET e.items = 0 WHERE COALESCE(e.linked_id, e.id) = :master;
  EXECUTE PROCEDURE door_fire(eid, other);
END^

-- door_blocked / plat_blocked: hurt and reverse
CREATE OR ALTER PROCEDURE mover_blocked (eid INTEGER, other INTEGER)
AS
DECLARE cls VARCHAR(40); DECLARE st SMALLINT; DECLARE dmg INTEGER; DECLARE wt DOUBLE PRECISION;
BEGIN
  IF (EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.qc_mode = 1)) THEN
  BEGIN
    EXECUTE PROCEDURE qc_blocked(eid, other);
    EXIT;
  END
  SELECT e.classname, e.mv_state, e.dmg, e.wait_ FROM ents e WHERE e.id = :eid INTO cls, st, dmg, wt;
  EXECUTE PROCEDURE t_damage(other, eid, eid, dmg);
  IF (cls = 'func_door' AND wt >= 0) THEN
  BEGIN
    IF (st = 3) THEN EXECUTE PROCEDURE door_go_up(eid); ELSE EXECUTE PROCEDURE door_go_down(eid);
  END
  ELSE IF (cls = 'func_plat') THEN
  BEGIN
    IF (st = 2) THEN EXECUTE PROCEDURE plat_go_down(eid); ELSE EXECUTE PROCEDURE plat_go_up(eid);
  END
END^

-- ── plats (plats.qc) ─────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE plat_go_down (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise1 FROM ents e WHERE e.id = :eid), 1, 1);
  UPDATE ents e SET e.mv_state = 3 WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p2x FROM ents e WHERE e.id = :eid), (SELECT e.p2y FROM ents e WHERE e.id = :eid),
    (SELECT e.p2z FROM ents e WHERE e.id = :eid), (SELECT e.speed FROM ents e WHERE e.id = :eid), 'plat_hit_bottom');
END^

CREATE OR ALTER PROCEDURE plat_go_up (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise1 FROM ents e WHERE e.id = :eid), 1, 1);
  UPDATE ents e SET e.mv_state = 2 WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p1x FROM ents e WHERE e.id = :eid), (SELECT e.p1y FROM ents e WHERE e.id = :eid),
    (SELECT e.p1z FROM ents e WHERE e.id = :eid), (SELECT e.speed FROM ents e WHERE e.id = :eid), 'plat_hit_top');
END^

CREATE OR ALTER PROCEDURE plat_hit_top (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise2 FROM ents e WHERE e.id = :eid), 1, 1);
  UPDATE ents e SET e.mv_state = 0, e.think = 'plat_go_down', e.nextthink = e.ltime + 3 WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE plat_hit_bottom (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise2 FROM ents e WHERE e.id = :eid), 1, 1);
  UPDATE ents e SET e.mv_state = 1 WHERE e.id = :eid;
END^

-- ── buttons ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE button_fire (eid INTEGER, activator INTEGER)
AS
DECLARE st SMALLINT;
BEGIN
  SELECT e.mv_state FROM ents e WHERE e.id = :eid INTO st;
  IF (st IN (2, 0)) THEN EXIT;
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise1 FROM ents e WHERE e.id = :eid), 1, 1);
  EXECUTE PROCEDURE use_targets(eid, activator);
  UPDATE ents e SET e.mv_state = 2, e.frame = 1 WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p2x FROM ents e WHERE e.id = :eid), (SELECT e.p2y FROM ents e WHERE e.id = :eid),
    (SELECT e.p2z FROM ents e WHERE e.id = :eid), (SELECT e.speed FROM ents e WHERE e.id = :eid), 'button_wait');
END^

CREATE OR ALTER PROCEDURE button_wait (eid INTEGER)
AS
BEGIN
  UPDATE ents e SET e.mv_state = 0, e.think = 'button_return', e.nextthink = e.ltime + e.wait_ WHERE e.id = :eid AND e.wait_ >= 0;
END^

CREATE OR ALTER PROCEDURE button_return (eid INTEGER)
AS
BEGIN
  UPDATE ents e SET e.mv_state = 3, e.frame = 0 WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p1x FROM ents e WHERE e.id = :eid), (SELECT e.p1y FROM ents e WHERE e.id = :eid),
    (SELECT e.p1z FROM ents e WHERE e.id = :eid), (SELECT e.speed FROM ents e WHERE e.id = :eid), 'button_done');
  UPDATE ents e SET e.health = e.max_health, e.takedamage = IIF(e.max_health > 0, 1, 0) WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE button_done (eid INTEGER)
AS
BEGIN
  UPDATE ents e SET e.mv_state = 1 WHERE e.id = :eid;
END^

-- ── trains ──────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE train_next (eid INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION;
DECLARE ctarget VARCHAR(40); DECLARE cwait DOUBLE PRECISION; DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
BEGIN
  SELECT e.target, e.minx, e.miny, e.minz FROM ents e WHERE e.id = :eid INTO tgt, mnx, mny, mnz;
  SELECT FIRST 1 e.x, e.y, e.z, e.target, e.wait_ FROM ents e WHERE e.targetname = :tgt AND e.classname = 'path_corner'
    INTO cx, cy, cz, ctarget, cwait;
  IF (cx IS NULL) THEN EXIT;
  UPDATE ents e SET e.target = :ctarget, e.wait_ = COALESCE(:cwait, 0) WHERE e.id = :eid;
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise1 FROM ents e WHERE e.id = :eid), 1, 1);
  EXECUTE PROCEDURE calc_move(eid, cx - mnx, cy - mny, cz - mnz, (SELECT e.speed FROM ents e WHERE e.id = :eid), 'train_wait');
END^

CREATE OR ALTER PROCEDURE train_wait (eid INTEGER)
AS
DECLARE wt DOUBLE PRECISION;
BEGIN
  SELECT e.wait_ FROM ents e WHERE e.id = :eid INTO wt;
  EXECUTE PROCEDURE snd(eid, 0, (SELECT e.noise2 FROM ents e WHERE e.id = :eid), 1, 1);
  IF (wt < 0) THEN EXIT;                                        -- wait for a trigger
  UPDATE ents e SET e.think = 'train_next', e.nextthink = e.ltime + IIF(:wt > 0, :wt, 0.1e0) WHERE e.id = :eid;
END^

-- ── secret doors ────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE secret_use (eid INTEGER)
AS
DECLARE st SMALLINT; DECLARE sf INTEGER; DECLARE yaw DOUBLE PRECISION;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE sx DOUBLE PRECISION; DECLARE sy DOUBLE PRECISION; DECLARE sz DOUBLE PRECISION;
DECLARE fx_ DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION;
DECLARE tw DOUBLE PRECISION; DECLARE tl DOUBLE PRECISION; DECLARE d1x DOUBLE PRECISION; DECLARE d1y DOUBLE PRECISION; DECLARE d1z DOUBLE PRECISION;
BEGIN
  SELECT e.mv_state, e.spawnflags, e.ideal_yaw, e.x, e.y, e.z, e.maxx - e.minx, e.maxy - e.miny, e.maxz - e.minz
    FROM ents e WHERE e.id = :eid INTO st, sf, yaw, px, py, pz, sx, sy, sz;
  IF (st <> 1) THEN EXIT;                                       -- only from the closed position
  UPDATE ents e SET e.message = NULL WHERE e.id = :eid;
  EXECUTE PROCEDURE snd(eid, 0, 'doors/latch2.wav', 1, 1);
  fx_ = COS(yaw * 0.0174532925e0); fy = SIN(yaw * 0.0174532925e0);
  rx = fy; ry = -fx_;                                           -- v_right
  IF (BIN_AND(sf, 2) <> 0) THEN BEGIN rx = -rx; ry = -ry; END   -- SECRET_1ST_LEFT
  tw = ABS(rx * sx + ry * sy);
  tl = ABS(fx_ * sx + fy * sy);
  IF (BIN_AND(sf, 4) <> 0) THEN                                 -- SECRET_1ST_DOWN
  BEGIN
    d1x = px; d1y = py; d1z = pz - sz;
  END
  ELSE
  BEGIN
    d1x = px + rx * tw; d1y = py + ry * tw; d1z = pz;
  END
  UPDATE ents e SET e.mv_state = 2, e.p1x = :d1x, e.p1y = :d1y, e.p1z = :d1z,
         e.p2x = :d1x + :fx_ * :tl, e.p2y = :d1y + :fy * :tl, e.p2z = :d1z, e.spawn_x = :px, e.spawn_y = :py, e.spawn_z = :pz
   WHERE e.id = :eid;
  EXECUTE PROCEDURE calc_move(eid, d1x, d1y, d1z, 50, 'secret_move1');
END^

CREATE OR ALTER PROCEDURE secret_move1 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/winch2.wav', 1, 1);
  UPDATE ents e SET e.think = 'secret_move2', e.nextthink = e.ltime + 1 WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE secret_move2 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/winch2.wav', 1, 1);
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p2x FROM ents e WHERE e.id = :eid), (SELECT e.p2y FROM ents e WHERE e.id = :eid),
    (SELECT e.p2z FROM ents e WHERE e.id = :eid), 50, 'secret_move3');
END^

CREATE OR ALTER PROCEDURE secret_move3 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/drclos4.wav', 1, 1);
  UPDATE ents e SET e.mv_state = 0 WHERE e.id = :eid;
  UPDATE ents e SET e.think = 'secret_move4', e.nextthink = e.ltime + 5 WHERE e.id = :eid AND BIN_AND(e.spawnflags, 1) = 0;
END^

CREATE OR ALTER PROCEDURE secret_move4 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/winch2.wav', 1, 1);
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.p1x FROM ents e WHERE e.id = :eid), (SELECT e.p1y FROM ents e WHERE e.id = :eid),
    (SELECT e.p1z FROM ents e WHERE e.id = :eid), 50, 'secret_move5');
END^

CREATE OR ALTER PROCEDURE secret_move5 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/winch2.wav', 1, 1);
  UPDATE ents e SET e.think = 'secret_move6', e.nextthink = e.ltime + 1 WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE secret_move6 (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE calc_move(eid, (SELECT e.spawn_x FROM ents e WHERE e.id = :eid), (SELECT e.spawn_y FROM ents e WHERE e.id = :eid),
    (SELECT e.spawn_z FROM ents e WHERE e.id = :eid), 50, 'secret_done');
END^

CREATE OR ALTER PROCEDURE secret_done (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE snd(eid, 0, 'doors/drclos4.wav', 1, 1);
  UPDATE ents e SET e.mv_state = 1, e.health = IIF(e.max_health > 0, e.max_health, 0), e.takedamage = IIF(e.max_health > 0, 1, 0) WHERE e.id = :eid;
END^

-- ── triggers ────────────────────────────────────────────────────────────
-- SUB_UseTargets: fire everything named by `target`, kill `killtarget`
CREATE OR ALTER PROCEDURE use_targets (eid INTEGER, activator INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE kt VARCHAR(40); DECLARE msg VARCHAR(200); DECLARE dl DOUBLE PRECISION;
DECLARE t INTEGER; DECLARE tcls VARCHAR(40); DECLARE tid INTEGER; DECLARE st SMALLINT;
BEGIN
  SELECT e.target, e.killtarget, e.message, e.delay FROM ents e WHERE e.id = :eid INTO tgt, kt, msg, dl;
  IF (dl > 0) THEN
  BEGIN
    -- create a temporary object to fire at a later time
    EXECUTE PROCEDURE spawn_ent('DelayedUse', 0, 0, 0) RETURNING_VALUES tid;
    UPDATE ents e SET e.target = :tgt, e.killtarget = :kt, e.message = :msg, e.think = 'delayed_use', e.nextthink = now_() + :dl,
           e.enemy_id = :activator WHERE e.id = :tid;
    EXIT;
  END
  IF (msg IS NOT NULL AND msg <> '' AND activator = player_ent()) THEN
  BEGIN
    EXECUTE PROCEDURE cprint(msg);
    IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND e.classname IN ('trigger_secret'))) THEN
      EXECUTE PROCEDURE snd(activator, 2, 'misc/talk.wav', 1, 1);
  END
  IF (kt IS NOT NULL AND kt <> '') THEN
    DELETE FROM ents e WHERE e.targetname = :kt;
  IF (tgt IS NULL OR tgt = '') THEN EXIT;
  FOR SELECT e.id, e.classname FROM ents e WHERE e.targetname = :tgt AND e.id <> :eid INTO t, tcls DO
  BEGIN
    IF (tcls = 'func_door') THEN EXECUTE PROCEDURE door_fire(t, activator);
    ELSE IF (tcls = 'func_door_secret') THEN EXECUTE PROCEDURE secret_use(t);
    ELSE IF (tcls = 'func_plat') THEN
    BEGIN
      SELECT e.mv_state FROM ents e WHERE e.id = :t INTO st;
      IF (st = 0) THEN EXECUTE PROCEDURE plat_go_down(t); ELSE IF (st = 1) THEN EXECUTE PROCEDURE plat_go_up(t);
    END
    ELSE IF (tcls = 'func_button') THEN EXECUTE PROCEDURE button_fire(t, activator);
    ELSE IF (tcls = 'func_train') THEN
    BEGIN
      SELECT e.mv_state FROM ents e WHERE e.id = :t INTO st;
      IF (st = 1) THEN BEGIN UPDATE ents e SET e.mv_state = 2 WHERE e.id = :t; EXECUTE PROCEDURE train_next(t); END
    END
    ELSE IF (tcls IN ('trigger_relay', 'trigger_once', 'trigger_multiple', 'trigger_secret')) THEN
      EXECUTE PROCEDURE trigger_fire(t, activator);
    ELSE IF (tcls = 'trigger_counter') THEN EXECUTE PROCEDURE counter_use(t, activator);
    ELSE IF (tcls = 'trigger_teleport') THEN
      UPDATE ents e SET e.nextthink = now_() + 0.2e0 WHERE e.id = :t;   -- enabled for a moment
    ELSE IF (tcls = 'light') THEN
      UPDATE lightstyles l SET l.pattern = IIF(l.pattern = 'a', 'm', 'a') WHERE l.style = (SELECT e.style FROM ents e WHERE e.id = :t);
    ELSE IF (tcls = 'trap_spikeshooter') THEN EXECUTE PROCEDURE spikeshooter_fire(t);
    ELSE IF (tcls = 'trap_shooter') THEN
      UPDATE ents e SET e.think = 'shooter_think', e.nextthink = now_() + 0.1e0 WHERE e.id = :t;
    ELSE IF (tcls = 'func_wall' OR tcls = 'func_illusionary') THEN
      UPDATE ents e SET e.frame = 1 - e.frame WHERE e.id = :t;              -- texture toggle
    ELSE IF (tcls = 'monster_boss') THEN EXECUTE PROCEDURE boss_awake(t);
    ELSE IF (tcls = 'event_lightning') THEN EXECUTE PROCEDURE event_lightning_fire(t);
    ELSE IF (tcls LIKE 'monster_%') THEN
      UPDATE ents e SET e.enemy_id = player_ent(), e.st = 'run', e.anim = NULL WHERE e.id = :t AND e.st = 'stand' AND e.health > 0;
    ELSE IF (tcls = 'func_episodegate' OR tcls = 'func_bossgate') THEN DELETE FROM ents e WHERE e.id = :t;
    ELSE IF (tcls = 'misc_fireball') THEN BEGIN END
    ELSE IF (tcls = 'info_null' OR tcls = 'info_notnull' OR tcls = 'path_corner') THEN BEGIN END
    ELSE IF (tcls = 'trigger_changelevel') THEN EXECUTE PROCEDURE changelevel(t);
    ELSE EXECUTE PROCEDURE use_targets(t, activator);               -- anything with a target of its own
  END
END^

CREATE OR ALTER PROCEDURE delayed_use (eid INTEGER)
AS
DECLARE act INTEGER;
BEGIN
  SELECT e.enemy_id FROM ents e WHERE e.id = :eid INTO act;
  EXECUTE PROCEDURE use_targets(eid, COALESCE(act, player_ent()));
  DELETE FROM ents e WHERE e.id = :eid;
END^

-- multi_trigger: message, sound, targets, then wait or die
CREATE OR ALTER PROCEDURE trigger_fire (eid INTEGER, activator INTEGER)
AS
DECLARE wt DOUBLE PRECISION; DECLARE nt DOUBLE PRECISION; DECLARE cls VARCHAR(40); DECLARE n1 VARCHAR(64);
BEGIN
  SELECT e.wait_, e.nextthink, e.classname, e.noise1 FROM ents e WHERE e.id = :eid INTO wt, nt, cls, n1;
  IF (nt IS NOT NULL AND nt > now_()) THEN EXIT;                   -- already been triggered
  IF (cls = 'trigger_secret') THEN
  BEGIN
    UPDATE game g SET g.found_secrets = g.found_secrets + 1 WHERE g.id = 1;
  END
  IF (n1 IS NOT NULL) THEN EXECUTE PROCEDURE snd(activator, 2, n1, 1, 1);
  -- don't trigger again until reset
  UPDATE ents e SET e.takedamage = 0 WHERE e.id = :eid;
  EXECUTE PROCEDURE use_targets(eid, activator);
  IF (wt > 0) THEN
    UPDATE ents e SET e.nextthink = now_() + :wt, e.think = 'multi_wait' WHERE e.id = :eid;
  ELSE
    DELETE FROM ents e WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE multi_wait (eid INTEGER)
AS
BEGIN
  UPDATE ents e SET e.nextthink = NULL, e.think = NULL, e.takedamage = IIF(e.max_health > 0, 1, 0), e.health = e.max_health WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE counter_use (eid INTEGER, activator INTEGER)
AS
DECLARE c INTEGER; DECLARE sf INTEGER;
BEGIN
  UPDATE ents e SET e.count_ = e.count_ - 1 WHERE e.id = :eid RETURNING e.count_, e.spawnflags INTO c, sf;
  IF (c < 0) THEN EXIT;
  IF (c <> 0) THEN
  BEGIN
    IF (BIN_AND(sf, 1) = 0) THEN
    BEGIN
      EXECUTE PROCEDURE cprint(CASE c WHEN 3 THEN 'There are more to go...' WHEN 2 THEN 'Only 2 more to go...' WHEN 1 THEN 'Only 1 more to go...' ELSE 'There are more to go...' END);
      EXECUTE PROCEDURE snd(activator, 2, 'misc/talk.wav', 1, 1);
    END
    EXIT;
  END
  IF (BIN_AND(sf, 1) = 0) THEN
  BEGIN
    EXECUTE PROCEDURE cprint('Sequence completed!');
    EXECUTE PROCEDURE snd(activator, 2, 'misc/talk.wav', 1, 1);
  END
  UPDATE ents e SET e.enemy_id = :activator WHERE e.id = :eid;
  EXECUTE PROCEDURE trigger_fire(eid, activator);
END^

CREATE OR ALTER PROCEDURE changelevel (eid INTEGER)
AS
DECLARE m VARCHAR(32); DECLARE ek SMALLINT; DECLARE pe INTEGER;
DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION; DECLARE cp DOUBLE PRECISION; DECLARE cyaw DOUBLE PRECISION;
BEGIN
  SELECT e.map FROM ents e WHERE e.id = :eid INTO m;
  SELECT g.exit_kind FROM game g WHERE g.id = 1 INTO ek;
  IF (ek <> 0 OR m IS NULL) THEN EXIT;
  -- the page shows the intermission's stats, the level's time as Quake counts it, until fire; the
  -- intermission music (svc_cdtrack 3)
  UPDATE game g SET g.next_map = :m, g.exit_kind = 1, g.intermission_tics = 0, g.intermission = 1, g.completed_time = g.time_, g.cdtrack = 3 WHERE g.id = 1;
  -- execute_changelevel: the view goes to an intermission camera (FindIntermission: one of the level's
  -- info_intermission spots at random, else the start), looking along its mangle, from the eye at the
  -- spot itself; the player is out of the world (not solid, not hurt, not moving)
  SELECT FIRST 1 m.ox, m.oy, m.oz, COALESCE(m.mpitch, 0), COALESCE(m.myaw, m.angle, 0) FROM map_ents m
   WHERE m.classname = 'info_intermission' ORDER BY RAND() INTO cx, cy, cz, cp, cyaw;
  IF (cx IS NULL) THEN
    SELECT FIRST 1 m.ox, m.oy, m.oz, 0, COALESCE(m.angle, 0) FROM map_ents m WHERE m.classname = 'info_player_start' INTO cx, cy, cz, cp, cyaw;
  IF (cx IS NULL) THEN EXIT;
  pe = player_ent();
  UPDATE ents e SET e.x = :cx, e.y = :cy, e.z = :cz, e.vx = 0, e.vy = 0, e.vz = 0, e.yaw = :cyaw,
         e.solid = 0, e.movetype = 0, e.takedamage = 0 WHERE e.id = :pe;
  UPDATE player p SET p.pitch = :cp, p.view_ofs = 0, p.stepz = 0, p.punchangle = 0 WHERE p.id = 1;
  EXECUTE PROCEDURE link_ent(pe);
END^

-- teleport_touch: send `other` to the destination
CREATE OR ALTER PROCEDURE teleport_touch (trig INTEGER, other INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE sf INTEGER; DECLARE tn VARCHAR(40); DECLARE nt DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE dyaw DOUBLE PRECISION;
DECLARE ocls VARCHAR(40); DECLARE oflags INTEGER; DECLARE v INTEGER;
BEGIN
  SELECT e.target, e.spawnflags, e.targetname, e.nextthink FROM ents e WHERE e.id = :trig INTO tgt, sf, tn, nt;
  SELECT e.classname, e.flags FROM ents e WHERE e.id = :other INTO ocls, oflags;
  IF (tn IS NOT NULL AND tn <> '' AND (nt IS NULL OR nt < now_())) THEN EXIT;    -- not fired yet
  IF (BIN_AND(sf, 1) <> 0 AND ocls <> 'player') THEN EXIT;                  -- PLAYER_ONLY
  IF (ocls <> 'player' AND BIN_AND(oflags, 32) = 0) THEN EXIT;              -- only players and monsters
  IF (ocls <> 'player' AND BIN_AND(sf, 1) <> 0) THEN EXIT;
  SELECT FIRST 1 e.x, e.y, e.z, e.yaw FROM ents e WHERE e.targetname = :tgt AND e.classname = 'info_teleport_destination'
    INTO dx, dy, dz, dyaw;
  IF (dx IS NULL) THEN EXIT;
  IF (BIN_AND(sf, 2) = 0) THEN
  BEGIN
    EXECUTE PROCEDURE snd(other, 0, 'misc/r_tele' || CAST(1 + FLOOR(RAND() * 5) AS INTEGER) || '.wav', 1, 1);
    EXECUTE PROCEDURE fx(5, (SELECT e.x FROM ents e WHERE e.id = :other), (SELECT e.y FROM ents e WHERE e.id = :other),
      (SELECT e.z FROM ents e WHERE e.id = :other), 0, 0, 0, 0);
  END
  -- telefrag anything at the destination
  FOR SELECT e.id FROM ents e JOIN ents o ON o.id = :other
       WHERE e.id <> :other AND e.takedamage > 0 AND e.health > 0
         AND e.x + e.maxx >= :dx + o.minx AND e.x + e.minx <= :dx + o.maxx
         AND e.y + e.maxy >= :dy + o.miny AND e.y + e.miny <= :dy + o.maxy
         AND e.z + e.maxz >= :dz + 27 + o.minz AND e.z + e.minz <= :dz + 27 + o.maxz INTO v DO
    EXECUTE PROCEDURE t_damage(v, other, other, 50000);
  -- Shub-Niggurath only dies this way: the telefrag must reach her whatever her takedamage
  FOR SELECT e.id FROM ents e JOIN ents o ON o.id = :other
       WHERE e.classname = 'monster_oldone' AND e.health > 0
         AND e.x + e.maxx >= :dx + o.minx AND e.x + e.minx <= :dx + o.maxx
         AND e.y + e.maxy >= :dy + o.miny AND e.y + e.miny <= :dy + o.maxy INTO v DO
    EXECUTE PROCEDURE monster_die(v, other);
  UPDATE ents e SET e.x = :dx, e.y = :dy, e.z = :dz + 27, e.yaw = :dyaw, e.pitch = 0,
         e.vx = COS(:dyaw * 0.0174532925e0) * 300, e.vy = SIN(:dyaw * 0.0174532925e0) * 300, e.vz = 0,
         e.flags = BIN_AND(e.flags, BIN_NOT(512)), e.teleport_time = now_() + 0.7e0
   WHERE e.id = :other;
  IF (ocls = 'player') THEN UPDATE player p SET p.pitch = 0 WHERE p.id = 1;
  EXECUTE PROCEDURE link_ent(other);
  EXECUTE PROCEDURE snd_at(dx, dy, dz, 'misc/r_tele' || CAST(1 + FLOOR(RAND() * 5) AS INTEGER) || '.wav', 1, 1);
  EXECUTE PROCEDURE fx(5, dx, dy, dz + 27, 0, 0, 0, 0);
END^

-- ── items (items.qc) ─────────────────────────────────────────────────────
-- W_BestWeapon
CREATE OR ALTER FUNCTION best_weapon () RETURNS INTEGER
AS
DECLARE it INTEGER; DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE wl SMALLINT;
BEGIN
  SELECT p.items, p.shells, p.nails, p.rockets, p.cells, COALESCE(e.waterlevel, 0) FROM player p LEFT JOIN ents e ON e.id = p.ent_id WHERE p.id = 1
    INTO it, sh, na, ro, ce, wl;
  IF (BIN_AND(it, 64) <> 0 AND ce >= 1 AND wl <= 1) THEN RETURN 64;
  IF (BIN_AND(it, 8) <> 0 AND na >= 2) THEN RETURN 8;
  IF (BIN_AND(it, 2) <> 0 AND sh >= 2) THEN RETURN 2;
  IF (BIN_AND(it, 4) <> 0 AND na >= 1) THEN RETURN 4;
  IF (BIN_AND(it, 1) <> 0 AND sh >= 1) THEN RETURN 1;
  RETURN 4096;
END^

CREATE OR ALTER PROCEDURE bound_ammo
AS
BEGIN
  UPDATE player p SET p.shells = MINVALUE(p.shells, 100), p.nails = MINVALUE(p.nails, 200), p.rockets = MINVALUE(p.rockets, 100), p.cells = MINVALUE(p.cells, 100) WHERE p.id = 1;
END^

CREATE OR ALTER PROCEDURE item_touch (item INTEGER, other INTEGER)
AS
DECLARE cls VARCHAR(40); DECLARE sf INTEGER; DECLARE items INTEGER; DECLARE hp INTEGER; DECLARE mhp INTEGER;
DECLARE snd_ VARCHAR(64); DECLARE msg VARCHAR(200); DECLARE pitems INTEGER; DECLARE newit INTEGER = 0;
DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE av INTEGER; DECLARE atype DOUBLE PRECISION;
DECLARE big SMALLINT; DECLARE w INTEGER; DECLARE t DOUBLE PRECISION; DECLARE wt SMALLINT;
BEGIN
  IF (other <> player_ent()) THEN EXIT;
  SELECT e.classname, e.spawnflags, e.ammo_shells, e.ammo_nails, e.ammo_rockets, e.ammo_cells FROM ents e WHERE e.id = :item
    INTO cls, sf, sh, na, ro, ce;
  SELECT e.health FROM ents e WHERE e.id = :other INTO hp;
  IF (hp <= 0) THEN EXIT;
  SELECT p.items, p.armorvalue, p.armortype FROM player p WHERE p.id = 1 INTO pitems, av, atype;
  t = now_();
  big = IIF(BIN_AND(sf, 1) <> 0, 1, 0);
  SELECT g.world_type FROM game g WHERE g.id = 1 INTO wt;
  snd_ = 'weapons/lock4.wav';

  IF (cls = 'item_health') THEN
  BEGIN
    IF (BIN_AND(sf, 2) <> 0) THEN                               -- MEGAHEALTH
    BEGIN
      IF (hp >= 250) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 100, 250) WHERE e.id = :other;
      UPDATE player p SET p.items = BIN_OR(p.items, 65536), p.dmg_time = :t WHERE p.id = 1;
      snd_ = 'items/r_item2.wav'; msg = 'You receive 100 health';
    END
    ELSE IF (BIN_AND(sf, 1) <> 0) THEN                          -- rotten
    BEGIN
      IF (hp >= 100) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 15, 100) WHERE e.id = :other;
      snd_ = 'items/r_item1.wav'; msg = 'You receive 15 health';
    END
    ELSE
    BEGIN
      IF (hp >= 100) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 25, 100) WHERE e.id = :other;
      snd_ = 'items/health1.wav'; msg = 'You receive 25 health';
    END
  END
  ELSE IF (cls IN ('item_armor1', 'item_armor2', 'item_armorInv')) THEN
  BEGIN
    IF (cls = 'item_armor1') THEN BEGIN hp = 100; atype = 0.3e0; newit = 8192; END
    ELSE IF (cls = 'item_armor2') THEN BEGIN hp = 150; atype = 0.6e0; newit = 16384; END
    ELSE BEGIN hp = 200; atype = 0.8e0; newit = 32768; END
    SELECT p.armorvalue, p.armortype FROM player p WHERE p.id = 1 INTO av, t;
    IF (av * t >= hp * atype) THEN EXIT;
    UPDATE player p SET p.armorvalue = :hp, p.armortype = :atype, p.items = BIN_OR(BIN_AND(p.items, BIN_NOT(8192 + 16384 + 32768)), :newit) WHERE p.id = 1;
    snd_ = 'items/armor1.wav'; msg = 'You got armor';
  END
  ELSE IF (cls IN ('item_shells', 'item_spikes', 'item_rockets', 'item_cells')) THEN
  BEGIN
    IF (cls = 'item_shells') THEN
    BEGIN
      SELECT p.shells FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.shells = p.shells + IIF(:big = 1, 40, 20) WHERE p.id = 1; msg = 'You got the shells';
    END
    ELSE IF (cls = 'item_spikes') THEN
    BEGIN
      SELECT p.nails FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 200) THEN EXIT;
      UPDATE player p SET p.nails = p.nails + IIF(:big = 1, 50, 25) WHERE p.id = 1; msg = 'You got the nails';
    END
    ELSE IF (cls = 'item_rockets') THEN
    BEGIN
      SELECT p.rockets FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.rockets = p.rockets + IIF(:big = 1, 10, 5) WHERE p.id = 1; msg = 'You got the rockets';
    END
    ELSE
    BEGIN
      SELECT p.cells FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.cells = p.cells + IIF(:big = 1, 12, 6) WHERE p.id = 1; msg = 'You got the cells';
    END
    EXECUTE PROCEDURE bound_ammo;
    -- switch to a better weapon if the current one is empty
    SELECT p.weapon FROM player p WHERE p.id = 1 INTO w;
    IF (w = 4096 OR (w = 1 AND (SELECT p.shells FROM player p WHERE p.id = 1) = 0)) THEN
      UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1;
  END
  ELSE IF (cls LIKE 'weapon_%') THEN
  BEGIN
    IF (cls = 'weapon_supershotgun') THEN BEGIN newit = 2; msg = 'You got the Double-barrelled Shotgun'; UPDATE player p SET p.shells = p.shells + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_nailgun') THEN BEGIN newit = 4; msg = 'You got the nailgun'; UPDATE player p SET p.nails = p.nails + 30 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_supernailgun') THEN BEGIN newit = 8; msg = 'You got the Super Nailgun'; UPDATE player p SET p.nails = p.nails + 30 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_grenadelauncher') THEN BEGIN newit = 16; msg = 'You got the Grenade Launcher'; UPDATE player p SET p.rockets = p.rockets + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_rocketlauncher') THEN BEGIN newit = 32; msg = 'You got the Rocket Launcher'; UPDATE player p SET p.rockets = p.rockets + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_lightning') THEN BEGIN newit = 64; msg = 'You got the Thunderbolt'; UPDATE player p SET p.cells = p.cells + 15 WHERE p.id = 1; END
    ELSE EXIT;
    EXECUTE PROCEDURE bound_ammo;
    UPDATE player p SET p.items = BIN_OR(p.items, :newit), p.weapon = :newit WHERE p.id = 1;
    snd_ = 'weapons/pkup.wav';
  END
  ELSE IF (cls = 'item_key1' OR cls = 'item_key2') THEN
  BEGIN
    newit = IIF(cls = 'item_key1', 131072, 262144);
    IF (BIN_AND(pitems, newit) <> 0) THEN EXIT;
    UPDATE player p SET p.items = BIN_OR(p.items, :newit) WHERE p.id = 1;
    msg = IIF(cls = 'item_key1', CASE wt WHEN 2 THEN 'You got the silver keycard' WHEN 1 THEN 'You got the silver runekey' ELSE 'You got the silver key' END,
                                 CASE wt WHEN 2 THEN 'You got the gold keycard' WHEN 1 THEN 'You got the gold runekey' ELSE 'You got the gold key' END);
    snd_ = CASE wt WHEN 2 THEN 'misc/medkey.wav' WHEN 1 THEN 'misc/runekey.wav' ELSE 'misc/medkey.wav' END;
  END
  ELSE IF (cls = 'item_sigil') THEN
  BEGIN
    UPDATE game g SET g.serverflags = BIN_OR(g.serverflags, BIN_SHR(:sf, 0)) WHERE g.id = 1;
    UPDATE player p SET p.items = BIN_OR(p.items, BIN_SHL(BIN_AND(:sf, 15), 28)) WHERE p.id = 1;
    msg = 'You got the rune!'; snd_ = 'misc/runekey.wav';
  END
  ELSE IF (cls = 'item_artifact_invulnerability') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 1048576), p.invincible_finished = :t + 30 WHERE p.id = 1;
    msg = 'Pentagram of Protection!'; snd_ = 'items/protect.wav';
  END
  ELSE IF (cls = 'item_artifact_invisibility') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 524288), p.invisible_finished = :t + 30 WHERE p.id = 1;
    msg = 'Ring of Shadows!'; snd_ = 'items/inv1.wav';
  END
  ELSE IF (cls = 'item_artifact_super_damage') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 4194304), p.super_damage_finished = :t + 30 WHERE p.id = 1;
    msg = 'Quad Damage!'; snd_ = 'items/damage.wav';
  END
  ELSE IF (cls = 'item_artifact_envirosuit') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 2097152), p.radsuit_finished = :t + 30 WHERE p.id = 1;
    msg = 'Biosuit'; snd_ = 'items/suit.wav';
  END
  ELSE IF (cls = 'backpack') THEN
  BEGIN
    UPDATE player p SET p.shells = p.shells + :sh, p.nails = p.nails + :na, p.rockets = p.rockets + :ro, p.cells = p.cells + :ce WHERE p.id = 1;
    EXECUTE PROCEDURE bound_ammo;
    msg = 'You get ' || TRIM(IIF(sh > 0, sh || ' shells ', '') || IIF(na > 0, na || ' nails ', '') || IIF(ro > 0, ro || ' rockets ', '') || IIF(ce > 0, ce || ' cells', ''));
    SELECT p.weapon FROM player p WHERE p.id = 1 INTO w;
    IF (w = 4096) THEN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1;
  END
  ELSE EXIT;

  EXECUTE PROCEDURE sprint(msg);
  EXECUTE PROCEDURE snd(other, 3, snd_, 1, 1);
  UPDATE player p SET p.bonus_time = :t WHERE p.id = 1;
  EXECUTE PROCEDURE use_targets(item, other);
  DELETE FROM ents e WHERE e.id = :item;
END^

-- ── damage (combat.qc) ───────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE throw_gib (eid INTEGER, model VARCHAR(64), dmg INTEGER)
AS
DECLARE g INTEGER; DECLARE spd DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE spawn_ent('gib', (SELECT e.x FROM ents e WHERE e.id = :eid), (SELECT e.y FROM ents e WHERE e.id = :eid),
    (SELECT e.z FROM ents e WHERE e.id = :eid)) RETURNING_VALUES g;
  EXECUTE PROCEDURE set_model(g, model);
  -- VelocityForDamage
  spd = IIF(dmg > 50, 2, IIF(dmg > 200, 4, 1)) * 1e0;
  UPDATE ents e SET e.movetype = 10, e.solid = 0,
         e.vx = 100 * (RAND() * 2 - 1) * :spd * 0.7e0, e.vy = 100 * (RAND() * 2 - 1) * :spd * 0.7e0, e.vz = (RAND() * 200 + 100) * :spd,
         e.avel_yaw = RAND() * 600, e.think = 'remove', e.nextthink = now_() + 10 + RAND() * 10, e.frame = 0 WHERE e.id = :g;
END^

CREATE OR ALTER PROCEDURE throw_head (eid INTEGER, model VARCHAR(64), dmg INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE set_model(eid, model);
  UPDATE ents e SET e.movetype = 10, e.solid = 0, e.takedamage = 0, e.frame = 0, e.anim = NULL, e.st = 'dead',
         e.minx = -16, e.miny = -16, e.minz = 0, e.maxx = 16, e.maxy = 16, e.maxz = 56,
         e.vx = 100 * (RAND() * 2 - 1), e.vy = 100 * (RAND() * 2 - 1), e.vz = RAND() * 200 + 200,
         e.avel_yaw = RAND() * 600, e.think = NULL, e.nextthink = NULL, e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :eid;
END^

-- Killed(): the target's health fell to zero
CREATE OR ALTER PROCEDURE killed (targ INTEGER, attacker INTEGER)
AS
DECLARE cls VARCHAR(40); DECLARE flags INTEGER; DECLARE hp INTEGER;
BEGIN
  SELECT e.classname, e.flags, e.health FROM ents e WHERE e.id = :targ INTO cls, flags, hp;
  IF (hp < -99) THEN UPDATE ents e SET e.health = -99 WHERE e.id = :targ;
  IF (cls = 'player') THEN
  BEGIN
    UPDATE ents e SET e.deadflag = 1, e.solid = 0, e.movetype = 6, e.minz = -24, e.maxz = -8, e.takedamage = 0,
           e.anim = 'death' || SUBSTRING('abcde' FROM 1 + FLOOR(RAND() * 5) FOR 1), e.anim_frame = 0 WHERE e.id = :targ;
    UPDATE player p SET p.dead_time = now_(), p.view_ofs = -8, p.weapon = 0, p.items = BIN_AND(p.items, BIN_NOT(1048576 + 524288 + 4194304 + 2097152)) WHERE p.id = 1;
    EXECUTE PROCEDURE snd(targ, 2, 'player/death' || CAST(1 + FLOOR(RAND() * 5) AS INTEGER) || '.wav', 1, 1);
    EXIT;
  END
  IF (BIN_AND(flags, 32) <> 0) THEN
  BEGIN
    EXECUTE PROCEDURE monster_die(targ, attacker);
    EXIT;
  END
  IF (cls = 'misc_explobox') THEN
  BEGIN
    EXECUTE PROCEDURE t_radius_damage(targ, attacker, 160, NULL);
    EXECUTE PROCEDURE snd(targ, 0, 'weapons/r_exp3.wav', 1, 1);
    EXECUTE PROCEDURE fx(2, (SELECT e.x + (e.minx + e.maxx) / 2 FROM ents e WHERE e.id = :targ), (SELECT e.y + (e.miny + e.maxy) / 2 FROM ents e WHERE e.id = :targ),
      (SELECT e.z + (e.minz + e.maxz) / 2 FROM ents e WHERE e.id = :targ), 0, 0, 0, 0);
    DELETE FROM ents e WHERE e.id = :targ;
    EXIT;
  END
  -- shootable doors, buttons and triggers
  IF (cls = 'func_door') THEN
  BEGIN
    UPDATE ents e SET e.takedamage = 0, e.health = e.max_health WHERE e.id = :targ;
    EXECUTE PROCEDURE door_fire(targ, attacker);
  END
  ELSE IF (cls = 'func_door_secret') THEN EXECUTE PROCEDURE secret_use(targ);
  ELSE IF (cls = 'func_button') THEN
  BEGIN
    UPDATE ents e SET e.takedamage = 0 WHERE e.id = :targ;
    EXECUTE PROCEDURE button_fire(targ, attacker);
  END
  ELSE IF (cls IN ('trigger_multiple', 'trigger_once')) THEN
  BEGIN
    UPDATE ents e SET e.takedamage = 0 WHERE e.id = :targ;
    EXECUTE PROCEDURE trigger_fire(targ, attacker);
  END
END^

-- T_Damage
CREATE OR ALTER PROCEDURE t_damage (targ INTEGER, inflictor INTEGER, attacker INTEGER, damage INTEGER)
AS
DECLARE td SMALLINT; DECLARE cls VARCHAR(40); DECLARE flags INTEGER; DECLARE hp INTEGER;
DECLARE save INTEGER; DECLARE take INTEGER; DECLARE av INTEGER; DECLARE atype DOUBLE PRECISION; DECLARE inv DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION;
DECLARE mt SMALLINT; DECLARE acls VARCHAR(40); DECLARE pe INTEGER; DECLARE sdf DOUBLE PRECISION; DECLARE pf DOUBLE PRECISION;
DECLARE cur INTEGER;
BEGIN
  SELECT e.takedamage, e.classname, e.flags, e.health, e.movetype FROM ents e WHERE e.id = :targ INTO td, cls, flags, hp, mt;
  IF (td IS NULL OR td = 0 OR hp <= 0 AND cls <> 'player') THEN EXIT;
  pe = player_ent();
  SELECT e.classname FROM ents e WHERE e.id = :attacker INTO acls;
  IF (attacker = pe) THEN
  BEGIN
    SELECT p.super_damage_finished FROM player p WHERE p.id = 1 INTO sdf;
    IF (sdf > now_()) THEN damage = damage * 4;
  END
  save = 0;
  IF (cls = 'player') THEN
  BEGIN
    IF (BIN_AND(flags, 64) <> 0) THEN EXIT;                               -- god mode
    SELECT p.armorvalue, p.armortype, p.invincible_finished FROM player p WHERE p.id = 1 INTO av, atype, inv;
    IF (inv >= now_()) THEN
    BEGIN
      SELECT p.pain_finished FROM player p WHERE p.id = 1 INTO pf;
      IF (pf < now_()) THEN
      BEGIN
        EXECUTE PROCEDURE snd(targ, 3, 'items/protect3.wav', 1, 1);
        UPDATE player p SET p.pain_finished = now_() + 2 WHERE p.id = 1;
      END
      EXIT;
    END
    save = CEILING(atype * damage);
    IF (save >= av) THEN
    BEGIN
      save = av;
      UPDATE player p SET p.armortype = 0, p.items = BIN_AND(p.items, BIN_NOT(8192 + 16384 + 32768)) WHERE p.id = 1;
    END
    UPDATE player p SET p.armorvalue = p.armorvalue - :save, p.dmg_take = p.dmg_take + (:damage - :save), p.dmg_save = p.dmg_save + :save, p.dmg_time = now_() WHERE p.id = 1;
  END
  take = CEILING(damage - save);

  -- add to the damage momentum of the entity
  IF (inflictor IS NOT NULL AND inflictor > 0 AND mt = 3) THEN
  BEGIN
    SELECT e1.x - (e2.x + (e2.minx + e2.maxx) / 2), e1.y - (e2.y + (e2.miny + e2.maxy) / 2), e1.z - (e2.z + (e2.minz + e2.maxz) / 2)
      FROM ents e1 CROSS JOIN ents e2 WHERE e1.id = :targ AND e2.id = :inflictor INTO dx, dy, dz;
    dl = vlen(dx, dy, dz);
    IF (dl > 0) THEN
      UPDATE ents e SET e.vx = e.vx + :dx / :dl * :damage * 8, e.vy = e.vy + :dy / :dl * :damage * 8, e.vz = e.vz + :dz / :dl * :damage * 8 WHERE e.id = :targ;
  END

  UPDATE ents e SET e.health = e.health - :take WHERE e.id = :targ RETURNING e.health INTO hp;
  IF (hp <= 0) THEN
  BEGIN
    EXECUTE PROCEDURE killed(targ, attacker);
    EXIT;
  END
  IF (cls = 'player') THEN
  BEGIN
    SELECT p.pain_finished FROM player p WHERE p.id = 1 INTO pf;
    IF (pf < now_() AND take > 0) THEN
    BEGIN
      EXECUTE PROCEDURE snd(targ, 2, 'player/pain' || CAST(1 + FLOOR(RAND() * 6) AS INTEGER) || '.wav', 1, 1);
      UPDATE player p SET p.pain_finished = now_() + 0.5e0, p.punchangle = -2 WHERE p.id = 1;
    END
    EXIT;
  END
  IF (BIN_AND(flags, 32) <> 0) THEN
  BEGIN
    -- T_Damage: get mad at whoever hurt us (not the world, not ourselves, not the enemy we have), unless
    -- it is one of our own kind, except for soldiers; a monster fighting another remembers the player
    SELECT e.enemy_id FROM ents e WHERE e.id = :targ INTO cur;
    IF (attacker IS NOT NULL AND attacker > 0 AND attacker <> targ AND attacker IS DISTINCT FROM cur
        AND (cls IS DISTINCT FROM acls OR cls = 'monster_army')) THEN
    BEGIN
      IF (cur = pe) THEN UPDATE ents e SET e.oldenemy_id = :pe WHERE e.id = :targ;
      EXECUTE PROCEDURE found_target(targ, attacker);
    END
    EXECUTE PROCEDURE monster_pain(targ, attacker, take);
    -- nightmare mode monsters don't go into pain frames often
    IF (nightmare() = 1) THEN UPDATE ents e SET e.pain_finished = now_() + 5 WHERE e.id = :targ;
  END
END^

-- T_RadiusDamage
CREATE OR ALTER PROCEDURE t_radius_damage (inflictor INTEGER, attacker INTEGER, damage INTEGER, ignore INTEGER)
AS
DECLARE ix DOUBLE PRECISION; DECLARE iy DOUBLE PRECISION; DECLARE iz DOUBLE PRECISION;
DECLARE eid INTEGER; DECLARE d DOUBLE PRECISION; DECLARE pts DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION;
BEGIN
  SELECT e.x, e.y, e.z FROM ents e WHERE e.id = :inflictor INTO ix, iy, iz;
  FOR SELECT e.id, e.x + (e.minx + e.maxx) / 2, e.y + (e.miny + e.maxy) / 2, e.z + (e.minz + e.maxz) / 2
        FROM ents e
       WHERE e.takedamage > 0 AND (:ignore IS NULL OR e.id <> :ignore)
         AND ABS(e.x - :ix) < :damage + 40 AND ABS(e.y - :iy) < :damage + 40 AND ABS(e.z - :iz) < :damage + 40
        INTO eid, cx, cy, cz
  DO
  BEGIN
    d = vlen(cx - ix, cy - iy, cz - iz);
    pts = damage - 0.5e0 * d;
    IF (eid = attacker) THEN pts = pts * 0.5e0;
    IF (pts <= 0) THEN CONTINUE;
    EXECUTE PROCEDURE trace_move(NULL, 0, 0, 0, 0, 0, 0, ix, iy, iz, cx, cy, cz, 1)
      RETURNING_VALUES f, ex, ey, ez, nx, ny, nz, als, sts, io, iw, hit;
    IF (f = 1 OR als = 1) THEN EXECUTE PROCEDURE t_damage(eid, inflictor, attacker, CAST(pts AS INTEGER));
  END
END^

-- ── projectiles ─────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE launch_spike (owner INTEGER, ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION,
  dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION, spd DOUBLE PRECISION, kind VARCHAR(16))
AS
DECLARE s INTEGER; DECLARE dl DOUBLE PRECISION;
BEGIN
  dl = vlen(dx, dy, dz);
  IF (dl = 0) THEN EXIT;
  EXECUTE PROCEDURE spawn_ent(kind, ox, oy, oz) RETURNING_VALUES s;
  EXECUTE PROCEDURE set_model(s, CASE kind WHEN 'superspike' THEN 'progs/s_spike.mdl' WHEN 'wizspike' THEN 'progs/w_spike.mdl' WHEN 'kspike' THEN 'progs/k_spike.mdl' ELSE 'progs/spike.mdl' END);
  UPDATE ents e SET e.owner_id = :owner, e.movetype = 9, e.solid = 2,
         e.vx = :dx / :dl * :spd, e.vy = :dy / :dl * :spd, e.vz = :dz / :dl * :spd,
         e.yaw = vectoyaw(:dx, :dy), e.pitch = ATAN2(:dz, vlen(:dx, :dy, 0)) * 57.29577951e0,
         e.dmg = CASE :kind WHEN 'superspike' THEN 18 ELSE 9 END,
         e.think = 'remove', e.nextthink = now_() + 6 WHERE e.id = :s;
  EXECUTE PROCEDURE link_ent(s);
END^

CREATE OR ALTER PROCEDURE launch_grenade (owner INTEGER, ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION,
  vx DOUBLE PRECISION, vy DOUBLE PRECISION, vz DOUBLE PRECISION, dmg INTEGER, model VARCHAR(64), fuse DOUBLE PRECISION)
AS
DECLARE s INTEGER;
BEGIN
  EXECUTE PROCEDURE spawn_ent('grenade', ox, oy, oz) RETURNING_VALUES s;
  EXECUTE PROCEDURE set_model(s, model);
  UPDATE ents e SET e.owner_id = :owner, e.movetype = 10, e.solid = 2, e.vx = :vx, e.vy = :vy, e.vz = :vz,
         e.yaw = vectoyaw(:vx, :vy), e.avel_yaw = 300, e.dmg = :dmg,
         e.think = 'grenade_explode', e.nextthink = now_() + :fuse WHERE e.id = :s;
  EXECUTE PROCEDURE link_ent(s);
END^

CREATE OR ALTER PROCEDURE launch_rocket (owner INTEGER, ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION,
  dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION, spd DOUBLE PRECISION, dmg INTEGER, model VARCHAR(64))
AS
DECLARE s INTEGER; DECLARE dl DOUBLE PRECISION;
BEGIN
  dl = vlen(dx, dy, dz);
  IF (dl = 0) THEN EXIT;
  EXECUTE PROCEDURE spawn_ent('rocket', ox, oy, oz) RETURNING_VALUES s;
  EXECUTE PROCEDURE set_model(s, model);
  UPDATE ents e SET e.owner_id = :owner, e.movetype = 9, e.solid = 2, e.effects = IIF(:model = 'progs/missile.mdl', 4, 8),
         e.vx = :dx / :dl * :spd, e.vy = :dy / :dl * :spd, e.vz = :dz / :dl * :spd,
         e.yaw = vectoyaw(:dx, :dy), e.pitch = ATAN2(:dz, vlen(:dx, :dy, 0)) * 57.29577951e0, e.dmg = :dmg,
         e.think = 'remove', e.nextthink = now_() + 5 WHERE e.id = :s;
  EXECUTE PROCEDURE link_ent(s);
END^

CREATE OR ALTER PROCEDURE grenade_explode (eid INTEGER)
AS
DECLARE own INTEGER; DECLARE dmg INTEGER; DECLARE cls VARCHAR(40);
BEGIN
  SELECT e.owner_id, e.dmg, e.classname FROM ents e WHERE e.id = :eid INTO own, dmg, cls;
  EXECUTE PROCEDURE t_radius_damage(eid, own, dmg, NULL);
  EXECUTE PROCEDURE snd(eid, 0, 'weapons/r_exp3.wav', 1, 1);
  EXECUTE PROCEDURE fx(IIF(cls = 'lavaball', 7, 2), (SELECT e.x FROM ents e WHERE e.id = :eid), (SELECT e.y FROM ents e WHERE e.id = :eid), (SELECT e.z FROM ents e WHERE e.id = :eid), 0, 0, 0, 0);
  DELETE FROM ents e WHERE e.id = :eid;
END^

-- ── touching ────────────────────────────────────────────────────────────
-- SV_Impact: e1 moved into e2 (e2 = 0 is the world)
CREATE OR ALTER PROCEDURE impact (e1 INTEGER, e2 INTEGER)
AS
DECLARE c1 VARCHAR(40); DECLARE c2 VARCHAR(40); DECLARE own INTEGER; DECLARE dmg INTEGER; DECLARE td2 SMALLINT;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION; DECLARE hp2 INTEGER;
BEGIN
  IF (EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.qc_mode = 1)) THEN
  BEGIN
    EXECUTE PROCEDURE qc_impact(e1, e2);
    EXIT;
  END
  SELECT e.classname, e.owner_id, e.dmg, e.x, e.y, e.z, e.vz FROM ents e WHERE e.id = :e1 INTO c1, own, dmg, x, y, z, vz;
  IF (e2 > 0) THEN SELECT e.classname, e.takedamage, e.health FROM ents e WHERE e.id = :e2 INTO c2, td2, hp2;
  ELSE BEGIN c2 = 'worldspawn'; td2 = 0; END
  IF (e2 = own) THEN EXIT;

  IF (c1 IN ('spike', 'superspike', 'wizspike', 'kspike')) THEN
  BEGIN
    IF (point_contents(x, y, z) = -6) THEN BEGIN DELETE FROM ents e WHERE e.id = :e1; EXIT; END   -- sky
    IF (td2 > 0 AND hp2 > 0) THEN
    BEGIN
      EXECUTE PROCEDURE fx(3, x, y, z, 0, 0, 0, dmg);
      EXECUTE PROCEDURE t_damage(e2, e1, own, dmg);
    END
    ELSE
    BEGIN
      EXECUTE PROCEDURE fx(6, x, y, z, 0, 0, 0, IIF(c1 = 'superspike', 1, 0));
      EXECUTE PROCEDURE snd_at(x, y, z, 'weapons/tink1.wav', 1, 1);
    END
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'rocket') THEN
  BEGIN
    IF (point_contents(x, y, z) = -6) THEN BEGIN DELETE FROM ents e WHERE e.id = :e1; EXIT; END
    IF (td2 > 0 AND hp2 > 0) THEN EXECUTE PROCEDURE t_damage(e2, e1, own, dmg + FLOOR(RAND() * 20));
    EXECUTE PROCEDURE t_radius_damage(e1, own, dmg, e2);
    EXECUTE PROCEDURE snd_at(x, y, z, 'weapons/r_exp3.wav', 1, 1);
    EXECUTE PROCEDURE fx(2, x, y, z, 0, 0, 0, 0);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'laser') THEN
  BEGIN
    IF (point_contents(x, y, z) = -6) THEN BEGIN DELETE FROM ents e WHERE e.id = :e1; EXIT; END
    EXECUTE PROCEDURE snd_at(x, y, z, 'enforcer/enfstop.wav', 1, 1);
    IF (td2 > 0 AND hp2 > 0) THEN
    BEGIN
      EXECUTE PROCEDURE fx(3, x, y, z, 0, 0, 0, 15);
      EXECUTE PROCEDURE t_damage(e2, e1, own, 15);
    END
    ELSE EXECUTE PROCEDURE fx(1, x, y, z, 0, 0, 0, 0);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'voreball') THEN
  BEGIN
    IF (td2 > 0 AND hp2 > 0) THEN EXECUTE PROCEDURE t_damage(e2, e1, own, 40);
    EXECUTE PROCEDURE t_radius_damage(e1, own, 40, e2);
    EXECUTE PROCEDURE snd_at(x, y, z, 'weapons/r_exp3.wav', 1, 1);
    EXECUTE PROCEDURE fx(2, x, y, z, 0, 0, 0, 0);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'lavaball') THEN
  BEGIN
    IF (td2 > 0 AND hp2 > 0) THEN EXECUTE PROCEDURE t_damage(e2, e1, own, dmg);
    EXECUTE PROCEDURE t_radius_damage(e1, own, dmg, e2);
    EXECUTE PROCEDURE snd_at(x, y, z, 'weapons/r_exp3.wav', 1, 1);
    EXECUTE PROCEDURE fx(7, x, y, z, 0, 0, 0, 0);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'fireball') THEN
  BEGIN
    IF (td2 > 0 AND hp2 > 0) THEN EXECUTE PROCEDURE t_damage(e2, e1, e1, 20);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'grenade') THEN
  BEGIN
    IF (td2 = 2 AND hp2 > 0) THEN EXECUTE PROCEDURE grenade_explode(e1);
    ELSE EXECUTE PROCEDURE snd_at(x, y, z, 'weapons/bounce.wav', 1, 1);
  END
  ELSE IF (c1 = 'zombie_gib') THEN
  BEGIN
    IF (td2 > 0 AND hp2 > 0) THEN
    BEGIN
      EXECUTE PROCEDURE t_damage(e2, e1, own, 10);
      EXECUTE PROCEDURE snd_at(x, y, z, 'zombie/z_hit.wav', 1, 1);
    END
    ELSE EXECUTE PROCEDURE snd_at(x, y, z, 'zombie/z_miss.wav', 1, 1);
    DELETE FROM ents e WHERE e.id = :e1;
  END
  ELSE IF (c1 = 'player' AND c2 = 'func_door') THEN EXECUTE PROCEDURE door_touch(e2, e1);
  ELSE IF (c1 = 'player' AND c2 = 'func_door_secret') THEN
  BEGIN
    IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :e2 AND (e.targetname IS NULL OR e.targetname = '') AND e.max_health = 0)) THEN
      EXECUTE PROCEDURE secret_use(e2);
    ELSE IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :e2 AND e.message IS NOT NULL AND e.attack_finished < now_())) THEN
    BEGIN
      EXECUTE PROCEDURE cprint((SELECT e.message FROM ents e WHERE e.id = :e2));
      EXECUTE PROCEDURE snd(e1, 2, 'misc/talk.wav', 1, 1);
      UPDATE ents e SET e.attack_finished = now_() + 2 WHERE e.id = :e2;
    END
  END
  ELSE IF (c1 = 'player' AND c2 = 'func_button') THEN
  BEGIN
    IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :e2 AND e.max_health = 0)) THEN EXECUTE PROCEDURE button_fire(e2, e1);
  END
  ELSE IF (c1 = 'player' AND c2 = 'misc_explobox') THEN BEGIN END
  ELSE IF (c1 = 'player' AND e2 = 0 AND vz < -300) THEN
  BEGIN
    -- falling damage, in SV_Physics_Client terms: lands hard
    IF (vz < -650) THEN
    BEGIN
      EXECUTE PROCEDURE t_damage(e1, 0, 0, 5);
      EXECUTE PROCEDURE snd(e1, 2, 'player/land2.wav', 1, 1);
    END
    ELSE EXECUTE PROCEDURE snd(e1, 2, 'player/land.wav', 1, 1);
  END
END^

-- ── map setup ───────────────────────────────────────────────────────────
-- spawn_map_ents: QuakeC's spawn functions for every classname we know
CREATE OR ALTER PROCEDURE spawn_map_ents (skill SMALLINT)
AS
DECLARE mid INTEGER; DECLARE cls VARCHAR(40); DECLARE tn VARCHAR(40); DECLARE tg VARCHAR(40); DECLARE kt VARCHAR(40); DECLARE mdl VARCHAR(40);
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE ang DOUBLE PRECISION;
DECLARE mp DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mr DOUBLE PRECISION;
DECLARE sf INTEGER; DECLARE msg VARCHAR(200); DECLARE wt DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION;
DECLARE lip DOUBLE PRECISION; DECLARE hp INTEGER; DECLARE lt INTEGER; DECLARE sty INTEGER; DECLARE snds INTEGER; DECLARE dmg INTEGER;
DECLARE hgt DOUBLE PRECISION; DECLARE cnt INTEGER; DECLARE map_ VARCHAR(32); DECLARE noise VARCHAR(64); DECLARE wtype INTEGER;
DECLARE eid INTEGER; DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION;
DECLARE sx DOUBLE PRECISION; DECLARE sy DOUBLE PRECISION; DECLARE sz DOUBLE PRECISION; DECLARE dist DOUBLE PRECISION;
DECLARE n1 VARCHAR(64); DECLARE n2 VARCHAR(64); DECLARE n3 VARCHAR(64);
DECLARE mname VARCHAR(16); DECLARE mmodel VARCHAR(40); DECLARE mhp INTEGER; DECLARE mhull SMALLINT; DECLARE mmaxz DOUBLE PRECISION; DECLARE mflags INTEGER;
DECLARE mys DOUBLE PRECISION; DECLARE stand VARCHAR(16);
DECLARE skillbit INTEGER;
DECLARE items INTEGER;
BEGIN
  skillbit = CASE skill WHEN 0 THEN 256 WHEN 1 THEN 512 ELSE 1024 END;
  FOR SELECT m.id, m.classname, m.targetname, m.target, m.killtarget, m.model, m.ox, m.oy, m.oz, m.angle, m.mpitch, m.myaw, m.mroll,
             m.spawnflags, m.message, m.wait_, m.delay, m.speed, m.lip, m.health, m.light, m.style, m.sounds, m.dmg, m.height, m.count_, m.map, m.noise, m.worldtype
        FROM map_ents m ORDER BY m.id
        INTO mid, cls, tn, tg, kt, mdl, ox, oy, oz, ang, mp, my, mr, sf, msg, wt, dl, spd, lip, hp, lt, sty, snds, dmg, hgt, cnt, map_, noise, wtype
  DO
  BEGIN
    IF (BIN_AND(sf, skillbit) <> 0) THEN CONTINUE;                 -- not on this skill
    IF (cls = 'worldspawn') THEN
    BEGIN
      UPDATE game g SET g.world_type = COALESCE(:wtype, 0), g.level_msg = :msg WHERE g.id = 1;
      CONTINUE;
    END
    IF (cls IN ('light', 'info_intermission', 'info_player_deathmatch', 'info_player_coop', 'light_fluoro', 'light_fluorospark', 'air_bubbles',
                'ambient_comp_hum', 'ambient_drip', 'ambient_drone', 'ambient_swamp1', 'ambient_swamp2', 'trigger_onlyregistered')) THEN
    BEGIN
      IF (cls = 'light' AND tn IS NOT NULL AND tn <> '' AND sty IS NOT NULL) THEN
      BEGIN
        EXECUTE PROCEDURE spawn_ent(cls, ox, oy, oz) RETURNING_VALUES eid;
        UPDATE ents e SET e.targetname = :tn, e.style = :sty WHERE e.id = :eid;
        UPDATE OR INSERT INTO lightstyles (style, pattern) VALUES (:sty, IIF(BIN_AND(:sf, 1) <> 0, 'a', 'm')) MATCHING (style);
      END
      IF (cls = 'trigger_onlyregistered' AND mdl IS NOT NULL) THEN
      BEGIN
        SELECT g.registered FROM game g WHERE g.id = 1 INTO wtype;
        IF (wtype = 1) THEN
        BEGIN
          -- registered: an ordinary trigger_multiple
          EXECUTE PROCEDURE spawn_ent('trigger_multiple', ox, oy, oz) RETURNING_VALUES eid;
          EXECUTE PROCEDURE set_model(eid, mdl);
          UPDATE ents e SET e.model_id = NULL, e.solid = 1, e.target = :tg, e.killtarget = :kt, e.message = :msg, e.spawnflags = :sf,
                 e.wait_ = IIF(COALESCE(:wt, 0) = 0, 2, :wt), e.targetname = :tn WHERE e.id = :eid;
        END
        ELSE
        BEGIN
          -- the shareware version: show the message, never fire
          EXECUTE PROCEDURE spawn_ent('trigger_message', ox, oy, oz) RETURNING_VALUES eid;
          EXECUTE PROCEDURE set_model(eid, mdl);
          UPDATE ents e SET e.model_id = NULL, e.solid = 1, e.message = COALESCE(:msg, 'This item is only available in the registered version'), e.wait_ = 2 WHERE e.id = :eid;
        END
      END
      CONTINUE;
    END

    EXECUTE PROCEDURE spawn_ent(cls, ox, oy, oz) RETURNING_VALUES eid;
    UPDATE ents e SET e.targetname = :tn, e.target = :tg, e.killtarget = :kt, e.spawnflags = :sf, e.message = :msg,
           e.wait_ = COALESCE(:wt, 0), e.delay = COALESCE(:dl, 0), e.speed = COALESCE(:spd, 0), e.lip = COALESCE(:lip, 0),
           e.health = COALESCE(:hp, 0), e.max_health = COALESCE(:hp, 0), e.style = COALESCE(:sty, 0), e.sounds = COALESCE(:snds, 0),
           e.dmg = COALESCE(:dmg, 0), e.height = COALESCE(:hgt, 0), e.count_ = COALESCE(:cnt, 0), e.map = :map_,
           e.yaw = COALESCE(:ang, 0), e.spawn_x = :ox, e.spawn_y = :oy, e.spawn_z = :oz
     WHERE e.id = :eid;
    IF (mdl IS NOT NULL AND mdl STARTING WITH '*') THEN EXECUTE PROCEDURE set_model(eid, mdl);
    SELECT e.maxx - e.minx, e.maxy - e.miny, e.maxz - e.minz FROM ents e WHERE e.id = :eid INTO sx, sy, sz;

    -- ── player ──
    IF (cls = 'info_player_start') THEN
    BEGIN
      UPDATE ents e SET e.classname = 'player', e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 32,
             e.solid = 3, e.movetype = 3, e.health = 100, e.max_health = 100, e.takedamage = 2, e.flags = 8, e.anim = 'stand' WHERE e.id = :eid;
      EXECUTE PROCEDURE set_model(eid, 'progs/player.mdl');
      UPDATE player p SET p.ent_id = :eid WHERE p.id = 1;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'info_player_start2') THEN
    BEGIN
      IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.classname = 'player')) THEN
      BEGIN
        UPDATE ents e SET e.classname = 'player', e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 32,
               e.solid = 3, e.movetype = 3, e.health = 100, e.max_health = 100, e.takedamage = 2, e.flags = 8 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_model(eid, 'progs/player.mdl');
        UPDATE player p SET p.ent_id = :eid WHERE p.id = 1;
      END
      ELSE DELETE FROM ents e WHERE e.id = :eid;
    END
    -- ── doors ──
    ELSE IF (cls = 'func_door') THEN
    BEGIN
      IF (snds = 0 OR snds IS NULL) THEN BEGIN n1 = 'misc/null.wav'; n2 = 'misc/null.wav'; END
      ELSE IF (snds = 1) THEN BEGIN n1 = 'doors/drclos4.wav'; n2 = 'doors/doormv1.wav'; END
      ELSE IF (snds = 2) THEN BEGIN n1 = 'doors/hydro2.wav'; n2 = 'doors/hydro1.wav'; END
      ELSE IF (snds = 3) THEN BEGIN n1 = 'doors/stndr2.wav'; n2 = 'doors/stndr1.wav'; END
      ELSE BEGIN n1 = 'doors/ddoor2.wav'; n2 = 'doors/ddoor1.wav'; END
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      IF (spd IS NULL OR spd = 0) THEN spd = 100;
      IF (wt IS NULL) THEN wt = 3;
      IF (lip IS NULL) THEN lip = 8;
      IF (dmg IS NULL OR dmg = 0) THEN dmg = 2;
      dist = ABS(dx * sx + dy * sy + dz * sz) - lip;
      items = IIF(BIN_AND(sf, 16) <> 0, 131072, 0) + IIF(BIN_AND(sf, 8) <> 0, 262144, 0);
      SELECT g.world_type FROM game g WHERE g.id = 1 INTO wtype;
      n3 = CASE wtype WHEN 2 THEN 'doors/basetry.wav' WHEN 1 THEN 'doors/runetry.wav' ELSE 'doors/medtry.wav' END;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.wait_ = :wt, e.lip = :lip, e.dmg = :dmg,
             e.noise1 = :n1, e.noise2 = :n2, e.noise3 = :n3, e.items = :items, e.takedamage = IIF(:hp > 0, 1, 0),
             e.p1x = 0, e.p1y = 0, e.p1z = 0, e.p2x = :dx * :dist, e.p2y = :dy * :dist, e.p2z = :dz * :dist, e.mv_state = 1 WHERE e.id = :eid;
      IF (BIN_AND(sf, 1) <> 0) THEN     -- DOOR_START_OPEN
        UPDATE ents e SET e.x = e.p2x, e.y = e.p2y, e.z = e.p2z, e.p2x = e.p1x, e.p2y = e.p1y, e.p2z = e.p1z,
               e.p1x = e.x, e.p1y = e.y, e.p1z = e.z WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'func_door_secret') THEN
    BEGIN
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.ideal_yaw = COALESCE(:ang, 0), e.yaw = 0, e.mv_state = 1, e.speed = 50,
             e.takedamage = IIF(BIN_AND(:sf, 8) = 0 AND (:tn IS NULL OR :tn = '' OR BIN_AND(:sf, 16) <> 0), 1, 0),
             e.health = 10000, e.max_health = IIF(BIN_AND(:sf, 8) = 0 AND (:tn IS NULL OR :tn = '' OR BIN_AND(:sf, 16) <> 0), 10000, 0) WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── plats ──
    ELSE IF (cls = 'func_plat') THEN
    BEGIN
      IF (snds IS NULL OR snds = 0) THEN snds = 2;
      n1 = TRIM(IIF(snds = 1, 'plats/plat1.wav', 'plats/medplat1.wav'));
      n2 = TRIM(IIF(snds = 1, 'plats/plat2.wav', 'plats/medplat2.wav'));
      IF (spd IS NULL OR spd = 0) THEN spd = 150;
      IF (hgt IS NULL OR hgt = 0) THEN hgt = sz - 8;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.noise1 = :n1, e.noise2 = :n2, e.height = :hgt,
             e.p1x = e.x, e.p1y = e.y, e.p1z = e.z, e.p2x = e.x, e.p2y = e.y, e.p2z = e.z - :hgt, e.dmg = 1 WHERE e.id = :eid;
      -- starts at the bottom unless it is triggered
      IF (tn IS NULL OR tn = '') THEN
        UPDATE ents e SET e.z = e.p2z, e.mv_state = 1 WHERE e.id = :eid;
      ELSE
        UPDATE ents e SET e.mv_state = 0 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── buttons ──
    ELSE IF (cls = 'func_button') THEN
    BEGIN
      n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'buttons/switch21.wav' WHEN 2 THEN 'buttons/switch02.wav' WHEN 3 THEN 'buttons/switch04.wav' ELSE 'buttons/airbut1.wav' END;
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      IF (spd IS NULL OR spd = 0) THEN spd = 40;
      IF (wt IS NULL OR wt = 0) THEN wt = 1;
      IF (lip IS NULL OR lip = 0) THEN lip = 4;
      dist = ABS(dx * sx + dy * sy + dz * sz) - lip;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.wait_ = :wt, e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0),
             e.p1x = e.x, e.p1y = e.y, e.p1z = e.z, e.p2x = e.x + :dx * :dist, e.p2y = e.y + :dy * :dist, e.p2z = e.z + :dz * :dist, e.mv_state = 1 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── trains ──
    ELSE IF (cls = 'func_train') THEN
    BEGIN
      IF (spd IS NULL OR spd = 0) THEN spd = 100;
      n1 = TRIM(IIF(COALESCE(snds, 1) = 1, 'plats/train2.wav', 'misc/null.wav'));
      n2 = TRIM(IIF(COALESCE(snds, 1) = 1, 'plats/train1.wav', 'misc/null.wav'));
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.noise1 = :n1, e.noise2 = :n2, e.dmg = IIF(COALESCE(:dmg, 0) = 0, 2, :dmg),
             e.mv_state = IIF(:tn IS NULL OR :tn = '', 2, 1), e.think = 'train_find', e.nextthink = 0.1e0 WHERE e.id = :eid;
    END
    ELSE IF (cls = 'path_corner') THEN BEGIN END
    ELSE IF (cls IN ('func_wall', 'func_episodegate', 'func_bossgate')) THEN
    BEGIN
      -- an episode gate stands only once its rune is held; the boss gate until all four are
      SELECT g.serverflags FROM game g WHERE g.id = 1 INTO wtype;
      IF (cls = 'func_episodegate' AND BIN_AND(wtype, sf) = 0) THEN DELETE FROM ents e WHERE e.id = :eid;
      ELSE IF (cls = 'func_bossgate' AND BIN_AND(wtype, 15) = 15) THEN DELETE FROM ents e WHERE e.id = :eid;
      ELSE UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0 WHERE e.id = :eid;
    END
    ELSE IF (cls = 'func_illusionary') THEN
      UPDATE ents e SET e.solid = 0, e.movetype = 0, e.yaw = 0 WHERE e.id = :eid;
    -- ── triggers ──
    ELSE IF (cls IN ('trigger_multiple', 'trigger_once', 'trigger_secret', 'trigger_counter', 'trigger_teleport', 'trigger_changelevel',
                     'trigger_push', 'trigger_hurt', 'trigger_monsterjump', 'trigger_relay', 'trigger_setskill')) THEN
    BEGIN
      UPDATE ents e SET e.model_id = NULL, e.solid = IIF(:mdl IS NULL, 0, 1), e.movetype = 0, e.yaw = 0 WHERE e.id = :eid;
      IF (cls = 'trigger_multiple') THEN
      BEGIN
        n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' WHEN 3 THEN 'misc/trigger1.wav' ELSE NULL END;
        UPDATE ents e SET e.wait_ = IIF(COALESCE(:wt, 0) = 0, 0.2e0, :wt), e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0),
               e.solid = IIF(:hp > 0, 2, e.solid) WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_once') THEN
      BEGIN
        n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' WHEN 3 THEN 'misc/trigger1.wav' ELSE NULL END;
        UPDATE ents e SET e.wait_ = -1, e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0), e.solid = IIF(:hp > 0, 2, e.solid) WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_secret') THEN
      BEGIN
        UPDATE game g SET g.total_secrets = g.total_secrets + 1 WHERE g.id = 1;
        n1 = CASE COALESCE(snds, 1) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' ELSE 'misc/secret.wav' END;
        UPDATE ents e SET e.wait_ = -1, e.noise1 = :n1, e.message = COALESCE(:msg, 'You found a secret area!') WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_counter') THEN
        UPDATE ents e SET e.wait_ = -1, e.count_ = IIF(COALESCE(:cnt, 0) = 0, 2, :cnt) WHERE e.id = :eid;
      ELSE IF (cls = 'trigger_push') THEN
      BEGIN
        EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
        UPDATE ents e SET e.speed = IIF(COALESCE(:spd, 0) = 0, 1000, :spd), e.p1x = :dx, e.p1y = :dy, e.p1z = :dz WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_hurt') THEN
        UPDATE ents e SET e.dmg = IIF(COALESCE(:dmg, 0) = 0, 5, :dmg) WHERE e.id = :eid;
      ELSE IF (cls = 'trigger_monsterjump') THEN
        UPDATE ents e SET e.speed = IIF(COALESCE(:spd, 0) = 0, 200, :spd), e.height = IIF(COALESCE(:hgt, 0) = 0, 200, :hgt) WHERE e.id = :eid;
    END
    ELSE IF (cls IN ('info_teleport_destination', 'info_null', 'info_notnull')) THEN
      UPDATE ents e SET e.solid = 0, e.yaw = COALESCE(:ang, 0) WHERE e.id = :eid;
    -- ── items ──
    ELSE IF (cls LIKE 'item_%' OR cls LIKE 'weapon_%') THEN
    BEGIN
      mdl = CASE cls
        WHEN 'item_health' THEN TRIM(IIF(BIN_AND(sf, 2) <> 0, 'maps/b_bh100.bsp', IIF(BIN_AND(sf, 1) <> 0, 'maps/b_bh10.bsp', 'maps/b_bh25.bsp')))
        WHEN 'item_armor1' THEN 'progs/armor.mdl' WHEN 'item_armor2' THEN 'progs/armor.mdl' WHEN 'item_armorInv' THEN 'progs/armor.mdl'
        WHEN 'item_shells' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_shell1.bsp', 'maps/b_shell0.bsp')
        WHEN 'item_spikes' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_nail1.bsp', 'maps/b_nail0.bsp')
        WHEN 'item_rockets' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_rock1.bsp', 'maps/b_rock0.bsp')
        WHEN 'item_cells' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_batt1.bsp', 'maps/b_batt0.bsp')
        WHEN 'item_key1' THEN NULL WHEN 'item_key2' THEN NULL
        WHEN 'item_sigil' THEN 'progs/end1.mdl'
        WHEN 'item_artifact_invulnerability' THEN 'progs/invulner.mdl' WHEN 'item_artifact_invisibility' THEN 'progs/invisibl.mdl'
        WHEN 'item_artifact_super_damage' THEN 'progs/quaddama.mdl' WHEN 'item_artifact_envirosuit' THEN 'progs/suit.mdl'
        WHEN 'weapon_supershotgun' THEN 'progs/g_shot.mdl' WHEN 'weapon_nailgun' THEN 'progs/g_nail.mdl' WHEN 'weapon_supernailgun' THEN 'progs/g_nail2.mdl'
        WHEN 'weapon_grenadelauncher' THEN 'progs/g_rock.mdl' WHEN 'weapon_rocketlauncher' THEN 'progs/g_rock2.mdl' WHEN 'weapon_lightning' THEN 'progs/g_light.mdl'
        ELSE NULL END;
      IF (cls IN ('item_key1', 'item_key2')) THEN
      BEGIN
        SELECT g.world_type FROM game g WHERE g.id = 1 INTO wtype;
        mdl = CASE wtype WHEN 2 THEN IIF(cls = 'item_key1', 'progs/b_s_key.mdl', 'progs/b_g_key.mdl')
                         WHEN 1 THEN IIF(cls = 'item_key1', 'progs/m_s_key.mdl', 'progs/m_g_key.mdl')
                         ELSE IIF(cls = 'item_key1', 'progs/w_s_key.mdl', 'progs/w_g_key.mdl') END;
        IF (model_by_name(mdl) IS NULL) THEN mdl = IIF(cls = 'item_key1', 'progs/w_s_key.mdl', 'progs/w_g_key.mdl');
      END
      EXECUTE PROCEDURE set_model(eid, mdl);
      UPDATE ents e SET e.solid = 1, e.movetype = 6, e.flags = 256, e.yaw = 0,
             e.skin = CASE :cls WHEN 'item_armor2' THEN 1 WHEN 'item_armorInv' THEN 2 ELSE 0 END WHERE e.id = :eid;
      IF (mdl IS NULL OR mdl NOT STARTING WITH 'maps/') THEN
        UPDATE ents e SET e.minx = -16, e.miny = -16, e.minz = 0, e.maxx = 16, e.maxy = 16, e.maxz = 56 WHERE e.id = :eid;
      ELSE
        UPDATE ents e SET e.minx = 0, e.miny = 0, e.minz = 0, e.maxx = 32, e.maxy = 32, e.maxz = IIF(:cls = 'item_health', 32, 56) WHERE e.id = :eid;
      -- items start 6 units above the floor and drop
      UPDATE ents e SET e.z = e.z + 6 WHERE e.id = :eid;
      EXECUTE PROCEDURE drop_to_floor(eid);
    END
    -- ── monsters ──
    ELSE IF (cls LIKE 'monster_%') THEN
    BEGIN
      mname = SUBSTRING(cls FROM 9);
      SELECT t.model, t.health, t.hull, t.maxz, t.flags, t.yaw_speed, t.stand_anim FROM monster_types t WHERE t.name = :mname
        INTO mmodel, mhp, mhull, mmaxz, mflags, mys, stand;
      IF (mmodel IS NULL) THEN BEGIN DELETE FROM ents e WHERE e.id = :eid; CONTINUE; END
      EXECUTE PROCEDURE set_model(eid, mmodel);
      UPDATE ents e SET e.mtype = :mname, e.health = :mhp, e.max_health = :mhp, e.solid = 3, e.takedamage = 2,
             e.movetype = IIF(BIN_AND(:mflags, 3) <> 0, 5, 4), e.flags = BIN_OR(32, :mflags), e.yaw_speed = :mys,
             e.minx = IIF(:mhull = 2, -32, -16), e.miny = IIF(:mhull = 2, -32, -16), e.minz = -24,
             e.maxx = IIF(:mhull = 2, 32, 16), e.maxy = IIF(:mhull = 2, 32, 16), e.maxz = :mmaxz,
             e.st = 'stand', e.anim = :stand, e.anim_frame = FLOOR(RAND() * 4), e.ideal_yaw = e.yaw,
             e.think = 'monster_think', e.nextthink = 0.1e0 + RAND() * 0.5e0 WHERE e.id = :eid;
      IF (mname = 'fish') THEN
        UPDATE ents e SET e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 24 WHERE e.id = :eid;
      IF (mname = 'oldone') THEN
        UPDATE ents e SET e.minx = -160, e.miny = -128, e.minz = -24, e.maxx = 160, e.maxy = 128, e.maxz = 256, e.takedamage = 0, e.movetype = 0 WHERE e.id = :eid;
      IF (mname = 'zombie' AND BIN_AND(sf, 1) <> 0) THEN       -- SPAWN_CRUCIFIED
        UPDATE ents e SET e.solid = 0, e.takedamage = 0, e.movetype = 0, e.anim = 'cruc_', e.flags = 0, e.st = 'cruc' WHERE e.id = :eid;
      ELSE
      BEGIN
        UPDATE game g SET g.total_monsters = g.total_monsters + 1 WHERE g.id = 1;
        IF (mname = 'boss') THEN
          UPDATE ents e SET e.model_id = NULL, e.solid = 0, e.takedamage = 0, e.movetype = 0, e.st = 'asleep', e.nextthink = NULL,
                 e.minx = -128, e.miny = -128, e.minz = -24, e.maxx = 128, e.maxy = 128, e.maxz = 256 WHERE e.id = :eid;
        ELSE IF (BIN_AND(mflags, 3) = 0) THEN EXECUTE PROCEDURE drop_to_floor(eid);
        ELSE EXECUTE PROCEDURE link_ent(eid);
        IF (tg IS NOT NULL AND tg <> '' AND mname <> 'boss') THEN
          UPDATE ents e SET e.st = 'walk', e.anim = NULL WHERE e.id = :eid;
      END
    END
    -- ── decorations and traps ──
    ELSE IF (cls = 'light_torch_small_walltorch') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/flame.mdl');
      UPDATE ents e SET e.solid = 0, e.effects = 8 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls IN ('light_flame_large_yellow', 'light_flame_small_yellow', 'light_flame_small_white')) THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/flame2.mdl');
      UPDATE ents e SET e.solid = 0, e.frame = IIF(:cls = 'light_flame_large_yellow', 0, 1), e.effects = 8 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'misc_explobox' OR cls = 'misc_explobox2') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, IIF(cls = 'misc_explobox', 'maps/b_explob.bsp', 'maps/b_exbox2.bsp'));
      UPDATE ents e SET e.solid = 2, e.movetype = 0, e.health = 20, e.takedamage = 2, e.yaw = 0,
             e.minx = 0, e.miny = 0, e.minz = 0, e.maxx = 32, e.maxy = 32, e.maxz = IIF(:cls = 'misc_explobox', 64, 32) WHERE e.id = :eid;
      EXECUTE PROCEDURE drop_to_floor(eid);
    END
    ELSE IF (cls = 'misc_fireball') THEN
      UPDATE ents e SET e.solid = 0, e.speed = IIF(COALESCE(:spd, 0) = 0, 1000, :spd), e.think = 'fireball_think', e.nextthink = RAND() * 5 WHERE e.id = :eid;
    ELSE IF (cls = 'trap_spikeshooter' OR cls = 'trap_shooter') THEN
    BEGIN
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      UPDATE ents e SET e.solid = 0, e.p1x = :dx, e.p1y = :dy, e.p1z = :dz, e.wait_ = IIF(COALESCE(:wt, 0) = 0, 1, :wt) WHERE e.id = :eid;
      IF (cls = 'trap_shooter') THEN UPDATE ents e SET e.think = 'shooter_think', e.nextthink = e.wait_ WHERE e.id = :eid;
    END
    ELSE IF (cls = 'event_lightning') THEN UPDATE ents e SET e.solid = 0 WHERE e.id = :eid;
    ELSE IF (cls = 'misc_teleporttrain') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/teleport.mdl');
      UPDATE ents e SET e.classname = 'trigger_teleport', e.solid = 1, e.movetype = 0, e.avel_yaw = 100, e.effects = 8,
             e.minx = -16, e.miny = -16, e.minz = -16, e.maxx = 16, e.maxy = 16, e.maxz = 16, e.target = :tg, e.targetname = :tn,
             e.speed = IIF(COALESCE(:spd, 0) = 0, 100, :spd), e.mv_state = 2, e.think = 'teleporttrain_next', e.nextthink = 0.1e0 WHERE e.id = :eid;
    END
    ELSE
      UPDATE ents e SET e.solid = 0 WHERE e.id = :eid;
  END

  -- LinkDoors: doors whose boxes touch open together (unless DOOR_DONT_LINK)
  FOR SELECT e.id FROM ents e WHERE e.classname = 'func_door' AND BIN_AND(e.spawnflags, 4) = 0 ORDER BY e.id INTO eid DO
  BEGIN
    SELECT MIN(COALESCE(o.linked_id, o.id)) FROM ents o
     WHERE o.classname = 'func_door' AND BIN_AND(o.spawnflags, 4) = 0 AND o.id < :eid
       AND EXISTS (SELECT 1 FROM ents s WHERE s.id = :eid
                   AND s.x + s.minx <= o.x + o.maxx AND s.x + s.maxx >= o.x + o.minx
                   AND s.y + s.miny <= o.y + o.maxy AND s.y + s.maxy >= o.y + o.miny
                   AND s.z + s.minz <= o.z + o.maxz AND s.z + s.maxz >= o.z + o.minz)
      INTO mid;
    IF (mid IS NOT NULL) THEN
    BEGIN
      UPDATE ents e SET e.linked_id = :mid WHERE e.id = :eid;
      -- the master carries the group's key, message and targetname
      UPDATE ents m SET m.items = BIN_OR(m.items, (SELECT e.items FROM ents e WHERE e.id = :eid)),
             m.message = COALESCE(m.message, (SELECT e.message FROM ents e WHERE e.id = :eid)),
             m.targetname = COALESCE(m.targetname, (SELECT e.targetname FROM ents e WHERE e.id = :eid)),
             m.max_health = MAXVALUE(m.max_health, (SELECT e.max_health FROM ents e WHERE e.id = :eid))
       WHERE m.id = :mid;
    END
  END
END^

CREATE OR ALTER PROCEDURE train_find (eid INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION; DECLARE st SMALLINT;
BEGIN
  SELECT e.target, e.mv_state FROM ents e WHERE e.id = :eid INTO tgt, st;
  SELECT FIRST 1 e.x, e.y, e.z FROM ents e WHERE e.targetname = :tgt AND e.classname = 'path_corner' INTO cx, cy, cz;
  IF (cx IS NOT NULL) THEN
    UPDATE ents e SET e.x = :cx - e.minx, e.y = :cy - e.miny, e.z = :cz - e.minz, e.think = NULL, e.nextthink = NULL WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
  IF (st = 2) THEN EXECUTE PROCEDURE train_next(eid);
END^

CREATE OR ALTER PROCEDURE fireball_think (eid INTEGER)
AS
DECLARE f INTEGER; DECLARE spd DOUBLE PRECISION;
BEGIN
  SELECT e.speed FROM ents e WHERE e.id = :eid INTO spd;
  EXECUTE PROCEDURE spawn_ent('fireball', (SELECT e.x FROM ents e WHERE e.id = :eid), (SELECT e.y FROM ents e WHERE e.id = :eid), (SELECT e.z FROM ents e WHERE e.id = :eid))
    RETURNING_VALUES f;
  EXECUTE PROCEDURE set_model(f, 'progs/lavaball.mdl');
  UPDATE ents e SET e.solid = 1, e.movetype = 6, e.vx = RAND() * 100 - 50, e.vy = RAND() * 100 - 50, e.vz = :spd + RAND() * 200,
         e.avel_yaw = 200, e.think = 'remove', e.nextthink = now_() + 5, e.effects = 4 WHERE e.id = :f;
  UPDATE ents e SET e.nextthink = now_() + RAND() * 5 + 3 WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE spikeshooter_fire (eid INTEGER)
AS
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE sf INTEGER;
BEGIN
  SELECT e.x, e.y, e.z, e.p1x, e.p1y, e.p1z, e.spawnflags FROM ents e WHERE e.id = :eid INTO x, y, z, dx, dy, dz, sf;
  EXECUTE PROCEDURE snd(eid, 0, 'weapons/spike2.wav', 1, 1);
  EXECUTE PROCEDURE launch_spike(eid, x, y, z, dx, dy, dz, 500, IIF(BIN_AND(sf, 2) <> 0, 'superspike', 'spike'));
END^

CREATE OR ALTER PROCEDURE shooter_think (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE spikeshooter_fire(eid);
  UPDATE ents e SET e.nextthink = now_() + e.wait_ WHERE e.id = :eid;
END^

SET TERM ; ^
