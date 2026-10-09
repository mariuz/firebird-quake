-- movers.sql – doors, plats, buttons, trains and secret doors (doors.qc, plats.qc, buttons.qc,
-- misc.qc): SUB_CalcMove's pushers and what they do at each end. The forward declarations
-- they call are in game.sql.

SET TERM ^ ;

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

SET TERM ; ^
