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
    -- each its own colours (top and bottom alike: red, blue, green, yellow, magenta, orange, light blue)
    INSERT INTO bots (c, name, aim_error, colors)
    VALUES (:i + 2, TRIM(CASE MOD(:i, 7) WHEN 0 THEN 'Grunt' WHEN 1 THEN 'Enforcer' WHEN 2 THEN 'Ogre' WHEN 3 THEN 'Knight'
                                         WHEN 4 THEN 'Fiend' WHEN 5 THEN 'Vore' ELSE 'Shambler' END),
            CASE :sk WHEN 0 THEN 20 WHEN 1 THEN 12 WHEN 2 THEN 6 ELSE 3 END,
            CASE MOD(:i, 7) WHEN 0 THEN 4 WHEN 1 THEN 13 WHEN 2 THEN 3 WHEN 3 THEN 12 WHEN 4 THEN 9 WHEN 5 THEN 6 ELSE 2 END * 17);
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

-- ── the bots' map of the level (FrikBot's dynamic waypoints) ─────────────────
-- A clear line between two floor spots, a little above the floor (the world only)
CREATE OR ALTER FUNCTION nav_clear (x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION,
                                    x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION) RETURNS SMALLINT
AS
DECLARE f DOUBLE PRECISION;
BEGIN
  SELECT r.fraction FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, :x1, :y1, :z1 + 8, :x2, :y2, :z2 + 8, 1) r INTO f;
  RETURN IIF(f >= 1, 1, 0);
END^

-- the node nearest a spot: within 64 units across and 24 up or down, in sight of it
CREATE OR ALTER FUNCTION nav_near (x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION, r DOUBLE PRECISION) RETURNS INTEGER
AS
DECLARE n INTEGER; DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
BEGIN
  FOR SELECT FIRST 4 d.id, d.x, d.y, d.z FROM nav_nodes d
       WHERE d.x BETWEEN :x - :r AND :x + :r AND d.y BETWEEN :y - :r AND :y + :r AND d.z BETWEEN :z - 24 AND :z + 24
       ORDER BY (d.x - :x) * (d.x - :x) + (d.y - :y) * (d.y - :y) INTO n, nx, ny, nz DO
    IF ((nx - x) * (nx - x) + (ny - y) * (ny - y) <= r * r AND nav_clear(x, y, z, nx, ny, nz) = 1) THEN RETURN n;
  RETURN NULL;
END^

-- a client's place after the frame: on the floor and alive, at a node (a new one where none is near),
-- linked from the node it was at last
CREATE OR ALTER PROCEDURE nav_mark (c INTEGER)
AS
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION; DECLARE fl INTEGER; DECLARE wl SMALLINT;
DECLARE n INTEGER; DECLARE last INTEGER; DECLARE lx DOUBLE PRECISION; DECLARE ly DOUBLE PRECISION; DECLARE lz DOUBLE PRECISION;
BEGIN
  SELECT e.x, e.y, e.z, e.flags, e.waterlevel FROM ents e WHERE e.id = :c INTO x, y, z, fl, wl;
  IF (x IS NULL OR qc_f(c, qc_fdef('health')) <= 0) THEN
  BEGIN
    DELETE FROM nav_track t WHERE t.c = :c;              -- dead: the way on starts again from the respawn
    EXIT;
  END
  IF (BIN_AND(fl, 512) = 0 OR wl >= 2) THEN EXIT;         -- in the air, or swimming
  -- still by its last node: nothing to do (most frames, and no trace)
  SELECT d.x, d.y, d.z FROM nav_track t JOIN nav_nodes d ON d.id = t.node WHERE t.c = :c INTO lx, ly, lz;
  IF (lx IS NOT NULL AND (lx - x) * (lx - x) + (ly - y) * (ly - y) < 32 * 32 AND ABS(lz - z) < 24) THEN EXIT;
  n = nav_near(x, y, z, 64);
  IF (n IS NULL) THEN
  BEGIN
    IF ((SELECT COUNT(*) FROM nav_nodes) >= 2000) THEN EXIT;
    n = COALESCE((SELECT MAX(d.id) FROM nav_nodes d), 0) + 1;
    INSERT INTO nav_nodes (id, x, y, z) VALUES (:n, :x, :y, :z);
  END
  SELECT t.node FROM nav_track t WHERE t.c = :c INTO last;
  IF (last IS NOT NULL AND last <> n) THEN
  BEGIN
    SELECT d.x, d.y, d.z FROM nav_nodes d WHERE d.id = :last INTO lx, ly, lz;
    SELECT d.x, d.y, d.z FROM nav_nodes d WHERE d.id = :n INTO x, y, z;
    -- the way it came, if it can be seen (not round a corner it cut); back again unless it dropped more
    -- than a step or went further than a run (a teleporter)
    IF (lx IS NOT NULL AND nav_clear(lx, ly, lz, x, y, z) = 1) THEN
    BEGIN
      UPDATE OR INSERT INTO nav_links (a, b) VALUES (:last, :n) MATCHING (a, b);
      IF (lz - z <= 18 AND (x - lx) * (x - lx) + (y - ly) * (y - ly) <= 160 * 160) THEN
        UPDATE OR INSERT INTO nav_links (a, b) VALUES (:n, :last) MATCHING (a, b);
    END
    ELSE IF (lx IS NOT NULL AND (x - lx) * (x - lx) + (y - ly) * (y - ly) > 256 * 256) THEN
      UPDATE OR INSERT INTO nav_links (a, b) VALUES (:last, :n) MATCHING (a, b);   -- teleported: one way
  END
  UPDATE OR INSERT INTO nav_track (c, node) VALUES (:c, :n) MATCHING (c);
END^

-- every node reachable from one, by breadth-first search: nav_search's depth and the way back
CREATE OR ALTER PROCEDURE nav_bfs (origin_node INTEGER)
AS
DECLARE d INTEGER = 0; DECLARE added INTEGER = 1;
BEGIN
  DELETE FROM nav_search;
  INSERT INTO nav_search (node, prev, depth) VALUES (:origin_node, NULL, 0);
  WHILE (added > 0 AND d < 500) DO
  BEGIN
    INSERT INTO nav_search (node, prev, depth)
      SELECT l.b, MIN(l.a), :d + 1 FROM nav_search s JOIN nav_links l ON l.a = s.node
       WHERE s.depth = :d AND NOT EXISTS (SELECT 1 FROM nav_search x WHERE x.node = l.b)
       GROUP BY l.b;
    added = ROW_COUNT;
    d = d + 1;
  END
END^

-- a bot's way from where it stands: to `goal`, or (goal NULL) to a node beside an item (a weapon, ammo,
-- armour, health: anything a client picks up) at least three links away, picked at random, so that it
-- makes for the level's pickups the way it or the others went; 1 when it has a way, 0 when nothing of
-- the kind is known yet (it wanders, and learns)
CREATE OR ALTER PROCEDURE bot_plan (c INTEGER, x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION, goal INTEGER)
RETURNS (ok SMALLINT)
AS
DECLARE origin_node INTEGER; DECLARE n INTEGER; DECLARE k INTEGER; DECLARE steps INTEGER; DECLARE mc INTEGER;
BEGIN
  ok = 0;
  DELETE FROM bot_route r WHERE r.c = :c;
  UPDATE bots b SET b.route_goal = NULL, b.route_step = 0 WHERE b.c = :c;
  origin_node = nav_near(x, y, z, 128);
  IF (origin_node IS NULL) THEN BEGIN SUSPEND; EXIT; END
  EXECUTE PROCEDURE nav_bfs(origin_node);
  IF (goal IS NULL) THEN
  BEGIN
    mc = qc_maxclients();
    DELETE FROM nav_pick;
    INSERT INTO nav_pick (node)
      SELECT s.node FROM nav_search s JOIN nav_nodes d ON d.id = s.node
       WHERE s.depth >= 3 AND EXISTS (SELECT 1 FROM ents i WHERE i.solid = 1 AND i.model_id IS NOT NULL AND i.id > :mc
                                         AND i.x BETWEEN d.x - 64 AND d.x + 64 AND i.y BETWEEN d.y - 64 AND d.y + 64
                                         AND i.z BETWEEN d.z - 48 AND d.z + 48);
    n = (SELECT COUNT(*) FROM nav_pick);
    IF (n = 0) THEN BEGIN SUSPEND; EXIT; END
    k = CAST(FLOOR(rnd() * n) AS INTEGER);
    SELECT p.node FROM nav_pick p ORDER BY p.node ROWS :k + 1 TO :k + 1 INTO goal;
  END
  steps = (SELECT s.depth FROM nav_search s WHERE s.node = :goal);
  IF (steps IS NULL OR steps = 0) THEN BEGIN SUSPEND; EXIT; END
  -- the way back from the goal, written as steps from where it stands
  n = goal;
  WHILE (n IS NOT NULL AND n <> origin_node) DO
  BEGIN
    INSERT INTO bot_route (c, step, node) VALUES (:c, (SELECT s.depth FROM nav_search s WHERE s.node = :n), :n);
    n = (SELECT s.prev FROM nav_search s WHERE s.node = :n);
  END
  UPDATE bots b SET b.route_goal = :goal, b.route_step = 1 WHERE b.c = :c;
  ok = 1;
  SUSPEND;
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
DECLARE route_goal INTEGER; DECLARE route_step INTEGER; DECLARE route_at DOUBLE PRECISION; DECLARE rn INTEGER; DECLARE ok SMALLINT; DECLARE k INTEGER;
BEGIN
  fmove = 0; smove = 0; upmove = 0; fire = 0; jump = 0; impulse = 0;
  SELECT b.aim_error, b.yaw, b.pitch, b.enemy, b.goal, b.aim_ofs, b.look_at, b.strafe, b.strafe_at, b.turn, b.lastx, b.lasty, b.stuck,
         b.goal_until, b.shun, b.shun_until, b.route_goal, b.route_step, b.route_at
    FROM bots b WHERE b.c = :c INTO aim_error, yaw, pitch, enemy, goal, aim_ofs, look_at, strafe, strafe_at, turn, lastx, lasty, stuck,
         goal_until, shun, shun_until, route_goal, route_step, route_at;
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
    UPDATE bots b SET b.enemy = NULL, b.goal = NULL, b.yaw = :yaw, b.pitch = 0, b.route_goal = NULL, b.route_at = 0 WHERE b.c = :c;
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
        -- (not one with FL_NOTARGET: the console's notarget hides the player from the bots as from the monsters)
        IF (qc_f(e, fh) > 0 AND BIN_AND((SELECT n.flags FROM ents n WHERE n.id = :e), 128) = 0 AND bot_sees(x, y, ez, e) = 1) THEN BEGIN enemy = e; LEAVE; END
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
    route_goal = NULL; route_at = t;                       -- after the fight or the item, a new way from wherever it is
  END
  ELSE
  BEGIN
    pitch = pitch * 0.8e0;
    -- nothing in sight: make for a node of the map it and the others have learnt, by the links between them
    IF (route_goal IS NULL AND t >= route_at) THEN
    BEGIN
      ok = 0;
      SELECT p.ok FROM bot_plan(:c, :x, :y, :z, NULL) p INTO ok;
      IF (ok = 1) THEN BEGIN route_goal = (SELECT b.route_goal FROM bots b WHERE b.c = :c); route_step = 1; route_at = t; END
      ELSE route_at = t + 2;                               -- too little known yet: wander, and try again
    END
    rn = NULL;
    IF (route_goal IS NOT NULL) THEN
      SELECT d.id, d.x, d.y, d.z FROM bot_route r JOIN nav_nodes d ON d.id = r.node WHERE r.c = :c AND r.step = :route_step INTO rn, tx, ty, tz;
    IF (rn IS NULL) THEN route_goal = NULL;
    ELSE
    BEGIN
      dist = SQRT((tx - x) * (tx - x) + (ty - y) * (ty - y));
      IF (dist < 24 AND ABS(tz - z) < 48) THEN
      BEGIN
        route_step = route_step + 1; route_at = t;
        -- there: wander on from it for a few seconds, learning what lies beyond, then plan again
        IF (NOT EXISTS (SELECT 1 FROM bot_route r WHERE r.c = :c AND r.step = :route_step)) THEN
        BEGIN
          route_goal = NULL; route_at = t + 3 + rnd() * 4;
        END
      END
      ELSE IF (t - route_at > 3) THEN
      BEGIN
        -- three seconds and not across: the link is no way after all (a ledge too high, a door shut since)
        IF (route_step > 1) THEN
          DELETE FROM nav_links l WHERE l.b = :rn AND l.a = (SELECT r.node FROM bot_route r WHERE r.c = :c AND r.step = :route_step - 1);
        route_goal = NULL; route_at = t + 1;
      END
      ELSE
      BEGIN
        iyaw = ATAN2(ty - y, tx - x) * 57.29577951e0;
        dyaw = bot_angdiff(yaw, iyaw);
        yaw = yaw + MAXVALUE(-540 * dt, MINVALUE(540 * dt, dyaw));
        fmove = IIF(ABS(dyaw) < 45, 400, IIF(ABS(dyaw) < 90, 150, 0));
        turn = 0;
      END
    END
  END
  IF (e IS NULL AND rn IS NULL) THEN
  BEGIN
    -- wander: run on, turning away from walls and from drops into nothing, lava or slime
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
      -- a wall within 64 units? (not a stair: a step up is no wall, as SV_StepMove climbs it)
      SELECT r.fraction FROM trace_move(:c, :mnx, :mny, :mnz, :mxx, :mxy, :mxz, :x, :y, :z, :x + :cx * 64, :y + :cy * 64, :z, 1) r INTO f;
      IF (f < 1) THEN
        SELECT MAXVALUE(:f, r.fraction) FROM trace_move(:c, :mnx, :mny, :mnz, :mxx, :mxy, :mxz, :x, :y, :z + 18, :x + :cx * 64, :y + :cy * 64, :z + 18, 1) r INTO f;
      IF (f >= 1) THEN
      BEGIN
        -- the floor 40 units ahead: within 60 units down (a step, a slope), and not under lava or slime
        ex = x + cx * 40; ey = y + cy * 40;
        SELECT r.fraction FROM trace_move(NULL, 0, 0, 0, 0, 0, 0, :ex, :ey, :z + :mnz + 1, :ex, :ey, :z + :mnz - 99, 1) r INTO f;
        ct = (SELECT l.contents FROM leaves l WHERE l.id = point_leaf(:ex, :ey, :z + :mnz + 1 - :f * 100 + 4));
        f = IIF(f < 0.6e0 AND COALESCE(ct, -1) NOT IN (-4, -5), 1, 0);
      END
      -- blocked: of five ways round (a quarter, three eighths and a half turn, a little jittered), the one with
      -- the most room ahead, and more for room it has no node in yet, so that roaming learns the level
      IF (f < 1) THEN
      BEGIN
        best = NULL; k = 0;
        WHILE (k < 5) DO
        BEGIN
          dyaw = CASE k WHEN 0 THEN 90 WHEN 1 THEN -90 WHEN 2 THEN 135 WHEN 3 THEN -135 ELSE 180 END + (rnd() * 2 - 1) * 20;
          cx = COS((yaw + dyaw) / 57.29577951e0); cy = SIN((yaw + dyaw) / 57.29577951e0);
          SELECT MAXVALUE(r.fraction, (SELECT u.fraction FROM trace_move(:c, :mnx, :mny, :mnz, :mxx, :mxy, :mxz, :x, :y, :z + 18, :x + :cx * 256, :y + :cy * 256, :z + 18, 1) u))
            FROM trace_move(:c, :mnx, :mny, :mnz, :mxx, :mxy, :mxz, :x, :y, :z, :x + :cx * 256, :y + :cy * 256, :z, 1) r INTO f;
          dist = f * 256 + IIF(nav_near(x + cx * f * 256, y + cy * f * 256, z, 96) IS NULL, 200, 0);
          IF (best IS NULL OR dist > best) THEN BEGIN best = dist; turn = dyaw; END
          k = k + 1;
        END
      END
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
                    b.goal_until = :goal_until, b.shun = :shun, b.shun_until = :shun_until,
                    b.route_goal = :route_goal, b.route_step = :route_step, b.route_at = :route_at
   WHERE b.c = :c;
  SUSPEND;
END^

SET TERM ; ^
