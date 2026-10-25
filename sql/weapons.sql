-- weapons.sql – weapons.qc and client.qc: what the player does each tic.

SET TERM ^ ;

-- the eye and the view vectors
CREATE OR ALTER PROCEDURE view_vectors
RETURNS (ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
         fx DOUBLE PRECISION, fy DOUBLE PRECISION, fz DOUBLE PRECISION,
         rx DOUBLE PRECISION, ry DOUBLE PRECISION, rz DOUBLE PRECISION,
         ux DOUBLE PRECISION, uy DOUBLE PRECISION, uz DOUBLE PRECISION)
AS
DECLARE yaw DOUBLE PRECISION; DECLARE pitch DOUBLE PRECISION;
DECLARE sy DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE sp DOUBLE PRECISION; DECLARE cp DOUBLE PRECISION;
BEGIN
  SELECT e.x, e.y, e.z + p.view_ofs, e.yaw, p.pitch FROM player p JOIN ents e ON e.id = p.ent_id WHERE p.id = 1 INTO ex, ey, ez, yaw, pitch;
  sy = SIN(yaw * 0.0174532925e0); cy = COS(yaw * 0.0174532925e0);
  sp = SIN(pitch * 0.0174532925e0); cp = COS(pitch * 0.0174532925e0);
  fx = cp * cy; fy = cp * sy; fz = -sp;
  rx = sy; ry = -cy; rz = 0;
  ux = sp * cy; uy = sp * sy; uz = cp;
  SUSPEND;
END^

-- FireBullets: `count` pellets with spread, 4 damage each
CREATE OR ALTER PROCEDURE fire_bullets (shooter INTEGER, cnt INTEGER,
  ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION,
  dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION, spread_x DOUBLE PRECISION, spread_y DOUBLE PRECISION)
AS
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE ax DOUBLE PRECISION; DECLARE ay DOUBLE PRECISION; DECLARE az DOUBLE PRECISION; DECLARE al DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE hx DOUBLE PRECISION; DECLARE hy DOUBLE PRECISION; DECLARE hz DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE i INTEGER = 0; DECLARE r1 DOUBLE PRECISION; DECLARE r2 DOUBLE PRECISION;
DECLARE td SMALLINT; DECLARE hp INTEGER;
BEGIN
  -- right and up perpendicular to the aim direction
  al = vlen(dx, dy, dz);
  IF (al = 0) THEN EXIT;
  dx = dx / al; dy = dy / al; dz = dz / al;
  rx = dy; ry = -dx; rz = 0;
  al = vlen(rx, ry, rz);
  IF (al < 1e-6) THEN BEGIN rx = 1; ry = 0; rz = 0; al = 1; END
  rx = rx / al; ry = ry / al; rz = rz / al;
  ux = ry * dz - rz * dy; uy = rz * dx - rx * dz; uz = rx * dy - ry * dx;
  WHILE (i < cnt) DO
  BEGIN
    r1 = (rnd() * 2 - 1) * spread_x; r2 = (rnd() * 2 - 1) * spread_y;
    ax = dx + r1 * rx + r2 * ux; ay = dy + r1 * ry + r2 * uy; az = dz + r1 * rz + r2 * uz;
    EXECUTE PROCEDURE trace_move(shooter, 0, 0, 0, 0, 0, 0, ox, oy, oz, ox + ax * 2048, oy + ay * 2048, oz + az * 2048, 0)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    IF (f < 1) THEN
    BEGIN
      td = 0;
      IF (hit > 0) THEN SELECT e.takedamage, e.health FROM ents e WHERE e.id = :hit INTO td, hp;
      IF (td > 0) THEN
      BEGIN
        EXECUTE PROCEDURE fx(3, hx, hy, hz, 0, 0, 0, 4);
        EXECUTE PROCEDURE t_damage(hit, shooter, shooter, 4);
      END
      ELSE IF (point_contents(hx, hy, hz) <> -6) THEN
        EXECUTE PROCEDURE fx(1, hx - ax * 4, hy - ay * 4, hz - az * 4, 0, 0, 0, 0);
    END
    i = i + 1;
  END
END^

-- LightningDamage: everything on the beam from p1 to p2
CREATE OR ALTER PROCEDURE lightning_damage (attacker INTEGER,
  x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION, damage INTEGER)
AS
DECLARE f DOUBLE PRECISION; DECLARE hx DOUBLE PRECISION; DECLARE hy DOUBLE PRECISION; DECLARE hz DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE i INTEGER = 0; DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION;
DECLARE h1 INTEGER = 0; DECLARE h2 INTEGER = 0;
BEGIN
  dl = vlen(x2 - x1, y2 - y1, 0);
  IF (dl = 0) THEN dl = 1;
  ox = (y2 - y1) / dl * 16; oy = -(x2 - x1) / dl * 16;
  -- three parallel traces: centre, 16 units left and right
  WHILE (i < 3) DO
  BEGIN
    EXECUTE PROCEDURE trace_move(attacker, 0, 0, 0, 0, 0, 0, x1 + ox * (i - 1), y1 + oy * (i - 1), z1, x2 + ox * (i - 1), y2 + oy * (i - 1), z2, 0)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    IF (hit > 0 AND hit <> h1 AND hit <> h2 AND EXISTS (SELECT 1 FROM ents e WHERE e.id = :hit AND e.takedamage > 0)) THEN
    BEGIN
      EXECUTE PROCEDURE fx(3, hx, hy, hz, 0, 0, 0, damage);
      EXECUTE PROCEDURE t_damage(hit, attacker, attacker, damage);
      IF (h1 = 0) THEN h1 = hit; ELSE h2 = hit;
    END
    i = i + 1;
  END
END^

-- PF_aim (sv_aim 0.93): straight ahead if a trace from origin + 20 up hits something DAMAGE_AIM; otherwise towards
-- the middle of the best such thing within the cone that a trace reaches (edict order, a tie to the later), turned
-- only up or down (the forward vector's run to it, at its height); else straight ahead
CREATE OR ALTER PROCEDURE aim_dir (e INTEGER, fx DOUBLE PRECISION, fy DOUBLE PRECISION, fz DOUBLE PRECISION)
RETURNS (ax DOUBLE PRECISION, ay DOUBLE PRECISION, az DOUBLE PRECISION)
AS
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION;
DECLARE hit INTEGER; DECLARE th INTEGER; DECLARE best DOUBLE PRECISION; DECLARE bent INTEGER;
DECLARE bx DOUBLE PRECISION; DECLARE by_ DOUBLE PRECISION; DECLARE bz DOUBLE PRECISION;
DECLARE mv DOUBLE PRECISION; DECLARE cur DOUBLE PRECISION; DECLARE c INTEGER;
BEGIN
  ax = fx; ay = fy; az = fz;
  SELECT d.x, d.y, d.z + 20 FROM ents d WHERE d.id = :e INTO x, y, z;
  SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :x + :fx * 2048, :y + :fy * 2048, :z + :fz * 2048, 0) t INTO hit;
  IF (hit > 0 AND EXISTS (SELECT 1 FROM ents d WHERE d.id = :hit AND d.takedamage = 2)) THEN BEGIN SUSPEND; EXIT; END
  best = 0.93e0; bent = 0;
  FOR SELECT d.id, d.x + (d.minx + d.maxx) * 0.5e0, d.y + (d.miny + d.maxy) * 0.5e0, d.z + (d.minz + d.maxz) * 0.5e0 FROM ents d
       WHERE d.id <> :e AND d.takedamage = 2 ORDER BY d.id INTO c, bx, by_, bz DO
  BEGIN
    mv = SQRT((bx - x) * (bx - x) + (by_ - y) * (by_ - y) + (bz - z) * (bz - z));
    IF (mv = 0) THEN CONTINUE;
    cur = ((bx - x) * fx + (by_ - y) * fy + (bz - z) * fz) / mv;
    IF (cur < best) THEN CONTINUE;
    SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :bx, :by_, :bz, 0) t INTO th;
    IF (th = c) THEN BEGIN best = cur; bent = c; END
  END
  IF (bent > 0) THEN
  BEGIN
    SELECT d.x - :x, d.y - :y, d.z - (:z - 20) FROM ents d WHERE d.id = :bent INTO bx, by_, bz;
    mv = bx * fx + by_ * fy + bz * fz;
    bx = fx * mv; by_ = fy * mv;
    mv = SQRT(bx * bx + by_ * by_ + bz * bz);
    IF (mv > 0) THEN BEGIN ax = bx / mv; ay = by_ / mv; az = bz / mv; END
  END
  SUSPEND;
END^

-- W_Attack
CREATE OR ALTER PROCEDURE player_fire (btn SMALLINT)
AS
DECLARE pe INTEGER; DECLARE w INTEGER; DECLARE af DOUBLE PRECISION; DECLARE t DOUBLE PRECISION;
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE fx_ DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE wl SMALLINT; DECLARE lefty SMALLINT;
DECLARE f DOUBLE PRECISION; DECLARE hx DOUBLE PRECISION; DECLARE hy DOUBLE PRECISION; DECLARE hz DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE quad DOUBLE PRECISION; DECLARE td SMALLINT;
DECLARE ax DOUBLE PRECISION; DECLARE ay DOUBLE PRECISION; DECLARE az DOUBLE PRECISION; DECLARE wf INTEGER;
BEGIN
  SELECT p.ent_id, p.weapon, p.attack_finished, p.shells, p.nails, p.rockets, p.cells, p.weapon_sound, p.super_damage_finished, p.weaponframe
    FROM player p WHERE p.id = 1 INTO pe, w, af, sh, na, ro, ce, lefty, quad, wf;
  t = now_();
  SELECT e.waterlevel FROM ents e WHERE e.id = :pe INTO wl;
  IF (btn = 0) THEN
  BEGIN
    UPDATE player p SET p.weapon_sound = 0 WHERE p.id = 1;
    EXIT;
  END
  -- btn 2: a nailgun's or the thunderbolt's next shot, fired by its frames (player_nail1/2, player_light1/2) while
  -- the button is held; a press starts them once attack_finished is past (W_WeaponFrame's W_Attack)
  IF (btn = 1 AND w IN (4, 8, 64) AND wf > 0) THEN EXIT;
  IF (af > t AND btn <> 2) THEN EXIT;
  EXECUTE PROCEDURE view_vectors RETURNING_VALUES ex, ey, ez, fx_, fy, fz, rx, ry, rz, ux, uy, uz;
  -- an attack starts the view weapon's frames at 1 (lightning_time doubles as their start); the cycle's shots go on
  UPDATE player p SET p.show_hostile = :t + 1, p.lightning_time = IIF(:btn = 2, p.lightning_time, :t),
    p.weaponframe = IIF(:btn = 2, p.weaponframe, 1) WHERE p.id = 1;

  IF (w = 4096) THEN                                                      -- axe
  BEGIN
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/ax1.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.5e0 WHERE p.id = 1;
    EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, ex, ey, ez - 6, ex + fx_ * 64, ey + fy * 64, ez - 6 + fz * 64, 0)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    IF (f = 1) THEN EXIT;
    td = 0;
    IF (hit > 0) THEN SELECT e.takedamage FROM ents e WHERE e.id = :hit INTO td;
    IF (td > 0) THEN
    BEGIN
      EXECUTE PROCEDURE fx(3, hx, hy, hz, 0, 0, 0, 20);
      EXECUTE PROCEDURE t_damage(hit, pe, pe, 20);
      EXECUTE PROCEDURE snd_at(hx, hy, hz, 'player/axhit1.wav', 1, 1);
    END
    ELSE
    BEGIN
      EXECUTE PROCEDURE snd_at(hx, hy, hz, 'player/axhit2.wav', 1, 1);
      EXECUTE PROCEDURE fx(1, hx, hy, hz, 0, 0, 0, 0);
    END
  END
  ELSE IF (w = 1) THEN                                                   -- shotgun
  BEGIN
    IF (sh < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/guncock.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.5e0, p.shells = p.shells - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE aim_dir(pe, fx_, fy, fz) RETURNING_VALUES ax, ay, az;     -- dir = aim(self, 100000)
    EXECUTE PROCEDURE fire_bullets(pe, 6, ex, ey, ez, ax, ay, az, 0.04e0, 0.04e0);
  END
  ELSE IF (w = 2) THEN                                                   -- super shotgun
  BEGIN
    IF (sh < 2) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/shotgn2.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.7e0, p.shells = p.shells - 2, p.punchangle = -4 WHERE p.id = 1;
    EXECUTE PROCEDURE aim_dir(pe, fx_, fy, fz) RETURNING_VALUES ax, ay, az;
    EXECUTE PROCEDURE fire_bullets(pe, 14, ex, ey, ez, ax, ay, az, 0.14e0, 0.08e0);
  END
  ELSE IF (w = 4 OR w = 8) THEN                                          -- nailguns
  BEGIN
    IF (na < IIF(w = 8, 2, 1)) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    SELECT p.weapon_sound FROM player p WHERE p.id = 1 INTO lefty;
    EXECUTE PROCEDURE aim_dir(pe, fx_, fy, fz) RETURNING_VALUES ax, ay, az;     -- dir = aim(self, 1000)
    UPDATE player p SET p.attack_finished = :t + 0.2e0, p.nails = p.nails - IIF(:w = 8, 2, 1), p.weapon_sound = 1 - COALESCE(:lefty, 0) WHERE p.id = 1;
    IF (w = 8) THEN
    BEGIN
      EXECUTE PROCEDURE snd(pe, 1, 'weapons/spike2.wav', 1, 1);
      EXECUTE PROCEDURE launch_spike(pe, ex + fx_ * 8, ey + fy * 8, ez - 6 + fz * 8, ax, ay, az, 1000, 'superspike');
    END
    ELSE
    BEGIN
      EXECUTE PROCEDURE snd(pe, 1, 'weapons/rocket1i.wav', 1, 1);
      EXECUTE PROCEDURE launch_spike(pe, ex + fx_ * 8 + rx * IIF(lefty = 1, -4, 4), ey + fy * 8 + ry * IIF(lefty = 1, -4, 4), ez - 6 + fz * 8, ax, ay, az, 1000, 'spike');
    END
    UPDATE player p SET p.punchangle = -2 WHERE p.id = 1;
  END
  ELSE IF (w = 16) THEN                                                  -- grenade launcher
  BEGIN
    IF (ro < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/grenade.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.6e0, p.rockets = p.rockets - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE launch_grenade(pe, ex, ey, ez - 6, fx_ * 600, fy * 600, fz * 600 + 200, 120, 'progs/grenade.mdl', 2.5e0);
  END
  ELSE IF (w = 32) THEN                                                  -- rocket launcher
  BEGIN
    IF (ro < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/sgun1.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.8e0, p.rockets = p.rockets - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE aim_dir(pe, fx_, fy, fz) RETURNING_VALUES ax, ay, az;     -- missile.velocity = aim(self, 1000) * 1000
    EXECUTE PROCEDURE launch_rocket(pe, ex + fx_ * 8, ey + fy * 8, ez - 6 + fz * 8, ax, ay, az, 1000, 100, 'progs/missile.mdl');
  END
  ELSE IF (w = 64) THEN                                                  -- thunderbolt
  BEGIN
    IF (ce < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon(), p.weaponframe = 0 WHERE p.id = 1; EXIT; END
    SELECT p.weapon_sound FROM player p WHERE p.id = 1 INTO lefty;
    IF (COALESCE(lefty, 0) = 0) THEN EXECUTE PROCEDURE snd(pe, 1, 'weapons/lstart.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.2e0, p.cells = p.cells - 1, p.weapon_sound = 1, p.punchangle = -2 WHERE p.id = 1;
    IF (wl > 1) THEN                                                     -- discharge!
    BEGIN
      EXECUTE PROCEDURE snd(pe, 1, 'weapons/lhit.wav', 1, 1);
      EXECUTE PROCEDURE t_radius_damage(pe, pe, 35 * (ce + 1), NULL);
      UPDATE player p SET p.cells = 0 WHERE p.id = 1;
      EXIT;
    END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/lhit.wav', 1, 1);
    EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, ex, ey, ez, ex + fx_ * 600, ey + fy * 600, ez + fz * 600, 1)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    EXECUTE PROCEDURE fx(4, ex + rx * 4, ey + ry * 4, ez - 8, hx, hy, hz, pe);
    EXECUTE PROCEDURE lightning_damage(pe, ex, ey, ez, hx + fx_ * 4, hy + fy * 4, hz + fz * 4, 30);
  END
  IF (quad > t) THEN EXECUTE PROCEDURE snd(pe, 3, 'items/damage3.wav', 1, 1);
END^

-- W_ChangeWeapon / W_SetCurrentAmmo for an impulse 1..8
CREATE OR ALTER PROCEDURE player_impulse (imp SMALLINT)
AS
DECLARE it INTEGER; DECLARE w INTEGER; DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE ok SMALLINT = 1;
BEGIN
  SELECT p.items, p.shells, p.nails, p.rockets, p.cells FROM player p WHERE p.id = 1 INTO it, sh, na, ro, ce;
  IF (imp = 9) THEN                                                      -- give all
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 4096 + 1 + 2 + 4 + 8 + 16 + 32 + 64 + 131072 + 262144), p.shells = 100, p.nails = 200, p.rockets = 100, p.cells = 100 WHERE p.id = 1;
    UPDATE ents e SET e.health = 100 WHERE e.id = player_ent();
    UPDATE player p SET p.armorvalue = 200, p.armortype = 0.8e0, p.items = BIN_OR(BIN_AND(p.items, BIN_NOT(8192 + 16384)), 32768) WHERE p.id = 1;
    EXECUTE PROCEDURE sprint('Very impressive');
    EXIT;
  END
  IF (imp = 10) THEN                                                      -- cycle
  BEGIN
    SELECT p.weapon FROM player p WHERE p.id = 1 INTO w;
    w = IIF(w >= 64, 4096, IIF(w = 4096, 1, w * 2));
    WHILE (BIN_AND(it, w) = 0) DO w = IIF(w >= 64, 4096, IIF(w = 4096, 1, w * 2));
    UPDATE player p SET p.weapon = :w, p.weaponframe = 0 WHERE p.id = 1;
    EXIT;
  END
  w = CASE imp WHEN 1 THEN 4096 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 4 WHEN 5 THEN 8 WHEN 6 THEN 16 WHEN 7 THEN 32 WHEN 8 THEN 64 ELSE 0 END;
  IF (w = 0 OR BIN_AND(it, w) = 0) THEN
  BEGIN
    IF (w <> 0) THEN EXECUTE PROCEDURE sprint('no weapon.');
    EXIT;
  END
  IF (w IN (1, 2) AND sh < 1) THEN ok = 0;
  IF (w IN (4, 8) AND na < 1) THEN ok = 0;
  IF (w IN (16, 32) AND ro < 1) THEN ok = 0;
  IF (w = 64 AND ce < 1) THEN ok = 0;
  IF (ok = 0) THEN
  BEGIN
    EXECUTE PROCEDURE sprint('not enough ammo.');
    EXIT;
  END
  UPDATE player p SET p.weapon = :w, p.weaponframe = 0 WHERE p.id = 1;
END^

-- SV_TouchLinks for the player (SV_LinkEdict(ent, true), every movetype): the triggers and items whose box it is
-- in, and the door and plat trigger fields
CREATE OR ALTER PROCEDURE player_touch_triggers (pe INTEGER, t DOUBLE PRECISION)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE tid INTEGER; DECLARE tcls VARCHAR(40); DECLARE tst SMALLINT; DECLARE tn VARCHAR(40); DECLARE titems INTEGER; DECLARE thp INTEGER;
DECLARE tdm INTEGER; DECLARE tlt DOUBLE PRECISION;
BEGIN
  -- SV_TouchLinks: triggers and items whose box we are in, the boxes as SV_LinkEdict makes absmin and absmax: a unit
  -- bigger all round, and an item (FL_ITEM) 15 units bigger across, so it is picked up from a little way off
  SELECT e.x, e.y, e.z, e.minx - 1, e.miny - 1, e.minz - 1, e.maxx + 1, e.maxy + 1, e.maxz + 1 FROM ents e WHERE e.id = :pe INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz;
  FOR SELECT e.id, e.classname FROM ents e
       WHERE e.solid = 1 AND e.id <> :pe
         AND e.x + e.maxx + IIF(e.classname LIKE 'item%' OR e.classname LIKE 'weapon%' OR e.classname = 'backpack', 15, 1) >= :px + :mnx
         AND e.x + e.minx - IIF(e.classname LIKE 'item%' OR e.classname LIKE 'weapon%' OR e.classname = 'backpack', 15, 1) <= :px + :mxx
         AND e.y + e.maxy + IIF(e.classname LIKE 'item%' OR e.classname LIKE 'weapon%' OR e.classname = 'backpack', 15, 1) >= :py + :mny
         AND e.y + e.miny - IIF(e.classname LIKE 'item%' OR e.classname LIKE 'weapon%' OR e.classname = 'backpack', 15, 1) <= :py + :mxy
         AND e.z + e.maxz + 1 >= :pz + :mnz AND e.z + e.minz - 1 <= :pz + :mxz
       ORDER BY e.id INTO tid, tcls
  DO
  BEGIN
    IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :tid)) THEN CONTINUE;
    IF (tcls IN ('trigger_multiple', 'trigger_once', 'trigger_secret')) THEN
    BEGIN
      IF (EXISTS (SELECT 1 FROM ents e WHERE e.id = :tid AND e.max_health = 0 AND BIN_AND(e.spawnflags, 2) = 0)) THEN
        EXECUTE PROCEDURE trigger_fire(tid, pe);
    END
    ELSE IF (tcls = 'trigger_teleport') THEN EXECUTE PROCEDURE teleport_touch(tid, pe);
    ELSE IF (tcls = 'trigger_changelevel') THEN EXECUTE PROCEDURE changelevel(tid);
    ELSE IF (tcls = 'trigger_push') THEN
    BEGIN
      UPDATE ents e SET e.vx = (SELECT tr.p1x * tr.speed * 10 FROM ents tr WHERE tr.id = :tid), e.vy = (SELECT tr.p1y * tr.speed * 10 FROM ents tr WHERE tr.id = :tid),
             e.vz = (SELECT tr.p1z * tr.speed * 10 FROM ents tr WHERE tr.id = :tid), e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :pe;
      IF ((SELECT p.fly_sound_time FROM player p WHERE p.id = 1) < t) THEN
      BEGIN
        UPDATE player p SET p.fly_sound_time = :t + 1.5e0 WHERE p.id = 1;
        EXECUTE PROCEDURE snd(pe, 0, 'ambience/windfly.wav', 1, 1);
      END
    END
    ELSE IF (tcls = 'trigger_hurt') THEN
    BEGIN
      SELECT e.nextthink, e.dmg FROM ents e WHERE e.id = :tid INTO tlt, tdm;
      IF (tlt IS NULL OR tlt < t) THEN
      BEGIN
        UPDATE ents e SET e.nextthink = :t + 1 WHERE e.id = :tid;
        EXECUTE PROCEDURE t_damage(pe, tid, tid, tdm);
      END
    END
    ELSE IF (tcls = 'trigger_setskill') THEN                  -- the start map's halls: the skill its message names
      UPDATE game g SET g.skill = (SELECT CAST(TRIM(e.message) AS SMALLINT) FROM ents e WHERE e.id = :tid AND TRIM(e.message) SIMILAR TO '[0-3]')
       WHERE g.id = 1 AND EXISTS (SELECT 1 FROM ents e WHERE e.id = :tid AND TRIM(e.message) SIMILAR TO '[0-3]');
    ELSE IF (tcls = 'trigger_message') THEN
    BEGIN
      SELECT e.attack_finished FROM ents e WHERE e.id = :tid INTO tlt;
      IF (tlt < t) THEN
      BEGIN
        UPDATE ents e SET e.attack_finished = :t + 4 WHERE e.id = :tid;
        EXECUTE PROCEDURE cprint((SELECT e.message FROM ents e WHERE e.id = :tid));
        EXECUTE PROCEDURE snd(pe, 2, 'misc/talk.wav', 1, 1);
      END
    END
    ELSE IF (tcls LIKE 'item_%' OR tcls LIKE 'weapon_%' OR tcls = 'backpack') THEN EXECUTE PROCEDURE item_touch(tid, pe);
  END

  -- door trigger fields: 60 units around a linked group of plain doors
  FOR SELECT DISTINCT COALESCE(d.linked_id, d.id) FROM ents d
       WHERE d.classname = 'func_door'
         AND d.x + d.maxx + 60 >= :px + :mnx AND d.x + d.minx - 60 <= :px + :mxx
         AND d.y + d.maxy + 60 >= :py + :mny AND d.y + d.miny - 60 <= :py + :mxy
         AND d.z + d.maxz + 8 >= :pz + :mnz AND d.z + d.minz - 8 <= :pz + :mxz
       INTO tid
  DO
  BEGIN
    SELECT e.mv_state, e.targetname, e.items, e.max_health FROM ents e WHERE e.id = :tid INTO tst, tn, titems, thp;
    IF ((tn IS NULL OR tn = '') AND titems = 0 AND thp = 0 AND tst IN (1, 3)) THEN EXECUTE PROCEDURE door_fire(tid, pe);
    ELSE IF ((tn IS NULL OR tn = '') AND titems = 0 AND thp = 0 AND tst = 0) THEN
      UPDATE ents e SET e.nextthink = e.ltime + e.wait_ WHERE COALESCE(e.linked_id, e.id) = :tid AND e.think = 'door_go_down';
  END
  -- plat trigger fields: inside the plat's footprint, up to 8 above its top
  FOR SELECT e.id, e.mv_state FROM ents e
       WHERE e.classname = 'func_plat'
         AND e.p1x + e.maxx - 25 >= :px + :mnx AND e.p1x + e.minx + 25 <= :px + :mxx
         AND e.p1y + e.maxy - 25 >= :py + :mny AND e.p1y + e.miny + 25 <= :py + :mxy
         AND e.p1z + e.maxz + 8 >= :pz + :mnz AND e.p2z + e.maxz - 8 <= :pz + :mxz
       INTO tid, tst
  DO
  BEGIN
    IF (tst = 1) THEN EXECUTE PROCEDURE plat_go_up(tid);
    ELSE IF (tst = 0) THEN UPDATE ents e SET e.nextthink = e.ltime + 1 WHERE e.id = :tid AND e.think = 'plat_go_down';
  END

END^

-- SV_CheckStuck for the player: inside something solid, back to the last free place (player.free_*, QuakeC's
-- oldorigin), or the first free spot within a unit across and 17 up; untested while the player is where its last
-- move left it (a move only ends where its traces found room). free = 0: stuck where it is.
CREATE OR ALTER PROCEDURE player_check_stuck (c INTEGER) RETURNS (free SMALLINT)
AS
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE i INTEGER; DECLARE j INTEGER; DECLARE k INTEGER;
BEGIN
  free = 1;
  SELECT d.x, d.y, d.z FROM ents d WHERE d.id = :c INTO ox, oy, oz;
  SELECT p.free_x, p.free_y, p.free_z FROM player p WHERE p.id = 1 INTO px, py, pz;
  IF (px = ox AND py = oy AND pz = oz) THEN EXIT;
  IF (test_position(c, ox, oy, oz) = 0) THEN
  BEGIN
    UPDATE player p SET p.free_x = :ox, p.free_y = :oy, p.free_z = :oz WHERE p.id = 1;
    EXIT;
  END
  IF (px IS NOT NULL AND test_position(c, px, py, pz) = 0) THEN
  BEGIN
    UPDATE ents d SET d.x = :px, d.y = :py, d.z = :pz WHERE d.id = :c;
    EXECUTE PROCEDURE link_ent(c);
    EXIT;
  END
  k = 0;
  WHILE (k < 18) DO
  BEGIN
    i = -1;
    WHILE (i <= 1) DO
    BEGIN
      j = -1;
      WHILE (j <= 1) DO
      BEGIN
        IF (test_position(c, ox + i, oy + j, oz + k) = 0) THEN
        BEGIN
          UPDATE ents d SET d.x = :ox + :i, d.y = :oy + :j, d.z = :oz + :k WHERE d.id = :c;
          EXECUTE PROCEDURE link_ent(c);
          EXIT;
        END
        j = j + 1;
      END
      i = i + 1;
    END
    k = k + 1;
  END
  free = 0;                                        -- player is stuck
END^

-- the view weapon's frame, as id's player_shot1..6 and kin step it: an attack sets frame 1 (player_fire), and a
-- think every 0.1 s from it steps it on, run in the tic it falls in (SV_RunThink runs a think due before the frame's
-- end) and before the move, as the client's think is; six frames for the shotguns and the launchers, four for the axe
-- (id's player_axe1..4; it picks frames 5 to 8 half the time); the nailguns cycle 1 to 8 and the thunderbolt 1 to 4,
-- each think firing the next shot while the button is held, back to 0 at the first think after it is let go
CREATE OR ALTER PROCEDURE player_weapon_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION, btn SMALLINT)
AS
DECLARE w INTEGER; DECLARE wf INTEGER; DECLARE lt DOUBLE PRECISION;
BEGIN
  SELECT p.weapon, p.weaponframe, p.lightning_time FROM player p WHERE p.id = 1 INTO w, wf, lt;
  IF (wf = 0) THEN EXIT;
  IF (FLOOR((t - lt + dt) * 10 + 0.001e0) = FLOOR((t - lt) * 10 + 0.001e0)) THEN EXIT;    -- no think due this tic
  IF (w IN (4, 8, 64) AND btn <> 0) THEN
  BEGIN
    UPDATE player p SET p.weaponframe = MOD(:wf, IIF(:w = 64, 4, 8)) + 1 WHERE p.id = 1;
    EXECUTE PROCEDURE player_fire(2);
    EXIT;
  END
  wf = IIF(w IN (4, 8, 64) OR wf + 1 > IIF(w = 4096, 4, 6), 0, wf + 1);
  UPDATE player p SET p.weaponframe = :wf WHERE p.id = 1;
END^

-- W_WeaponFrame's ImpulseCommands: the impulse the client sent last (kept until used, as the engine keeps it) waits
-- until attack_finished has passed; a weapon change puts the view weapon back to its first frame (player_run)
CREATE OR ALTER PROCEDURE player_impulse_due (t DOUBLE PRECISION)
AS
DECLARE imp SMALLINT;
BEGIN
  SELECT p.impulse FROM player p WHERE p.id = 1 AND p.attack_finished <= :t INTO imp;
  IF (imp IS NULL OR imp = 0) THEN EXIT;
  UPDATE player p SET p.impulse = 0 WHERE p.id = 1;
  EXECUTE PROCEDURE player_impulse(imp);
END^

-- SV_ClientThink + PlayerPreThink + physics + PlayerPostThink for one tic
CREATE OR ALTER PROCEDURE player_think (dt DOUBLE PRECISION, fwd DOUBLE PRECISION, side DOUBLE PRECISION,
  yaw_d DOUBLE PRECISION, pitch_d DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, run SMALLINT, imp SMALLINT)
AS
DECLARE pe INTEGER; DECLARE t DOUBLE PRECISION; DECLARE dead SMALLINT; DECLARE flags INTEGER; DECLARE wl SMALLINT; DECLARE wt INTEGER;
DECLARE yaw DOUBLE PRECISION; DECLARE pitch DOUBLE PRECISION;
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE spd DOUBLE PRECISION; DECLARE ns DOUBLE PRECISION; DECLARE control DOUBLE PRECISION;
DECLARE fx_ DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION;
DECLARE wx DOUBLE PRECISION; DECLARE wy DOUBLE PRECISION; DECLARE wz DOUBLE PRECISION; DECLARE wspd DOUBLE PRECISION; DECLARE maxspd DOUBLE PRECISION;
DECLARE cur DOUBLE PRECISION; DECLARE add_ DOUBLE PRECISION; DECLARE acc DOUBLE PRECISION;
DECLARE jr SMALLINT; DECLARE onground SMALLINT;
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE tid INTEGER; DECLARE tcls VARCHAR(40); DECLARE tst SMALLINT; DECLARE tn VARCHAR(40); DECLARE titems INTEGER; DECLARE thp INTEGER;
DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION; DECLARE tdm INTEGER; DECLARE tw DOUBLE PRECISION;
DECLARE dltime DOUBLE PRECISION; DECLARE afin DOUBLE PRECISION; DECLARE hp INTEGER; DECLARE deadt DOUBLE PRECISION;
DECLARE tlt DOUBLE PRECISION; DECLARE oldz DOUBLE PRECISION; DECLARE w INTEGER;
DECLARE wj SMALLINT; DECLARE ttime DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE hx DOUBLE PRECISION; DECLARE hy DOUBLE PRECISION; DECLARE hz DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE fwx DOUBLE PRECISION; DECLARE fwy DOUBLE PRECISION; DECLARE stuckfree SMALLINT; DECLARE jf DOUBLE PRECISION;
DECLARE fm DOUBLE PRECISION; DECLARE sm DOUBLE PRECISION; DECLARE owl SMALLINT;
BEGIN
  -- the intermission: the player is at its camera, out of the world (MOVETYPE_NONE), until the page goes on
  IF (EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.intermission = 1)) THEN EXIT;
  SELECT p.ent_id, p.jump_released, p.dmg_lava_time, p.air_finished, p.dead_time, p.weapon FROM player p WHERE p.id = 1 INTO pe, jr, dltime, afin, deadt, w;
  SELECT e.deadflag, e.flags, e.waterlevel, e.watertype, e.yaw, e.health, e.z FROM ents e WHERE e.id = :pe INTO dead, flags, wl, wt, yaw, hp, oldz;
  t = now_();
  IF (pe IS NULL) THEN EXIT;

  IF (dead = 1) THEN
  BEGIN
    -- PlayerDeathThink: lie there, then restart the level on any button
    EXECUTE PROCEDURE toss_move(pe, dt);
    IF (t > deadt + 1.5e0 AND (fire = 1 OR jump = 1)) THEN
      UPDATE game g SET g.exit_kind = 3 WHERE g.id = 1;
    EXIT;
  END

  -- view angles
  yaw = anglemod(yaw + yaw_d);
  UPDATE player p SET p.pitch = MAXVALUE(-70, MINVALUE(80, p.pitch + :pitch_d)), p.punchangle = MINVALUE(0, p.punchangle + 10 * :dt) WHERE p.id = 1 RETURNING p.pitch INTO pitch;
  UPDATE ents e SET e.yaw = :yaw WHERE e.id = :pe;
  IF (imp > 0) THEN UPDATE player p SET p.impulse = :imp WHERE p.id = 1;   -- kept for W_WeaponFrame (player_impulse_due)

  -- MOVETYPE_NOCLIP (the console's noclip): SV_AirMove's wish velocity along the whole view, pitch included,
  -- capped at sv_maxspeed and taken as the velocity, then SV_Physics_Noclip's move through everything, linked
  -- with its trigger touches (items, teleporters, exits); no water, no gravity, no ground; the weapon still fires
  IF ((SELECT e.movetype FROM ents e WHERE e.id = :pe) = 8) THEN
  BEGIN
    EXECUTE PROCEDURE player_weapon_frame(t, dt, fire);
    maxspd = IIF(run = 1, 320, 200);
    fx_ = COS(yaw * 0.0174532925e0) * COS(pitch * 0.0174532925e0); fy = SIN(yaw * 0.0174532925e0) * COS(pitch * 0.0174532925e0);
    fz = -SIN(pitch * 0.0174532925e0); rx = SIN(yaw * 0.0174532925e0); ry = -COS(yaw * 0.0174532925e0);
    vx = (fx_ * fwd + rx * side) * maxspd; vy = (fy * fwd + ry * side) * maxspd; vz = fz * fwd * maxspd + IIF(jump = 1, maxspd, 0);
    wspd = vlen(vx, vy, vz);
    IF (wspd > 320) THEN BEGIN vx = vx * 320 / wspd; vy = vy * 320 / wspd; vz = vz * 320 / wspd; END
    UPDATE ents e SET e.vx = :vx, e.vy = :vy, e.vz = :vz, e.x = e.x + :vx * :dt, e.y = e.y + :vy * :dt, e.z = e.z + :vz * :dt,
                      e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :pe;
    EXECUTE PROCEDURE link_ent(pe);
    EXECUTE PROCEDURE player_touch_triggers(pe, t);      -- SV_LinkEdict(ent, true): noclip touches triggers too
    IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :pe)) THEN EXIT;
    EXECUTE PROCEDURE player_impulse_due(t);
    EXECUTE PROCEDURE player_fire(fire);
    EXECUTE PROCEDURE player_current_ammo;
    EXIT;
  END

  -- water: drowning, slime and lava. As in Quake, everything before the move sees the water level and type the last
  -- frame's SV_CheckWater stored (taken before that frame's move): SV_ClientThink, PlayerPreThink's WaterMove,
  -- CheckWaterJump and PlayerJump; this frame's check comes just before the gravity, which it decides
  SELECT e.waterlevel, e.watertype FROM ents e WHERE e.id = :pe INTO owl, wt;
  wl = owl;
  -- WaterMove: out of the water a gasp after a long breath held, and the air back to 12 s; under it, past the air,
  -- a bite each second that grows by 2 (2, 4 ... 14, then 10 again), the drowning sound for its pain
  IF (wl <> 3) THEN
  BEGIN
    IF (afin < t) THEN EXECUTE PROCEDURE snd(pe, 2, 'player/gasp2.wav', 1, 1);
    ELSE IF (afin < t + 9) THEN EXECUTE PROCEDURE snd(pe, 2, 'player/gasp1.wav', 1, 1);
    UPDATE player p SET p.air_finished = :t + 12, p.drown_dmg = 2 WHERE p.id = 1 AND (p.air_finished <> :t + 12 OR p.drown_dmg <> 2);
  END
  ELSE IF (afin < t AND (SELECT p.pain_finished FROM player p WHERE p.id = 1) < t) THEN
  BEGIN
    UPDATE player p SET p.drown_dmg = IIF(p.drown_dmg + 2 > 15, 10, p.drown_dmg + 2) WHERE p.id = 1;
    EXECUTE PROCEDURE t_damage(pe, 0, 0, (SELECT p.drown_dmg FROM player p WHERE p.id = 1));
    EXECUTE PROCEDURE snd(pe, 2, 'player/drown' || CAST(1 + FLOOR(rnd() * 2) AS INTEGER) || '.wav', 1, 1);
    UPDATE player p SET p.pain_finished = :t + 1 WHERE p.id = 1;
  END
  -- lava burns 10 × waterlevel every 0.2 s (every second in the biosuit), slime 4 × waterlevel every second (not at
  -- all in the biosuit); a bite waits until time is past dmgtime
  IF (wl > 0 AND wt = -5 AND dltime < t) THEN
  BEGIN
    UPDATE player p SET p.dmg_lava_time = :t + IIF(p.radsuit_finished > :t, 1, 0.2e0) WHERE p.id = 1;
    EXECUTE PROCEDURE t_damage(pe, 0, 0, 10 * wl);
  END
  ELSE IF (wl > 0 AND wt = -4 AND dltime < t AND (SELECT p.radsuit_finished FROM player p WHERE p.id = 1) < t) THEN
  BEGIN
    UPDATE player p SET p.dmg_lava_time = :t + 1 WHERE p.id = 1;
    EXECUTE PROCEDURE t_damage(pe, 0, 0, 4 * wl);
  END
  IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :pe)) THEN EXIT;
  -- going in (FL_INWATER): the liquid's sound, and dmgtime cleared, so the frame after the first bite bites again;
  -- coming out: misc/outwater.wav
  SELECT e.flags FROM ents e WHERE e.id = :pe INTO flags;
  IF (wl = 0 AND BIN_AND(flags, 16) <> 0) THEN
  BEGIN
    EXECUTE PROCEDURE snd(pe, 4, 'misc/outwater.wav', 1, 1);
    UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(16)) WHERE e.id = :pe;
  END
  ELSE IF (wl > 0 AND BIN_AND(flags, 16) = 0) THEN
  BEGIN
    IF (wt = -5) THEN EXECUTE PROCEDURE snd(pe, 4, 'player/inlava.wav', 1, 1);
    ELSE IF (wt = -3) THEN EXECUTE PROCEDURE snd(pe, 4, 'player/inh2o.wav', 1, 1);
    ELSE IF (wt = -4) THEN EXECUTE PROCEDURE snd(pe, 4, 'player/slimbrn2.wav', 1, 1);
    UPDATE ents e SET e.flags = BIN_OR(e.flags, 16) WHERE e.id = :pe;
    UPDATE player p SET p.dmg_lava_time = 0 WHERE p.id = 1;
  END

  -- SV_WaterJump (SV_ClientThink, while FL_WATERJUMP holds from an earlier frame): the push into the ledge the jump
  -- found (CheckWaterJump's movedir) is the velocity across, until teleport_time or out of the water; that frame has
  -- no friction or acceleration of its own
  SELECT e.flags, e.teleport_time, e.yaw FROM ents e WHERE e.id = :pe INTO flags, ttime, yaw;
  wj = IIF(BIN_AND(flags, 2048) <> 0, 1, 0);
  IF (wj = 1) THEN
  BEGIN
    IF (owl = 0 OR t > ttime) THEN
      UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(2048)), e.teleport_time = 0 WHERE e.id = :pe;
    UPDATE ents e SET e.vx = (SELECT p.wj_dx FROM player p WHERE p.id = 1), e.vy = (SELECT p.wj_dy FROM player p WHERE p.id = 1) WHERE e.id = :pe;
  END

  SELECT e.vx, e.vy, e.vz, e.flags FROM ents e WHERE e.id = :pe INTO vx, vy, vz, flags;
  onground = IIF(BIN_AND(flags, 512) <> 0, 1, 0);
  maxspd = IIF(run = 1, 320, 200);

  -- SV_ClientThink's move, as QuakeC mode has it: the input as Quake's client sends it (cl_forwardspeed 200 and
  -- cl_sidespeed 350, twice those running), no backing into a teleporter just used; then SV_WaterMove (the whole
  -- view's direction, friction 4 on the speed, 0.7 of the wish) or SV_AirMove (the body's angles, whose pitch is a
  -- third of the view's, the wish flat and at most sv_maxspeed 320; on the ground SV_UserFriction, doubled at an
  -- edge, and SV_Accelerate; in the air SV_AirAccelerate)
  fm = fwd * IIF(run = 1, 400, 200); sm = side * IIF(run = 1, 700, 350);
  IF (t < ttime AND fm < 0) THEN fm = 0;
  rx = SIN(yaw * 0.0174532925e0); ry = -COS(yaw * 0.0174532925e0);
  IF (wl >= 2 AND wj = 0) THEN
  BEGIN
    spd = vlen(vx, vy, vz);
    IF (spd > 0) THEN
    BEGIN
      ns = MAXVALUE(0, spd - dt * spd * 4);
      vx = vx * ns / spd; vy = vy * ns / spd; vz = vz * ns / spd;
    END
    fx_ = COS(pitch * 0.0174532925e0) * COS(yaw * 0.0174532925e0); fy = COS(pitch * 0.0174532925e0) * SIN(yaw * 0.0174532925e0);
    fz = -SIN(pitch * 0.0174532925e0);
    wx = fx_ * fm + rx * sm; wy = fy * fm + ry * sm; wz = fz * fm;
    IF (fm = 0 AND sm = 0) THEN wz = wz - 60;                      -- drift towards the bottom (jump is no upmove)
    wspd = vlen(wx, wy, wz);
    IF (wspd > 320) THEN BEGIN wx = wx * 320 / wspd; wy = wy * 320 / wspd; wz = wz * 320 / wspd; wspd = 320; END
    IF (wspd > 0) THEN
    BEGIN
      cur = vlen(vx, vy, vz);                                        -- SV_WaterMove: the wish less the whole speed
      add_ = wspd * 0.7e0 - cur;
      IF (add_ > 0) THEN
      BEGIN
        acc = MINVALUE(add_, 10 * wspd * 0.7e0 * dt);
        vx = vx + acc * wx / wspd; vy = vy + acc * wy / wspd; vz = vz + acc * wz / wspd;
      END
    END
  END
  ELSE IF (wj = 0) THEN
  BEGIN
    fx_ = COS(pitch / 3 * 0.0174532925e0) * COS(yaw * 0.0174532925e0); fy = COS(pitch / 3 * 0.0174532925e0) * SIN(yaw * 0.0174532925e0);
    wx = fx_ * fm + rx * sm; wy = fy * fm + ry * sm;
    wspd = vlen(wx, wy, 0);
    IF (wspd > 320) THEN BEGIN wx = wx * 320 / wspd; wy = wy * 320 / wspd; wspd = 320; END
    IF (onground = 1) THEN
    BEGIN
      spd = vlen(vx, vy, 0);
      IF (spd > 0) THEN
      BEGIN
        SELECT e.x, e.y, e.z + e.minz FROM ents e WHERE e.id = :pe INTO px, py, pz;
        EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, px + vx / spd * 16, py + vy / spd * 16, pz, px + vx / spd * 16, py + vy / spd * 16, pz - 34, 1)
          RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
        control = IIF(spd < 100, 100, spd);
        ns = MAXVALUE(0, spd - dt * control * IIF(f = 1, 8, 4));
        vx = vx * ns / spd; vy = vy * ns / spd; vz = vz * ns / spd;     -- all three, as SV_UserFriction scales them
      END
    END
    IF (wspd > 0) THEN
    BEGIN
      cur = (vx * wx + vy * wy) / wspd;
      IF (onground = 1) THEN add_ = wspd - cur;
      ELSE add_ = MINVALUE(wspd, 30) - cur;                            -- SV_AirAccelerate
      IF (add_ > 0) THEN
      BEGIN
        acc = MINVALUE(add_, 10 * wspd * dt);
        vx = vx + acc * wx / wspd; vy = vy + acc * wy / wspd;
      END
    END
  END
  -- WaterMove's drag (PlayerPreThink): in a liquid, but not in a water jump, the speed loses 0.8 × waterlevel of
  -- itself a second
  IF (wl > 0 AND BIN_AND(flags, 2048) = 0) THEN
  BEGIN
    vx = vx - 0.8e0 * wl * dt * vx; vy = vy - 0.8e0 * wl * dt * vy; vz = vz - 0.8e0 * wl * dt * vz;
  END

  -- CheckWaterJump (PlayerPreThink, waist deep, whatever the input): solid at the waist 24 units ahead along the
  -- body's yaw, open at the head (maxs_z up): the hop out, 225 up, the push into the ledge (its normal × -50) kept
  -- for SV_WaterJump, 2 seconds at most
  IF (wl = 2) THEN
  BEGIN
    SELECT e.x, e.y, e.z, e.maxz FROM ents e WHERE e.id = :pe INTO px, py, pz, tz;
    EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, px, py, pz + 8, px + COS(yaw * 0.0174532925e0) * 24, py + SIN(yaw * 0.0174532925e0) * 24, pz + 8, 1)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    IF (f < 1) THEN
    BEGIN
      tx = nx * -50; ty = ny * -50;
      EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, px, py, pz + tz, px + COS(yaw * 0.0174532925e0) * 24, py + SIN(yaw * 0.0174532925e0) * 24, pz + tz, 1)
        RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
      IF (f = 1) THEN
      BEGIN
        flags = BIN_OR(flags, 2048); vz = 225;
        UPDATE ents e SET e.teleport_time = :t + 2 WHERE e.id = :pe;
        UPDATE player p SET p.jump_released = 0, p.wj_dx = :tx, p.wj_dy = :ty WHERE p.id = 1;
        jr = 0;
      END
    END
  END

  -- jumping (PlayerJump, in PlayerPreThink: after SV_ClientThink's friction and acceleration, so the jump's frame
  -- still has the ground's friction and swimming up is the liquid's speed itself)
  IF (jump = 1 AND BIN_AND(flags, 2048) <> 0) THEN BEGIN END     -- no jumping during a water jump
  ELSE IF (jump = 1) THEN
  BEGIN
    IF (wl >= 2) THEN
    BEGIN
      vz = IIF(wt = -3, 100, IIF(wt = -4, 80, 50));
      IF ((SELECT p.swim_time FROM player p WHERE p.id = 1) < t) THEN
      BEGIN
        UPDATE player p SET p.swim_time = :t + 1 WHERE p.id = 1;
        EXECUTE PROCEDURE snd(pe, 2, IIF(rnd() < 0.5e0, 'misc/water1.wav', 'misc/water2.wav'), 1, 1);
      END
    END
    ELSE IF (onground = 1 AND jr = 1) THEN
    BEGIN
      vz = vz + 270;
      flags = BIN_AND(flags, BIN_NOT(512));
      onground = 0;
      UPDATE player p SET p.jump_released = 0 WHERE p.id = 1;
      EXECUTE PROCEDURE snd(pe, 2, 'player/plyrjmp8.wav', 1, 1);
    END
  END
  ELSE UPDATE player p SET p.jump_released = 1 WHERE p.id = 1;

  -- SV_AddGravity, every frame but swimming or water-jumping, on the ground too: the walk then presses into
  -- the floor and finds it again (without it FL_ONGROUND went off every other frame, halving friction
  -- and dropping jumps)
  -- the client's think (SV_RunThink, before the move): the view weapon's frames, the nailguns' next shot
  EXECUTE PROCEDURE player_weapon_frame(t, dt, fire);
  -- SV_CheckWater, then: no gravity waist deep or deeper
  EXECUTE PROCEDURE check_water(pe) RETURNING_VALUES wl, wt;
  IF (wl < 2 AND BIN_AND(flags, 2048) = 0) THEN vz = vz - (SELECT g.gravity FROM game g WHERE g.id = 1) * dt;
  UPDATE ents e SET e.vx = :vx, e.vy = :vy, e.vz = :vz, e.flags = :flags WHERE e.id = :pe;

  -- move: SV_CheckStuck, then the walk (where it ends is free, kept as the place to come back to)
  EXECUTE PROCEDURE player_check_stuck(pe) RETURNING_VALUES stuckfree;
  -- SV_WalkMove, swimming too (SV_Physics_Client's MOVETYPE_WALK: in the water it may stair up, so the player climbs
  -- out onto a ledge a step above), with the view's forward vector for SV_TryUnstick and SV_WallFriction
  EXECUTE PROCEDURE walk_move(pe, dt, COS(pitch * 0.0174532925e0) * COS(yaw * 0.0174532925e0), COS(pitch * 0.0174532925e0) * SIN(yaw * 0.0174532925e0));
  EXECUTE PROCEDURE link_ent(pe);
  IF (stuckfree = 1) THEN
    UPDATE player p SET p.free_x = (SELECT e.x FROM ents e WHERE e.id = :pe), p.free_y = (SELECT e.y FROM ents e WHERE e.id = :pe),
                        p.free_z = (SELECT e.z FROM ents e WHERE e.id = :pe) WHERE p.id = 1;
  -- smooth the view over steps
  SELECT e.z FROM ents e WHERE e.id = :pe INTO pz;
  UPDATE player p SET p.stepz = IIF(BIN_AND((SELECT e.flags FROM ents e WHERE e.id = :pe), 512) <> 0 AND :pz - :oldz > 0 AND :pz - :oldz <= 18,
                                     MINVALUE(p.stepz + (:pz - :oldz), 18), MAXVALUE(0, p.stepz - 160 * :dt)) WHERE p.id = 1;

  EXECUTE PROCEDURE player_touch_triggers(pe, t);

  -- powerups wearing off
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(1048576)) WHERE p.id = 1 AND p.invincible_finished < :t AND BIN_AND(p.items, 1048576) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(524288)) WHERE p.id = 1 AND p.invisible_finished < :t AND BIN_AND(p.items, 524288) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(4194304)) WHERE p.id = 1 AND p.super_damage_finished < :t AND BIN_AND(p.items, 4194304) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(2097152)) WHERE p.id = 1 AND p.radsuit_finished < :t AND BIN_AND(p.items, 2097152) <> 0;
  -- item_megahealth_rot: from 5 s after a megahealth, a point of health a second while over 100, then IT_SUPERHEALTH
  -- off; the megahealth's own think, so run in the tic it falls in (due before the frame's end) and stepped from its
  -- due time (player.rot_time)
  IF ((SELECT p.rot_time FROM player p WHERE p.id = 1) <= t + dt + 1e-6) THEN
  BEGIN
    IF ((SELECT e.health FROM ents e WHERE e.id = :pe) > 100) THEN
    BEGIN
      UPDATE ents e SET e.health = e.health - 1 WHERE e.id = :pe;
      UPDATE player p SET p.rot_time = p.rot_time + 1 WHERE p.id = 1;
    END
    ELSE UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(65536)), p.rot_time = NULL WHERE p.id = 1;
  END

  -- weapon (W_WeaponFrame)
  EXECUTE PROCEDURE player_impulse_due(t);
  EXECUTE PROCEDURE player_fire(fire);
  -- PlayerPostThink's landing: on the ground (on anything) after a frame in the air that left it falling faster than
  -- 300, a splash in water, else the thud, and from faster than 650 five points of damage
  SELECT e.flags, e.vz, e.watertype, e.health FROM ents e WHERE e.id = :pe INTO flags, vz, wt, hp;
  SELECT p.jump_flag FROM player p WHERE p.id = 1 INTO jf;
  IF (BIN_AND(flags, 512) <> 0 AND jf < -300 AND hp > 0) THEN
  BEGIN
    IF (wt = -3) THEN EXECUTE PROCEDURE snd(pe, 4, 'player/h2ojump.wav', 1, 1);
    ELSE IF (jf < -650) THEN
    BEGIN
      EXECUTE PROCEDURE t_damage(pe, 0, 0, 5);
      EXECUTE PROCEDURE snd(pe, 2, 'player/land2.wav', 1, 1);
    END
    ELSE EXECUTE PROCEDURE snd(pe, 2, 'player/land.wav', 1, 1);
    jf = 0;
  END
  IF (BIN_AND(flags, 512) = 0) THEN jf = vz;
  UPDATE player p SET p.jump_flag = :jf WHERE p.id = 1 AND p.jump_flag <> :jf;
  IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :pe)) THEN EXIT;
  EXECUTE PROCEDURE player_current_ammo;
  -- player animation
  UPDATE ents e SET e.anim = TRIM(IIF(ABS(e.vx) + ABS(e.vy) > 10, 'rockrun', 'stand')), e.anim_frame = MOD(CAST(:t * 10 AS INTEGER), 6) WHERE e.id = :pe;
END^

SET TERM ; ^
