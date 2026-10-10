-- bots.sql – deathmatch and coop opponents for QuakeC mode: clients played by PSQL.
--
-- Quake's multiplayer rules are progs.dat's (frags, obituaries, respawning, the weapons staying,
-- the items coming back, fraglimit and timelimit, info_player_deathmatch and info_player_coop); the
-- engine side is that the server has more than one client (game.maxclients, edicts 1..maxclients,
-- sql/qcvm.sql). A bot is such a client whose move is not read from a connection but made here, each
-- server frame, by qc_bot_think: the same forward, side and up speeds, view angles, buttons and
-- impulse a player sends. It sees what it can trace a line to, runs at the nearest enemy (another
-- client in deathmatch, a monster in coop) circling and firing with an aim error set by the skill,
-- otherwise runs for items it can see, otherwise wanders, turning away from walls and drops. Its
-- random choices go through rnd(), so demos replay bots too.
--
--   EXECUTE PROCEDURE qc_setup_server(1, 0, 3, 10, 0);   -- deathmatch, 3 bots, fraglimit 10
--   ... loadMap, qc_begin_map: the bots join after the player ...
--   SELECT * FROM qc_scores;

SET TERM ^ ;

-- the rules for the next level (and on): deathmatch, coop, how many bots, fraglimit, timelimit (minutes).
-- Without deathmatch or coop there are no bots.
CREATE OR ALTER PROCEDURE qc_setup_server (deathmatch SMALLINT, coop SMALLINT, nbots SMALLINT, fraglimit INTEGER, timelimit INTEGER)
AS
DECLARE i INTEGER = 0; DECLARE sk SMALLINT;
BEGIN
  IF (deathmatch <> 0 OR coop <> 0) THEN nbots = MAXVALUE(0, MINVALUE(nbots, 7)); ELSE nbots = 0;
  UPDATE game g SET g.deathmatch = :deathmatch, g.coop = IIF(:deathmatch <> 0, 0, :coop), g.maxclients = 1 + :nbots,
                    g.fraglimit = :fraglimit, g.timelimit = :timelimit WHERE g.id = 1;
  sk = COALESCE((SELECT g.skill FROM game g WHERE g.id = 1), 1);
  DELETE FROM bots;
  WHILE (i < nbots) DO
  BEGIN
    INSERT INTO bots (c, name, aim_error)
    VALUES (:i + 2, TRIM(CASE MOD(:i, 7) WHEN 0 THEN 'Grunt' WHEN 1 THEN 'Enforcer' WHEN 2 THEN 'Ogre' WHEN 3 THEN 'Knight'
                                         WHEN 4 THEN 'Fiend' WHEN 5 THEN 'Vore' ELSE 'Shambler' END),
            CASE :sk WHEN 0 THEN 20 WHEN 1 THEN 12 WHEN 2 THEN 6 ELSE 3 END);
    i = i + 1;
  END
END^

-- the scoreboard: every client in the game, its name, frags and whether it is alive
CREATE OR ALTER PROCEDURE qc_scores
RETURNS (c INTEGER, name VARCHAR(64), frags INTEGER, alive SMALLINT)
AS
DECLARE fn INTEGER; DECLARE ff INTEGER; DECLARE fh INTEGER;
BEGIN
  fn = qc_fdef('netname'); ff = qc_fdef('frags'); fh = qc_fdef('health');
  -- (a client slot no one has connected into has no name; a mod's own bots name theirs)
  FOR SELECT d.id FROM qc_edicts d WHERE d.id >= 1 AND d.id <= qc_maxclients() AND d.free = 0 ORDER BY d.id INTO c DO
  BEGIN
    name = qc_str(CAST(qc_f(c, fn) AS INTEGER));
    IF (qc_client_active(c) = 0 AND COALESCE(name, '') = '') THEN CONTINUE;
    frags = CAST(qc_f(c, ff) AS INTEGER);
    alive = IIF(qc_f(c, fh) > 0, 1, 0);
    SUSPEND;
  END
END^

-- the angle from a to b, -180..180
CREATE OR ALTER FUNCTION bot_angdiff (a DOUBLE PRECISION, b DOUBLE PRECISION) RETURNS DOUBLE PRECISION
AS
DECLARE d DOUBLE PRECISION;
BEGIN
  d = b - a;
  RETURN d - 360 * FLOOR((d + 180) / 360);
END^

-- a clear line from a point to an entity's middle, through the world only
CREATE OR ALTER FUNCTION bot_sees (x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION, e INTEGER) RETURNS SMALLINT
AS
DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION; DECLARE f DOUBLE PRECISION;
BEGIN
  SELECT d.x, d.y, d.z + (d.minz + d.maxz) / 2 FROM ents d WHERE d.id = :e INTO tx, ty, tz;
  IF (tx IS NULL) THEN RETURN 0;
  SELECT r.fraction FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, :x, :y, :z, :tx, :ty, :tz, 1) r INTO f;
  RETURN IIF(f >= 1, 1, 0);
END^

CREATE OR ALTER PROCEDURE qc_bot_think (c INTEGER, t DOUBLE PRECISION, dt DOUBLE PRECISION)
RETURNS (fmove DOUBLE PRECISION, smove DOUBLE PRECISION, upmove DOUBLE PRECISION, pitch DOUBLE PRECISION, yaw DOUBLE PRECISION,
         fire SMALLINT, jump SMALLINT, impulse SMALLINT)
AS
DECLARE fh INTEGER; DECLARE ffa INTEGER; DECLARE fcl INTEGER; DECLARE hp DOUBLE PRECISION; DECLARE tic INTEGER; DECLARE dmatch SMALLINT; DECLARE inter SMALLINT;
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION; DECLARE byaw DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION; DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE aim_error DOUBLE PRECISION; DECLARE enemy INTEGER; DECLARE goal INTEGER; DECLARE aim_ofs DOUBLE PRECISION; DECLARE look_at DOUBLE PRECISION;
DECLARE strafe SMALLINT; DECLARE strafe_at DOUBLE PRECISION; DECLARE turn DOUBLE PRECISION; DECLARE lastx DOUBLE PRECISION; DECLARE lasty DOUBLE PRECISION; DECLARE stuck INTEGER;
DECLARE e INTEGER; DECLARE best DOUBLE PRECISION; DECLARE dist DOUBLE PRECISION; DECLARE cls VARCHAR(2048) CHARACTER SET ASCII;
DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION; DECLARE iyaw DOUBLE PRECISION; DECLARE ipitch DOUBLE PRECISION;
DECLARE dyaw DOUBLE PRECISION; DECLARE dpitch DOUBLE PRECISION; DECLARE f DOUBLE PRECISION; DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION;
DECLARE mc INTEGER; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ct INTEGER;
DECLARE goal_until DOUBLE PRECISION; DECLARE shun INTEGER; DECLARE shun_until DOUBLE PRECISION; DECLARE oldgoal INTEGER;
BEGIN
  fmove = 0; smove = 0; upmove = 0; fire = 0; jump = 0; impulse = 0;
  SELECT b.aim_error, b.yaw, b.pitch, b.enemy, b.goal, b.aim_ofs, b.look_at, b.strafe, b.strafe_at, b.turn, b.lastx, b.lasty, b.stuck,
         b.goal_until, b.shun, b.shun_until
    FROM bots b WHERE b.c = :c INTO aim_error, yaw, pitch, enemy, goal, aim_ofs, look_at, strafe, strafe_at, turn, lastx, lasty, stuck,
         goal_until, shun, shun_until;
  IF (aim_error IS NULL) THEN BEGIN yaw = 0; pitch = 0; SUSPEND; EXIT; END
  SELECT g.tic, g.deathmatch, g.intermission FROM game g WHERE g.id = 1 INTO tic, dmatch, inter;
  SELECT d.x, d.y, d.z, d.yaw, d.minx, d.miny, d.minz, d.maxx, d.maxy, d.maxz FROM ents d WHERE d.id = :c INTO x, y, z, byaw, mnx, mny, mnz, mxx, mxy, mxz;
  fh = qc_fdef('health'); ffa = qc_fdef('fixangle'); fcl = qc_fdef('classname');
  -- spawned or teleported (svc_setangle): the view takes the body's angles
  IF (yaw IS NULL OR qc_f(c, ffa) <> 0) THEN
  BEGIN
    yaw = COALESCE(byaw, 0); pitch = 0;
    EXECUTE PROCEDURE qc_sf(c, ffa, 0);
  END
  -- the intermission: hands off the buttons, or the first bot to press one would end it for everyone
  IF (inter <> 0 OR x IS NULL) THEN BEGIN SUSPEND; EXIT; END
  hp = qc_f(c, fh);
  IF (hp <= 0) THEN
  BEGIN
    -- PlayerDeathThink waits for the buttons to be let go, then pressed: respawn
    fire = IIF(MOD(tic, 8) < 4, 0, 1);
    UPDATE bots b SET b.enemy = NULL, b.goal = NULL, b.yaw = :yaw, b.pitch = 0 WHERE b.c = :c;
    pitch = 0;
    SUSPEND; EXIT;
  END
  ez = z + 22;
  mc = qc_maxclients();

  -- look around every 0.3 s: the nearest enemy it can see, else the nearest item it can see
  IF (t >= look_at) THEN
  BEGIN
    enemy = NULL; best = NULL;
    IF (dmatch <> 0) THEN
      FOR SELECT d.id, SQRT((d.x - :x) * (d.x - :x) + (d.y - :y) * (d.y - :y) + (d.z - :z) * (d.z - :z)) FROM ents d
           JOIN qc_edicts q ON q.id = d.id AND q.free = 0
          WHERE d.id >= 1 AND d.id <= :mc AND d.id <> :c ORDER BY 2 INTO e, dist DO
      BEGIN
        IF (qc_f(e, fh) > 0 AND bot_sees(x, y, ez, e) = 1) THEN BEGIN enemy = e; LEAVE; END
      END
    ELSE
      FOR SELECT FIRST 6 d.id FROM ents d WHERE BIN_AND(d.flags, 32) <> 0 AND d.solid <> 0
            AND ABS(d.x - :x) < 1200 AND ABS(d.y - :y) < 1200 AND ABS(d.z - :z) < 600
          ORDER BY (d.x - :x) * (d.x - :x) + (d.y - :y) * (d.y - :y) INTO e DO
      BEGIN
        IF (qc_f(e, fh) > 0 AND bot_sees(x, y, ez, e) = 1) THEN BEGIN enemy = e; LEAVE; END
      END
    -- a new sighting: a new aim error
    aim_ofs = (rnd() * 2 - 1) * aim_error;
    -- an item it ran for too long is left alone for a while
    IF (goal IS NOT NULL AND t >= goal_until) THEN BEGIN shun = goal; shun_until = t + 10; END
    oldgoal = goal;
    goal = NULL;
    IF (enemy IS NULL) THEN
      FOR SELECT FIRST 10 d.id FROM ents d WHERE d.solid = 1 AND d.model_id IS NOT NULL AND d.id > :mc
            AND (d.id <> :shun OR :t >= :shun_until OR :shun IS NULL)
            AND ABS(d.x - :x) < 900 AND ABS(d.y - :y) < 900 AND d.z - :z < 40 AND :z - d.z < 200
          ORDER BY (d.x - :x) * (d.x - :x) + (d.y - :y) * (d.y - :y) INTO e DO
      BEGIN
        cls = qc_str(CAST(qc_f(e, fcl) AS INTEGER));
        IF ((cls STARTING WITH 'item_' OR cls STARTING WITH 'weapon_') AND bot_sees(x, y, ez, e) = 1) THEN BEGIN goal = e; LEAVE; END
      END
    IF (goal IS DISTINCT FROM oldgoal) THEN goal_until = t + 4;
    look_at = t + 0.3e0;
  END

  e = COALESCE(enemy, goal);
  IF (e IS NOT NULL) THEN
    SELECT d.x, d.y, d.z + (d.minz + d.maxz) / 2 FROM ents d WHERE d.id = :e AND d.solid <> 0 INTO tx, ty, tz;
  IF (e IS NOT NULL AND tx IS NULL) THEN BEGIN enemy = NULL; goal = NULL; e = NULL; END   -- gone, or picked up

  IF (e IS NOT NULL) THEN
  BEGIN
    dist = SQRT((tx - x) * (tx - x) + (ty - y) * (ty - y));
    iyaw = IIF(dist > 0.01e0, ATAN2(ty - y, tx - x) * 57.29577951e0, yaw);
    ipitch = IIF(dist > 0.01e0 OR ABS(tz - ez) > 0.01e0, -ATAN2(tz - ez, dist) * 57.29577951e0, 0);
    IF (enemy IS NOT NULL) THEN BEGIN iyaw = iyaw + aim_ofs; ipitch = ipitch + aim_ofs / 3; END
    -- turn towards it, 540 degrees a second at most
    dyaw = bot_angdiff(yaw, iyaw);
    yaw = yaw + MAXVALUE(-540 * dt, MINVALUE(540 * dt, dyaw));
    dpitch = ipitch - pitch;
    pitch = pitch + MAXVALUE(-360 * dt, MINVALUE(360 * dt, dpitch));
    IF (enemy IS NOT NULL) THEN
    BEGIN
      -- fight: close in, keep a little distance, circle-strafe, fire when roughly on target
      fmove = IIF(dist > 260, 400, IIF(dist < 120, -300, 0));
      IF (t >= strafe_at) THEN BEGIN strafe = IIF(rnd() < 0.5e0, -1, 1); strafe_at = t + 0.6e0 + rnd() * 0.8e0; END
      smove = strafe * 350;
      fire = IIF(ABS(bot_angdiff(yaw, iyaw - aim_ofs)) < 12 + aim_error AND dist < 2000, 1, 0);
    END
    ELSE fmove = IIF(ABS(dyaw) < 60, 400, 100);
    turn = 0;
  END
  ELSE
  BEGIN
    -- wander: run on, turning away from walls and from drops into nothing, lava or slime
    pitch = pitch * 0.8e0;
    IF (turn <> 0) THEN
    BEGIN
      dyaw = MAXVALUE(-360 * dt, MINVALUE(360 * dt, turn));
      yaw = yaw + dyaw; turn = turn - dyaw;
      IF (ABS(turn) < 1) THEN turn = 0;
      fmove = 200;
    END
    ELSE
    BEGIN
      cx = COS(yaw / 57.29577951e0); cy = SIN(yaw / 57.29577951e0);
      -- a wall within 64 units?
      SELECT r.fraction FROM trace_move(:c, :mnx, :mny, :mnz, :mxx, :mxy, :mxz, :x, :y, :z, :x + :cx * 64, :y + :cy * 64, :z, 1) r INTO f;
      IF (f >= 1) THEN
      BEGIN
        -- the floor 40 units ahead: within 60 units down (a step, a slope), and not under lava or slime
        ex = x + cx * 40; ey = y + cy * 40;
        SELECT r.fraction FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, :ex, :ey, :z + :mnz + 1, :ex, :ey, :z + :mnz - 99, 1) r INTO f;
        ct = (SELECT l.contents FROM leaves l WHERE l.id = point_leaf(:ex, :ey, :z + :mnz + 1 - :f * 100 + 4));
        f = IIF(f < 0.6e0 AND COALESCE(ct, -1) NOT IN (-4, -5), 1, 0);
      END
      IF (f < 1) THEN turn = IIF(rnd() < 0.5e0, -1, 1) * (90 + rnd() * 90);
      fmove = 400;
    END
  END

  -- stuck against something: jump, and turn
  IF (fmove <> 0 AND lastx IS NOT NULL AND ABS(x - lastx) + ABS(y - lasty) < 1) THEN stuck = stuck + 1; ELSE stuck = 0;
  IF (stuck > 6) THEN
  BEGIN
    jump = 1; stuck = 0;
    IF (enemy IS NOT NULL) THEN strafe = -strafe;
    ELSE
    BEGIN
      IF (goal IS NOT NULL) THEN BEGIN shun = goal; shun_until = t + 10; goal = NULL; END   -- the way to it is blocked
      turn = IIF(rnd() < 0.5e0, -1, 1) * (60 + rnd() * 120);
    END
  END
  yaw = yaw - 360 * FLOOR(yaw / 360);
  UPDATE bots b SET b.yaw = :yaw, b.pitch = :pitch, b.enemy = :enemy, b.goal = :goal, b.aim_ofs = :aim_ofs, b.look_at = :look_at,
                    b.strafe = :strafe, b.strafe_at = :strafe_at, b.turn = :turn, b.lastx = :x, b.lasty = :y, b.stuck = :stuck,
                    b.goal_until = :goal_until, b.shun = :shun, b.shun_until = :shun_until
   WHERE b.c = :c;
  SUSPEND;
END^

SET TERM ; ^
