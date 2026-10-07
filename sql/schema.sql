-- schema.sql – the whole of Quake's world, as Firebird tables.
--
-- A BSP file is a relational database already: FACES reference PLANES and
-- TEXINFO and own an ordered list of VERTICES through EDGES and SURFEDGES;
-- LEAVES list the faces they contain through MARKSURFACES and carry a
-- potentially visible set; NODES and CLIPNODES form the BSP trees that
-- rendering and collision walk. loader.js copies those lumps in (slightly
-- denormalised so the hot loops never need a second lookup); game.sql
-- simulates the entities and render.sql draws the frame.

-- ── session / configuration ─────────────────────────────────────────────
CREATE TABLE game (
  id             SMALLINT NOT NULL PRIMARY KEY,
  tic            INTEGER DEFAULT 0 NOT NULL,
  time_          DOUBLE PRECISION DEFAULT 0 NOT NULL,   -- seconds, tic / 20
  map_name       VARCHAR(32),
  next_map       VARCHAR(32),                           -- set by trigger_changelevel
  exit_kind      SMALLINT DEFAULT 0 NOT NULL,           -- 0 playing, 1 change level, 3 restart (player died)
  skill          SMALLINT DEFAULT 1 NOT NULL,
  world_model    INTEGER DEFAULT 0 NOT NULL,            -- models.id of the world
  total_monsters INTEGER DEFAULT 0 NOT NULL,
  killed         INTEGER DEFAULT 0 NOT NULL,
  total_secrets  INTEGER DEFAULT 0 NOT NULL,
  found_secrets  INTEGER DEFAULT 0 NOT NULL,
  serverflags    INTEGER DEFAULT 0 NOT NULL,            -- runes collected
  world_type     SMALLINT DEFAULT 0 NOT NULL,           -- 0 medieval 1 metal 2 base (key names)
  level_msg      VARCHAR(80),
  intermission_tics INTEGER DEFAULT 0 NOT NULL,
  registered     SMALLINT DEFAULT 0 NOT NULL,           -- pak1 present: all four episodes
  gravity        DOUBLE PRECISION DEFAULT 800 NOT NULL, -- sv_gravity: 100 on Ziggurat Vertigo
  finale         SMALLINT DEFAULT 0 NOT NULL,           -- Shub-Niggurath is dead
  qc_mode        SMALLINT DEFAULT 0 NOT NULL            -- 1: the QuakeC VM owns ents (sql/qcvm.sql, qc_enter)
);

CREATE TABLE viewcfg (
  id     SMALLINT NOT NULL PRIMARY KEY,
  w      INTEGER NOT NULL,
  h      INTEGER NOT NULL,
  fov    DOUBLE PRECISION NOT NULL,     -- horizontal, degrees
  near_z DOUBLE PRECISION NOT NULL,
  vis_leaf INTEGER                     -- the leaf VIS_FACES was marked for
);

-- ── resources ───────────────────────────────────────────────────────────
-- Every model the renderer and the simulation know: the world and its
-- submodels (*1, *2, …), the ammo/health boxes (maps/b_*.bsp, also BSP),
-- alias models (progs/*.mdl) and sprites (progs/*.spr).
CREATE TABLE models (
  id        INTEGER NOT NULL PRIMARY KEY,
  name      VARCHAR(64) NOT NULL,
  kind      CHAR(1) NOT NULL,            -- B bsp, M mdl, S spr
  minx DOUBLE PRECISION, miny DOUBLE PRECISION, minz DOUBLE PRECISION,
  maxx DOUBLE PRECISION, maxy DOUBLE PRECISION, maxz DOUBLE PRECISION,
  hull0 INTEGER, hull1 INTEGER, hull2 INTEGER,   -- head nodes (hull 0 = nodes, 1/2 = clipnodes)
  first_face INTEGER, num_faces INTEGER,
  nframes   INTEGER DEFAULT 1 NOT NULL,
  flags     INTEGER DEFAULT 0 NOT NULL,          -- mdl flags: 1 rocket trail 2 grenade 4 gib 8 rotate ...
  radius    DOUBLE PRECISION DEFAULT 0 NOT NULL
);
CREATE INDEX models_name ON models (name);

-- Frame runs of an alias model: "run1".."run6" → ('run', first, 6).
CREATE TABLE anims (
  model_id INTEGER NOT NULL,
  anim     VARCHAR(16) NOT NULL,
  first_frame INTEGER NOT NULL,
  frame_count INTEGER NOT NULL,
  PRIMARY KEY (model_id, anim)
);

CREATE TABLE lightstyles (
  style   INTEGER NOT NULL PRIMARY KEY,
  pattern VARCHAR(64) NOT NULL          -- 'a' dark … 'm' normal … 'z' double
);

-- ── map geometry ─────────────────────────────────────────────────────────
-- Collision hulls. hull 0 is the node tree itself (children < 0 are leaf
-- contents); hull 1 (player size) and hull 2 (shambler size) share the
-- CLIPNODES array and differ only by head node. The plane is copied in so
-- a trace step is one lookup.
CREATE TABLE hulls (
  hull SMALLINT NOT NULL,
  node INTEGER NOT NULL,
  nx DOUBLE PRECISION NOT NULL, ny DOUBLE PRECISION NOT NULL, nz DOUBLE PRECISION NOT NULL,
  dist DOUBLE PRECISION NOT NULL,
  c0 INTEGER NOT NULL,                  -- front child: >= 0 node, < 0 contents
  c1 INTEGER NOT NULL,
  PRIMARY KEY (hull, node)
);

CREATE TABLE leaves (
  id       INTEGER NOT NULL PRIMARY KEY,
  contents INTEGER NOT NULL,
  minx DOUBLE PRECISION, miny DOUBLE PRECISION, minz DOUBLE PRECISION,
  maxx DOUBLE PRECISION, maxy DOUBLE PRECISION, maxz DOUBLE PRECISION,
  first_ms INTEGER NOT NULL,
  num_ms   INTEGER NOT NULL,
  ambient  INTEGER DEFAULT 0 NOT NULL,          -- ambient_level[AMBIENT_WATER]
  ambient_sky INTEGER DEFAULT 0 NOT NULL,       -- ambient_level[AMBIENT_SKY] (wind)
  -- the decompressed PVS as hex: leaf j (1-based) visible ⇔ bit (j-1).
  -- '' means everything is visible (no vis data, or the solid leaf).
  pvs      VARCHAR(2048) CHARACTER SET ASCII
);

CREATE TABLE marksurfaces (
  id   INTEGER NOT NULL PRIMARY KEY,
  face INTEGER NOT NULL
);

CREATE TABLE faces (
  id        INTEGER NOT NULL PRIMARY KEY,
  model_id  INTEGER NOT NULL,
  -- plane, already flipped for side = 1 so the normal faces the front
  nx DOUBLE PRECISION NOT NULL, ny DOUBLE PRECISION NOT NULL, nz DOUBLE PRECISION NOT NULL,
  dist DOUBLE PRECISION NOT NULL,
  nverts    INTEGER NOT NULL,
  miptex    INTEGER,
  -- texinfo: texel s = p·svec + soff, t = p·tvec + toff
  sx DOUBLE PRECISION NOT NULL, sy DOUBLE PRECISION NOT NULL, sz DOUBLE PRECISION NOT NULL, soff DOUBLE PRECISION NOT NULL,
  tx DOUBLE PRECISION NOT NULL, ty DOUBLE PRECISION NOT NULL, tz DOUBLE PRECISION NOT NULL, toff DOUBLE PRECISION NOT NULL,
  sky       SMALLINT DEFAULT 0 NOT NULL,
  liquid    SMALLINT DEFAULT 0 NOT NULL,
  style0    INTEGER DEFAULT 0 NOT NULL,
  cx DOUBLE PRECISION DEFAULT 0 NOT NULL, cy DOUBLE PRECISION DEFAULT 0 NOT NULL, cz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  radius DOUBLE PRECISION DEFAULT 0 NOT NULL
);
CREATE INDEX faces_model ON faces (model_id);

CREATE TABLE face_verts (
  face INTEGER NOT NULL,
  seq  INTEGER NOT NULL,
  x DOUBLE PRECISION NOT NULL, y DOUBLE PRECISION NOT NULL, z DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (face, seq)
);

CREATE TABLE miptex (
  id   INTEGER NOT NULL PRIMARY KEY,
  name VARCHAR(16) NOT NULL,
  w    INTEGER NOT NULL,
  h    INTEGER NOT NULL
);

-- The entity lump as authored (the common keys; spawn_map_ents reads it).
CREATE TABLE map_ents (
  id         INTEGER NOT NULL PRIMARY KEY,
  classname  VARCHAR(40) NOT NULL,
  targetname VARCHAR(40),
  target     VARCHAR(40),
  killtarget VARCHAR(40),
  model      VARCHAR(40),              -- '*N' for brush models
  ox DOUBLE PRECISION DEFAULT 0 NOT NULL, oy DOUBLE PRECISION DEFAULT 0 NOT NULL, oz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  angle      DOUBLE PRECISION,
  mpitch DOUBLE PRECISION, myaw DOUBLE PRECISION, mroll DOUBLE PRECISION,   -- "mangle"
  spawnflags INTEGER DEFAULT 0 NOT NULL,
  message    VARCHAR(200),
  wait_      DOUBLE PRECISION,
  delay      DOUBLE PRECISION,
  speed      DOUBLE PRECISION,
  lip        DOUBLE PRECISION,
  health     INTEGER,
  light      INTEGER,
  style      INTEGER,
  sounds     INTEGER,
  dmg        INTEGER,
  height     DOUBLE PRECISION,
  count_     INTEGER,
  map        VARCHAR(32),
  noise      VARCHAR(64),
  worldtype  INTEGER
);
CREATE INDEX map_ents_class ON map_ents (classname);
CREATE INDEX map_ents_tname ON map_ents (targetname);

-- ── live entities (Quake's edicts) ──────────────────────────────────────
CREATE SEQUENCE ent_seq;

CREATE TABLE ents (
  id         INTEGER NOT NULL PRIMARY KEY,
  classname  VARCHAR(40) NOT NULL,
  model_id   INTEGER,                   -- NULL = invisible
  frame      INTEGER DEFAULT 0 NOT NULL,
  skin       INTEGER DEFAULT 0 NOT NULL,
  effects    INTEGER DEFAULT 0 NOT NULL,  -- 4 dim light (rocket/laser), 8 bright light
  x DOUBLE PRECISION DEFAULT 0 NOT NULL, y DOUBLE PRECISION DEFAULT 0 NOT NULL, z DOUBLE PRECISION DEFAULT 0 NOT NULL,
  vx DOUBLE PRECISION DEFAULT 0 NOT NULL, vy DOUBLE PRECISION DEFAULT 0 NOT NULL, vz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  pitch DOUBLE PRECISION DEFAULT 0 NOT NULL, yaw DOUBLE PRECISION DEFAULT 0 NOT NULL, roll DOUBLE PRECISION DEFAULT 0 NOT NULL,
  avel_yaw   DOUBLE PRECISION DEFAULT 0 NOT NULL,   -- degrees per second (spinning gibs)
  minx DOUBLE PRECISION DEFAULT 0 NOT NULL, miny DOUBLE PRECISION DEFAULT 0 NOT NULL, minz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  maxx DOUBLE PRECISION DEFAULT 0 NOT NULL, maxy DOUBLE PRECISION DEFAULT 0 NOT NULL, maxz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  solid      SMALLINT DEFAULT 0 NOT NULL,   -- 0 not 1 trigger 2 bbox 3 slidebox 4 bsp
  movetype   SMALLINT DEFAULT 0 NOT NULL,   -- 0 none 3 walk 4 step 5 fly 6 toss 7 push 8 noclip 9 flymissile 10 bounce
  flags      INTEGER DEFAULT 0 NOT NULL,    -- FL_* bits
  health     INTEGER DEFAULT 0 NOT NULL,
  max_health INTEGER DEFAULT 0 NOT NULL,
  takedamage SMALLINT DEFAULT 0 NOT NULL,   -- 0 no 1 yes 2 aim
  deadflag   SMALLINT DEFAULT 0 NOT NULL,
  owner_id   INTEGER,
  enemy_id   INTEGER,
  goal_id    INTEGER,
  movetarget INTEGER,
  st         VARCHAR(12) DEFAULT 'idle' NOT NULL,  -- monsters: stand walk run attack melee pain die dead / doors: top bottom up down
  anim       VARCHAR(16),
  anim_frame INTEGER DEFAULT 0 NOT NULL,           -- index into the anim run
  anim_tic   INTEGER DEFAULT 0 NOT NULL,           -- last tic the frame advanced
  think      VARCHAR(24),
  nextthink  DOUBLE PRECISION,
  targetname VARCHAR(40),
  target     VARCHAR(40),
  killtarget VARCHAR(40),
  message    VARCHAR(200),
  spawnflags INTEGER DEFAULT 0 NOT NULL,
  wait_      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  delay      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  speed      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  lip        DOUBLE PRECISION DEFAULT 0 NOT NULL,
  dmg        INTEGER DEFAULT 0 NOT NULL,
  count_     INTEGER DEFAULT 0 NOT NULL,
  style      INTEGER DEFAULT 0 NOT NULL,
  sounds     INTEGER DEFAULT 0 NOT NULL,
  height     DOUBLE PRECISION DEFAULT 0 NOT NULL,
  map        VARCHAR(32),
  -- movers (doors, plats, buttons, trains)
  p1x DOUBLE PRECISION DEFAULT 0 NOT NULL, p1y DOUBLE PRECISION DEFAULT 0 NOT NULL, p1z DOUBLE PRECISION DEFAULT 0 NOT NULL,
  p2x DOUBLE PRECISION DEFAULT 0 NOT NULL, p2y DOUBLE PRECISION DEFAULT 0 NOT NULL, p2z DOUBLE PRECISION DEFAULT 0 NOT NULL,
  dstx DOUBLE PRECISION DEFAULT 0 NOT NULL, dsty DOUBLE PRECISION DEFAULT 0 NOT NULL, dstz DOUBLE PRECISION DEFAULT 0 NOT NULL,
  mv_state   SMALLINT DEFAULT 0 NOT NULL,   -- 0 top 1 bottom 2 up 3 down
  mv_done    VARCHAR(24),                   -- think to run when the move finishes
  mv_time    DOUBLE PRECISION,              -- when it finishes
  linked_id  INTEGER,                       -- doors: the master of a linked group
  noise1     VARCHAR(64),                   -- open / start sound
  noise2     VARCHAR(64),                   -- close / stop sound
  noise3     VARCHAR(64),
  -- monsters
  ideal_yaw  DOUBLE PRECISION DEFAULT 0 NOT NULL,
  yaw_speed  DOUBLE PRECISION DEFAULT 20 NOT NULL,
  attack_finished DOUBLE PRECISION DEFAULT 0 NOT NULL,
  pain_finished   DOUBLE PRECISION DEFAULT 0 NOT NULL,
  search_time     DOUBLE PRECISION DEFAULT 0 NOT NULL,
  attack_state    SMALLINT DEFAULT 0 NOT NULL,   -- 1 straight 2 sliding 3 melee 4 missile
  lefty      SMALLINT DEFAULT 0 NOT NULL,
  -- items carried by boxes and backpacks
  ammo_shells INTEGER DEFAULT 0 NOT NULL, ammo_nails INTEGER DEFAULT 0 NOT NULL,
  ammo_rockets INTEGER DEFAULT 0 NOT NULL, ammo_cells INTEGER DEFAULT 0 NOT NULL,
  items       INTEGER DEFAULT 0 NOT NULL,
  -- placement
  leaf       INTEGER,                      -- leaf of the origin (hull 0)
  leafs      VARCHAR(200) CHARACTER SET ASCII,   -- ',' separated leaves the box touches
  waterlevel SMALLINT DEFAULT 0 NOT NULL,
  watertype  INTEGER DEFAULT -1 NOT NULL,
  ltime      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  teleport_time DOUBLE PRECISION DEFAULT 0 NOT NULL,
  spawn_x DOUBLE PRECISION DEFAULT 0 NOT NULL, spawn_y DOUBLE PRECISION DEFAULT 0 NOT NULL, spawn_z DOUBLE PRECISION DEFAULT 0 NOT NULL,
  mtype      VARCHAR(16),                  -- monster_types.name
  alpha      SMALLINT DEFAULT 0 NOT NULL   -- 1 = draw translucent (ghostly)
);
CREATE INDEX ents_class ON ents (classname);
CREATE INDEX ents_tname ON ents (targetname);
CREATE INDEX ents_solid ON ents (solid);
CREATE INDEX ents_think ON ents (nextthink);
CREATE INDEX ents_model ON ents (model_id);

-- The one client.
CREATE TABLE player (
  id              SMALLINT NOT NULL PRIMARY KEY,
  ent_id          INTEGER,
  armorvalue      INTEGER DEFAULT 0 NOT NULL,
  armortype       DOUBLE PRECISION DEFAULT 0 NOT NULL,    -- 0.3 0.6 0.8
  shells          INTEGER DEFAULT 25 NOT NULL,
  nails           INTEGER DEFAULT 0 NOT NULL,
  rockets         INTEGER DEFAULT 0 NOT NULL,
  cells           INTEGER DEFAULT 0 NOT NULL,
  items           INTEGER DEFAULT 4097 NOT NULL,          -- IT_* bits: axe + shotgun
  weapon          INTEGER DEFAULT 1 NOT NULL,             -- the IT_ bit of the current weapon
  weaponframe     INTEGER DEFAULT 0 NOT NULL,
  attack_finished DOUBLE PRECISION DEFAULT 0 NOT NULL,
  pain_finished   DOUBLE PRECISION DEFAULT 0 NOT NULL,
  punchangle      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  view_ofs        DOUBLE PRECISION DEFAULT 22 NOT NULL,
  dmg_take        INTEGER DEFAULT 0 NOT NULL,
  dmg_save        INTEGER DEFAULT 0 NOT NULL,
  dmg_time        DOUBLE PRECISION DEFAULT 0 NOT NULL,
  bonus_time      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  invincible_finished  DOUBLE PRECISION DEFAULT 0 NOT NULL,
  invisible_finished   DOUBLE PRECISION DEFAULT 0 NOT NULL,
  super_damage_finished DOUBLE PRECISION DEFAULT 0 NOT NULL,
  radsuit_finished     DOUBLE PRECISION DEFAULT 0 NOT NULL,
  jump_released   SMALLINT DEFAULT 1 NOT NULL,
  fly_sound_time  DOUBLE PRECISION DEFAULT 0 NOT NULL,
  swim_time       DOUBLE PRECISION DEFAULT 0 NOT NULL,
  air_finished    DOUBLE PRECISION DEFAULT 0 NOT NULL,
  dmg_lava_time   DOUBLE PRECISION DEFAULT 0 NOT NULL,
  msg             VARCHAR(200),
  msg_time        DOUBLE PRECISION DEFAULT 0 NOT NULL,
  cprint          VARCHAR(200),                           -- centerprint
  cprint_time     DOUBLE PRECISION DEFAULT 0 NOT NULL,
  kills           INTEGER DEFAULT 0 NOT NULL,
  dead_time       DOUBLE PRECISION DEFAULT 0 NOT NULL,
  lightning_time  DOUBLE PRECISION DEFAULT 0 NOT NULL,
  show_hostile    DOUBLE PRECISION DEFAULT 0 NOT NULL,
  axhitme         SMALLINT DEFAULT 0 NOT NULL,
  impulse         SMALLINT DEFAULT 0 NOT NULL,
  pitch           DOUBLE PRECISION DEFAULT 0 NOT NULL,    -- view pitch, degrees (+down)
  idealpitch      DOUBLE PRECISION DEFAULT 0 NOT NULL,
  oldz            DOUBLE PRECISION DEFAULT 0 NOT NULL,    -- for the stair-step view smoothing
  stepz           DOUBLE PRECISION DEFAULT 0 NOT NULL,
  weapon_sound    SMALLINT DEFAULT 0 NOT NULL
);

-- S_StartSound: every sound the simulation makes, for the browser to play.
CREATE SEQUENCE sound_seq;
CREATE TABLE sound_events (
  id     INTEGER NOT NULL PRIMARY KEY,
  tic    INTEGER NOT NULL,
  ent_id INTEGER,                  -- a new sound on the same ent/channel cuts the old one
  chan   SMALLINT DEFAULT 0 NOT NULL,
  snd    VARCHAR(64) NOT NULL,
  vol    DOUBLE PRECISION DEFAULT 1 NOT NULL,
  attn   DOUBLE PRECISION DEFAULT 1 NOT NULL,
  x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION
);

-- Visual effects the browser draws for a moment: 1 gunshot puff, 2 explosion,
-- 3 blood, 4 lightning beam (to x2 y2 z2), 5 teleport splash, 6 spike hit, 7 lava splash, 8 tar explosion
CREATE SEQUENCE fx_seq;
CREATE TABLE fx_events (
  id   INTEGER NOT NULL PRIMARY KEY,
  tic  INTEGER NOT NULL,
  kind SMALLINT NOT NULL,
  x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION,
  n    INTEGER DEFAULT 0 NOT NULL
);

-- Monster definitions: the data side of ai.qc + each monster's .qc.
CREATE TABLE monster_types (
  name        VARCHAR(16) NOT NULL PRIMARY KEY,   -- classname without monster_
  model       VARCHAR(40) NOT NULL,
  head_model  VARCHAR(40),
  health      INTEGER NOT NULL,
  hull        SMALLINT NOT NULL,                   -- 1 or 2
  maxz        DOUBLE PRECISION NOT NULL,           -- 40 for hull 1 humanoids, 64 hull 2
  flags       INTEGER DEFAULT 0 NOT NULL,          -- FL_FLY 1, FL_SWIM 2
  run_speed   DOUBLE PRECISION NOT NULL,           -- units per anim frame while running
  walk_speed  DOUBLE PRECISION NOT NULL,
  yaw_speed   DOUBLE PRECISION NOT NULL,
  stand_anim  VARCHAR(16) NOT NULL,
  walk_anim   VARCHAR(16) NOT NULL,
  run_anim    VARCHAR(16) NOT NULL,
  pain_anims  VARCHAR(80) NOT NULL,                -- ',' separated alternatives
  death_anims VARCHAR(80) NOT NULL,
  melee_anim  VARCHAR(16),
  melee_frame INTEGER,                             -- frame of melee_anim that hits
  melee_range DOUBLE PRECISION DEFAULT 100 NOT NULL,
  melee_dmg   INTEGER,                             -- damage = melee_dmg * (1 + rnd 0..2) style varies
  missile_anim VARCHAR(16),
  missile_frames VARCHAR(40),                      -- ',' separated frames that fire
  missile_kind VARCHAR(16),                        -- shotgun grenade spike wspike lavaball lightning gib leap
  attack_chance DOUBLE PRECISION DEFAULT 0.3 NOT NULL,
  pain_chance DOUBLE PRECISION DEFAULT 1 NOT NULL,
  sight_snd   VARCHAR(64),
  idle_snd    VARCHAR(64),
  pain_snd    VARCHAR(64),
  death_snd   VARCHAR(64),
  attack_snd  VARCHAR(64),
  melee_snd   VARCHAR(64),
  gib_health  INTEGER DEFAULT -40 NOT NULL,
  drop_item   VARCHAR(16)                          -- backpack contents: shells / rockets
);

-- ── The QuakeC VM (sql/qcvm.sql): progs.dat as tables ──────────────────────
-- Statements (op, a, b, c), functions, global and field definitions, the string table, the global
-- image (loaded twice: qc_globals0 is the pristine copy that qc_reset restores), the edicts the
-- programs spawn with their fields, a log of what the builtins print, and the VM's own state.
CREATE TABLE qc_statements (
  id INTEGER NOT NULL PRIMARY KEY,
  op SMALLINT NOT NULL,
  a INTEGER NOT NULL, b INTEGER NOT NULL, c INTEGER NOT NULL
);
CREATE TABLE qc_functions (
  id INTEGER NOT NULL PRIMARY KEY,
  first_statement INTEGER NOT NULL,      -- negative: a builtin, -first_statement is its number
  parm_start INTEGER NOT NULL,
  locals INTEGER NOT NULL,
  name VARCHAR(64),                      -- function 0 has none
  file VARCHAR(64),
  numparms SMALLINT NOT NULL,
  p0 SMALLINT, p1 SMALLINT, p2 SMALLINT, p3 SMALLINT, p4 SMALLINT, p5 SMALLINT, p6 SMALLINT, p7 SMALLINT,
  shared SMALLINT DEFAULT 0 NOT NULL,        -- 1: its locals overlap another function's (FTEQCC): saved on every call
  active INTEGER DEFAULT 0 NOT NULL,         -- activations on the call stack: locals are saved only when re-entered (or shared)
  calls INTEGER DEFAULT 0 NOT NULL,          -- times entered through the interpreter: the hot ones get compiled (src/qcjit.js)
  compiled SMALLINT DEFAULT 0 NOT NULL       -- 1: runs as its own procedure, through the dispatcher qc_inv<numparms>; -1: cannot be
);
CREATE INDEX qc_functions_name ON qc_functions (name);
CREATE TABLE qc_defs (
  id INTEGER NOT NULL PRIMARY KEY,
  kind SMALLINT NOT NULL,                -- 0 global, 1 entity field
  type_ SMALLINT NOT NULL,               -- 1 string 2 float 3 vector 4 entity 5 field 6 function
  ofs INTEGER NOT NULL,
  name VARCHAR(64)
);
CREATE INDEX qc_defs_name ON qc_defs (kind, name);
CREATE TABLE qc_strings (
  ofs INTEGER NOT NULL PRIMARY KEY,      -- negative: a string made at run time (ftos, vtos)
  s VARCHAR(2048) CHARACTER SET ASCII              -- NULL is the empty string (the loader reads '' as NULL)
);
CREATE DESCENDING INDEX qc_strings_down ON qc_strings (ofs);   -- the string containing an offset: the nearest below
CREATE TABLE qc_globals0 (ofs INTEGER NOT NULL PRIMARY KEY, v DOUBLE PRECISION NOT NULL);
-- a function's parameters: callee slot dst ← src (OFS_PARM0 + 3·i + j)
CREATE TABLE qc_parmmap (
  fnum INTEGER NOT NULL,
  dst INTEGER NOT NULL,
  src INTEGER NOT NULL,
  PRIMARY KEY (fnum, dst)
);
CREATE TABLE qc_globals (ofs INTEGER NOT NULL PRIMARY KEY, v DOUBLE PRECISION NOT NULL);
CREATE TABLE qc_edicts (
  id INTEGER NOT NULL PRIMARY KEY,
  free SMALLINT DEFAULT 0 NOT NULL
);
CREATE TABLE qc_fields (
  ent INTEGER NOT NULL,
  ofs INTEGER NOT NULL,
  v DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ent, ofs)
);
-- In QuakeC mode the engine's own fields of an edict (origin, velocity, angles, the box, solid,
-- movetype, flags, frame…) live in its ents row, so that the physics, the traces and the renderer
-- work on QuakeC entities unchanged; the VM's field access routes these offsets to ents columns.
-- Empty outside QuakeC mode. col: 1..3 x y z, 4..6 vx vy vz, 7..9 pitch yaw roll, 10 avel_yaw,
-- 11..16 minx..maxz, 17 solid, 18 movetype, 19 flags, 20 frame, 21 skin, 22 effects, 23 model_id,
-- 24 ltime, 25 waterlevel, 26 watertype, 27 owner_id; read-only, computed: 31..33 absmin,
-- 34..36 absmax, 37..39 size; 40 the model string, kept in qc_fields, which shows or hides the model;
-- 28 enemy_id, 29 goal_id (goalentity), 41 ideal_yaw, 42 yaw_speed: what the monster movement reads.
CREATE TABLE qc_engine_fields (
  ofs INTEGER NOT NULL PRIMARY KEY,
  col SMALLINT NOT NULL
);
-- what crosses a level change (SV_SaveSpawnparms): the client's parms and serverflags, by global offset
CREATE TABLE qc_saved (
  ofs INTEGER NOT NULL PRIMARY KEY,
  v DOUBLE PRECISION NOT NULL
);
CREATE TABLE qc_log (
  id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kind VARCHAR(16) NOT NULL,             -- print, dprint, bprint, sprint, centerprint, sound, error, cmd, cvar_set, trace
  msg VARCHAR(1024)
);
CREATE TABLE qc_vm (
  id INTEGER NOT NULL PRIMARY KEY,
  depth INTEGER DEFAULT 0 NOT NULL,
  steps BIGINT DEFAULT 0 NOT NULL,
  max_steps BIGINT DEFAULT 5000000 NOT NULL,
  next_string INTEGER DEFAULT -1 NOT NULL,
  -- the globals and fields the VM itself touches (OP_STATE, makevectors, traceline, setorigin…)
  g_self INTEGER, g_other INTEGER, g_world INTEGER, g_time INTEGER, g_frametime INTEGER,
  g_vfwd INTEGER, g_vup INTEGER, g_vright INTEGER,
  g_trace_allsolid INTEGER, g_trace_startsolid INTEGER, g_trace_fraction INTEGER, g_trace_endpos INTEGER,
  g_trace_plane_normal INTEGER, g_trace_plane_dist INTEGER, g_trace_ent INTEGER, g_trace_inopen INTEGER, g_trace_inwater INTEGER,
  f_origin INTEGER, f_mins INTEGER, f_maxs INTEGER, f_size INTEGER, f_absmin INTEGER, f_absmax INTEGER,
  f_model INTEGER, f_modelindex INTEGER, f_classname INTEGER, f_chain INTEGER, f_angles INTEGER,
  f_ideal_yaw INTEGER, f_yaw_speed INTEGER, f_nextthink INTEGER, f_think INTEGER, f_frame INTEGER,
  -- the server frame (qc_server_frame)
  sv_time DOUBLE PRECISION DEFAULT 0 NOT NULL,
  f_touch INTEGER, f_blocked INTEGER, f_v_angle INTEGER, f_avelocity INTEGER, f_gravity INTEGER,
  f_teleport_time INTEGER, f_punchangle INTEGER, f_groundentity INTEGER, f_view_ofs INTEGER, f_health INTEGER,
  -- a temp entity being written (WriteByte SVC_TEMPENTITY, its type, then its coordinates)
  te_state SMALLINT DEFAULT 0 NOT NULL, te_type SMALLINT DEFAULT 0 NOT NULL, te_n SMALLINT DEFAULT 0 NOT NULL,
  te_c0 DOUBLE PRECISION, te_c1 DOUBLE PRECISION, te_c2 DOUBLE PRECISION, te_c3 DOUBLE PRECISION, te_c4 DOUBLE PRECISION, te_c5 DOUBLE PRECISION,
  -- checkclient's client: the PVS of its eye, kept for 0.1 s (sv.lastcheck, sv.lastchecktime)
  check_time DOUBLE PRECISION, check_pvs VARCHAR(2048) CHARACTER SET ASCII
);
-- checkclient's cache of each caller's eye leaf, by the eye's position (emptied with the level)
CREATE TABLE qc_eyeleaf (
  ent INTEGER NOT NULL PRIMARY KEY,
  x DOUBLE PRECISION NOT NULL, y DOUBLE PRECISION NOT NULL, z DOUBLE PRECISION NOT NULL,
  leaf INTEGER NOT NULL
);
CREATE GLOBAL TEMPORARY TABLE qc_localstack (
  depth INTEGER NOT NULL,
  ofs INTEGER NOT NULL,
  v DOUBLE PRECISION NOT NULL
) ON COMMIT PRESERVE ROWS;
CREATE EXCEPTION qc_error 'QuakeC runtime error';
