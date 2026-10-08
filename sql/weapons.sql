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
    r1 = (RAND() * 2 - 1) * spread_x; r2 = (RAND() * 2 - 1) * spread_y;
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
BEGIN
  SELECT p.ent_id, p.weapon, p.attack_finished, p.shells, p.nails, p.rockets, p.cells, p.weapon_sound, p.super_damage_finished
    FROM player p WHERE p.id = 1 INTO pe, w, af, sh, na, ro, ce, lefty, quad;
  t = now_();
  SELECT e.waterlevel FROM ents e WHERE e.id = :pe INTO wl;
  IF (btn = 0) THEN
  BEGIN
    UPDATE player p SET p.weapon_sound = 0 WHERE p.id = 1;
    EXIT;
  END
  IF (af > t) THEN EXIT;
  EXECUTE PROCEDURE view_vectors RETURNING_VALUES ex, ey, ez, fx_, fy, fz, rx, ry, rz, ux, uy, uz;
  UPDATE player p SET p.show_hostile = :t + 1, p.lightning_time = :t WHERE p.id = 1;   -- lightning_time doubles as attack start

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
    IF (sh < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/guncock.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.5e0, p.shells = p.shells - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE fire_bullets(pe, 6, ex, ey, ez, fx_, fy, fz, 0.04e0, 0.04e0);
  END
  ELSE IF (w = 2) THEN                                                   -- super shotgun
  BEGIN
    IF (sh < 2) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/shotgn2.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.7e0, p.shells = p.shells - 2, p.punchangle = -4 WHERE p.id = 1;
    EXECUTE PROCEDURE fire_bullets(pe, 14, ex, ey, ez, fx_, fy, fz, 0.14e0, 0.08e0);
  END
  ELSE IF (w = 4 OR w = 8) THEN                                          -- nailguns
  BEGIN
    IF (na < IIF(w = 8, 2, 1)) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    SELECT p.weapon_sound FROM player p WHERE p.id = 1 INTO lefty;
    UPDATE player p SET p.attack_finished = :t + 0.1e0, p.nails = p.nails - IIF(:w = 8, 2, 1), p.weapon_sound = 1 - COALESCE(:lefty, 0) WHERE p.id = 1;
    IF (w = 8) THEN
    BEGIN
      EXECUTE PROCEDURE snd(pe, 1, 'weapons/spike2.wav', 1, 1);
      EXECUTE PROCEDURE launch_spike(pe, ex + fx_ * 8, ey + fy * 8, ez - 6 + fz * 8, fx_, fy, fz, 1000, 'superspike');
    END
    ELSE
    BEGIN
      EXECUTE PROCEDURE snd(pe, 1, 'weapons/rocket1i.wav', 1, 1);
      EXECUTE PROCEDURE launch_spike(pe, ex + fx_ * 8 + rx * IIF(lefty = 1, -4, 4), ey + fy * 8 + ry * IIF(lefty = 1, -4, 4), ez - 6 + fz * 8, fx_, fy, fz, 1000, 'spike');
    END
    UPDATE player p SET p.punchangle = -2 WHERE p.id = 1;
  END
  ELSE IF (w = 16) THEN                                                  -- grenade launcher
  BEGIN
    IF (ro < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/grenade.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.6e0, p.rockets = p.rockets - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE launch_grenade(pe, ex, ey, ez - 6, fx_ * 600, fy * 600, fz * 600 + 200, 120, 'progs/grenade.mdl', 2.5e0);
  END
  ELSE IF (w = 32) THEN                                                  -- rocket launcher
  BEGIN
    IF (ro < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    EXECUTE PROCEDURE snd(pe, 1, 'weapons/sgun1.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.8e0, p.rockets = p.rockets - 1, p.punchangle = -2 WHERE p.id = 1;
    EXECUTE PROCEDURE launch_rocket(pe, ex + fx_ * 8, ey + fy * 8, ez - 6 + fz * 8, fx_, fy, fz, 1000, 100, 'progs/missile.mdl');
  END
  ELSE IF (w = 64) THEN                                                  -- thunderbolt
  BEGIN
    IF (ce < 1) THEN BEGIN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1; EXIT; END
    SELECT p.weapon_sound FROM player p WHERE p.id = 1 INTO lefty;
    IF (COALESCE(lefty, 0) = 0) THEN EXECUTE PROCEDURE snd(pe, 1, 'weapons/lstart.wav', 1, 1);
    UPDATE player p SET p.attack_finished = :t + 0.1e0, p.cells = p.cells - 1, p.weapon_sound = 1, p.punchangle = -2 WHERE p.id = 1;
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
    UPDATE player p SET p.weapon = :w WHERE p.id = 1;
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
  UPDATE player p SET p.weapon = :w WHERE p.id = 1;
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
  IF (imp > 0) THEN EXECUTE PROCEDURE player_impulse(imp);

  -- water: drowning, slime and lava
  EXECUTE PROCEDURE check_water(pe) RETURNING_VALUES wl, wt;
  IF (wl = 3) THEN
  BEGIN
    IF (afin < t) THEN
    BEGIN
      EXECUTE PROCEDURE t_damage(pe, 0, 0, 2);
      EXECUTE PROCEDURE snd(pe, 2, 'player/drown' || CAST(1 + FLOOR(RAND() * 2) AS INTEGER) || '.wav', 1, 1);
      UPDATE player p SET p.air_finished = :t + 1 WHERE p.id = 1;
    END
  END
  ELSE UPDATE player p SET p.air_finished = :t + 12 WHERE p.id = 1;
  IF (wl > 0 AND wt IN (-4, -5) AND dltime < t) THEN
  BEGIN
    UPDATE player p SET p.dmg_lava_time = :t + 0.2e0 WHERE p.id = 1;
    IF ((SELECT p.radsuit_finished FROM player p WHERE p.id = 1) < t) THEN
      EXECUTE PROCEDURE t_damage(pe, 0, 0, IIF(wt = -5, 10, 4) * wl);
  END
  IF (wl > 0 AND wt = -3 AND dltime < t AND BIN_AND(flags, 16) = 0) THEN
    EXECUTE PROCEDURE snd(pe, 2, 'player/inh2o.wav', 1, 1);
  UPDATE ents e SET e.flags = IIF(:wl > 0, BIN_OR(e.flags, 16), BIN_AND(e.flags, BIN_NOT(16))) WHERE e.id = :pe;

  -- FL_WATERJUMP: the hop out of the water onto a low ledge (CheckWaterJump)
  SELECT e.flags, e.teleport_time, e.yaw FROM ents e WHERE e.id = :pe INTO flags, ttime, yaw;
  wj = IIF(BIN_AND(flags, 2048) <> 0, 1, 0);
  IF (wj = 1 AND (wl = 0 OR ttime < t)) THEN
  BEGIN
    UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(2048)) WHERE e.id = :pe;
    wj = 0;
  END
  IF (wj = 0 AND wl = 2 AND fwd > 0) THEN
  BEGIN
    SELECT e.x, e.y, e.z FROM ents e WHERE e.id = :pe INTO px, py, pz;
    -- solid at the waist 24 units ahead, open at the head: a ledge to climb
    EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, px, py, pz + 8, px + COS(yaw * 0.0174532925e0) * 24, py + SIN(yaw * 0.0174532925e0) * 24, pz + 8, 1)
      RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
    IF (f < 1) THEN
    BEGIN
      EXECUTE PROCEDURE trace_move(pe, 0, 0, 0, 0, 0, 0, px, py, pz + 24, px + COS(yaw * 0.0174532925e0) * 24, py + SIN(yaw * 0.0174532925e0) * 24, pz + 24, 1)
        RETURNING_VALUES f, hx, hy, hz, nx, ny, nz, als, sts, io, iw, hit;
      IF (f = 1) THEN
      BEGIN
        UPDATE ents e SET e.flags = BIN_OR(e.flags, 2048), e.vz = 225, e.teleport_time = :t + 2 WHERE e.id = :pe;
        UPDATE player p SET p.jump_released = 0 WHERE p.id = 1;
        wj = 1;
      END
    END
  END

  SELECT e.vx, e.vy, e.vz, e.flags FROM ents e WHERE e.id = :pe INTO vx, vy, vz, flags;
  onground = IIF(BIN_AND(flags, 512) <> 0, 1, 0);
  maxspd = IIF(run = 1, 320, 200);

  -- jumping
  IF (jump = 1) THEN
  BEGIN
    IF (wl >= 2) THEN
    BEGIN
      vz = IIF(wt = -3, 100, IIF(wt = -4, 80, 50));
      IF ((SELECT p.swim_time FROM player p WHERE p.id = 1) < t) THEN
      BEGIN
        UPDATE player p SET p.swim_time = :t + 1 WHERE p.id = 1;
        EXECUTE PROCEDURE snd(pe, 2, IIF(RAND() < 0.5e0, 'misc/water1.wav', 'misc/water2.wav'), 1, 1);
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

  -- SV_UserFriction
  IF (wj = 0 AND (onground = 1 OR wl >= 2)) THEN
  BEGIN
    spd = IIF(wl >= 2, vlen(vx, vy, vz), vlen(vx, vy, 0));
    IF (spd > 0) THEN
    BEGIN
      IF (wl >= 2) THEN ns = spd - dt * spd * 4;
      ELSE
      BEGIN
        control = IIF(spd < 100, 100, spd);
        ns = spd - dt * control * 4;
      END
      IF (ns < 0) THEN ns = 0;
      vx = vx * ns / spd; vy = vy * ns / spd;
      IF (wl >= 2) THEN vz = vz * ns / spd;
    END
  END

  -- the wish direction
  fx_ = COS(yaw * 0.0174532925e0); fy = SIN(yaw * 0.0174532925e0);
  rx = fy; ry = -fx_;
  IF (wl >= 2 AND wj = 0) THEN
  BEGIN
    -- swimming: the forward vector follows the pitch
    fz = -SIN(pitch * 0.0174532925e0);
    fx_ = fx_ * COS(pitch * 0.0174532925e0); fy = fy * COS(pitch * 0.0174532925e0);
    wx = fx_ * fwd * maxspd + rx * side * maxspd; wy = fy * fwd * maxspd + ry * side * maxspd; wz = fz * fwd * maxspd;
    IF (fwd = 0 AND side = 0 AND jump = 0) THEN wz = wz - 60;      -- drift towards the bottom
    wspd = vlen(wx, wy, wz);
    IF (wspd > maxspd) THEN BEGIN wx = wx * maxspd / wspd; wy = wy * maxspd / wspd; wz = wz * maxspd / wspd; wspd = maxspd; END
    wspd = wspd * 0.7e0;
    IF (wspd > 0) THEN
    BEGIN
      cur = (vx * wx + vy * wy + vz * wz) / vlen(wx, wy, wz);
      add_ = wspd - cur;
      IF (add_ > 0) THEN
      BEGIN
        acc = MINVALUE(add_, 10 * wspd * dt);
        vx = vx + acc * wx / vlen(wx, wy, wz); vy = vy + acc * wy / vlen(wx, wy, wz); vz = vz + acc * wz / vlen(wx, wy, wz);
      END
    END
  END
  ELSE
  BEGIN
    wx = fx_ * fwd * maxspd + rx * side * maxspd; wy = fy * fwd * maxspd + ry * side * maxspd;
    wspd = vlen(wx, wy, 0);
    IF (wspd > maxspd) THEN BEGIN wx = wx * maxspd / wspd; wy = wy * maxspd / wspd; wspd = maxspd; END
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
  -- gravity (not during the water jump)
  IF (onground = 0 AND wl < 2 AND wj = 0) THEN vz = vz - (SELECT g.gravity FROM game g WHERE g.id = 1) * dt;
  UPDATE ents e SET e.vx = :vx, e.vy = :vy, e.vz = :vz, e.flags = :flags WHERE e.id = :pe;

  -- move
  IF (wl >= 2 AND wj = 0) THEN
  BEGIN
    UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :pe;
    EXECUTE PROCEDURE fly_move(pe, dt) RETURNING_VALUES tst, tid;
  END
  ELSE EXECUTE PROCEDURE walk_move(pe, dt);
  EXECUTE PROCEDURE link_ent(pe);
  -- smooth the view over steps
  SELECT e.z FROM ents e WHERE e.id = :pe INTO pz;
  UPDATE player p SET p.stepz = IIF(BIN_AND((SELECT e.flags FROM ents e WHERE e.id = :pe), 512) <> 0 AND :pz - :oldz > 0 AND :pz - :oldz <= 18,
                                     MINVALUE(p.stepz + (:pz - :oldz), 18), MAXVALUE(0, p.stepz - 160 * :dt)) WHERE p.id = 1;

  -- SV_TouchLinks: triggers and items whose box we are in
  SELECT e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz FROM ents e WHERE e.id = :pe INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz;
  FOR SELECT e.id, e.classname FROM ents e
       WHERE e.solid = 1 AND e.id <> :pe
         AND e.x + e.maxx >= :px + :mnx AND e.x + e.minx <= :px + :mxx
         AND e.y + e.maxy >= :py + :mny AND e.y + e.miny <= :py + :mxy
         AND e.z + e.maxz >= :pz + :mnz AND e.z + e.minz <= :pz + :mxz
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

  -- powerups wearing off
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(1048576)) WHERE p.id = 1 AND p.invincible_finished < :t AND BIN_AND(p.items, 1048576) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(524288)) WHERE p.id = 1 AND p.invisible_finished < :t AND BIN_AND(p.items, 524288) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(4194304)) WHERE p.id = 1 AND p.super_damage_finished < :t AND BIN_AND(p.items, 4194304) <> 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(2097152)) WHERE p.id = 1 AND p.radsuit_finished < :t AND BIN_AND(p.items, 2097152) <> 0;
  -- megahealth rots
  UPDATE ents e SET e.health = e.health - 1 WHERE e.id = :pe AND e.health > 100 AND MOD((SELECT g.tic FROM game g WHERE g.id = 1), 20) = 0;
  UPDATE player p SET p.items = BIN_AND(p.items, BIN_NOT(65536)) WHERE p.id = 1 AND (SELECT e.health FROM ents e WHERE e.id = :pe) <= 100;

  -- weapon
  EXECUTE PROCEDURE player_fire(fire);
  UPDATE player p SET p.weaponframe = IIF(p.attack_finished > :t AND p.weapon <> 0, 1 + FLOOR((:t - p.lightning_time) * 10 + 0.001e0), 0) WHERE p.id = 1;
  -- player animation
  UPDATE ents e SET e.anim = TRIM(IIF(ABS(e.vx) + ABS(e.vy) > 10, 'rockrun', 'stand')), e.anim_frame = MOD(CAST(:t * 10 AS INTEGER), 6) WHERE e.id = :pe;
END^

SET TERM ; ^
