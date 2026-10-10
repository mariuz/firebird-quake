-- qcphysics.sql – the server's physics on QuakeC edicts in QuakeC mode (sv_phys.c, sv_user.c): the
-- client's move, the pushers, toss and step, the thinks on their clocks, and qc_server_frame.

SET TERM ^ ;

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
  IF (qc_client_active(c) = 0 OR NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :c)) THEN EXIT;
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
  IF (qc_client_active(c) = 0 OR NOT EXISTS (SELECT 1 FROM ents d WHERE d.id = :c)) THEN EXIT;
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
    IF (EXISTS (SELECT 1 FROM bots b WHERE b.c = :c) AND EXISTS (SELECT 1 FROM qc_edicts d WHERE d.id = :c AND d.free = 0)) THEN
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
    -- (the edict's ents row and its nextthink joined once, rather than looked up by each EXISTS; the + 0
    -- keeps the plan walking the edicts in order)
    SELECT FIRST 1 d.id FROM qc_edicts d LEFT JOIN ents x ON x.id = d.id + 0 LEFT JOIN qc_fields n ON n.ent = d.id + 0 AND n.ofs = :f_nt
      WHERE d.free = 0 AND d.id > :last AND (
        d.id <= :mc
        OR (n.v > 0 AND n.v <= :t + :dt + 1e-6)
        OR (x.movetype = 7 AND n.v > 0)
        OR (x.movetype IN (7, 5, 9, 8) AND (x.vx <> 0 OR x.vy <> 0 OR x.vz <> 0))
        OR (x.movetype IN (6, 10) AND BIN_AND(x.flags, 512) = 0)
        OR (x.movetype = 4 AND BIN_AND(x.flags, 515) = 0))
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

SET TERM ; ^
