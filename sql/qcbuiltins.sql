-- qcbuiltins.sql – the QuakeC VM's builtins (pr_cmds.c), the parameters at OFS_PARM0.. and the result at
-- OFS_RETURN, in five procedures by kind (qc_bi_math, _move, _trace, _ent, _io), each declaring only the
-- locals its builtins use: a procedure's locals cost about 0.1 µs each to set up on every call, and an IF
-- chain about 0.1 µs a branch. qc_builtin dispatches on qc_bi_group(n); the JIT calls the group directly.
-- Also the temp-entity and client messages that WriteByte and its kin send. After qcvm.sql.

SET TERM ^ ;

-- ── builtins (pr_cmds.c) ────────────────────────────────────────────────
-- Parameters sit at OFS_PARM0 = 4, PARM1 = 7, … (three slots each); the result goes to OFS_RETURN = 1.

CREATE OR ALTER PROCEDURE qc_call (fnum INTEGER) AS BEGIN END^
CREATE OR ALTER PROCEDURE qc_touch_triggers (e INTEGER) AS BEGIN END^

-- the group of builtin n (1 math, 2 move, 3 trace, 4 ent, 5 io; 0 none): qc_builtin dispatches on it, and the
-- JIT (src/qcjit.js) reads it once to call a builtin's group procedure directly
CREATE OR ALTER FUNCTION qc_bi_group (n INTEGER) RETURNS SMALLINT
AS
BEGIN
  RETURN CASE WHEN n IN (1, 6, 7, 9, 12, 13, 26, 27, 28, 29, 30, 36, 37, 38, 43, 51) THEN 1
              WHEN n IN (32, 49, 67) THEN 2
              WHEN n IN (16, 17, 40, 41, 44) THEN 3
              WHEN n IN (2, 3, 4, 14, 15, 18, 22, 34, 35, 47, 69) THEN 4
              WHEN n IN (8, 10, 11, 19, 20, 21, 23, 24, 25, 31, 45, 46, 48, 52, 53, 54, 55, 56, 57, 58, 59, 68, 70, 72, 73, 74, 75, 76, 77, 78) THEN 5 ELSE 0 END;
END^

-- vector and number arithmetic, the strings of numbers: 1, 6, 7, 9, 12, 13, 26, 27, 28, 29, 30, 36, 37, 38, 43, 51
CREATE OR ALTER PROCEDURE qc_bi_math (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE sp DOUBLE PRECISION; DECLARE cp DOUBLE PRECISION; DECLARE sy DOUBLE PRECISION;
DECLARE cy DOUBLE PRECISION; DECLARE sr DOUBLE PRECISION; DECLARE cr DOUBLE PRECISION; DECLARE vm_fwd INTEGER;
DECLARE vm_up INTEGER; DECLARE vm_right INTEGER;
BEGIN
  IF (n = 1) THEN                                   -- makevectors(angles)
  BEGIN
    SELECT v.g_vfwd, v.g_vup, v.g_vright FROM qc_vm v WHERE v.id = 1 INTO vm_fwd, vm_up, vm_right;
    a = qc_g(4) * 0.0174532925e0; b = qc_g(5) * 0.0174532925e0; c = qc_g(6) * 0.0174532925e0;   -- pitch, yaw, roll
    sp = SIN(a); cp = COS(a); sy = SIN(b); cy = COS(b); sr = SIN(c); cr = COS(c);
    EXECUTE PROCEDURE qc_sg(vm_fwd, cp * cy); EXECUTE PROCEDURE qc_sg(vm_fwd + 1, cp * sy); EXECUTE PROCEDURE qc_sg(vm_fwd + 2, -sp);
    EXECUTE PROCEDURE qc_sg(vm_right, -sr * sp * cy + cr * sy); EXECUTE PROCEDURE qc_sg(vm_right + 1, -sr * sp * sy - cr * cy); EXECUTE PROCEDURE qc_sg(vm_right + 2, -sr * cp);
    EXECUTE PROCEDURE qc_sg(vm_up, cr * sp * cy + sr * sy); EXECUTE PROCEDURE qc_sg(vm_up + 1, cr * sp * sy - sr * cy); EXECUTE PROCEDURE qc_sg(vm_up + 2, cr * cp);
  END
  ELSE IF (n = 6) THEN BEGIN END                    -- break
  ELSE IF (n = 7) THEN EXECUTE PROCEDURE qc_sg(1, rnd());                                            -- random()
  ELSE IF (n = 9) THEN                              -- normalize(v)
  BEGIN
    a = SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5) + qc_g(6) * qc_g(6));
    IF (a = 0) THEN BEGIN EXECUTE PROCEDURE qc_sg(1, 0); EXECUTE PROCEDURE qc_sg(2, 0); EXECUTE PROCEDURE qc_sg(3, 0); END
    ELSE BEGIN EXECUTE PROCEDURE qc_sg(1, qc_g(4) / a); EXECUTE PROCEDURE qc_sg(2, qc_g(5) / a); EXECUTE PROCEDURE qc_sg(3, qc_g(6) / a); END
  END
  ELSE IF (n = 12) THEN EXECUTE PROCEDURE qc_sg(1, SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5) + qc_g(6) * qc_g(6)));   -- vlen
  ELSE IF (n = 13) THEN                             -- vectoyaw(v)
  BEGIN
    IF (qc_g(4) = 0 AND qc_g(5) = 0) THEN a = 0;
    ELSE BEGIN a = ATAN2(qc_g(5), qc_g(4)) * 57.2957795e0; IF (a < 0) THEN a = a + 360; END
    EXECUTE PROCEDURE qc_sg(1, a);
  END
  ELSE IF (n = 26) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_ftos(qc_g(4))));                     -- ftos
  ELSE IF (n = 27) THEN EXECUTE PROCEDURE qc_sg(1, qc_newstr(qc_vtos(qc_g(4), qc_g(5), qc_g(6))));    -- vtos
  ELSE IF (n IN (28, 29, 30)) THEN BEGIN END         -- coredump, traceon, traceoff
  ELSE IF (n = 36) THEN EXECUTE PROCEDURE qc_sg(1, IIF(qc_g(4) > 0, FLOOR(qc_g(4) + 0.5e0), CEIL(qc_g(4) - 0.5e0)));   -- rint
  ELSE IF (n = 37) THEN EXECUTE PROCEDURE qc_sg(1, FLOOR(qc_g(4)));
  ELSE IF (n = 38) THEN EXECUTE PROCEDURE qc_sg(1, CEIL(qc_g(4)));
  ELSE IF (n = 43) THEN EXECUTE PROCEDURE qc_sg(1, ABS(qc_g(4)));
  ELSE IF (n = 51) THEN                             -- vectoangles(v)
  BEGIN
    IF (qc_g(5) = 0 AND qc_g(4) = 0) THEN BEGIN b = 0; a = IIF(qc_g(6) > 0, 90, 270); END
    ELSE
    BEGIN
      b = ATAN2(qc_g(5), qc_g(4)) * 57.2957795e0; IF (b < 0) THEN b = b + 360;
      a = ATAN2(qc_g(6), SQRT(qc_g(4) * qc_g(4) + qc_g(5) * qc_g(5))) * 57.2957795e0; IF (a < 0) THEN a = a + 360;
    END
    EXECUTE PROCEDURE qc_sg(1, a); EXECUTE PROCEDURE qc_sg(2, b); EXECUTE PROCEDURE qc_sg(3, 0);
  END
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- monster movement: 32, 49, 67
CREATE OR ALTER PROCEDURE qc_bi_move (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE e INTEGER; DECLARE i INTEGER;
DECLARE vm_fo INTEGER; DECLARE hit INTEGER; DECLARE head INTEGER; DECLARE cur DOUBLE PRECISION;
DECLARE ideal DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION; DECLARE mv DOUBLE PRECISION;
DECLARE gself INTEGER; DECLARE oself DOUBLE PRECISION; DECLARE ok SMALLINT;
BEGIN
  SELECT v.g_self, v.f_origin
    FROM qc_vm v WHERE v.id = 1 INTO gself, vm_fo;
  IF (n = 32 AND qc_on() = 1) THEN            -- walkmove(yaw, dist): SV_movestep, touching triggers
  BEGIN
    oself = qc_g(gself); e = CAST(oself AS INTEGER); a = qc_g(4) * 0.0174532925e0; b = qc_g(7);
    ok = 0;
    IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e AND BIN_AND(d.flags, 515) <> 0)) THEN
    BEGIN
      ok = move_step(e, COS(a) * b, SIN(a) * b, 0);
      IF (ok = 1) THEN EXECUTE PROCEDURE qc_touch_triggers(e);
      EXECUTE PROCEDURE qc_sg(gself, oself);
    END
    EXECUTE PROCEDURE qc_sg(1, ok);
  END
  ELSE IF (n = 32) THEN                             -- walkmove(yaw, dist): the step, unchecked
  BEGIN
    e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER); a = qc_g(4) * 0.0174532925e0; b = qc_g(7);
    EXECUTE PROCEDURE qc_sf(e, vm_fo, qc_f(e, vm_fo) + COS(a) * b); EXECUTE PROCEDURE qc_sf(e, vm_fo + 1, qc_f(e, vm_fo + 1) + SIN(a) * b);
    EXECUTE PROCEDURE qc_sg(1, 1);
  END
  ELSE IF (n = 49) THEN                             -- changeyaw(): self.angles_y towards ideal_yaw by yaw_speed
  BEGIN
    e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER);
    SELECT v.f_angles, v.f_ideal_yaw, v.f_yaw_speed FROM qc_vm v WHERE v.id = 1 INTO i, hit, head;
    cur = MOD(CAST(qc_f(e, i + 1) * 65536 / 360 AS BIGINT), 65536) * 360.0e0 / 65536; ideal = qc_f(e, hit); spd = qc_f(e, head);
    IF (cur <> ideal) THEN
    BEGIN
      mv = ideal - cur;
      IF (ideal > cur) THEN BEGIN IF (mv >= 180) THEN mv = mv - 360; END
      ELSE BEGIN IF (mv <= -180) THEN mv = mv + 360; END
      IF (mv > 0) THEN BEGIN IF (mv > spd) THEN mv = spd; END
      ELSE BEGIN IF (mv < -spd) THEN mv = -spd; END
      EXECUTE PROCEDURE qc_sf(e, i + 1, MOD(CAST((cur + mv) * 65536 / 360 AS BIGINT), 65536) * 360.0e0 / 65536);
    END
  END
  ELSE IF (n = 67) THEN                             -- movetogoal(dist): SV_MoveToGoal (step towards the goal, or a new chase direction)
  BEGIN
    IF (qc_on() = 1) THEN
    BEGIN
      oself = qc_g(gself); e = CAST(oself AS INTEGER);
      IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e AND BIN_AND(d.flags, 515) <> 0)) THEN
      BEGIN
        EXECUTE PROCEDURE move_to_goal(e, qc_g(4));
        IF (EXISTS (SELECT 1 FROM ents d WHERE d.id = :e)) THEN EXECUTE PROCEDURE qc_touch_triggers(e);
        EXECUTE PROCEDURE qc_sg(gself, oself);
      END
    END
  END
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- traces and the world: 16, 17, 40, 41, 44
CREATE OR ALTER PROCEDURE qc_bi_trace (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE e INTEGER;
DECLARE i INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII; DECLARE sp DOUBLE PRECISION;
DECLARE vm_fwd INTEGER; DECLARE frac DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION;
DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION; DECLARE nx DOUBLE PRECISION;
DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE hit INTEGER; DECLARE alls SMALLINT;
DECLARE starts SMALLINT; DECLARE inw SMALLINT; DECLARE head INTEGER; DECLARE wm INTEGER; DECLARE mid INTEGER;
DECLARE cur DOUBLE PRECISION; DECLARE ideal DOUBLE PRECISION; DECLARE mv DOUBLE PRECISION;
DECLARE gself INTEGER; DECLARE ok SMALLINT; DECLARE pv d_pvs; DECLARE bx DOUBLE PRECISION;
DECLARE by_ DOUBLE PRECISION; DECLARE bz DOUBLE PRECISION; DECLARE best DOUBLE PRECISION;
DECLARE bent INTEGER; DECLARE th INTEGER; DECLARE cc INTEGER; DECLARE mcl INTEGER; DECLARE kk INTEGER;
BEGIN
  SELECT v.g_self, v.g_vfwd
    FROM qc_vm v WHERE v.id = 1 INTO gself, vm_fwd;
  IF (n = 16) THEN                             -- traceline(v1, v2, nomonsters, forent): the world, and in QuakeC mode the entities too
  BEGIN
    frac = 1; ex = qc_g(7); ey = qc_g(8); ez = qc_g(9); nx = 0; ny = 0; nz = 0; hit = 0; alls = 0; starts = 0; inw = 0;
    wm = (SELECT g.world_model FROM game g WHERE g.id = 1);
    IF (qc_on() = 1) THEN
      SELECT t.fraction, t.ex, t.ey, t.ez, t.nx, t.ny, t.nz, t.allsolid, t.startsolid, t.inwater, t.hit_ent
        FROM trace_move(CAST(qc_g(13) AS INTEGER), 0, 0, 0, 0, 0, 0, qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9), CAST(qc_g(10) AS SMALLINT)) t
        INTO frac, ex, ey, ez, nx, ny, nz, alls, starts, inw, hit;
    ELSE IF (wm IS NOT NULL) THEN
    BEGIN
      SELECT m.hull0 FROM models m WHERE m.id = :wm INTO head;
      SELECT t.fraction, t.ex, t.ey, t.ez, t.nx, t.ny, t.nz, t.allsolid, t.startsolid, t.inwater
        FROM trace_hull(0, :head, 0, 0, 0, qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9)) t
        INTO frac, ex, ey, ez, nx, ny, nz, alls, starts, inw;
    END
    SELECT v.g_trace_allsolid, v.g_trace_startsolid, v.g_trace_fraction, v.g_trace_endpos, v.g_trace_plane_normal, v.g_trace_plane_dist, v.g_trace_ent, v.g_trace_inopen, v.g_trace_inwater
      FROM qc_vm v WHERE v.id = 1 INTO a, b, c, x, y, z, e, i, sp;
    EXECUTE PROCEDURE qc_sg(CAST(a AS INTEGER), alls); EXECUTE PROCEDURE qc_sg(CAST(b AS INTEGER), starts); EXECUTE PROCEDURE qc_sg(CAST(c AS INTEGER), frac);
    EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER), ex); EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER) + 1, ey); EXECUTE PROCEDURE qc_sg(CAST(x AS INTEGER) + 2, ez);
    EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER), nx); EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER) + 1, ny); EXECUTE PROCEDURE qc_sg(CAST(y AS INTEGER) + 2, nz);
    EXECUTE PROCEDURE qc_sg(CAST(z AS INTEGER), nx * ex + ny * ey + nz * ez);
    EXECUTE PROCEDURE qc_sg(e, hit); EXECUTE PROCEDURE qc_sg(i, IIF(frac < 1, 1, 0)); EXECUTE PROCEDURE qc_sg(CAST(sp AS INTEGER), inw);
  END
  ELSE IF (n = 17) THEN                             -- checkclient(): the client, if the caller's eye is in the PVS of the client's eye
  BEGIN
    c = 0;
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(gself) AS INTEGER);
      SELECT v.f_health, v.f_view_ofs, v.check_time, v.check_pvs, v.sv_time, v.check_client FROM qc_vm v WHERE v.id = 1
        INTO head, mid, a, pv, b, cc;
      -- PF_newcheckclient: every 0.1 s the next client in turn that is in the game and alive, and its eye's PVS
      IF (a IS NULL OR b - a >= 0.1e0 OR b < a) THEN
      BEGIN
        mcl = qc_maxclients(); kk = 0; i = COALESCE(cc, mcl); cc = NULL; pv = NULL;
        WHILE (kk < mcl) DO
        BEGIN
          i = MOD(i, mcl) + 1; kk = kk + 1;
          IF (EXISTS (SELECT 1 FROM ents d JOIN qc_edicts q ON q.id = d.id AND q.free = 0 WHERE d.id = :i AND BIN_AND(d.flags, 128) = 0) AND qc_fq(i, head) > 0) THEN
          BEGIN cc = i; LEAVE; END
        END
        IF (cc IS NOT NULL) THEN
          SELECT l.pvs FROM ents d JOIN leaves l ON l.id = point_leaf(d.x + qc_fq(:cc, :mid), d.y + qc_fq(:cc, :mid + 1), d.z + qc_fq(:cc, :mid + 2))
           WHERE d.id = :cc INTO pv;
        UPDATE qc_vm v SET v.check_time = :b, v.check_pvs = :pv, v.check_client = :cc WHERE v.id = 1;
      END
      IF (cc IS NOT NULL AND pv IS NOT NULL AND qc_fq(cc, head) > 0) THEN
      BEGIN
        -- the caller's eye, and its leaf: kept while it stands there (a waiting monster asks every think)
        SELECT d.x + COALESCE(MAX(IIF(f.ofs = :mid, f.v, NULL)), 0), d.y + COALESCE(MAX(IIF(f.ofs = :mid + 1, f.v, NULL)), 0), d.z + COALESCE(MAX(IIF(f.ofs = :mid + 2, f.v, NULL)), 0)
          FROM ents d LEFT JOIN qc_fields f ON f.ent = d.id AND f.ofs BETWEEN :mid AND :mid + 2 WHERE d.id = :e GROUP BY d.x, d.y, d.z INTO bx, by_, bz;
        IF (bx IS NOT NULL) THEN
        BEGIN
          wm = NULL;
          SELECT k.leaf FROM qc_eyeleaf k WHERE k.ent = :e AND k.x = :bx AND k.y = :by_ AND k.z = :bz INTO wm;
          IF (wm IS NULL) THEN
          BEGIN
            wm = point_leaf(bx, by_, bz);
            UPDATE OR INSERT INTO qc_eyeleaf (ent, x, y, z, leaf) VALUES (:e, :bx, :by_, :bz, :wm) MATCHING (ent);
          END
          IF (pvs_visible(pv, wm) = 1) THEN c = cc;
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n = 40) THEN                             -- checkbottom(e): SV_CheckBottom, every corner on something
  BEGIN
    ok = 1;
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(4) AS INTEGER);
      SELECT d.x + d.minx, d.y + d.miny, d.z + d.minz, d.x + d.maxx, d.y + d.maxy FROM ents d WHERE d.id = :e INTO x, y, z, a, b;
      IF (point_contents(x, y, z - 1) <> -2 OR point_contents(x, b, z - 1) <> -2 OR point_contents(a, y, z - 1) <> -2 OR point_contents(a, b, z - 1) <> -2) THEN
      BEGIN
        -- the real check: the middle's floor within a step below, and no corner more than a step below it
        SELECT t.fraction, t.ez FROM trace_move(:e, 0, 0, 0, 0, 0, 0, (:x + :a) / 2, (:y + :b) / 2, :z, (:x + :a) / 2, (:y + :b) / 2, :z - 36, 1) t INTO frac, cur;
        IF (frac = 1) THEN ok = 0;
        ELSE
        BEGIN
          best = cur;
          FOR SELECT IIF(r.k < 2, :x, :a), IIF(MOD(r.k, 2) = 0, :y, :b) FROM (SELECT 0 k FROM rdb$database UNION ALL SELECT 1 FROM rdb$database UNION ALL SELECT 2 FROM rdb$database UNION ALL SELECT 3 FROM rdb$database) r INTO bx, by_ DO
          BEGIN
            SELECT t.fraction, t.ez FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :bx, :by_, :z, :bx, :by_, :z - 36, 1) t INTO frac, ideal;
            IF (frac < 1 AND ideal > best) THEN best = ideal;
            IF (frac = 1 OR cur - ideal > 18) THEN ok = 0;
          END
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, ok);
  END
  ELSE IF (n = 41) THEN                             -- pointcontents(v)
    EXECUTE PROCEDURE qc_sg(1, IIF(EXISTS (SELECT 1 FROM game g WHERE g.id = 1 AND g.world_model IS NOT NULL), point_contents(qc_g(4), qc_g(5), qc_g(6)), -1));
  ELSE IF (n = 44) THEN                             -- aim(e, speed): PF_aim, straight ahead unless a target is within the autoaim cone
  BEGIN
    a = qc_g(vm_fwd); b = qc_g(vm_fwd + 1); c = qc_g(vm_fwd + 2);
    IF (qc_on() = 1) THEN
    BEGIN
      e = CAST(qc_g(4) AS INTEGER);
      SELECT d.x, d.y, d.z + 20 FROM ents d WHERE d.id = :e INTO x, y, z;
      i = qc_fdef('takedamage');
      SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :x + :a * 2048, :y + :b * 2048, :z + :c * 2048, 0) t INTO hit;
      IF (hit IS NULL OR hit = 0 OR qc_f(hit, i) <> 2) THEN
      BEGIN
        best = 0.93e0; bent = 0;
        FOR SELECT d.id, d.x + (d.minx + d.maxx) * 0.5e0, d.y + (d.miny + d.maxy) * 0.5e0, d.z + (d.minz + d.maxz) * 0.5e0 FROM ents d
             WHERE d.id <> :e AND d.solid <> 0 AND qc_f(d.id, :i) = 2 INTO hit, bx, by_, bz DO
        BEGIN
          mv = SQRT((bx - x) * (bx - x) + (by_ - y) * (by_ - y) + (bz - z) * (bz - z));
          IF (mv = 0) THEN CONTINUE;
          cur = ((bx - x) * a + (by_ - y) * b + (bz - z) * c) / mv;
          IF (cur < best) THEN CONTINUE;
          SELECT t.hit_ent FROM trace_move(:e, 0, 0, 0, 0, 0, 0, :x, :y, :z, :bx, :by_, :bz, 0) t INTO th;
          IF (th = hit) THEN BEGIN best = cur; bent = hit; END
        END
        IF (bent > 0) THEN
        BEGIN
          SELECT d.x - :x, d.y - :y, d.z - (:z - 20) FROM ents d WHERE d.id = :bent INTO bx, by_, bz;
          mv = bx * a + by_ * b + bz * c;
          bx = a * mv; by_ = b * mv;
          mv = SQRT(bx * bx + by_ * by_ + bz * bz);
          IF (mv > 0) THEN BEGIN a = bx / mv; b = by_ / mv; c = bz / mv; END
        END
      END
    END
    EXECUTE PROCEDURE qc_sg(1, a); EXECUTE PROCEDURE qc_sg(2, b); EXECUTE PROCEDURE qc_sg(3, c);
  END
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- edicts: placing, sizing, finding, spawning: 2, 3, 4, 14, 15, 18, 22, 34, 35, 47, 69
CREATE OR ALTER PROCEDURE qc_bi_ent (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE e INTEGER;
DECLARE i INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII; DECLARE vm_fo INTEGER; DECLARE vm_mi INTEGER;
DECLARE vm_ma INTEGER; DECLARE vm_sz INTEGER; DECLARE vm_amin INTEGER; DECLARE vm_amax INTEGER;
DECLARE vm_chain INTEGER; DECLARE frac DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION;
DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION; DECLARE nx DOUBLE PRECISION;
DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE hit INTEGER; DECLARE alls SMALLINT;
DECLARE mid INTEGER;
BEGIN
  SELECT v.f_origin, v.f_mins, v.f_maxs, v.f_size, v.f_absmin, v.f_absmax, v.f_chain
    FROM qc_vm v WHERE v.id = 1 INTO vm_fo, vm_mi, vm_ma, vm_sz, vm_amin, vm_amax, vm_chain;
  IF (n = 2) THEN                              -- setorigin(e, org)
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, vm_fo, qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_fo + 1, qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_fo + 2, qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amin, qc_g(7) + qc_f(e, vm_mi)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 1, qc_g(8) + qc_f(e, vm_mi + 1)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 2, qc_g(9) + qc_f(e, vm_mi + 2));
    EXECUTE PROCEDURE qc_sf(e, vm_amax, qc_g(7) + qc_f(e, vm_ma)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 1, qc_g(8) + qc_f(e, vm_ma + 1)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 2, qc_g(9) + qc_f(e, vm_ma + 2));
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
  END
  ELSE IF (n = 3) THEN                              -- setmodel(e, model): the model's bounds when it is loaded
  BEGIN
    e = CAST(qc_g(4) AS INTEGER); s = qc_str(CAST(qc_g(7) AS INTEGER));
    EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_model FROM qc_vm v WHERE v.id = 1), qc_g(7));
    mid = (SELECT FIRST 1 m.id FROM models m WHERE m.name = :s);
    EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_modelindex FROM qc_vm v WHERE v.id = 1), COALESCE(mid, IIF(s = '', 0, 1)));
    x = NULL;
    IF (mid IS NOT NULL) THEN SELECT m.minx, m.miny, m.minz, m.maxx, m.maxy, m.maxz FROM models m WHERE m.id = :mid INTO x, y, z, ex, ey, ez;
    IF (x IS NOT NULL) THEN                        -- brush models carry their bounds; alias models get theirs from setsize
    BEGIN
      EXECUTE PROCEDURE qc_sf(e, vm_mi, x); EXECUTE PROCEDURE qc_sf(e, vm_mi + 1, y); EXECUTE PROCEDURE qc_sf(e, vm_mi + 2, z);
      EXECUTE PROCEDURE qc_sf(e, vm_ma, ex); EXECUTE PROCEDURE qc_sf(e, vm_ma + 1, ey); EXECUTE PROCEDURE qc_sf(e, vm_ma + 2, ez);
      EXECUTE PROCEDURE qc_sf(e, vm_sz, ex - x); EXECUTE PROCEDURE qc_sf(e, vm_sz + 1, ey - y); EXECUTE PROCEDURE qc_sf(e, vm_sz + 2, ez - z);
    END
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
  END
  ELSE IF (n = 4) THEN                              -- setsize(e, mins, maxs)
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, vm_mi, qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 1, qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_mi + 2, qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_ma, qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 1, qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_ma + 2, qc_g(12));
    EXECUTE PROCEDURE qc_sf(e, vm_sz, qc_g(10) - qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 1, qc_g(11) - qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_sz + 2, qc_g(12) - qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amin, qc_f(e, vm_fo) + qc_g(7)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 1, qc_f(e, vm_fo + 1) + qc_g(8)); EXECUTE PROCEDURE qc_sf(e, vm_amin + 2, qc_f(e, vm_fo + 2) + qc_g(9));
    EXECUTE PROCEDURE qc_sf(e, vm_amax, qc_f(e, vm_fo) + qc_g(10)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 1, qc_f(e, vm_fo + 1) + qc_g(11)); EXECUTE PROCEDURE qc_sf(e, vm_amax + 2, qc_f(e, vm_fo + 2) + qc_g(12));
    IF (e > 0 AND qc_on() = 1) THEN EXECUTE PROCEDURE link_ent(e);
  END
  ELSE IF (n = 14) THEN EXECUTE PROCEDURE qc_sg(1, qc_spawn());                                        -- spawn()
  ELSE IF (n = 15) THEN EXECUTE PROCEDURE qc_free(CAST(qc_g(4) AS INTEGER));                           -- remove(e)
  ELSE IF (n = 18) THEN                             -- find(start, field, match)
  BEGIN
    s = qc_str(CAST(qc_g(10) AS INTEGER)); i = CAST(qc_g(7) AS INTEGER); c = 0;
    FOR SELECT d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id INTO e DO
      IF (qc_str(CAST(qc_f(e, i) AS INTEGER)) = s) THEN BEGIN c = e; LEAVE; END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n = 22) THEN                             -- findradius(org, rad): a chain through .chain
  BEGIN
    -- PF_findradius: every edict after the world that is not SOLID_NOT (the world, last in the walk, would
    -- otherwise end the chain as soon as a radius reached the map's centre: FrikBot's 13000 does)
    a = qc_g(7); c = 0; hit = 0; i = qc_fdef('solid');
    FOR SELECT d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > 0 ORDER BY d.id DESC INTO e DO
    IF (qc_f(e, i) <> 0) THEN
    BEGIN
      x = qc_f(e, vm_fo) + (qc_f(e, vm_mi) + qc_f(e, vm_ma)) * 0.5e0 - qc_g(4);
      y = qc_f(e, vm_fo + 1) + (qc_f(e, vm_mi + 1) + qc_f(e, vm_ma + 1)) * 0.5e0 - qc_g(5);
      z = qc_f(e, vm_fo + 2) + (qc_f(e, vm_mi + 2) + qc_f(e, vm_ma + 2)) * 0.5e0 - qc_g(6);
      IF (SQRT(x * x + y * y + z * z) <= a) THEN BEGIN EXECUTE PROCEDURE qc_sf(e, vm_chain, c); c = e; END
    END
    EXECUTE PROCEDURE qc_sg(1, c);
  END
  ELSE IF (n = 34) THEN                             -- droptofloor(): down to 256 units onto what is below
  BEGIN
    IF (qc_on() = 0) THEN EXECUTE PROCEDURE qc_sg(1, 1);
    ELSE
    BEGIN
      e = CAST(qc_g((SELECT v.g_self FROM qc_vm v WHERE v.id = 1)) AS INTEGER);
      SELECT d.x, d.y, d.z, d.minx, d.miny, d.minz, d.maxx, d.maxy, d.maxz FROM ents d WHERE d.id = :e INTO x, y, z, a, b, c, nx, ny, nz;
      SELECT t.fraction, t.ex, t.ey, t.ez, t.allsolid, t.hit_ent FROM trace_move(:e, :a, :b, :c, :nx, :ny, :nz, :x, :y, :z, :x, :y, :z - 256, 0) t
        INTO frac, ex, ey, ez, alls, hit;
      IF (frac = 1 OR alls = 1) THEN EXECUTE PROCEDURE qc_sg(1, 0);
      ELSE
      BEGIN
        UPDATE ents d SET d.x = :ex, d.y = :ey, d.z = :ez, d.flags = BIN_OR(d.flags, 512) WHERE d.id = :e;
        EXECUTE PROCEDURE link_ent(e);
        EXECUTE PROCEDURE qc_sf(e, (SELECT v.f_groundentity FROM qc_vm v WHERE v.id = 1), hit);
        EXECUTE PROCEDURE qc_sg(1, 1);
      END
    END
  END
  ELSE IF (n = 35) THEN                             -- lightstyle(style, value)
    UPDATE OR INSERT INTO lightstyles (style, pattern) VALUES (CAST(qc_g(4) AS INTEGER), qc_str(CAST(qc_g(7) AS INTEGER))) MATCHING (style);
  ELSE IF (n = 47) THEN                             -- nextent(e)
    EXECUTE PROCEDURE qc_sg(1, COALESCE((SELECT FIRST 1 d.id FROM qc_edicts d WHERE d.free = 0 AND d.id > CAST(qc_g(4) AS INTEGER) ORDER BY d.id), 0));
  ELSE IF (n = 69) THEN                             -- makestatic(e): drawn from now on as a static entity, the edict freed
  BEGIN
    e = CAST(qc_g(4) AS INTEGER);
    -- SV_MakeStatic_f's baseline: the model, frame, skin, origin and angles, in an ents row of their own above the
    -- edicts (not solid, never thinks), which the renderer draws like any other
    IF (qc_on() = 1) THEN
      INSERT INTO ents (id, classname, model_id, frame, skin, effects, x, y, z, pitch, yaw, roll, solid, movetype, leaf, leafs)
      SELECT 500000 + GEN_ID(ent_seq, 1), 'static', d.model_id, d.frame, d.skin, d.effects, d.x, d.y, d.z, d.pitch, d.yaw, d.roll, 0, 0, d.leaf, d.leafs
        FROM ents d WHERE d.id = :e AND d.model_id IS NOT NULL;
    EXECUTE PROCEDURE qc_free(e);
  END
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- sounds, prints, messages, cvars, the level change, precaches: 8, 10, 11, 19, 20, 21, 23, 24, 25, 31, 45, 46, 48, 52, 53, 54, 55, 56, 57, 58, 59, 68, 70, 72, 73, 74, 75, 76, 77, 78
CREATE OR ALTER PROCEDURE qc_bi_io (n INTEGER, fnum INTEGER)
AS
DECLARE a DOUBLE PRECISION; DECLARE b DOUBLE PRECISION; DECLARE c DOUBLE PRECISION;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE e INTEGER;
DECLARE i INTEGER; DECLARE s VARCHAR(2048) CHARACTER SET ASCII; DECLARE s2 VARCHAR(2048) CHARACTER SET ASCII;
DECLARE hit INTEGER; DECLARE tst SMALLINT; DECLARE tty SMALLINT; DECLARE tn SMALLINT;
BEGIN
  IF (n = 8) THEN                              -- sound(e, channel, sample, volume, attenuation): logged, and played in QuakeC mode
  BEGIN
    EXECUTE PROCEDURE qc_print('sound', TRIM(qc_ftos(qc_g(4))) || ' ' || TRIM(qc_ftos(qc_g(7))) || ' ' || qc_str(CAST(qc_g(10) AS INTEGER)) || ' ' || TRIM(qc_ftos(qc_g(13))) || ' ' || TRIM(qc_ftos(qc_g(16))));
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE snd(CAST(qc_g(4) AS INTEGER), CAST(qc_g(7) AS SMALLINT), SUBSTRING(qc_str(CAST(qc_g(10) AS INTEGER)) FROM 1 FOR 64), qc_g(13), qc_g(16));
  END
  ELSE IF (n = 10 OR n = 11) THEN                   -- error(s), objerror(s)
  BEGIN
    EXECUTE PROCEDURE qc_print('error', qc_str(CAST(qc_g(4) AS INTEGER)));
    EXCEPTION qc_error qc_str(CAST(qc_g(4) AS INTEGER));
  END
  ELSE IF (n IN (19, 20, 68, 75, 76, 77)) THEN EXECUTE PROCEDURE qc_sg(1, qc_g(4));                  -- precache_*: nothing to do
  ELSE IF (n = 21 OR n = 46) THEN                   -- stuffcmd(client, s), localcmd(s): "bf" is the pickup flash
  BEGIN
    s = qc_str(CAST(qc_g(IIF(n = 21, 7, 4)) AS INTEGER));
    EXECUTE PROCEDURE qc_print('cmd', s);
    IF (qc_on() = 1 AND s STARTING WITH 'bf' AND (n = 46 OR CAST(qc_g(4) AS INTEGER) = 1)) THEN UPDATE player p SET p.bonus_time = (SELECT g.time_ FROM game g WHERE g.id = 1) WHERE p.id = 1;
    -- localcmd: the console buffer, a line at a time (QuakeC's newline is the two characters backslash-n);
    -- "skill N" is what trigger_setskill sends, read by cvar("skill") from the next frame on
    IF (n = 46) THEN
    BEGIN
      UPDATE qc_vm v SET v.cmdbuf = SUBSTRING(v.cmdbuf || :s FROM 1 FOR 256) WHERE v.id = 1 RETURNING v.cmdbuf INTO s2;
      i = POSITION('\n', s2);
      IF (i > 0) THEN
      BEGIN
        s = TRIM(SUBSTRING(s2 FROM 1 FOR i - 1));
        UPDATE qc_vm v SET v.cmdbuf = SUBSTRING(:s2 FROM :i + 2) WHERE v.id = 1;
        IF (s SIMILAR TO 'skill [0-3]') THEN UPDATE game g SET g.skill = CAST(SUBSTRING(:s FROM 7) AS SMALLINT) WHERE g.id = 1;
        -- "restart", which respawn sends in single player (dead, or the console's kill): the level again,
        -- as the PSQL game's death restarts it (exit_kind 3, which the page answers with the map anew)
        ELSE IF (s = 'restart') THEN UPDATE game g SET g.exit_kind = 3 WHERE g.id = 1;
      END
    END
  END
  ELSE IF (n = 23) THEN                             -- bprint(s): everyone's message line
  BEGIN
    EXECUTE PROCEDURE qc_print('bprint', qc_str(CAST(qc_g(4) AS INTEGER)));
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE qc_msg(qc_str(CAST(qc_g(4) AS INTEGER)));
  END
  ELSE IF (n = 24) THEN                             -- sprint(client, s)
  BEGIN
    EXECUTE PROCEDURE qc_print('sprint', qc_str(CAST(qc_g(7) AS INTEGER)));
    IF (qc_on() = 1 AND CAST(qc_g(4) AS INTEGER) = 1) THEN EXECUTE PROCEDURE qc_msg(qc_str(CAST(qc_g(7) AS INTEGER)));
  END
  ELSE IF (n = 25) THEN EXECUTE PROCEDURE qc_print('dprint', qc_str(CAST(qc_g(4) AS INTEGER)));
  ELSE IF (n = 31) THEN EXECUTE PROCEDURE qc_print('eprint', 'edict ' || qc_ftos(qc_g(4)));
  ELSE IF (n = 45) THEN                             -- cvar(name)
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER));
    EXECUTE PROCEDURE qc_sg(1, CASE s WHEN 'skill' THEN COALESCE((SELECT g.skill FROM game g WHERE g.id = 1), 1) WHEN 'sv_gravity' THEN COALESCE((SELECT g.gravity FROM game g WHERE g.id = 1), 800) WHEN 'sv_maxspeed' THEN 320 WHEN 'sv_friction' THEN 4 WHEN 'sv_accelerate' THEN 10 WHEN 'sv_stopspeed' THEN 100 WHEN 'sv_nostep' THEN 0 WHEN 'registered' THEN COALESCE((SELECT g.registered FROM game g WHERE g.id = 1), 0)
      WHEN 'deathmatch' THEN COALESCE((SELECT g.deathmatch FROM game g WHERE g.id = 1), 0) WHEN 'coop' THEN COALESCE((SELECT g.coop FROM game g WHERE g.id = 1), 0)
      WHEN 'fraglimit' THEN COALESCE((SELECT g.fraglimit FROM game g WHERE g.id = 1), 0) WHEN 'timelimit' THEN COALESCE((SELECT g.timelimit FROM game g WHERE g.id = 1), 0)
      ELSE 0 END);
  END
  ELSE IF (n = 48) THEN                             -- particle(org, dir, color, count): blood is colour 73
  BEGIN
    IF (qc_on() = 1) THEN EXECUTE PROCEDURE fx(IIF(qc_g(10) = 73, 3, 1), qc_g(4), qc_g(5), qc_g(6), qc_g(7), qc_g(8), qc_g(9), CAST(qc_g(13) AS INTEGER));
  END
  ELSE IF (n BETWEEN 52 AND 59) THEN               -- WriteByte … WriteEntity: temp entities (as fx_events), and the client messages the page shows
  BEGIN
    IF (qc_on() = 1) THEN
    BEGIN
      SELECT v.te_state, v.te_type, v.te_n FROM qc_vm v WHERE v.id = 1 INTO tst, tty, tn;
      IF (n = 52 AND tst = 0 AND qc_g(7) = 23) THEN UPDATE qc_vm v SET v.te_state = 1 WHERE v.id = 1;     -- SVC_TEMPENTITY
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 30) THEN                                                   -- SVC_INTERMISSION: the stats
        UPDATE game g SET g.intermission = 1, g.completed_time = (SELECT v.sv_time FROM qc_vm v WHERE v.id = 1) WHERE g.id = 1;
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 31) THEN                                                   -- SVC_FINALE: a string follows
      BEGIN
        UPDATE qc_vm v SET v.te_state = 10 WHERE v.id = 1;
        UPDATE game g SET g.intermission = 2, g.finale_text = '', g.completed_time = IIF(g.intermission = 0, (SELECT v.sv_time FROM qc_vm v WHERE v.id = 1), g.completed_time) WHERE g.id = 1;
      END
      ELSE IF (n = 58 AND tst = 10) THEN                                                                   -- the finale's text
      BEGIN
        UPDATE game g SET g.finale_text = SUBSTRING(REPLACE(qc_str(CAST(qc_g(7) AS INTEGER)), '\n', ASCII_CHAR(10)) FROM 1 FOR 1024) WHERE g.id = 1;
        UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
      END
      ELSE IF (n = 52 AND tst = 0 AND qc_g(7) = 32) THEN UPDATE qc_vm v SET v.te_state = 11 WHERE v.id = 1;   -- SVC_CDTRACK: the track, then the loop track
      ELSE IF (n = 52 AND tst = 11) THEN
      BEGIN
        UPDATE game g SET g.cdtrack = CAST(qc_g(7) AS SMALLINT) WHERE g.id = 1;
        UPDATE qc_vm v SET v.te_state = 12 WHERE v.id = 1;
      END
      ELSE IF (n = 52 AND tst = 12) THEN UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
      ELSE IF (n = 52 AND tst = 1) THEN UPDATE qc_vm v SET v.te_state = 2, v.te_type = CAST(qc_g(7) AS SMALLINT), v.te_n = 0, v.te_ent = 0 WHERE v.id = 1;
      ELSE IF (n = 59 AND tst = 2) THEN UPDATE qc_vm v SET v.te_ent = CAST(qc_g(7) AS INTEGER) WHERE v.id = 1;   -- the beam's owner (the page moves the player's own beam with the player)
      ELSE IF (n = 56 AND tst = 2) THEN
      BEGIN
        UPDATE qc_vm v SET v.te_c0 = IIF(:tn = 0, qc_g(7), v.te_c0), v.te_c1 = IIF(:tn = 1, qc_g(7), v.te_c1), v.te_c2 = IIF(:tn = 2, qc_g(7), v.te_c2),
                           v.te_c3 = IIF(:tn = 3, qc_g(7), v.te_c3), v.te_c4 = IIF(:tn = 4, qc_g(7), v.te_c4), v.te_c5 = IIF(:tn = 5, qc_g(7), v.te_c5),
                           v.te_n = v.te_n + 1 WHERE v.id = 1;
        IF (tn + 1 = IIF(tty IN (5, 6, 9), 6, 3)) THEN
        BEGIN
          -- TE_SPIKE, SUPERSPIKE, WIZSPIKE, KNIGHTSPIKE: a spike hit; GUNSHOT: a puff; EXPLOSION; TAREXPLOSION; the LIGHTNINGs: a beam; LAVASPLASH; TELEPORT
          SELECT v.te_c0, v.te_c1, v.te_c2, v.te_c3, v.te_c4, v.te_c5 FROM qc_vm v WHERE v.id = 1 INTO x, y, z, a, b, c;
          IF (tty IN (5, 6, 9)) THEN EXECUTE PROCEDURE fx(4, x, y, z, a, b, c, (SELECT v.te_ent FROM qc_vm v WHERE v.id = 1));
          ELSE EXECUTE PROCEDURE fx(CASE tty WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 8 WHEN 10 THEN 7 WHEN 11 THEN 5 ELSE 6 END, x, y, z, 0, 0, 0, 0);
          UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;
        END
      END
      ELSE IF (n = 52 AND tst = 2) THEN UPDATE qc_vm v SET v.te_state = 0 WHERE v.id = 1;    -- a byte where a coordinate was due: give up
    END
  END
  ELSE IF (n = 70) THEN                             -- changelevel(map): the first one counts (svs.changelevel_issued)
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER));
    EXECUTE PROCEDURE qc_print('changelevel', s);
    IF (qc_on() = 1) THEN UPDATE game g SET g.next_map = SUBSTRING(:s FROM 1 FOR 32), g.exit_kind = 1 WHERE g.id = 1 AND g.exit_kind = 0;
  END
  ELSE IF (n = 72) THEN                             -- cvar_set(name, value): sv_gravity is the one the progs set
  BEGIN
    s = qc_str(CAST(qc_g(4) AS INTEGER)); s2 = qc_str(CAST(qc_g(7) AS INTEGER));
    EXECUTE PROCEDURE qc_print('cvar_set', s || ' ' || s2);
    IF (s = 'sv_gravity') THEN UPDATE game g SET g.gravity = CAST(:s2 AS DOUBLE PRECISION) WHERE g.id = 1;
  END
  ELSE IF (n = 73) THEN                             -- centerprint(client, s)
  BEGIN
    EXECUTE PROCEDURE qc_print('centerprint', qc_str(CAST(qc_g(7) AS INTEGER)));
    IF (qc_on() = 1 AND CAST(qc_g(4) AS INTEGER) = 1) THEN EXECUTE PROCEDURE cprint(SUBSTRING(REPLACE(qc_str(CAST(qc_g(7) AS INTEGER)), '\n', ASCII_CHAR(10)) FROM 1 FOR 200));
  END
  ELSE IF (n = 74) THEN EXECUTE PROCEDURE qc_print('ambientsound', qc_str(CAST(qc_g(7) AS INTEGER)));
  ELSE IF (n = 78) THEN BEGIN END                    -- setspawnparms
  ELSE
  BEGIN
    EXECUTE PROCEDURE qc_print('error', 'builtin #' || n || ' is not implemented (' || COALESCE((SELECT f.name FROM qc_functions f WHERE f.id = :fnum), '?') || ')');
    EXCEPTION qc_error 'builtin #' || n || ' is not implemented';
  END
END^

-- qc_builtin(n, fnum): the interpreter's call of builtin n (the JIT calls the group's procedure itself)
CREATE OR ALTER PROCEDURE qc_builtin (n INTEGER, fnum INTEGER)
AS
DECLARE g SMALLINT;
BEGIN
  g = qc_bi_group(n);
  IF (g = 1) THEN EXECUTE PROCEDURE qc_bi_math(n, fnum);
  ELSE IF (g = 2) THEN EXECUTE PROCEDURE qc_bi_move(n, fnum);
  ELSE IF (g = 3) THEN EXECUTE PROCEDURE qc_bi_trace(n, fnum);
  ELSE IF (g = 4) THEN EXECUTE PROCEDURE qc_bi_ent(n, fnum);
  ELSE EXECUTE PROCEDURE qc_bi_io(n, fnum);
END^

SET TERM ; ^
