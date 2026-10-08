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
  IF (t <> 0) THEN EXCEPTION save_error 'a demo starts with its level: record before the first tic';
  DELETE FROM demo_tics;
  UPDATE demo d SET d.map_name = (SELECT g.map_name FROM game g WHERE g.id = 1), d.skill = (SELECT g.skill FROM game g WHERE g.id = 1),
         d.qc_mode = (SELECT g.qc_mode FROM game g WHERE g.id = 1), d.seed = (SELECT r.level_seed FROM rng r WHERE r.id = 1),
         d.recording = 1, d.calls = 0
   WHERE d.id = 1;
END^

CREATE OR ALTER PROCEDURE demo_stop
AS
BEGIN
  UPDATE demo d SET d.recording = 0 WHERE d.id = 1;
END^

SET TERM ; ^
