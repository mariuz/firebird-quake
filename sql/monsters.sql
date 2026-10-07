-- monsters.sql – ai.qc, fight.qc and the monsters' .qc files, plus the
-- per-tic driver (sv_main.c's SV_Physics) and level setup.

SET TERM ^ ;

CREATE OR ALTER PROCEDURE run_think (eid INTEGER, think VARCHAR(24)) AS BEGIN END^
CREATE OR ALTER PROCEDURE teleporttrain_next (eid INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE mover_blocked (eid INTEGER, other INTEGER) AS BEGIN END^

-- the current frame of an entity's animation
CREATE OR ALTER PROCEDURE set_anim (eid INTEGER, anim VARCHAR(16))
AS
DECLARE mid INTEGER; DECLARE ff INTEGER;
BEGIN
  SELECT e.model_id FROM ents e WHERE e.id = :eid INTO mid;
  SELECT a.first_frame FROM anims a WHERE a.model_id = :mid AND a.anim = :anim INTO ff;
  IF (ff IS NULL) THEN SELECT FIRST 1 a.first_frame FROM anims a WHERE a.model_id = :mid ORDER BY a.first_frame INTO ff;
  UPDATE ents e SET e.anim = :anim, e.anim_frame = 0, e.frame = COALESCE(:ff, 0) WHERE e.id = :eid;
END^

-- ChangeYaw: turn toward ideal_yaw by at most yaw_speed
CREATE OR ALTER PROCEDURE change_yaw (eid INTEGER)
AS
DECLARE cur DOUBLE PRECISION; DECLARE ideal DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION; DECLARE mv DOUBLE PRECISION;
BEGIN
  SELECT anglemod(e.yaw), e.ideal_yaw, e.yaw_speed FROM ents e WHERE e.id = :eid INTO cur, ideal, spd;
  IF (cur = ideal) THEN EXIT;
  mv = ideal - cur;
  IF (ideal > cur) THEN BEGIN IF (mv >= 180) THEN mv = mv - 360; END
  ELSE BEGIN IF (mv <= -180) THEN mv = mv + 360; END
  IF (mv > 0) THEN BEGIN IF (mv > spd) THEN mv = spd; END
  ELSE BEGIN IF (mv < -spd) THEN mv = -spd; END
  UPDATE ents e SET e.yaw = anglemod(:cur + :mv) WHERE e.id = :eid;
END^

CREATE OR ALTER FUNCTION facing_ideal (eid INTEGER) RETURNS SMALLINT
AS
DECLARE d DOUBLE PRECISION;
BEGIN
  SELECT anglemod(e.yaw - e.ideal_yaw) FROM ents e WHERE e.id = :eid INTO d;
  RETURN IIF(d > 45 AND d < 315, 0, 1);
END^

-- SV_StepDirection: turn to yaw and try to step dist that way
CREATE OR ALTER FUNCTION step_direction (eid INTEGER, yaw DOUBLE PRECISION, dist DOUBLE PRECISION) RETURNS SMALLINT
AS
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE d DOUBLE PRECISION;
BEGIN
  UPDATE ents e SET e.ideal_yaw = :yaw WHERE e.id = :eid;
  EXECUTE PROCEDURE change_yaw(eid);
  SELECT e.x, e.y, e.z FROM ents e WHERE e.id = :eid INTO ox, oy, oz;
  IF (move_step(eid, COS(yaw * 0.0174532925e0) * dist, SIN(yaw * 0.0174532925e0) * dist, 0) = 1) THEN
  BEGIN
    SELECT anglemod(e.yaw - e.ideal_yaw) FROM ents e WHERE e.id = :eid INTO d;
    IF (d > 45 AND d < 315) THEN
    BEGIN
      -- not turned far enough, so don't take the step
      UPDATE ents e SET e.x = :ox, e.y = :oy, e.z = :oz WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    RETURN 1;
  END
  RETURN 0;
END^

-- SV_NewChaseDir: pick a direction toward the goal, trying the sides
CREATE OR ALTER PROCEDURE new_chase_dir (eid INTEGER, goal INTEGER, dist DOUBLE PRECISION)
AS
DECLARE olddir DOUBLE PRECISION; DECLARE turnaround DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE d1 DOUBLE PRECISION; DECLARE d2 DOUBLE PRECISION; DECLARE tdir DOUBLE PRECISION;
DECLARE nodir DOUBLE PRECISION = -1;
BEGIN
  SELECT anglemod(FLOOR(e.ideal_yaw / 45) * 45) FROM ents e WHERE e.id = :eid INTO olddir;
  turnaround = anglemod(olddir - 180);
  SELECT g.x - e.x, g.y - e.y FROM ents e CROSS JOIN ents g WHERE e.id = :eid AND g.id = :goal INTO dx, dy;
  IF (dx IS NULL) THEN EXIT;
  d1 = IIF(dx > 10, 0, IIF(dx < -10, 180, nodir));
  d2 = IIF(dy < -10, 270, IIF(dy > 10, 90, nodir));
  -- try direct route
  IF (d1 <> nodir AND d2 <> nodir) THEN
  BEGIN
    tdir = IIF(d1 = 0, IIF(d2 = 90, 45, 315), IIF(d2 = 90, 135, 215));
    IF (tdir <> turnaround AND step_direction(eid, tdir, dist) = 1) THEN EXIT;
  END
  -- try other directions
  IF (RAND() < 0.5e0 OR ABS(dy) > ABS(dx)) THEN BEGIN tdir = d1; d1 = d2; d2 = tdir; END
  IF (d1 <> nodir AND d1 <> turnaround AND step_direction(eid, d1, dist) = 1) THEN EXIT;
  IF (d2 <> nodir AND d2 <> turnaround AND step_direction(eid, d2, dist) = 1) THEN EXIT;
  -- there is no direct path to the player, so pick another direction
  IF (olddir <> nodir AND step_direction(eid, olddir, dist) = 1) THEN EXIT;
  tdir = IIF(RAND() < 0.5e0, 0, 315);
  d1 = 0;
  WHILE (d1 < 8) DO
  BEGIN
    IF (step_direction(eid, anglemod(tdir + IIF(tdir = 0, 45, -45) * d1), dist) = 1) THEN EXIT;
    d1 = d1 + 1;
  END
  IF (turnaround <> nodir AND step_direction(eid, turnaround, dist) = 1) THEN EXIT;
  UPDATE ents e SET e.ideal_yaw = :olddir WHERE e.id = :eid;     -- can't move
END^

-- SV_MoveToGoal
CREATE OR ALTER PROCEDURE move_to_goal (eid INTEGER, dist DOUBLE PRECISION)
AS
DECLARE goal INTEGER; DECLARE flags INTEGER; DECLARE iy DOUBLE PRECISION; DECLARE close_ SMALLINT = 0;
BEGIN
  SELECT COALESCE(e.goal_id, e.enemy_id), e.flags, e.ideal_yaw FROM ents e WHERE e.id = :eid INTO goal, flags, iy;
  IF (BIN_AND(flags, 512 + 1 + 2) = 0) THEN EXIT;              -- in the air
  IF (goal IS NULL) THEN EXIT;
  -- SV_CloseEnough: the boxes are within dist
  SELECT 1 FROM ents e CROSS JOIN ents g WHERE e.id = :eid AND g.id = :goal
     AND g.x + g.minx <= e.x + e.maxx + :dist AND g.x + g.maxx >= e.x + e.minx - :dist
     AND g.y + g.miny <= e.y + e.maxy + :dist AND g.y + g.maxy >= e.y + e.minx - :dist
     AND g.z + g.minz <= e.z + e.maxz + :dist AND g.z + g.maxz >= e.z + e.minz - :dist INTO close_;
  IF (close_ = 1 AND EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND e.enemy_id = :goal)) THEN EXIT;
  IF (FLOOR(RAND() * 4) = 1 OR step_direction(eid, iy, dist) = 0) THEN
    EXECUTE PROCEDURE new_chase_dir(eid, goal, dist);
END^

-- FindTarget: can this monster see the player?
CREATE OR ALTER FUNCTION find_target (eid INTEGER) RETURNS SMALLINT
AS
DECLARE pe INTEGER; DECLARE r INTEGER; DECLARE inv DOUBLE PRECISION; DECLARE sh DOUBLE PRECISION; DECLARE php INTEGER;
BEGIN
  pe = player_ent();
  SELECT p.invisible_finished, p.show_hostile FROM player p WHERE p.id = 1 INTO inv, sh;
  SELECT e.health FROM ents e WHERE e.id = :pe INTO php;
  IF (php <= 0) THEN RETURN 0;
  IF (inv > now_() AND RAND() < 0.95e0) THEN RETURN 0;
  r = ent_range(eid, pe);
  IF (r = 3) THEN RETURN 0;
  IF (visible(eid, pe) = 0) THEN RETURN 0;
  IF (r = 1) THEN BEGIN IF (sh < now_() AND infront(eid, pe) = 0) THEN RETURN 0; END
  ELSE IF (r = 2) THEN BEGIN IF (infront(eid, pe) = 0) THEN RETURN 0; END
  RETURN 1;
END^

-- FoundTarget / HuntTarget
CREATE OR ALTER PROCEDURE found_target (eid INTEGER)
AS
DECLARE s VARCHAR(64); DECLARE run_ VARCHAR(16);
BEGIN
  SELECT t.sight_snd, t.run_anim FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid INTO s, run_;
  EXECUTE PROCEDURE snd(eid, 2, s, 1, 1);
  UPDATE ents e SET e.enemy_id = player_ent(), e.goal_id = NULL, e.st = 'run', e.search_time = now_() + 5, e.attack_finished = now_() + 1 WHERE e.id = :eid;
  EXECUTE PROCEDURE set_anim(eid, run_);
END^

-- CheckAttack: decide between melee, missile and keep running
CREATE OR ALTER FUNCTION check_attack (eid INTEGER) RETURNS SMALLINT
AS
DECLARE enemy INTEGER; DECLARE r INTEGER; DECLARE has_melee SMALLINT; DECLARE has_missile SMALLINT; DECLARE af DOUBLE PRECISION;
DECLARE chance DOUBLE PRECISION; DECLARE mk VARCHAR(16); DECLARE ac DOUBLE PRECISION; DECLARE mrange DOUBLE PRECISION;
DECLARE x1 DOUBLE PRECISION; DECLARE y1 DOUBLE PRECISION; DECLARE z1 DOUBLE PRECISION; DECLARE x2 DOUBLE PRECISION; DECLARE y2 DOUBLE PRECISION; DECLARE z2 DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER; DECLARE d DOUBLE PRECISION;
BEGIN
  SELECT e.enemy_id, IIF(t.melee_anim IS NULL, 0, 1), IIF(t.missile_anim IS NULL, 0, 1), e.attack_finished, t.missile_kind, t.attack_chance, t.melee_range
    FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid INTO enemy, has_melee, has_missile, af, mk, ac, mrange;
  IF (enemy IS NULL) THEN RETURN 0;
  -- see if any entities are in the way of the shot
  SELECT e.x, e.y, e.z + e.maxz - 8 FROM ents e WHERE e.id = :eid INTO x1, y1, z1;
  SELECT e.x, e.y, e.z + 22 FROM ents e WHERE e.id = :enemy INTO x2, y2, z2;
  EXECUTE PROCEDURE trace_move(eid, 0, 0, 0, 0, 0, 0, x1, y1, z1, x2, y2, z2, 0)
    RETURNING_VALUES f, ex, ey, ez, nx, ny, nz, als, sts, io, iw, hit;
  IF (f < 1 AND hit <> enemy) THEN RETURN 0;                   -- don't have a clear shot
  IF (io = 1 AND iw = 1) THEN RETURN 0;                        -- sight line crossed contents
  r = ent_range(eid, enemy);
  d = vlen(x2 - x1, y2 - y1, 0);
  IF (has_melee = 1 AND d <= mrange AND (r = 0 OR d < 100)) THEN
  BEGIN
    UPDATE ents e SET e.attack_state = 3 WHERE e.id = :eid;
    RETURN 1;
  END
  -- missile attack
  IF (has_missile = 0) THEN RETURN 0;
  IF (now_() < af) THEN RETURN 0;
  IF (r = 3) THEN RETURN 0;
  IF (mk = 'leap') THEN
  BEGIN
    -- DemonCheckAttack / dog: jump when 100–400 away and roughly level
    IF (d > 400 OR ABS(z1 - z2) > 64) THEN RETURN 0;
    IF (d < 100 AND NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND e.mtype = 'tarbaby')) THEN RETURN 0;   -- the spawn jumps from anywhere
    chance = IIF(r = 1, 0.5e0, 0.2e0);
  END
  ELSE IF (r = 0) THEN chance = 0.9e0;
  ELSE IF (r = 1) THEN chance = IIF(has_melee = 1, 0.2e0, 0.4e0);
  ELSE IF (r = 2) THEN chance = IIF(has_melee = 1, 0.05e0, 0.1e0);
  ELSE chance = 0;
  chance = chance * ac / 0.3e0;
  IF (RAND() < chance) THEN
  BEGIN
    UPDATE ents e SET e.attack_state = 4, e.attack_finished = now_() + 2 * RAND() WHERE e.id = :eid;
    RETURN 1;
  END
  UPDATE ents e SET e.attack_state = IIF(:r = 2, 1, 2) WHERE e.id = :eid;
  RETURN 0;
END^

-- a monster's missile at the frame that fires
CREATE OR ALTER PROCEDURE monster_missile (eid INTEGER)
AS
DECLARE mk VARCHAR(16); DECLARE enemy INTEGER; DECLARE asnd VARCHAR(64);
DECLARE x1 DOUBLE PRECISION; DECLARE y1 DOUBLE PRECISION; DECLARE z1 DOUBLE PRECISION; DECLARE yaw DOUBLE PRECISION;
DECLARE x2 DOUBLE PRECISION; DECLARE y2 DOUBLE PRECISION; DECLARE z2 DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION;
DECLARE evx DOUBLE PRECISION; DECLARE evy DOUBLE PRECISION; DECLARE evz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE hx DOUBLE PRECISION; DECLARE hy DOUBLE PRECISION; DECLARE hz DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER; DECLARE g INTEGER;
BEGIN
  SELECT t.missile_kind, e.enemy_id, t.attack_snd, e.x, e.y, e.z, e.yaw FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid
    INTO mk, enemy, asnd, x1, y1, z1, yaw;
  IF (enemy IS NULL) THEN EXIT;
  SELECT e.x, e.y, e.z, e.vx, e.vy, e.vz FROM ents e WHERE e.id = :enemy INTO x2, y2, z2, evx, evy, evz;
  IF (x2 IS NULL) THEN EXIT;
  IF (mk = 'shotgun') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    EXECUTE PROCEDURE fire_bullets(eid, 4, x1, y1, z1 + 20, x2 - x1, y2 - y1, z2 + 16 - z1 - 20, 0.1e0, 0.1e0);
  END
  ELSE IF (mk = 'grenade') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 - z1; dl = vlen(dx, dy, dz);
    IF (dl = 0) THEN EXIT;
    EXECUTE PROCEDURE launch_grenade(eid, x1, y1, z1 + 16, dx / dl * 600, dy / dl * 600, dz / dl * 600 + 200, 40, 'progs/grenade.mdl', 2.5e0);
  END
  ELSE IF (mk = 'wspike') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 - z1;
    EXECUTE PROCEDURE launch_spike(eid, x1 + SIN(yaw * 0.0174532925e0) * 14, y1 - COS(yaw * 0.0174532925e0) * 14, z1 + 30, dx, dy, dz, 600, 'wizspike');
  END
  ELSE IF (mk = 'gib') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 - z1; dl = vlen(dx, dy, dz);
    IF (dl = 0) THEN EXIT;
    EXECUTE PROCEDURE spawn_ent('zombie_gib', x1, y1, z1 + 24) RETURNING_VALUES g;
    EXECUTE PROCEDURE set_model(g, 'progs/zom_gib.mdl');
    UPDATE ents e SET e.owner_id = :eid, e.movetype = 10, e.solid = 2, e.vx = :dx / :dl * 600, e.vy = :dy / :dl * 600, e.vz = :dz / :dl * 600 + 200,
           e.avel_yaw = 300, e.think = 'remove', e.nextthink = now_() + 2.5e0 WHERE e.id = :g;
  END
  ELSE IF (mk = 'lavaball') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1 + evx * 0.3e0; dy = y2 - y1 + evy * 0.3e0; dz = z2 - z1 + 100;
    EXECUTE PROCEDURE launch_rocket(eid, x1 + COS(yaw * 0.0174532925e0) * 80, y1 + SIN(yaw * 0.0174532925e0) * 80, z1 + 100, dx, dy, dz, 300, 100, 'progs/lavaball.mdl');
    UPDATE ents e SET e.classname = 'lavaball', e.movetype = 6, e.vz = e.vz + 150 WHERE e.id = (SELECT MAX(r.id) FROM ents r WHERE r.classname = 'rocket' AND r.owner_id = :eid);
  END
  ELSE IF (mk = 'lightning') THEN
  BEGIN
    -- CastLightning
    dx = x2 - x1; dy = y2 - y1; dz = z2 + 16 - (z1 + 40); dl = vlen(dx, dy, dz);
    IF (dl = 0) THEN EXIT;
    EXECUTE PROCEDURE trace_move(eid, 0, 0, 0, 0, 0, 0, x1, y1, z1 + 40, x1 + dx / dl * 600, y1 + dy / dl * 600, z1 + 40 + dz / dl * 600, 1)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    EXECUTE PROCEDURE snd(eid, 1, 'shambler/sboom.wav', 1, 1);
    EXECUTE PROCEDURE fx(4, x1, y1, z1 + 40, hx, hy, hz, eid);
    EXECUTE PROCEDURE lightning_damage(eid, x1, y1, z1 + 40, hx, hy, hz, 10);
  END
  ELSE IF (mk = 'laser') THEN
  BEGIN
    -- enforcer: a laser bolt from the gun, 15 damage
    EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 + 16 - z1 - 20;
    EXECUTE PROCEDURE launch_rocket(eid, x1 + COS(yaw * 0.0174532925e0) * 30 + SIN(yaw * 0.0174532925e0) * 8.5e0,
      y1 + SIN(yaw * 0.0174532925e0) * 30 - COS(yaw * 0.0174532925e0) * 8.5e0, z1 + 16, dx, dy, dz, 600, 15, 'progs/laser.mdl');
    UPDATE ents e SET e.classname = 'laser', e.effects = 4 WHERE e.id = (SELECT MAX(r.id) FROM ents r WHERE r.classname = 'rocket' AND r.owner_id = :eid);
  END
  ELSE IF (mk = 'kspike') THEN
  BEGIN
    -- hell knight: one flame spike per frame, fanned around the aim
    IF ((SELECT e.anim_frame FROM ents e WHERE e.id = :eid) = 6) THEN EXECUTE PROCEDURE snd(eid, 1, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 - z1;
    dl = ((SELECT e.anim_frame FROM ents e WHERE e.id = :eid) - 8.5e0) * 0.1e0;
    EXECUTE PROCEDURE launch_spike(eid, x1, y1, z1 + 20, dx - dy * dl * 0.7e0, dy + dx * dl * 0.7e0, dz, 300, 'kspike');
  END
  ELSE IF (mk = 'voreball') THEN
  BEGIN
    -- vore: a homing pod
    EXECUTE PROCEDURE snd(eid, 1, 'shalrath/attack2.wav', 1, 1);
    dx = x2 - x1; dy = y2 - y1; dz = z2 - z1;
    EXECUTE PROCEDURE launch_rocket(eid, x1, y1, z1 + 10, dx, dy, dz, 400, 40, 'progs/v_spike.mdl');
    UPDATE ents e SET e.classname = 'voreball', e.effects = 0, e.think = 'vore_track', e.nextthink = now_() + 0.1e0, e.enemy_id = :enemy
     WHERE e.id = (SELECT MAX(r.id) FROM ents r WHERE r.classname = 'rocket' AND r.owner_id = :eid);
  END
  ELSE IF (mk = 'leap') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 2, asnd, 1, 1);
    dx = x2 - x1; dy = y2 - y1; dl = vlen(dx, dy, 0);
    IF (dl = 0) THEN EXIT;
    UPDATE ents e SET e.vx = :dx / :dl * 300, e.vy = :dy / :dl * 300, e.vz = 200 + IIF(e.mtype = 'demon1', 50, 0),
           e.flags = BIN_AND(e.flags, BIN_NOT(512)), e.movetype = 6, e.attack_state = 5 WHERE e.id = :eid;
  END
END^

-- ai_melee at the frame that hits
CREATE OR ALTER PROCEDURE monster_melee (eid INTEGER)
AS
DECLARE enemy INTEGER; DECLARE d DOUBLE PRECISION; DECLARE dmg INTEGER; DECLARE ms VARCHAR(64); DECLARE mrange DOUBLE PRECISION; DECLARE mt VARCHAR(16);
BEGIN
  SELECT e.enemy_id, t.melee_dmg, t.melee_snd, t.melee_range, e.mtype FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid
    INTO enemy, dmg, ms, mrange, mt;
  IF (enemy IS NULL) THEN EXIT;
  SELECT vlen(a.x - b.x, a.y - b.y, a.z - b.z) FROM ents a CROSS JOIN ents b WHERE a.id = :eid AND b.id = :enemy INTO d;
  IF (d IS NULL OR d > mrange) THEN EXIT;
  IF (ms IS NOT NULL) THEN EXECUTE PROCEDURE snd(eid, 1, ms, 1, 1);
  dmg = CAST(dmg * (0.5e0 + RAND()) AS INTEGER);
  EXECUTE PROCEDURE t_damage(enemy, eid, eid, dmg);
  EXECUTE PROCEDURE fx(3, (SELECT e.x FROM ents e WHERE e.id = :enemy), (SELECT e.y FROM ents e WHERE e.id = :enemy), (SELECT e.z + 10 FROM ents e WHERE e.id = :enemy), 0, 0, 0, dmg);
END^

-- ShalMissileHome: the vore's pod turns toward its target every 0.1 s
CREATE OR ALTER PROCEDURE vore_track (eid INTEGER)
AS
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE ehp INTEGER;
BEGIN
  SELECT t.x - e.x, t.y - e.y, t.z + 10 - e.z, t.health FROM ents e JOIN ents t ON t.id = e.enemy_id WHERE e.id = :eid INTO dx, dy, dz, ehp;
  IF (dx IS NULL OR ehp <= 0) THEN
  BEGIN
    DELETE FROM ents e WHERE e.id = :eid;
    EXIT;
  END
  dl = vlen(dx, dy, dz);
  IF (dl = 0) THEN EXIT;
  UPDATE ents e SET e.vx = :dx / :dl * 350, e.vy = :dy / :dl * 350, e.vz = :dz / :dl * 350, e.yaw = vectoyaw(:dx, :dy),
         e.nextthink = now_() + 0.1e0 WHERE e.id = :eid;
END^

-- the spawn (tarbaby) bursts: 120 radius damage, and it is gone
CREATE OR ALTER PROCEDURE tarbaby_explode (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE t_radius_damage(eid, eid, 120, eid);
  EXECUTE PROCEDURE snd(eid, 2, 'blob/death1.wav', 1, 1);
  EXECUTE PROCEDURE fx(8, (SELECT e.x FROM ents e WHERE e.id = :eid), (SELECT e.y FROM ents e WHERE e.id = :eid), (SELECT e.z FROM ents e WHERE e.id = :eid), 0, 0, 0, 0);
  UPDATE game g SET g.killed = g.killed + 1 WHERE g.id = 1;
  DELETE FROM ents e WHERE e.id = :eid;
END^

-- th_pain
CREATE OR ALTER PROCEDURE monster_pain (eid INTEGER, attacker INTEGER, damage INTEGER)
AS
DECLARE st VARCHAR(12); DECLARE pf DOUBLE PRECISION; DECLARE pc DOUBLE PRECISION; DECLARE anims VARCHAR(80); DECLARE ps VARCHAR(64); DECLARE n INTEGER; DECLARE pick VARCHAR(16);
DECLARE p INTEGER; DECLARE q INTEGER; DECLARE i INTEGER; DECLARE mt VARCHAR(16); DECLARE hp INTEGER;
BEGIN
  SELECT e.st, e.pain_finished, t.pain_chance, t.pain_anims, t.pain_snd, e.mtype, e.health FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid
    INTO st, pf, pc, anims, ps, mt, hp;
  IF (st IN ('die', 'dead', 'cruc', 'asleep')) THEN EXIT;
  IF (mt = 'zombie') THEN
  BEGIN
    -- zombies only go down from a big hit, and always get back up
    UPDATE ents e SET e.health = 60 WHERE e.id = :eid;
    IF (damage < 9) THEN EXIT;
    IF (pf > now_()) THEN EXIT;
    EXECUTE PROCEDURE snd(eid, 2, ps, 1, 1);
    IF (damage >= 25) THEN pick = 'paine'; ELSE pick = IIF(RAND() < 0.5e0, 'paina', IIF(RAND() < 0.5e0, 'painb', IIF(RAND() < 0.5e0, 'painc', 'paind')));
    UPDATE ents e SET e.st = 'pain', e.pain_finished = now_() + IIF(:pick = 'paine', 3, 1) WHERE e.id = :eid;
    EXECUTE PROCEDURE set_anim(eid, pick);
    EXIT;
  END
  IF (pf > now_()) THEN EXIT;
  IF (RAND() > pc) THEN EXIT;
  IF (mt = 'boss') THEN EXIT;
  EXECUTE PROCEDURE snd(eid, 2, ps, 1, 1);
  -- pick one of the pain animations
  n = 1; p = 1;
  WHILE (POSITION(',', anims, p) > 0) DO BEGIN n = n + 1; p = POSITION(',', anims, p) + 1; END
  i = FLOOR(RAND() * n); p = 1;
  WHILE (i > 0) DO BEGIN p = POSITION(',', anims, p) + 1; i = i - 1; END
  q = POSITION(',', anims, p);
  pick = IIF(q = 0, SUBSTRING(anims FROM p), SUBSTRING(anims FROM p FOR q - p));
  UPDATE ents e SET e.st = 'pain', e.pain_finished = now_() + 1, e.vx = 0, e.vy = 0 WHERE e.id = :eid;
  EXECUTE PROCEDURE set_anim(eid, pick);
END^

-- th_die
CREATE OR ALTER PROCEDURE monster_die (eid INTEGER, attacker INTEGER)
AS
DECLARE hp INTEGER; DECLARE gh INTEGER; DECLARE hm VARCHAR(40); DECLARE ds VARCHAR(64); DECLARE anims VARCHAR(80); DECLARE drop_ VARCHAR(16);
DECLARE pick VARCHAR(16); DECLARE q INTEGER; DECLARE mt VARCHAR(16); DECLARE st VARCHAR(12); DECLARE bp INTEGER;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION;
BEGIN
  SELECT e.health, t.gib_health, t.head_model, t.death_snd, t.death_anims, t.drop_item, e.mtype, e.st, e.x, e.y, e.z
    FROM ents e JOIN monster_types t ON t.name = e.mtype WHERE e.id = :eid INTO hp, gh, hm, ds, anims, drop_, mt, st, x, y, z;
  IF (st IN ('die', 'dead')) THEN
  BEGIN
    -- gibbing a corpse
    IF (hp < gh AND hm IS NOT NULL) THEN
    BEGIN
      EXECUTE PROCEDURE snd(eid, 2, 'player/udeath.wav', 1, 1);
      EXECUTE PROCEDURE throw_gib(eid, 'progs/gib1.mdl', -hp);
      EXECUTE PROCEDURE throw_gib(eid, 'progs/gib2.mdl', -hp);
      EXECUTE PROCEDURE throw_gib(eid, 'progs/gib3.mdl', -hp);
      EXECUTE PROCEDURE throw_head(eid, hm, -hp);
    END
    EXIT;
  END
  IF (mt = 'tarbaby') THEN
  BEGIN
    IF (attacker = player_ent()) THEN UPDATE player p SET p.kills = p.kills + 1 WHERE p.id = 1;
    EXECUTE PROCEDURE tarbaby_explode(eid);
    EXIT;
  END
  IF (mt = 'oldone') THEN
  BEGIN
    -- finale_1: Shub-Niggurath is dead; the browser shows the ending
    EXECUTE PROCEDURE snd(eid, 2, ds, 1, 1);
    UPDATE ents e SET e.st = 'die', e.solid = 0, e.takedamage = 0, e.movetype = 0 WHERE e.id = :eid;
    EXECUTE PROCEDURE set_anim(eid, 'shake');
    UPDATE game g SET g.finale = 1, g.killed = g.killed + 1 WHERE g.id = 1;
    UPDATE ents e SET e.health = 0, e.st = 'dead', e.nextthink = NULL WHERE e.mtype IS NOT NULL AND e.id <> :eid AND e.health > 0 AND e.st <> 'cruc';
    EXECUTE PROCEDURE cprint('Congratulations and well done! You have beaten the hideous Shub-Niggurath, and its hordes of spawn.');
    EXIT;
  END
  UPDATE game g SET g.killed = g.killed + 1 WHERE g.id = 1;
  IF (attacker = player_ent()) THEN UPDATE player p SET p.kills = p.kills + 1 WHERE p.id = 1;
  -- drop the backpack
  IF (drop_ IS NOT NULL) THEN
  BEGIN
    EXECUTE PROCEDURE spawn_ent('backpack', x, y, z - 24) RETURNING_VALUES bp;
    EXECUTE PROCEDURE set_model(bp, 'progs/backpack.mdl');
    UPDATE ents e SET e.solid = 1, e.movetype = 6, e.flags = 256, e.minx = -16, e.miny = -16, e.minz = 0, e.maxx = 16, e.maxy = 16, e.maxz = 56,
           e.ammo_shells = IIF(:drop_ = 'shells', 5, 0), e.ammo_rockets = IIF(:drop_ = 'rockets', 2, 0), e.ammo_cells = IIF(:drop_ = 'cells', 5, 0),
           e.think = 'remove', e.nextthink = now_() + 120 WHERE e.id = :bp;
    EXECUTE PROCEDURE drop_to_floor(bp);
  END
  IF (mt = 'boss') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 2, ds, 1, 1);
    UPDATE ents e SET e.st = 'die', e.solid = 0, e.takedamage = 0, e.movetype = 0 WHERE e.id = :eid;
    EXECUTE PROCEDURE set_anim(eid, 'death');
    EXECUTE PROCEDURE use_targets(eid, player_ent());
    EXIT;
  END
  -- gib?
  IF (hp < gh OR mt = 'zombie') THEN
  BEGIN
    EXECUTE PROCEDURE snd(eid, 2, IIF(mt = 'zombie', 'zombie/z_gib.wav', 'player/udeath.wav'), 1, 1);
    EXECUTE PROCEDURE throw_gib(eid, 'progs/gib1.mdl', -hp);
    EXECUTE PROCEDURE throw_gib(eid, 'progs/gib2.mdl', -hp);
    EXECUTE PROCEDURE throw_gib(eid, 'progs/gib3.mdl', -hp);
    IF (hm IS NOT NULL) THEN EXECUTE PROCEDURE throw_head(eid, hm, -hp);
    ELSE DELETE FROM ents e WHERE e.id = :eid;
    EXIT;
  END
  EXECUTE PROCEDURE snd(eid, 2, ds, 1, 1);
  q = POSITION(',', anims);
  IF (q > 0 AND RAND() < 0.5e0) THEN pick = SUBSTRING(anims FROM q + 1); ELSE pick = IIF(q > 0, SUBSTRING(anims FROM 1 FOR q - 1), anims);
  q = POSITION(',', pick);
  IF (q > 0) THEN pick = SUBSTRING(pick FROM 1 FOR q - 1);
  UPDATE ents e SET e.st = 'die', e.solid = 0, e.movetype = 6, e.vx = 0, e.vy = 0, e.flags = BIN_AND(e.flags, BIN_NOT(1 + 2)),
         e.minz = -24, e.maxz = -8 WHERE e.id = :eid;
  EXECUTE PROCEDURE set_anim(eid, pick);
END^

-- the boss: rises out of the lava when the level triggers it
CREATE OR ALTER PROCEDURE boss_awake (eid INTEGER)
AS
BEGIN
  IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND e.st <> 'asleep')) THEN EXIT;
  UPDATE ents e SET e.st = 'rise', e.solid = 3, e.takedamage = 0, e.model_id = model_by_name('progs/boss.mdl'), e.health = 3,
         e.enemy_id = player_ent(), e.think = 'monster_think', e.nextthink = now_() + 0.1e0, e.yaw_speed = 5 WHERE e.id = :eid;
  EXECUTE PROCEDURE set_anim(eid, 'rise');
  EXECUTE PROCEDURE snd(eid, 2, 'boss1/out1.wav', 1, 1);
  EXECUTE PROCEDURE snd(eid, 0, 'boss1/sight1.wav', 1, 1);
  EXECUTE PROCEDURE link_ent(eid);
END^

-- event_lightning (boss.qc's lightning_fire): the two terminals are the
-- doors whose target is "lightning"; both must be up (at their top) for the
-- bolt to arc between them, 16 units under their bases. Chthon takes one of
-- his three hits when he stands on the bolt.
CREATE OR ALTER PROCEDURE event_lightning_fire (eid INTEGER)
AS
DECLARE x1 DOUBLE PRECISION; DECLARE y1 DOUBLE PRECISION; DECLARE z1 DOUBLE PRECISION; DECLARE s1 SMALLINT;
DECLARE x2 DOUBLE PRECISION; DECLARE y2 DOUBLE PRECISION; DECLARE z2 DOUBLE PRECISION; DECLARE s2 SMALLINT;
DECLARE b INTEGER; DECLARE hp INTEGER;
BEGIN
  SELECT FIRST 1 e.x + (e.minx + e.maxx) / 2, e.y + (e.miny + e.maxy) / 2, e.z + e.minz - 16, e.mv_state
    FROM ents e WHERE e.target = 'lightning' AND e.classname = 'func_door' ORDER BY e.id INTO x1, y1, z1, s1;
  SELECT FIRST 1 SKIP 1 e.x + (e.minx + e.maxx) / 2, e.y + (e.miny + e.maxy) / 2, e.z + e.minz - 16, e.mv_state
    FROM ents e WHERE e.target = 'lightning' AND e.classname = 'func_door' ORDER BY e.id INTO x2, y2, z2, s2;
  IF (x1 IS NULL OR x2 IS NULL) THEN EXIT;
  IF (s1 <> 0 OR s2 <> 0) THEN EXIT;                        -- a terminal is not up
  -- compensate for the length of the bolt
  x2 = x2 - (x2 - x1) * 0.1e0; y2 = y2 - (y2 - y1) * 0.1e0; z2 = z2 - (z2 - z1) * 0.1e0;
  EXECUTE PROCEDURE fx(4, x1, y1, z1, x2, y2, z2, 0);
  EXECUTE PROCEDURE snd_at((x1 + x2) / 2, (y1 + y2) / 2, z1, 'weapons/lhit.wav', 1, 1);
  EXECUTE PROCEDURE lightning_damage(eid, x1, y1, z1, x2, y2, z2, 10);   -- anything else on the bolt
  SELECT FIRST 1 e.id, e.health FROM ents e WHERE e.classname = 'monster_boss' AND e.st NOT IN ('asleep', 'die', 'dead') INTO b, hp;
  IF (b IS NULL) THEN EXIT;
  -- is Chthon on the bolt? (within his box of the segment, in the horizontal plane)
  IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :b
        AND ABS((:x2 - :x1) * (e.y - :y1) - (:y2 - :y1) * (e.x - :x1)) / MAXVALUE(1, vlen(:x2 - :x1, :y2 - :y1, 0)) < 160
        AND ((e.x - :x1) * (:x2 - :x1) + (e.y - :y1) * (:y2 - :y1)) BETWEEN 0 AND (:x2 - :x1) * (:x2 - :x1) + (:y2 - :y1) * (:y2 - :y1))) THEN EXIT;
  UPDATE ents e SET e.health = e.health - 1 WHERE e.id = :b RETURNING e.health INTO hp;
  EXECUTE PROCEDURE snd(b, 2, 'boss1/pain.wav', 1, 1);
  IF (hp <= 0) THEN EXECUTE PROCEDURE monster_die(b, player_ent());
  ELSE
  BEGIN
    UPDATE ents e SET e.st = 'pain', e.pain_finished = now_() + 2 WHERE e.id = :b;
    EXECUTE PROCEDURE set_anim(b, CASE hp WHEN 2 THEN 'shocka' WHEN 1 THEN 'shockb' ELSE 'shockc' END);
  END
END^

-- the 10 Hz monster frame: the state machine of ai.qc
CREATE OR ALTER PROCEDURE monster_think (eid INTEGER)
AS
DECLARE st VARCHAR(12); DECLARE anim VARCHAR(16); DECLARE af INTEGER; DECLARE mid INTEGER; DECLARE enemy INTEGER; DECLARE flags INTEGER;
DECLARE mt VARCHAR(16); DECLARE ehp INTEGER; DECLARE t DOUBLE PRECISION;
DECLARE ff INTEGER; DECLARE fc INTEGER; DECLARE atkst SMALLINT; DECLARE tgt VARCHAR(40); DECLARE goal INTEGER;
DECLARE run_spd DOUBLE PRECISION; DECLARE walk_spd DOUBLE PRECISION; DECLARE stand_a VARCHAR(16); DECLARE walk_a VARCHAR(16); DECLARE run_a VARCHAR(16);
DECLARE melee_a VARCHAR(16); DECLARE melee_f INTEGER; DECLARE missile_a VARCHAR(16); DECLARE missile_f VARCHAR(40); DECLARE idle_s VARCHAR(64);
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE gx DOUBLE PRECISION; DECLARE gy DOUBLE PRECISION; DECLARE gz DOUBLE PRECISION;
DECLARE d DOUBLE PRECISION; DECLARE gt VARCHAR(40); DECLARE gw DOUBLE PRECISION; DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII; DECLARE lf INTEGER; DECLARE ex DOUBLE PRECISION;
DECLARE wl SMALLINT; DECLARE wt INTEGER;
BEGIN
  t = now_();
  SELECT e.st, e.anim, e.anim_frame, e.model_id, e.enemy_id, e.flags, e.mtype, e.attack_state, e.target, e.goal_id, e.x, e.y, e.z, e.leaf
    FROM ents e WHERE e.id = :eid INTO st, anim, af, mid, enemy, flags, mt, atkst, tgt, goal, x, y, z, lf;
  SELECT t.run_speed, t.walk_speed, t.stand_anim, t.walk_anim, t.run_anim, t.melee_anim, t.melee_frame, t.missile_anim, t.missile_frames, t.idle_snd
    FROM monster_types t WHERE t.name = :mt INTO run_spd, walk_spd, stand_a, walk_a, run_a, melee_a, melee_f, missile_a, missile_f, idle_s;
  UPDATE ents e SET e.nextthink = :t + 0.1e0 WHERE e.id = :eid;
  IF (st = 'dead' OR st = 'cruc') THEN
  BEGIN
    IF (st = 'cruc') THEN
    BEGIN
      UPDATE ents e SET e.anim_frame = MOD(e.anim_frame + 1, 6), e.frame = (SELECT a.first_frame FROM anims a WHERE a.model_id = :mid AND a.anim = 'cruc_') + MOD(e.anim_frame + 1, 6) WHERE e.id = :eid;
      IF (RAND() < 0.02e0) THEN EXECUTE PROCEDURE snd(eid, 2, 'zombie/idle_w2.wav', 1, 1);
    END
    ELSE UPDATE ents e SET e.nextthink = NULL WHERE e.id = :eid;
    EXIT;
  END
  IF (anim IS NULL) THEN
  BEGIN
    EXECUTE PROCEDURE set_anim(eid, CASE st WHEN 'run' THEN run_a WHEN 'walk' THEN walk_a ELSE stand_a END);
    SELECT e.anim FROM ents e WHERE e.id = :eid INTO anim;
    af = 0;
  END
  SELECT a.first_frame, a.frame_count FROM anims a WHERE a.model_id = :mid AND a.anim = :anim INTO ff, fc;
  IF (ff IS NULL) THEN BEGIN ff = 0; fc = 12; END   -- no such animation (model missing): a typical run length, so attack frames still come

  -- the enemy died?
  IF (enemy IS NOT NULL) THEN
  BEGIN
    SELECT e.health FROM ents e WHERE e.id = :enemy INTO ehp;
    IF (ehp IS NULL OR ehp <= 0) THEN
    BEGIN
      enemy = NULL;
      UPDATE ents e SET e.enemy_id = NULL WHERE e.id = :eid;
      IF (st IN ('run', 'melee', 'missile')) THEN
      BEGIN
        st = 'stand';
        UPDATE ents e SET e.st = 'stand' WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, stand_a);
        EXIT;
      END
    END
  END

  IF (st = 'stand' OR st = 'walk' OR st = 'rise') THEN
  BEGIN
    -- ai_stand / ai_walk: look for the player (cheaply: only when in the player's PVS)
    IF (st <> 'rise' AND MOD(af, 2) = 0) THEN
    BEGIN
      SELECT l.pvs FROM leaves l WHERE l.id = (SELECT e.leaf FROM ents e WHERE e.id = player_ent()) INTO pvs;
      IF (pvs_visible(pvs, lf) = 1 AND find_target(eid) = 1) THEN
      BEGIN
        EXECUTE PROCEDURE found_target(eid);
        EXIT;
      END
    END
    IF (st = 'walk' AND tgt IS NOT NULL) THEN
    BEGIN
      -- follow the path_corner chain
      IF (goal IS NULL) THEN
      BEGIN
        SELECT FIRST 1 e.id FROM ents e WHERE e.targetname = :tgt AND e.classname = 'path_corner' INTO goal;
        UPDATE ents e SET e.goal_id = :goal WHERE e.id = :eid;
      END
      IF (goal IS NOT NULL) THEN
      BEGIN
        SELECT e.x, e.y, e.z, e.target, e.wait_ FROM ents e WHERE e.id = :goal INTO gx, gy, gz, gt, gw;
        IF (vlen(gx - x, gy - y, 0) < 24) THEN
        BEGIN
          -- t_movetarget: next corner, maybe after a pause
          UPDATE ents e SET e.target = :gt, e.goal_id = NULL, e.ideal_yaw = vectoyaw(:gx - e.x, :gy - e.y) WHERE e.id = :eid;
          IF (gt IS NULL OR gw > 0) THEN
          BEGIN
            UPDATE ents e SET e.st = 'stand', e.search_time = :t + COALESCE(:gw, 0) WHERE e.id = :eid;
            EXECUTE PROCEDURE set_anim(eid, stand_a);
            EXIT;
          END
        END
        ELSE
        BEGIN
          UPDATE ents e SET e.ideal_yaw = vectoyaw(:gx - :x, :gy - :y) WHERE e.id = :eid;
          EXECUTE PROCEDURE move_to_goal(eid, walk_spd);
        END
      END
    END
    ELSE IF (st = 'stand' AND tgt IS NOT NULL AND (SELECT e.search_time FROM ents e WHERE e.id = :eid) < t AND EXISTS (SELECT 1 FROM ents c WHERE c.targetname = :tgt AND c.classname = 'path_corner')) THEN
    BEGIN
      UPDATE ents e SET e.st = 'walk' WHERE e.id = :eid;
      EXECUTE PROCEDURE set_anim(eid, walk_a);
      EXIT;
    END
    IF (st = 'stand' AND RAND() < 0.02e0 AND idle_s IS NOT NULL) THEN EXECUTE PROCEDURE snd(eid, 2, idle_s, 1, 1);
    -- advance the frame
    af = af + 1;
    IF (af >= fc) THEN
    BEGIN
      af = 0;
      IF (st = 'rise') THEN
      BEGIN
        UPDATE ents e SET e.st = 'run', e.takedamage = 0 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, run_a);
        EXIT;
      END
    END
    UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
    EXIT;
  END

  IF (st = 'run') THEN
  BEGIN
    IF (enemy IS NULL) THEN
    BEGIN
      UPDATE ents e SET e.st = 'stand' WHERE e.id = :eid;
      EXECUTE PROCEDURE set_anim(eid, stand_a);
      EXIT;
    END
    -- leaping: wait until we land
    IF (atkst = 5) THEN
    BEGIN
      SELECT e.flags FROM ents e WHERE e.id = :eid INTO flags;
      IF (BIN_AND(flags, 512) <> 0) THEN
      BEGIN
        UPDATE ents e SET e.attack_state = 1, e.movetype = 4 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, run_a);
      END
      ELSE
      BEGIN
        -- Demon_JumpTouch: hurt the enemy if we land on them
        SELECT vlen(a.x - b.x, a.y - b.y, 0) FROM ents a CROSS JOIN ents b WHERE a.id = :eid AND b.id = :enemy INTO d;
        IF (d < 48 AND (SELECT e.attack_finished FROM ents e WHERE e.id = :eid) < t) THEN
        BEGIN
          IF (mt = 'tarbaby') THEN EXECUTE PROCEDURE snd(eid, 1, 'blob/hit1.wav', 1, 1);   -- Tar_JumpTouch
          EXECUTE PROCEDURE t_damage(enemy, eid, eid, 10 + FLOOR(RAND() * 10) + IIF(mt = 'demon1', 10, 0));
          UPDATE ents e SET e.attack_finished = :t + 1 WHERE e.id = :eid;
        END
      END
      EXIT;
    END
    UPDATE ents e SET e.ideal_yaw = vectoyaw((SELECT x FROM ents n WHERE n.id = :enemy) - e.x, (SELECT y FROM ents n WHERE n.id = :enemy) - e.y) WHERE e.id = :eid;
    IF (atkst = 3) THEN                                    -- ai_run_melee
    BEGIN
      EXECUTE PROCEDURE change_yaw(eid);
      IF (facing_ideal(eid) = 1) THEN
      BEGIN
        UPDATE ents e SET e.st = 'melee', e.attack_state = 1 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, melee_a);
        IF (mt = 'knight') THEN EXECUTE PROCEDURE snd(eid, 1, 'knight/sword1.wav', 1, 1);
        IF (mt = 'ogre') THEN EXECUTE PROCEDURE snd(eid, 1, 'ogre/ogsawatk.wav', 1, 1);
        IF (mt = 'shambler') THEN EXECUTE PROCEDURE snd(eid, 1, 'shambler/melee1.wav', 1, 1);
      END
      EXIT;
    END
    IF (atkst = 4) THEN                                    -- ai_run_missile
    BEGIN
      EXECUTE PROCEDURE change_yaw(eid);
      IF (facing_ideal(eid) = 1) THEN
      BEGIN
        UPDATE ents e SET e.st = 'missile', e.attack_state = 1 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, missile_a);
        IF (mt = 'shambler') THEN EXECUTE PROCEDURE snd(eid, 1, 'shambler/sattck1.wav', 1, 1);
        IF (mt = 'wizard') THEN EXECUTE PROCEDURE snd(eid, 1, 'wizard/wattack.wav', 1, 1);
      END
      EXIT;
    END
    -- far from the player and out of its sight: think less often, stride further
    SELECT vlen(a.x - b.x, a.y - b.y, a.z - b.z) FROM ents a CROSS JOIN ents b WHERE a.id = :eid AND b.id = :enemy INTO d;
    IF (d > 1200 AND pvs_visible((SELECT l.pvs FROM leaves l WHERE l.id = (SELECT e.leaf FROM ents e WHERE e.id = :enemy)), lf) = 0) THEN
    BEGIN
      UPDATE ents e SET e.nextthink = :t + 0.3e0 WHERE e.id = :eid;
      IF (run_spd > 0) THEN EXECUTE PROCEDURE move_to_goal(eid, run_spd * 3);
      af = MOD(af + 1, fc);
      UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
      EXIT;
    END
    IF (check_attack(eid) = 1) THEN EXIT;
    IF (run_spd > 0) THEN EXECUTE PROCEDURE move_to_goal(eid, run_spd);
    ELSE EXECUTE PROCEDURE change_yaw(eid);
    af = MOD(af + 1, fc);
    UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
    EXIT;
  END

  IF (st = 'melee' OR st = 'missile') THEN
  BEGIN
    -- ai_face each frame; act on the key frames
    IF (enemy IS NOT NULL) THEN
    BEGIN
      UPDATE ents e SET e.ideal_yaw = vectoyaw((SELECT x FROM ents n WHERE n.id = :enemy) - e.x, (SELECT y FROM ents n WHERE n.id = :enemy) - e.y) WHERE e.id = :eid;
      EXECUTE PROCEDURE change_yaw(eid);
    END
    IF (st = 'melee' AND af = melee_f) THEN EXECUTE PROCEDURE monster_melee(eid);
    IF (st = 'missile' AND POSITION(',' || af || ',', ',' || missile_f || ',') > 0) THEN EXECUTE PROCEDURE monster_missile(eid);
    IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND e.st = :st)) THEN EXIT;   -- a leap changed state
    af = af + 1;
    IF (af >= fc) THEN
    BEGIN
      UPDATE ents e SET e.st = 'run' WHERE e.id = :eid;
      EXECUTE PROCEDURE set_anim(eid, run_a);
      EXIT;
    END
    UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
    EXIT;
  END

  IF (st = 'pain') THEN
  BEGIN
    af = af + 1;
    IF (af >= fc) THEN
    BEGIN
      IF (mt = 'boss') THEN
      BEGIN
        UPDATE ents e SET e.st = 'run' WHERE e.id = :eid;
        EXECUTE PROCEDURE set_anim(eid, 'walk');
        EXIT;
      END
      UPDATE ents e SET e.st = TRIM(IIF(e.enemy_id IS NULL, 'stand', 'run')) WHERE e.id = :eid;   -- TRIM: IIF pads to the longer literal
      EXECUTE PROCEDURE set_anim(eid, IIF(enemy IS NULL, stand_a, run_a));
      EXIT;
    END
    UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
    EXIT;
  END

  IF (st = 'die') THEN
  BEGIN
    af = af + 1;
    IF (af >= fc) THEN
    BEGIN
      UPDATE ents e SET e.st = 'dead', e.anim_frame = :fc - 1, e.frame = :ff + :fc - 1, e.nextthink = NULL WHERE e.id = :eid;
      IF (mt = 'boss') THEN DELETE FROM ents e WHERE e.id = :eid;
      EXIT;
    END
    UPDATE ents e SET e.anim_frame = :af, e.frame = :ff + :af WHERE e.id = :eid;
    EXIT;
  END
END^

-- the END's spiked ball: glides from path corner to path corner (its target
-- chain is the destinations; the first corner's target keeps the teleport
-- destination name while the ball itself keeps 'target' = next corner)
CREATE OR ALTER PROCEDURE teleporttrain_next (eid INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION; DECLARE ctarget VARCHAR(40);
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION;
DECLARE dest VARCHAR(40);
BEGIN
  SELECT e.noise1, e.x, e.y, e.z, e.speed, e.target FROM ents e WHERE e.id = :eid INTO tgt, px, py, pz, spd, dest;
  IF (tgt IS NULL) THEN tgt = dest;                              -- first call: the ball's target is the first corner
  SELECT FIRST 1 e.x, e.y, e.z, e.target FROM ents e WHERE e.targetname = :tgt AND e.classname = 'path_corner' INTO cx, cy, cz, ctarget;
  IF (cx IS NULL) THEN EXIT;
  dl = vlen(cx - px, cy - py, cz - pz);
  IF (dl < 4) THEN
  BEGIN
    -- arrived: head for the next corner
    UPDATE ents e SET e.noise1 = :ctarget, e.vx = 0, e.vy = 0, e.vz = 0, e.nextthink = now_() + 0.05e0 WHERE e.id = :eid;
    EXIT;
  END
  UPDATE ents e SET e.noise1 = :tgt, e.x = e.x + (:cx - e.x) / :dl * MINVALUE(:dl, :spd * 0.05e0),
         e.y = e.y + (:cy - e.y) / :dl * MINVALUE(:dl, :spd * 0.05e0), e.z = e.z + (:cz - e.z) / :dl * MINVALUE(:dl, :spd * 0.05e0),
         e.yaw = MOD(e.yaw + 5, 360), e.nextthink = now_() + 0.05e0 WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
END^

-- a console helper: put a monster in front of the player (impulse-free cheating)
CREATE OR ALTER PROCEDURE spawn_monster (mname VARCHAR(16), dist DOUBLE PRECISION)
RETURNS (id INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION; DECLARE yaw DOUBLE PRECISION;
DECLARE mmodel VARCHAR(40); DECLARE mhp INTEGER; DECLARE mhull SMALLINT; DECLARE mmaxz DOUBLE PRECISION; DECLARE mflags INTEGER; DECLARE mys DOUBLE PRECISION; DECLARE stand VARCHAR(16);
BEGIN
  SELECT e.x, e.y, e.z, e.yaw FROM ents e WHERE e.id = player_ent() INTO px, py, pz, yaw;
  SELECT t.model, t.health, t.hull, t.maxz, t.flags, t.yaw_speed, t.stand_anim FROM monster_types t WHERE t.name = :mname
    INTO mmodel, mhp, mhull, mmaxz, mflags, mys, stand;
  IF (mmodel IS NULL) THEN EXIT;
  EXECUTE PROCEDURE spawn_ent('monster_' || mname, px + COS(yaw * 0.0174532925e0) * dist, py + SIN(yaw * 0.0174532925e0) * dist, pz + 8) RETURNING_VALUES id;
  EXECUTE PROCEDURE set_model(id, mmodel);
  UPDATE ents e SET e.mtype = :mname, e.health = :mhp, e.max_health = :mhp, e.solid = 3, e.takedamage = 2,
         e.movetype = IIF(BIN_AND(:mflags, 3) <> 0, 5, 4), e.flags = BIN_OR(32, :mflags), e.yaw_speed = :mys, e.yaw = anglemod(:yaw + 180),
         e.minx = IIF(:mhull = 2, -32, -16), e.miny = IIF(:mhull = 2, -32, -16), e.minz = -24,
         e.maxx = IIF(:mhull = 2, 32, 16), e.maxy = IIF(:mhull = 2, 32, 16), e.maxz = :mmaxz,
         e.st = 'stand', e.anim = :stand, e.ideal_yaw = e.yaw, e.spawn_x = e.x, e.spawn_y = e.y, e.spawn_z = e.z,
         e.think = 'monster_think', e.nextthink = now_() + 0.1e0 WHERE e.id = :id;
  IF (mname = 'fish') THEN UPDATE ents e SET e.maxz = 24 WHERE e.id = :id;
  IF (mname = 'oldone') THEN UPDATE ents e SET e.minx = -160, e.miny = -128, e.maxx = 160, e.maxy = 128, e.maxz = 256, e.takedamage = 0, e.movetype = 0 WHERE e.id = :id;
  UPDATE game g SET g.total_monsters = g.total_monsters + 1 WHERE g.id = 1;
  IF (BIN_AND(mflags, 3) = 0) THEN EXECUTE PROCEDURE drop_to_floor(id); ELSE EXECUTE PROCEDURE link_ent(id);
  SUSPEND;
END^

-- ── the pushers (SV_Physics_Pusher) ─────────────────────────────────────
SET TERM ; ^
CREATE GLOBAL TEMPORARY TABLE pushed (
  ent INTEGER NOT NULL PRIMARY KEY,
  ox DOUBLE PRECISION NOT NULL, oy DOUBLE PRECISION NOT NULL, oz DOUBLE PRECISION NOT NULL
) ON COMMIT DELETE ROWS;
SET TERM ^ ;

CREATE OR ALTER PROCEDURE push_move (eid INTEGER, movetime DOUBLE PRECISION)
AS
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE mx DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mz DOUBLE PRECISION;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE c INTEGER; DECLARE cmt SMALLINT; DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION;
DECLARE csolid SMALLINT; DECLARE blocked SMALLINT; DECLARE pe INTEGER; DECLARE r INTEGER;
BEGIN
  SELECT e.vx, e.vy, e.vz, e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz FROM ents e WHERE e.id = :eid
    INTO vx, vy, vz, px, py, pz, mnx, mny, mnz, mxx, mxy, mxz;
  IF (vx = 0 AND vy = 0 AND vz = 0) THEN
  BEGIN
    UPDATE ents e SET e.ltime = e.ltime + :movetime WHERE e.id = :eid;
    EXIT;
  END
  mx = vx * movetime; my = vy * movetime; mz = vz * movetime;
  UPDATE ents e SET e.x = e.x + :mx, e.y = e.y + :my, e.z = e.z + :mz, e.ltime = e.ltime + :movetime WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
  DELETE FROM pushed;
  pe = player_ent();

  FOR SELECT e.id, e.movetype, e.x, e.y, e.z, e.solid FROM ents e
       WHERE e.id <> :eid AND e.movetype NOT IN (0, 7, 8) AND e.solid <> 0 AND e.health > -1
         AND e.x + e.maxx >= :px + :mnx + MINVALUE(0, :mx) - 1 AND e.x + e.minx <= :px + :mxx + MAXVALUE(0, :mx) + 1
         AND e.y + e.maxy >= :py + :mny + MINVALUE(0, :my) - 1 AND e.y + e.miny <= :py + :mxy + MAXVALUE(0, :my) + 1
         AND e.z + e.maxz >= :pz + :mnz + MINVALUE(0, :mz) - 1 AND e.z + e.minz <= :pz + :mxz + MAXVALUE(0, :mz) + 1
        INTO c, cmt, cx, cy, cz, csolid
  DO
  BEGIN
    -- riding on top, or now inside the pusher?
    IF (test_position(c, cx, cy, cz) = 0 AND NOT (cz + 1 >= pz - mz + mxz - 0.5e0 AND cz - 1 <= pz - mz + mxz + 0.5e0 AND mz <> 0)) THEN
    BEGIN
      IF (cz + (SELECT e.minz FROM ents e WHERE e.id = :c) < pz - mz + mxz - 2 OR cz + (SELECT e.minz FROM ents e WHERE e.id = :c) > pz - mz + mxz + 2) THEN CONTINUE;
      IF (cx + (SELECT e.maxx FROM ents e WHERE e.id = :c) < px + mnx OR cx + (SELECT e.minx FROM ents e WHERE e.id = :c) > px + mxx) THEN CONTINUE;
      IF (cy + (SELECT e.maxy FROM ents e WHERE e.id = :c) < py + mny OR cy + (SELECT e.miny FROM ents e WHERE e.id = :c) > py + mxy) THEN CONTINUE;
      IF (mz < 0) THEN CONTINUE;         -- standing on a sinking plat: gravity brings us down
    END
    -- try moving the contacted entity along
    INSERT INTO pushed (ent, ox, oy, oz) VALUES (:c, :cx, :cy, :cz);
    UPDATE ents e SET e.x = e.x + :mx, e.y = e.y + :my, e.z = e.z + :mz WHERE e.id = :c;
    IF (test_position(c, cx + mx, cy + my, cz + mz) = 0) THEN
    BEGIN
      EXECUTE PROCEDURE link_ent(c);
      IF (c = pe) THEN UPDATE player p SET p.oldz = p.oldz + :mz WHERE p.id = 1;
      CONTINUE;
    END
    -- if it is ok to leave in the old position, do it
    IF (cmt <> 3) THEN
    BEGIN
      UPDATE ents e SET e.x = :cx, e.y = :cy, e.z = :cz WHERE e.id = :c;
      IF (test_position(c, cx, cy, cz) = 0) THEN
      BEGIN
        DELETE FROM pushed WHERE ent = :c;
        CONTINUE;
      END
    END
    -- corpses and items get crushed out of the way
    IF (csolid IN (0, 1) OR cmt IN (6, 10)) THEN
    BEGIN
      UPDATE ents e SET e.solid = 0, e.minx = 0, e.miny = 0, e.minz = 0, e.maxx = 0, e.maxy = 0, e.maxz = 0 WHERE e.id = :c;
      CONTINUE;
    END
    -- blocked: move everything back
    UPDATE ents e SET e.x = :cx, e.y = :cy, e.z = :cz WHERE e.id = :c;
    UPDATE ents e SET e.x = e.x - :mx, e.y = e.y - :my, e.z = e.z - :mz, e.ltime = e.ltime - :movetime WHERE e.id = :eid;
    EXECUTE PROCEDURE link_ent(eid);
    FOR SELECT p.ent, p.ox, p.oy, p.oz FROM pushed p WHERE p.ent <> :c INTO r, cx, cy, cz DO
    BEGIN
      UPDATE ents e SET e.x = :cx, e.y = :cy, e.z = :cz WHERE e.id = :r;
      EXECUTE PROCEDURE link_ent(r);
    END
    EXECUTE PROCEDURE mover_blocked(eid, c);
    EXIT;
  END
END^

CREATE OR ALTER PROCEDURE run_pushers (dt DOUBLE PRECISION)
AS
DECLARE eid INTEGER; DECLARE lt DOUBLE PRECISION; DECLARE mvt DOUBLE PRECISION; DECLARE done VARCHAR(24); DECLARE movetime DOUBLE PRECISION;
DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION; DECLARE think VARCHAR(24); DECLARE nt DOUBLE PRECISION;
BEGIN
  FOR SELECT e.id FROM ents e WHERE e.movetype = 7 INTO eid DO
  BEGIN
    SELECT e.ltime, e.mv_time, e.mv_done, e.dstx, e.dsty, e.dstz, e.think, e.nextthink FROM ents e WHERE e.id = :eid INTO lt, mvt, done, tx, ty, tz, think, nt;
    IF (mvt IS NOT NULL) THEN
    BEGIN
      movetime = MINVALUE(dt, MAXVALUE(0, mvt - lt));
      IF (movetime > 0) THEN EXECUTE PROCEDURE push_move(eid, movetime);
      ELSE UPDATE ents e SET e.ltime = e.ltime + :dt WHERE e.id = :eid;
      SELECT e.ltime, e.mv_time FROM ents e WHERE e.id = :eid INTO lt, mvt;
      IF (mvt IS NOT NULL AND lt >= mvt - 1e-6) THEN
      BEGIN
        -- SUB_CalcMoveDone: snap to the destination and run the think
        UPDATE ents e SET e.x = :tx, e.y = :ty, e.z = :tz, e.vx = 0, e.vy = 0, e.vz = 0, e.mv_time = NULL, e.mv_done = NULL WHERE e.id = :eid;
        EXECUTE PROCEDURE link_ent(eid);
        EXECUTE PROCEDURE run_think(eid, done);
      END
    END
    ELSE
    BEGIN
      UPDATE ents e SET e.ltime = e.ltime + :dt WHERE e.id = :eid;
      IF (think IS NOT NULL AND nt IS NOT NULL AND nt <= lt + dt + 1e-6) THEN
      BEGIN
        UPDATE ents e SET e.think = NULL, e.nextthink = NULL WHERE e.id = :eid;
        EXECUTE PROCEDURE run_think(eid, think);
      END
    END
  END
END^

-- dispatch a think by name
CREATE OR ALTER PROCEDURE run_think (eid INTEGER, think VARCHAR(24))
AS
BEGIN
  IF (think IS NULL) THEN EXIT;
  IF (think = 'door_go_down') THEN EXECUTE PROCEDURE door_go_down(eid);
  ELSE IF (think = 'door_go_up') THEN EXECUTE PROCEDURE door_go_up(eid);
  ELSE IF (think = 'door_hit_top') THEN EXECUTE PROCEDURE door_hit_top(eid);
  ELSE IF (think = 'door_hit_bottom') THEN EXECUTE PROCEDURE door_hit_bottom(eid);
  ELSE IF (think = 'plat_go_down') THEN EXECUTE PROCEDURE plat_go_down(eid);
  ELSE IF (think = 'plat_go_up') THEN EXECUTE PROCEDURE plat_go_up(eid);
  ELSE IF (think = 'plat_hit_top') THEN EXECUTE PROCEDURE plat_hit_top(eid);
  ELSE IF (think = 'plat_hit_bottom') THEN EXECUTE PROCEDURE plat_hit_bottom(eid);
  ELSE IF (think = 'button_wait') THEN EXECUTE PROCEDURE button_wait(eid);
  ELSE IF (think = 'button_return') THEN EXECUTE PROCEDURE button_return(eid);
  ELSE IF (think = 'button_done') THEN EXECUTE PROCEDURE button_done(eid);
  ELSE IF (think = 'train_next') THEN EXECUTE PROCEDURE train_next(eid);
  ELSE IF (think = 'train_wait') THEN EXECUTE PROCEDURE train_wait(eid);
  ELSE IF (think = 'train_find') THEN EXECUTE PROCEDURE train_find(eid);
  ELSE IF (think STARTING WITH 'secret_move') THEN
  BEGIN
    IF (think = 'secret_move1') THEN EXECUTE PROCEDURE secret_move1(eid);
    ELSE IF (think = 'secret_move2') THEN EXECUTE PROCEDURE secret_move2(eid);
    ELSE IF (think = 'secret_move3') THEN EXECUTE PROCEDURE secret_move3(eid);
    ELSE IF (think = 'secret_move4') THEN EXECUTE PROCEDURE secret_move4(eid);
    ELSE IF (think = 'secret_move5') THEN EXECUTE PROCEDURE secret_move5(eid);
    ELSE IF (think = 'secret_move6') THEN EXECUTE PROCEDURE secret_move6(eid);
  END
  ELSE IF (think = 'secret_done') THEN EXECUTE PROCEDURE secret_done(eid);
  ELSE IF (think = 'multi_wait') THEN EXECUTE PROCEDURE multi_wait(eid);
  ELSE IF (think = 'delayed_use') THEN EXECUTE PROCEDURE delayed_use(eid);
  ELSE IF (think = 'grenade_explode') THEN EXECUTE PROCEDURE grenade_explode(eid);
  ELSE IF (think = 'vore_track') THEN EXECUTE PROCEDURE vore_track(eid);
  ELSE IF (think = 'teleporttrain_next') THEN EXECUTE PROCEDURE teleporttrain_next(eid);
  ELSE IF (think = 'remove') THEN DELETE FROM ents e WHERE e.id = :eid;
  ELSE IF (think = 'monster_think') THEN EXECUTE PROCEDURE monster_think(eid);
  ELSE IF (think = 'fireball_think') THEN EXECUTE PROCEDURE fireball_think(eid);
  ELSE IF (think = 'shooter_think') THEN EXECUTE PROCEDURE shooter_think(eid);
END^

-- SV_Physics for everything but the player and the pushers
CREATE OR ALTER PROCEDURE run_physics (dt DOUBLE PRECISION)
AS
DECLARE eid INTEGER; DECLARE mt SMALLINT; DECLARE think VARCHAR(24); DECLARE nt DOUBLE PRECISION; DECLARE t DOUBLE PRECISION;
DECLARE flags INTEGER; DECLARE cls VARCHAR(40); DECLARE wl SMALLINT; DECLARE wt INTEGER; DECLARE pe INTEGER;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION; DECLARE tid INTEGER; DECLARE tcls VARCHAR(40);
BEGIN
  t = now_();
  pe = player_ent();
  -- thinks that are due (non-pushers)
  -- (a hair of tolerance: tic time accumulates in floating point, and a think due exactly now must run now, not a tic late)
  FOR SELECT e.id, e.think FROM ents e WHERE e.nextthink IS NOT NULL AND e.nextthink <= :t + 1e-6 AND e.movetype <> 7 AND e.think IS NOT NULL ORDER BY e.id INTO eid, think DO
  BEGIN
    UPDATE ents e SET e.nextthink = NULL WHERE e.id = :eid AND e.think = :think AND e.think <> 'monster_think';
    EXECUTE PROCEDURE run_think(eid, think);
  END
  -- toss, bounce, fly, flymissile, and monsters in the air
  FOR SELECT e.id, e.movetype, e.flags, e.classname FROM ents e WHERE e.movetype IN (6, 9, 10) OR (e.movetype IN (4, 5) AND BIN_AND(e.flags, 512 + 1 + 2) = 0 AND e.st <> 'dead')
        INTO eid, mt, flags, cls DO
  BEGIN
    IF (mt IN (4, 5)) THEN
    BEGIN
      -- SV_Physics_Step: a monster that is not on the ground falls
      UPDATE ents e SET e.vz = e.vz - (SELECT g.gravity FROM game g WHERE g.id = 1) * :dt WHERE e.id = :eid;
      EXECUTE PROCEDURE fly_move(eid, dt) RETURNING_VALUES wl, tid;
      IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid AND BIN_AND(e.flags, 512) <> 0)) THEN
      BEGIN
        UPDATE ents e SET e.vx = 0, e.vy = 0, e.vz = 0 WHERE e.id = :eid;
        EXECUTE PROCEDURE snd(eid, 2, 'demon/dland2.wav', 1, 1);
      END
      EXECUTE PROCEDURE link_ent(eid);
      CONTINUE;
    END
    IF (BIN_AND(flags, 512) <> 0 AND mt <> 9) THEN CONTINUE;      -- resting
    EXECUTE PROCEDURE toss_move(eid, dt);
  END
  -- monsters touching teleporters / monster jumps
  FOR SELECT m.id, m.x, m.y, m.z FROM ents m WHERE BIN_AND(m.flags, 32) <> 0 AND m.health > 0 AND m.st IN ('run', 'walk') INTO eid, px, py, pz DO
  BEGIN
    FOR SELECT tr.id, tr.classname FROM ents tr JOIN ents m ON m.id = :eid
         WHERE tr.solid = 1 AND tr.classname IN ('trigger_teleport', 'trigger_monsterjump')
           AND tr.x + tr.maxx >= m.x + m.minx AND tr.x + tr.minx <= m.x + m.maxx
           AND tr.y + tr.maxy >= m.y + m.miny AND tr.y + tr.miny <= m.y + m.maxy
           AND tr.z + tr.maxz >= m.z + m.minz AND tr.z + tr.minz <= m.z + m.maxz
          INTO tid, tcls DO
    BEGIN
      IF (tcls = 'trigger_teleport') THEN EXECUTE PROCEDURE teleport_touch(tid, eid);
      ELSE
        UPDATE ents e SET e.vx = COS(e.yaw * 0.0174532925e0) * (SELECT tr.speed FROM ents tr WHERE tr.id = :tid),
               e.vy = SIN(e.yaw * 0.0174532925e0) * (SELECT tr.speed FROM ents tr WHERE tr.id = :tid),
               e.vz = (SELECT tr.height FROM ents tr WHERE tr.id = :tid), e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :eid;
    END
  END
END^

-- ── the tic ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE quake_tic (
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
  amb_water INTEGER, amb_sky INTEGER, finale SMALLINT)
AS
DECLARE i INTEGER = 0; DECLARE t DOUBLE PRECISION; DECLARE pe INTEGER;
DECLARE wl SMALLINT; DECLARE wt INTEGER;
BEGIN
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  DELETE FROM sound_events s WHERE s.tic < :tic - 40;
  DELETE FROM fx_events f WHERE f.tic < :tic - 40;
  WHILE (i < tics) DO
  BEGIN
    UPDATE game g SET g.tic = g.tic + 1, g.time_ = g.time_ + 0.05e0 WHERE g.id = 1;
    EXECUTE PROCEDURE player_think(0.05e0, fwd, side, yaw_d / tics, pitch_d / tics, fire, jump, run, IIF(i = 0, imp, 0));
    EXECUTE PROCEDURE run_pushers(0.05e0);
    EXECUTE PROCEDURE run_physics(0.05e0);
    i = i + 1;
  END
  SELECT g.tic, g.time_, e.health, p.armorvalue, p.armortype, p.shells, p.nails, p.rockets, p.cells, p.items, p.weapon, p.weaponframe,
         e.x, e.y, e.z, e.yaw, p.pitch + p.punchangle, e.z + p.view_ofs - p.stepz, p.punchangle,
         IIF(p.msg_time > g.time_, p.msg, NULL), IIF(p.cprint_time > g.time_, p.cprint, NULL),
         p.dmg_take, p.dmg_save, p.dmg_time, p.bonus_time, e.deadflag, g.exit_kind, g.next_map, g.killed, g.total_monsters,
         g.found_secrets, g.total_secrets, e.waterlevel, e.watertype, g.map_name, g.level_msg,
         IIF(p.invincible_finished > g.time_, 1, 0), IIF(p.super_damage_finished > g.time_, 1, 0),
         IIF(p.invisible_finished > g.time_, 1, 0), IIF(p.radsuit_finished > g.time_, 1, 0), e.leaf,
         COALESCE(l.ambient, 0), COALESCE(l.ambient_sky, 0), g.finale
    FROM game g CROSS JOIN player p JOIN ents e ON e.id = p.ent_id LEFT JOIN leaves l ON l.id = e.leaf
   WHERE g.id = 1 AND p.id = 1
    INTO tic, time_, health, armorvalue, armortype, shells, nails, rockets, cells, items, weapon, weaponframe,
         px, py, pz, yaw, pitch, view_z, punch, msg, cprint, dmg_take, dmg_save, dmg_time, bonus_time, dead, exit_kind, next_map,
         killed, total_monsters, found_secrets, total_secrets, waterlevel, watertype, map_name, level_msg, invincible, quad, invisible, suit, leaf,
         amb_water, amb_sky, finale;
  UPDATE player p SET p.dmg_take = 0, p.dmg_save = 0 WHERE p.id = 1 AND p.dmg_time < :time_ - 0.05e0;
  SUSPEND;
END^

-- SV_SpawnServer + worldspawn + the player's spawn
CREATE OR ALTER PROCEDURE init_map (map_name VARCHAR(32), world_model INTEGER, skill SMALLINT, new_game SMALLINT)
AS
DECLARE i INTEGER;
BEGIN
  UPDATE game g SET g.tic = 0, g.time_ = 0, g.map_name = :map_name, g.next_map = NULL, g.exit_kind = 0, g.skill = :skill, g.world_model = :world_model,
         g.total_monsters = 0, g.killed = 0, g.total_secrets = 0, g.found_secrets = 0, g.level_msg = NULL, g.intermission_tics = 0, g.finale = 0,
         g.gravity = IIF(LOWER(:map_name) = 'e1m8', 100, 800) WHERE g.id = 1;   -- worldspawn: Ziggurat Vertigo has low gravity
  -- switchable lights back to their patterns
  DELETE FROM lightstyles l WHERE l.style >= 32;
  i = 32;
  WHILE (i < 64) DO BEGIN INSERT INTO lightstyles (style, pattern) VALUES (:i, 'm'); i = i + 1; END
  IF (new_game = 1) THEN
    UPDATE player p SET p.armorvalue = 0, p.armortype = 0, p.shells = 25, p.nails = 0, p.rockets = 0, p.cells = 0, p.items = 4097, p.weapon = 1,
           p.invincible_finished = 0, p.invisible_finished = 0, p.super_damage_finished = 0, p.radsuit_finished = 0, p.kills = 0 WHERE p.id = 1;
  UPDATE player p SET p.weaponframe = 0, p.attack_finished = 0, p.pain_finished = 0, p.punchangle = 0, p.view_ofs = 22, p.dmg_take = 0, p.dmg_save = 0,
         p.dmg_time = -10, p.bonus_time = -10, p.msg = NULL, p.msg_time = 0, p.cprint = NULL, p.cprint_time = 0, p.dead_time = 0, p.pitch = 0, p.stepz = 0,
         p.jump_released = 1, p.air_finished = 12, p.dmg_lava_time = 0, p.weapon_sound = 0, p.items = BIN_AND(p.items, BIN_NOT(131072 + 262144)) WHERE p.id = 1;
  -- keys don't carry over; neither do dead weapons
  UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1 AND BIN_AND(p.items, p.weapon) = 0;
  EXECUTE PROCEDURE spawn_map_ents(skill);
  -- the level name
  UPDATE player p SET p.cprint = (SELECT g.level_msg FROM game g WHERE g.id = 1), p.cprint_time = 3 WHERE p.id = 1;
END^

SET TERM ; ^
