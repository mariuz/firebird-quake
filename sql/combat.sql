-- combat.sql – combat.qc and the projectiles: gibs, Killed, T_Damage, T_RadiusDamage, the
-- spikes, grenades and rockets, and SV_Impact's touches.

SET TERM ^ ;

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
         e.vx = 100 * (rnd() * 2 - 1) * :spd * 0.7e0, e.vy = 100 * (rnd() * 2 - 1) * :spd * 0.7e0, e.vz = (rnd() * 200 + 100) * :spd,
         e.avel_yaw = rnd() * 600, e.think = 'remove', e.nextthink = now_() + 10 + rnd() * 10, e.frame = 0 WHERE e.id = :g;
END^

CREATE OR ALTER PROCEDURE throw_head (eid INTEGER, model VARCHAR(64), dmg INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE set_model(eid, model);
  UPDATE ents e SET e.movetype = 10, e.solid = 0, e.takedamage = 0, e.frame = 0, e.anim = NULL, e.st = 'dead',
         e.minx = -16, e.miny = -16, e.minz = 0, e.maxx = 16, e.maxy = 16, e.maxz = 56,
         e.vx = 100 * (rnd() * 2 - 1), e.vy = 100 * (rnd() * 2 - 1), e.vz = rnd() * 200 + 200,
         e.avel_yaw = rnd() * 600, e.think = NULL, e.nextthink = NULL, e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :eid;
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
           e.anim = 'death' || SUBSTRING('abcde' FROM 1 + FLOOR(rnd() * 5) FOR 1), e.anim_frame = 0 WHERE e.id = :targ;
    UPDATE player p SET p.dead_time = now_(), p.view_ofs = -8, p.weapon = 0, p.items = BIN_AND(p.items, BIN_NOT(1048576 + 524288 + 4194304 + 2097152)) WHERE p.id = 1;
    EXECUTE PROCEDURE snd(targ, 2, 'player/death' || CAST(1 + FLOOR(rnd() * 5) AS INTEGER) || '.wav', 1, 1);
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
      EXECUTE PROCEDURE snd(targ, 2, 'player/pain' || CAST(1 + FLOOR(rnd() * 6) AS INTEGER) || '.wav', 1, 1);
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
    IF (td2 > 0 AND hp2 > 0) THEN EXECUTE PROCEDURE t_damage(e2, e1, own, dmg + FLOOR(rnd() * 20));
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

SET TERM ; ^
