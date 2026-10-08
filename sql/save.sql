-- save.sql – save games: host.c's Host_Savegame_f and Host_Loadgame_f.
--
-- The whole state of a game is a handful of tables (game, player, ents, lightstyles, and in QuakeC
-- mode the VM's globals, fields, edicts, run-time strings and parms); the rest is the map, the pak and
-- progs.dat, which a load reads again. So a save is a copy of those rows into the sv_<table> tables
-- under a slot, and a load copies them back over a freshly loaded copy of the same map.
-- src/loader.js generates the sv_ tables and save_tables / restore_tables / drop_saved from the live
-- tables' columns (savedTablesSql); src/saves.js carries a slot's rows to the browser's storage and
-- back, so a save outlives the page.
--
--   EXECUTE PROCEDURE save_game(0);     -- slot 0 (s0.sav)
--   EXECUTE PROCEDURE load_game(0);     -- the map must be the save's (loadMap first)
--   SELECT * FROM saves;

CREATE EXCEPTION save_error 'save game error';

SET TERM ^ ;

-- Host_Savegame_f: not while dead, not in the intermission. The comment is SaveGame_Comment's: the
-- level's name in 22 columns and the kills.
CREATE OR ALTER PROCEDURE save_game (slot SMALLINT)
AS
DECLARE qc SMALLINT; DECLARE dead SMALLINT; DECLARE inter SMALLINT; DECLARE ek SMALLINT;
DECLARE kills INTEGER; DECLARE total INTEGER; DECLARE lvl VARCHAR(80); DECLARE mn VARCHAR(32);
BEGIN
  IF (slot IS NULL OR slot < 0 OR slot > 12) THEN EXCEPTION save_error 'a save slot is 0 to 11, or 12 (quick)';
  SELECT g.qc_mode, g.intermission, g.exit_kind, g.killed, g.total_monsters, COALESCE(g.level_msg, g.map_name), g.map_name
    FROM game g WHERE g.id = 1 INTO qc, inter, ek, kills, total, lvl, mn;
  IF (mn IS NULL) THEN EXCEPTION save_error 'no game to save';
  IF (inter <> 0 OR ek <> 0) THEN EXCEPTION save_error 'Can''t save in intermission.';
  IF (qc = 1) THEN
  BEGIN
    dead = IIF(qc_f(1, qc_fdef('deadflag')) > 0 OR qc_f(1, qc_fdef('health')) <= 0, 1, 0);
    kills = CAST(qc_g(qc_gdef('killed_monsters')) AS INTEGER);
    total = CAST(qc_g(qc_gdef('total_monsters')) AS INTEGER);
  END
  ELSE
    SELECT IIF(e.deadflag <> 0 OR e.health <= 0, 1, 0) FROM player p JOIN ents e ON e.id = p.ent_id WHERE p.id = 1 INTO dead;
  IF (dead = 1) THEN EXCEPTION save_error 'Can''t savegame with a dead player';
  DELETE FROM saves s WHERE s.slot = :slot;
  INSERT INTO saves (slot, map_name, comment, qc_mode, skill, time_, world_model, ent_seq)
  SELECT :slot, g.map_name,
         RPAD(SUBSTRING(TRIM(REPLACE(:lvl, ASCII_CHAR(10), ' ')) FROM 1 FOR 22), 22) || ' kills:' || LPAD(:kills, 3) || '/' || LPAD(:total, 3),
         g.qc_mode, g.skill, g.time_, g.world_model, GEN_ID(ent_seq, 0)
    FROM game g WHERE g.id = 1;
  EXECUTE PROCEDURE save_tables(slot, qc);
END^

-- Host_Loadgame_f, after the page has loaded the save's map (and, for a QuakeC save, entered
-- QuakeC mode with progs.dat loaded): the rows come back, the brush models are renumbered to this
-- copy of the map, the edict sequence goes back to where it was, and what was only for the moment
-- (sounds, effects, the marked faces, the VM's stack and caches) is dropped.
CREATE OR ALTER PROCEDURE load_game (slot SMALLINT)
AS
DECLARE mn VARCHAR(32); DECLARE qc SMALLINT; DECLARE w0 INTEGER; DECLARE seq BIGINT;
DECLARE cur VARCHAR(32); DECLARE w1 INTEGER; DECLARE reg SMALLINT; DECLARE skip BIGINT;
BEGIN
  SELECT s.map_name, s.qc_mode, s.world_model, s.ent_seq FROM saves s WHERE s.slot = :slot INTO mn, qc, w0, seq;
  IF (mn IS NULL) THEN EXCEPTION save_error 'that save slot is empty';
  SELECT g.map_name, g.world_model, g.registered FROM game g WHERE g.id = 1 INTO cur, w1, reg;
  IF (LOWER(cur) IS DISTINCT FROM LOWER(mn)) THEN EXCEPTION save_error 'load the save''s map first: ' || mn;
  IF (qc = 1 AND NOT EXISTS (SELECT 1 FROM qc_engine_fields)) THEN EXCEPTION save_error 'a QuakeC save needs QuakeC mode (qc_enter)';
  EXECUTE PROCEDURE restore_tables(slot, qc);
  -- this copy of the map: its world model's id (the brush models follow it in order), the pak's flag
  UPDATE game g SET g.world_model = :w1, g.registered = :reg, g.qc_mode = :qc WHERE g.id = 1;
  IF (w1 <> w0) THEN UPDATE ents e SET e.model_id = e.model_id - :w0 + :w1 WHERE e.model_id >= :w0;
  skip = GEN_ID(ent_seq, :seq - GEN_ID(ent_seq, 0));
  DELETE FROM sound_events;
  DELETE FROM fx_events;
  DELETE FROM vis_faces;
  UPDATE viewcfg c SET c.vis_leaf = NULL;
  IF (qc = 1) THEN
  BEGIN
    DELETE FROM qc_localstack;
    DELETE FROM qc_eyeleaf;
    DELETE FROM qc_log;
    UPDATE qc_functions f SET f.active = 0 WHERE f.active <> 0;
    UPDATE qc_vm v SET v.depth = 0, v.check_time = NULL, v.check_pvs = NULL WHERE v.id = 1;
  END
  ELSE
    EXECUTE PROCEDURE qc_leave;
END^

CREATE OR ALTER PROCEDURE delete_save (slot SMALLINT)
AS
BEGIN
  DELETE FROM saves s WHERE s.slot = :slot;
  EXECUTE PROCEDURE drop_saved(slot);
END^

SET TERM ; ^
