-- qcpage.sql – the page in QuakeC mode: a level (qc_begin_map), its change (qc_change_parms), and
-- qc_tic, shaped like QUAKE_TIC's row.

SET TERM ^ ;

-- ── the page in QuakeC mode: a level, its change, and a tic shaped like QUAKE_TIC's ──

-- SV_SaveSpawnparms: SetChangeParms on the client, its parms and serverflags kept for the next level
CREATE OR ALTER PROCEDURE qc_change_parms
AS
DECLARE f INTEGER; DECLARE i INTEGER; DECLARE o INTEGER;
BEGIN
  DELETE FROM qc_saved;
  EXECUTE PROCEDURE qc_sg((SELECT v.g_self FROM qc_vm v WHERE v.id = 1), 1);
  f = qc_fn('SetChangeParms');
  IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  i = 1;
  WHILE (i <= 16) DO
  BEGIN
    o = qc_gdef('parm' || i);
    IF (o IS NOT NULL) THEN INSERT INTO qc_saved (ofs, v) VALUES (:o, qc_g(:o));
    i = i + 1;
  END
  o = qc_gdef('serverflags');
  IF (o IS NOT NULL) THEN INSERT INTO qc_saved (ofs, v) VALUES (:o, qc_g(:o));
END^

-- A level in QuakeC mode, after loadMap has loaded its geometry: QuakeC mode entered (the globals reset),
-- the carried parms and serverflags restored (carry = 1) or a new game's, mapname and world.model set,
-- the map spawned by its spawn functions at time 1, and the client put in.
CREATE OR ALTER PROCEDURE qc_begin_map (skill SMALLINT, carry SMALLINT)
AS
DECLARE o INTEGER; DECLARE v DOUBLE PRECISION; DECLARE mn VARCHAR(32); DECLARE a INTEGER; DECLARE b INTEGER; DECLARE c INTEGER;
BEGIN
  IF (carry = 0) THEN DELETE FROM qc_saved;
  EXECUTE PROCEDURE qc_enter;
  FOR SELECT s.ofs, s.v FROM qc_saved s INTO o, v DO EXECUTE PROCEDURE qc_sg(o, v);
  mn = (SELECT g.map_name FROM game g WHERE g.id = 1);
  EXECUTE PROCEDURE qc_sg(qc_gdef('mapname'), qc_newstr(mn));
  -- SV_SpawnServer: the deathmatch and coop globals come from the server's rules
  EXECUTE PROCEDURE qc_sg(qc_gdef('deathmatch'), (SELECT g.deathmatch FROM game g WHERE g.id = 1));
  EXECUTE PROCEDURE qc_sg(qc_gdef('coop'), (SELECT g.coop FROM game g WHERE g.id = 1));
  EXECUTE PROCEDURE qc_sf(0, qc_fdef('model'), qc_newstr('maps/' || mn || '.bsp'));
  UPDATE game g SET g.time_ = 1.0, g.tic = 0, g.next_map = NULL, g.exit_kind = 0, g.intermission = 0, g.completed_time = 0, g.finale_text = NULL, g.cdtrack = -1 WHERE g.id = 1;
  UPDATE player p SET p.msg = NULL, p.msg_time = 0, p.cprint = NULL, p.cprint_time = 0, p.bonus_time = -10, p.dmg_time = -10,
                      p.dmg_take = 0, p.dmg_save = 0, p.pitch = 0, p.punchangle = 0, p.view_ofs = 22, p.stepz = 0 WHERE p.id = 1;
  SELECT r.spawned, r.failed, r.skipped FROM qc_spawn_map(:skill, 1.0) r INTO a, b, c;
  EXECUTE PROCEDURE qc_client_join(1.0, carry);
  -- the bots come in after the player, as clients connecting (sql/bots.sql)
  FOR SELECT b.c, b.name FROM bots b WHERE b.c <= qc_maxclients() ORDER BY b.c INTO a, mn DO
  BEGIN
    UPDATE bots b SET b.yaw = NULL, b.enemy = NULL, b.goal = NULL, b.look_at = 0, b.turn = 0, b.stuck = 0, b.lastx = NULL WHERE b.c = :a;
    EXECUTE PROCEDURE qc_client_join_n(a, 1.0, 0, mn);
  END
  -- the level's name, as the PSQL game shows it
  UPDATE player p SET p.cprint = (SELECT g.level_msg FROM game g WHERE g.id = 1), p.cprint_time = 3 WHERE p.id = 1;
END^

-- QUAKE_TIC for QuakeC mode: the same input and the same row. Each tic is a 0.05 s server frame; the view
-- angles are the client's own (svc_setangle when the progs set fixangle: spawning, teleporting, the
-- intermission camera), the row is read from the client's QuakeC fields, and the damage the client
-- took is handed over once (SV_WriteClientdataToMessage) and cleared.
CREATE OR ALTER PROCEDURE qc_tic (
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
  amb_water INTEGER, amb_sky INTEGER, finale SMALLINT,
  intermission SMALLINT, completed_time DOUBLE PRECISION, finale_text VARCHAR(1024), cdtrack SMALLINT, skill SMALLINT)
AS
DECLARE i INTEGER = 0; DECLARE t DOUBLE PRECISION; DECLARE r INTEGER; DECLARE fl INTEGER;
DECLARE vyaw DOUBLE PRECISION; DECLARE vpitch DOUBLE PRECISION; DECLARE va INTEGER; DECLARE fa INTEGER;
DECLARE fdt INTEGER; DECLARE fds INTEGER; DECLARE vo DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE demo_note(tics, fwd, side, yaw_d, pitch_d, fire, jump, run, imp);
  SELECT g.tic FROM game g WHERE g.id = 1 INTO tic;
  DELETE FROM sound_events s WHERE s.tic < :tic - 40;
  DELETE FROM fx_events f WHERE f.tic < :tic - 40;
  -- SV_CleanupEnts: a muzzle flash lasts the frame it was sent in (the page lights it once)
  UPDATE ents e SET e.effects = BIN_AND(e.effects, BIN_NOT(2)) WHERE BIN_AND(e.effects, 2) <> 0;
  va = (SELECT v.f_v_angle FROM qc_vm v WHERE v.id = 1);
  fa = qc_fdef('fixangle');
  vyaw = qc_f(1, va + 1);
  vpitch = (SELECT p.pitch FROM player p WHERE p.id = 1);
  WHILE (i < tics) DO
  BEGIN
    IF (qc_f(1, fa) <> 0) THEN                      -- svc_setangle: the view takes the body's angles
    BEGIN
      SELECT e.pitch, e.yaw FROM ents e WHERE e.id = 1 INTO vpitch, vyaw;
      EXECUTE PROCEDURE qc_sf(1, fa, 0);
    END
    vyaw = vyaw + yaw_d / tics;
    vpitch = MAXVALUE(-70, MINVALUE(80, vpitch + pitch_d / tics));
    t = (SELECT g.time_ FROM game g WHERE g.id = 1);
    SELECT x.ran FROM qc_server_frame(:t, 0.05e0, :fwd * IIF(:run = 1, 400, 200), :side * IIF(:run = 1, 700, 350), 0,
                                      :vpitch, :vyaw, :fire, :jump, IIF(:i = 0, :imp, 0)) x INTO r;
    UPDATE game g SET g.time_ = :t + 0.05e0 WHERE g.id = 1;
    i = i + 1;
  END
  -- the eye: view_ofs, and the damage handed over once
  vo = qc_f(1, qc_fdef('view_ofs') + 2);
  fdt = qc_fdef('dmg_take'); fds = qc_fdef('dmg_save');
  dmg_take = CAST(qc_f(1, fdt) AS INTEGER); dmg_save = CAST(qc_f(1, fds) AS INTEGER);
  SELECT g.time_ FROM game g WHERE g.id = 1 INTO time_;
  IF (dmg_take <> 0 OR dmg_save <> 0) THEN
  BEGIN
    UPDATE player p SET p.dmg_time = :time_ WHERE p.id = 1;
    EXECUTE PROCEDURE qc_sf(1, fdt, 0); EXECUTE PROCEDURE qc_sf(1, fds, 0);
  END
  UPDATE player p SET p.view_ofs = :vo WHERE p.id = 1;
  SELECT g.tic, CAST(qc_f(1, qc_fdef('health')) AS INTEGER), CAST(qc_f(1, qc_fdef('armorvalue')) AS INTEGER), qc_f(1, qc_fdef('armortype')),
         CAST(qc_f(1, qc_fdef('ammo_shells')) AS INTEGER), CAST(qc_f(1, qc_fdef('ammo_nails')) AS INTEGER),
         CAST(qc_f(1, qc_fdef('ammo_rockets')) AS INTEGER), CAST(qc_f(1, qc_fdef('ammo_cells')) AS INTEGER),
         CAST(qc_f(1, qc_fdef('items')) AS INTEGER), CAST(qc_f(1, qc_fdef('weapon')) AS INTEGER), CAST(qc_f(1, qc_fdef('weaponframe')) AS INTEGER),
         e.x, e.y, e.z, :vyaw, p.pitch + p.punchangle, e.z + :vo, p.punchangle,
         IIF(p.msg_time > g.time_, TRIM(TRAILING ASCII_CHAR(10) FROM p.msg), NULL), IIF(p.cprint_time > g.time_, p.cprint, NULL),
         p.dmg_time, p.bonus_time, IIF(qc_f(1, qc_fdef('deadflag')) > 0, 1, 0), g.exit_kind, g.next_map,
         CAST(qc_g(qc_gdef('killed_monsters')) AS INTEGER), CAST(qc_g(qc_gdef('total_monsters')) AS INTEGER),
         CAST(qc_g(qc_gdef('found_secrets')) AS INTEGER), CAST(qc_g(qc_gdef('total_secrets')) AS INTEGER),
         e.waterlevel, e.watertype, g.map_name, g.level_msg, g.finale, e.leaf, COALESCE(l.ambient, 0), COALESCE(l.ambient_sky, 0),
         g.intermission, g.completed_time, g.finale_text, g.cdtrack, g.skill
    FROM game g CROSS JOIN player p JOIN ents e ON e.id = 1 LEFT JOIN leaves l ON l.id = e.leaf
   WHERE g.id = 1 AND p.id = 1
    INTO tic, health, armorvalue, armortype, shells, nails, rockets, cells, items, weapon, weaponframe,
         px, py, pz, yaw, pitch, view_z, punch, msg, cprint, dmg_time, bonus_time, dead, exit_kind, next_map,
         killed, total_monsters, found_secrets, total_secrets, waterlevel, watertype, map_name, level_msg, finale, leaf, amb_water, amb_sky,
         intermission, completed_time, finale_text, cdtrack, skill;
  invincible = IIF(BIN_AND(items, 1048576) <> 0, 1, 0); quad = IIF(BIN_AND(items, 4194304) <> 0, 1, 0);
  invisible = IIF(BIN_AND(items, 524288) <> 0, 1, 0); suit = IIF(BIN_AND(items, 2097152) <> 0, 1, 0);
  SUSPEND;
END^

SET TERM ; ^
