-- triggers.sql – SUB_UseTargets and the triggers (triggers.qc, subs.qc): multiple and once,
-- counters, relays, changelevel, teleporters.

SET TERM ^ ;

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
   WHERE m.classname = 'info_intermission' ORDER BY rnd() INTO cx, cy, cz, cp, cyaw;
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
    EXECUTE PROCEDURE snd(other, 0, 'misc/r_tele' || CAST(1 + FLOOR(rnd() * 5) AS INTEGER) || '.wav', 1, 1);
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
  EXECUTE PROCEDURE snd_at(dx, dy, dz, 'misc/r_tele' || CAST(1 + FLOOR(rnd() * 5) AS INTEGER) || '.wav', 1, 1);
  EXECUTE PROCEDURE fx(5, dx, dy, dz + 27, 0, 0, 0, 0);
END^

SET TERM ; ^
