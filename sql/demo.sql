-- demo.sql – demos: cl_demo.c's record and playdemo, for a game that is a function of its input.
--
-- Every random choice goes through rnd() (physics.sql), seeded per level by init_map, and the game
-- reads no clock: its time is the tic count. So a level spawned with the same seed and given the same
-- quake_tic (or qc_tic) arguments plays out the same, bit for bit, in either logic. A demo is the
-- level's map, skill, logic and seed, and demo_tics, the arguments of each call after the spawn, which
-- demo_note (physics.sql) appends while recording. Playback is the page's: it loads the map with the
-- seed (loadMap's seed option sets rng.next_seed) and feeds the rows back in; src/demos.js carries a
-- demo to the browser's storage and back. A demo is one level: init_map stops a recording.
--
-- Recorded mid-level (Quake's record works at any moment, the server sending the whole state first), a
-- demo starts from a save: demo_record saves the game into slot 13 (rng included, so the random choices
-- go on as they would have) and from_save says so; the demo carries the save, and playback loads it
-- onto the map before the first recorded call.
--
--   EXECUTE PROCEDURE demo_record;          -- right after the level is loaded, before its first tic
--   ... SELECT * FROM quake_tic(...) ...
--   EXECUTE PROCEDURE demo_stop;
--   SELECT * FROM demo; SELECT * FROM demo_tics ORDER BY n;

SET TERM ^ ;

CREATE OR ALTER PROCEDURE demo_record
AS
DECLARE t INTEGER;
BEGIN
  SELECT g.tic FROM game g WHERE g.id = 1 INTO t;
  IF (t IS NULL) THEN EXCEPTION save_error 'no level to record';
  DELETE FROM demo_tics;
  IF (t <> 0) THEN EXECUTE PROCEDURE save_game(13);         -- mid-level: from here (not dead, not in the intermission)
  UPDATE demo d SET d.map_name = (SELECT g.map_name FROM game g WHERE g.id = 1), d.skill = (SELECT g.skill FROM game g WHERE g.id = 1),
         d.qc_mode = (SELECT g.qc_mode FROM game g WHERE g.id = 1), d.seed = (SELECT r.level_seed FROM rng r WHERE r.id = 1),
         d.recording = 1, d.calls = 0,
         d.deathmatch = (SELECT g.deathmatch FROM game g WHERE g.id = 1), d.coop = (SELECT g.coop FROM game g WHERE g.id = 1),
         d.nbots = (SELECT g.maxclients - 1 FROM game g WHERE g.id = 1), d.fraglimit = (SELECT g.fraglimit FROM game g WHERE g.id = 1),
         d.timelimit = (SELECT g.timelimit FROM game g WHERE g.id = 1), d.from_save = IIF(:t <> 0, 1, 0)
   WHERE d.id = 1;
END^

CREATE OR ALTER PROCEDURE demo_stop
AS
BEGIN
  UPDATE demo d SET d.recording = 0 WHERE d.id = 1;
END^

SET TERM ; ^
