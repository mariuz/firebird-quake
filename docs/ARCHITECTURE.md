# How Firebird Quake is made

This is the long version of the README's "How it works": what runs where, how the data flows, what
each file and procedure is for, and the decisions that shaped them. Read it before changing the
engine. The companion documents are [ROADMAP.md](ROADMAP.md) (what is missing) and
[screenshots.md](screenshots.md) (every level, with the commands that rendered it).

## 1. The idea, and the division of labour

Quake's server (physics, game rules, monster AI) and the visibility half of its renderer run as PSQL
inside Firebird 6, compiled to WebAssembly and loaded in a browser Worker. JavaScript keeps only what
SQL cannot do: read the keyboard and mouse, paint pixels on a canvas, and play sounds.

| concern | where | entry point |
|---|---|---|
| one game tic (20 Hz) | PSQL | `SELECT * FROM quake_tic(tics, fwd, side, yaw_d, pitch_d, fire, jump, run, impulse)` |
| which faces are on screen | PSQL | `SELECT * FROM frame_faces_fast` (or `frame_faces`) |
| which models are on screen, posed | PSQL | `SELECT * FROM frame_ents` |
| light animation | SQL view | `SELECT * FROM frame_lightstyles` |
| what to play | tables | `sound_events`, `fx_events` (rows appended by the tic, read by id) |
| rasterising | JS | `src/renderer.js` |
| input, loop, UI, audio | JS | `src/main.js`, `src/audio.js`, `src/hud.js` |

Every piece of game state is a row. There is no JavaScript game state at all: the page could be
closed and reopened against the same database and the game would continue. This is also why the SQL
console on the page can change anything while playing.

## 2. Boot

`src/main.js` → `openDatabase()` creates a `FirebirdBrowser` (package `firebird-wasm`) backed by a
Worker running the engine; the Node scripts use `DirectTransport` instead, same API, no Worker. The
engine needs `SharedArrayBuffer`, so the page must be cross-origin isolated: the dev server sends the
COOP/COEP headers with `--coi`, GitHub Pages cannot, so `public/coi-serviceworker.js` installs a
service worker that re-issues every response with the headers after one reload.

`createSchema(db, sql)` in `src/loader.js` runs the SQL files in order, `SQL_FILES = schema,
physics, game, weapons, monsters, render, qcvm, bots, save, demo`, splitting each on `SET TERM`; the generated
`load_<table>` procedures follow the schema, and the generated save tables (`savedTablesSql`, section
6a) come just before `save.sql`. The order matters because
PSQL procedures must exist before a caller compiles: each file starts with stubs (`CREATE OR ALTER
PROCEDURE x (...) AS BEGIN END^`) for the procedures it calls before defining them, and the stub's
signature must match the real one exactly.

Then the page picks a data set (section 11), loads it with `loadResources`, and `startMap` loads a
level with `loadMap`.

## 3. The data pipeline (`src/pak.js`, `src/bsp.js`, `src/mdl.js`, `src/loader.js`)

`Pak` reads a PAK directory; `PakSet` merges several paks with the same interface, later paks
shadowing earlier ones (pak0 + pak1). `Wad2` reads `gfx.wad` for the status bar pictures and the
console font; `loadPalette` the 256 RGB colours.

`Bsp` parses BSP version 29 only. It produces, for the SQL side: planes folded into faces (the plane
flipped for `side`), texture info and miptex, the lightmap bytes per face, the ordered vertex list per
face (edges and surfedges resolved), leaves with their contents, bounding box and the PVS run-length
decoded into a hex string, marksurfaces, nodes (hull 0) and clipnodes (hulls 1 and 2) with their planes
copied in, submodels (`*N`), the entity lump parsed into objects, and the texture names for the sky.

`Mdl` parses `.mdl`: skins (first of a group), vertices as `(x, y, z, normalIndex)` bytes per frame,
frame groups flattened to their first frame with the group kept for the painter, and `animations()`:
consecutive frames whose names share a prefix (`run1`…`run6`) become one named run. LibreQuake's
models name frames `1`, `2`… so the loader substitutes the id layout (section 3.1).

`loader.js` holds `TABLES`, a one-line spec per table (`name:type` columns). From it the loader
*generates* a `LOAD_<table>` PSQL procedure that parses `|`-separated lines, and `bulkLoad` feeds
text chunks of 30 KB to it. The WASM build binds parameters only as text; this beats `EXECUTE BLOCK`s
of `INSERT`s by about 2.5×, and E1M1 (70 k rows) loads in two seconds.

`loadResources(db, pak, view)` loads what does not change between maps: every `.mdl` and `.spr`,
the `b_*.bsp` item boxes, `monster_types` from `src/gamedata.js`, the light styles, `viewcfg`, and
the `game` row with the `registered` flag (set when `maps/e2m1.bsp` exists). It returns `res`: models
by id and by name, with the parsed `Mdl` for the painter.

`loadMap(db, pak, res, name, { skill })` clears the per-map tables, loads the BSP tables, runs
`init_map` (worldspawn message and type, gravity, `spawn_map_ents(skill)`), and returns the `Bsp`
for the painter (which keeps textures, lightmaps and vertices in JavaScript; the SQL side has the
same vertices for the slow renderer mode).

### 3.1 Frame layouts

`src/framelayouts.js` is generated by `npm run gen-frame-layouts` from paks with named frames: for
each model, its frame count and the list of `(anim, first, count)`. `animationsOf()` in the loader
uses it for any model whose frames carry no names and whose frame count matches. QuakeC addresses
frames by number, so any model that works with the original `progs.dat` has the same layout.

## 4. The schema (`sql/schema.sql`)

Static per map:

- `faces (id, model_id, nx, ny, nz, dist, nverts, miptex, sx, sy, sz, soff, tx, ty, tz, toff, sky, liquid, style0..3, cx, cy, cz, radius, lm_off, lm_w, lm_h, …)`: a face with its plane, texture mapping, light styles and a bounding sphere for frustum tests.
- `face_verts (face, seq, x, y, z)`: primary key `(face, seq)` yields the polygon's vertices in order.
- `leaves (id, contents, minx..maxz, first_ms, num_ms, ambient, ambient_sky, pvs)`: `pvs` is a hex string; leaf *j* is visible when bit *j−1* is set, low nibble first.
- `marksurfaces (id, face)`, `hulls (model_id, hull, id, planenx..dist, child0, child1)`: hull 0 is the nodes (children `-(leaf)-1` for leaves), hulls 1 and 2 share the clipnodes.
- `miptex`, `map_ents (id, classname, the common keys as columns)`, and `map_keys (ent, k, v)`, every key of every entity as written: QuakeC mode sets each one that names a field (`ED_ParseEpair`: strings, floats, vectors, functions), so a mod's or LibreQuake's extra keys (a boss's `armorvalue`) arrive.
- `models (id, name, kind, hull0, hull1, hull2, minx..maxz, …)`: the world, its submodels, boxes, alias models and sprites, all in one id space.
- `anims (model_id, anim, first_frame, frame_count)`.

Dynamic:

- `ents`: the edict table, one wide row per entity: origin, velocity, angles, bounding box (`minx..maxz`), `model_id`, `frame`, `anim`, `anim_frame`, `health`, `flags`, `solid`, `movetype`, `think`/`nextthink`, `touch`, `st` (state), the mover fields (`mv_state`, `p1`/`p2`, `dst`, `speed`, `wait`, `lip`, `linked_id`, `noise1..3`), AI fields (`mtype`, `enemy_id`, `goal_id`, `ideal_yaw`, `attack_state`, `attack_finished`), `items`, ammo, `leaf`/`leafs` (the leaves the box touches, for the PVS), `waterlevel`/`watertype`, `owner_id`, `target`/`targetname`, `spawn_x/y/z`, `effects`, `alpha`.
- `player`: the client's extras (`ent_id`, `pitch`, `view_ofs`, `weapon`, `weaponframe`, `attack_finished`, `punchangle`, `air_finished`, powerup times, `jump_released`, damage flash…).
- `game`: `tic`, `time_`, `map_name`, `next_map`, `exit_kind`, `skill`, `world_model`, totals (monsters, secrets, kills), `serverflags`, `world_type`, `level_msg`, `registered`, `finale`, `gravity`, `intermission_tics`.
- `viewcfg (w, h, fov, near_z, vis_leaf)`; `vis_faces (face, ent_id, ox, oy, oz)` the current leaf's marked faces; `sel_faces` (GTT) this frame's pre-filter.
- `sound_events (id, tic, ent_id, chan, snd, vol, attn, x, y, z)`, `fx_events (id, tic, kind, x, y, z, dx, dy, dz, n)`: kept for 40 tics (two seconds) by `quake_tic`.
- `lightstyles (style, pattern)`, `monster_types` (section 8).
- Global temporary tables, because PSQL has no arrays: `clip_planes` (fly_move's bumps), `pushed` (what a pusher carried), `sel_faces`.

Conventions: angles in degrees (`yaw`, `pitch`), Quake units, times in seconds as `DOUBLE PRECISION`,
`BIN_AND`/`BIN_OR` for flags, `ents.flags` bit 512 = resting on the ground (FL_ONGROUND), 2048 =
water jump, 64 = god.

## 5. Physics (`sql/physics.sql`)

A direct port of `world.c` and `sv_phys.c`:

- `point_leaf(x, y, z)` walks hull 0; `hull_contents(hull, node, x, y, z)` walks a clip hull; `point_contents` is the world's hull 0 contents (`-1` empty, `-2` solid, `-3` water, `-4` slime, `-5` lava, `-6` sky). Clip hulls carry no liquid contents, so water levels use the point hull.
- `pvs_visible(pvs, leaf)` tests one bit of the hex string.
- `rhc(...)` is `SV_RecursiveHullCheck`: it splits the segment at each plane and recurses into both sides, threading the whole trace state (`allsolid`, `startsolid`, `inopen`, `inwater`, fraction, end point, hit plane) through its parameters, since PSQL procedures can recurse but cannot share arrays.
- `trace_hull(hull, head, ...)` runs `rhc` from a hull's head node, offsetting by the entity's origin.
- `trace_box` clips a moving box against another entity's box (Minkowski sum, slab test).
- `trace_move(ent, minx..maxz, from, to, nomonsters)` picks the hull by the box size (point, player, or the big hull), runs the world, then every brush-model entity at its own origin with its own hull, then monsters and the player as boxes; returns `fraction`, end point, `hit_ent`, normal, `allsolid`, `startsolid`, `inwater`. Note the mapping `trace_hull(IIF(hull = 0, 0, 1), …)`: hulls 1 and 2 are both stored under hull row 1 since they share clipnodes; the hull number only selects the head node.
- `test_position`, `link_ent` (recomputes `leaf` and `leafs` for the PVS and the touch loop: `box_leafs` is `SV_FindTouchedLeafs`, one recursive query that walks the BSP tree down both sides of every plane the box straddles, carrying the origin along so that its leaf comes out of the same walk; it replaced ten point walks, the corners, the centre and the origin, and made `link_ent` four to five times cheaper), `check_water` (waterlevel 0..3 and watertype from the point hull), `clip_velocity` (slide along a plane with overbounce).
- `fly_move(ent, dt)`: up to four bumps, planes collected in `clip_planes`, the velocity clipped against each and against pairs (crease); returns the blocked bits and the entity hit.
- `walk_move`: the player's step: try the move, if blocked try from 18 units up and settle down, with the step-smoothing that the client applies.
- `move_step(ent, dx, dy, dz)`: monsters' step with the drop-to-floor check (no walking off ledges, flying and swimming variants by the type's flags).
- `toss_move`: gravity (`game.gravity`), bounce (`movetype` 10), rest when landing on a floor (flag 512), the entity is only relinked when it moved: items at rest cost nothing per tic.
- `push_entity`/`push_move`: a pusher (door, plat, train) moves, carrying what stands on it and crushing or blocking on what it hits (`mover_blocked`), with the `pushed` table to undo a blocked move.

## 6. The game (`sql/game.sql`)

- `spawn_map_ents(skill)`: walks `map_ents`, drops entities by skill flags and deathmatch, applies the registered-only gates (`trigger_onlyregistered`, `func_episodegate`, `func_bossgate`), and spawns each class: `light_*` and `ambient_*` as point entities that only the audio reads, `func_*` movers with their sounds, speeds and positions (`calc_move`, START_OPEN, `lip`, `wait`), `trigger_*` as non-solid boxes with `touch`, items with their box model (`b_*.bsp`) and `drop_to_floor`, keys by `world_type`, weapons, `misc_*`, `trap_spikeshooter`, `path_corner`, `info_*`, and every `monster_*` through `spawn_monster` by the class suffix. Doors that touch are linked (`linked_id`) so a pair opens as one.
- Pushers (`push_move`, `SV_PushMove`): what stands on or is caught by a moving brush model moves with it, or blocks it; on a sinking one a walker (the player) follows by gravity and everything else rides down; what it carries touches the triggers it is carried into. A `trigger_hurt` hurts monsters as well as the player, resting a second after each hit.
- Movers: `door_*` (`door_touch` with the two-second debounce via `attack_finished`, key checks with the metal/base/medieval messages, `door_fire`/`go_up`/`go_down`/`hit_top`/`hit_bottom`), `plat_*`, `button_*`, `train_*` with `path_corner` targets, `secret_*` (the six-step secret door). All use `mv_state` 0 top, 1 bottom, 2 up, 3 down, and `SUB_CalcMove` semantics: a destination, a speed, and `ltime`-based arrival.
- Triggers: once, multiple (with `wait`), relay, counter, secret, teleport (`teleport_touch`, telefrag by box overlap), push, hurt, monsterjump, setskill (the start map's halls: the player's touch sets `game.skill` to the hall's message, which the tic's `skill` column hands to the page for the next level, as Quake's `localcmd("skill N")` does; in QuakeC mode `localcmd` keeps a console buffer in `qc_vm.cmdbuf` and runs `skill N` lines), changelevel (`changelevel` sets `next_map` and `exit_kind`, and, as `execute_changelevel`, moves the player to an intermission camera: one of the `info_intermission` spots of `map_ents` at random, else the start, looking along its `mangle` with `view_ofs` 0; `player_think` does nothing while `game.intermission` is set, so the camera holds; CD track 3), message, onlyregistered. `use_targets(ent, activator)` fires everything with a matching `targetname`, by class; `delayed_use` through a think.
- Items: `item_touch` gives health (with the mega-health rot), armour, ammo (`bound_ammo`), weapons (`best_weapon`), keys, sigils, powerups, backpacks; respawn is deathmatch-only and absent.
- Combat: `t_damage(target, inflictor, attacker, dmg)` with armour absorption, god mode, the damage momentum, pain (`monster_pain`), death (`killed` → `monster_die`, gibs through `throw_gib`/`throw_head`, kill count); `t_radius_damage` for explosions. On skill 3 (`nightmare()`) a monster gets no wait before attacking (`found_target`, `check_attack` and the return to the player leave `attack_finished` alone, as `SUB_AttackFinished` does) and, once hurt, no pain animation for five seconds (`t_damage` sets `pain_finished`, as `T_Damage` does); it spawns the hard skill's entities. A monster hurt by anything but the world, itself or the enemy it already has gets mad at the attacker (`found_target(eid, enemy)`: the sight sound, the run, a second before the first attack) unless the attacker is of its own class, soldiers excepted, as `combat.qc`'s `T_Damage` has it; a monster that was hunting the player keeps it in `oldenemy_id`, and when its enemy dies it goes back to the player (`ai_run`'s `HuntTarget`). So an ogre's grenade turns a knight on the ogre, two grunts can shoot it out, and a barrel's blast turns monsters on the barrel for as long as it lasts (`scripts/infight-test.mjs`).
- Projectiles: `launch_spike`/`launch_grenade`/`launch_rocket` create tossed or flying entities whose `impact(e1, e2)` does the class-specific thing: spikes and the three monster spike kinds, rockets, lasers, vore balls, lava balls, fireballs, grenades (bounce, explode on a timer or on a monster), zombie gibs, and the player bumping doors, secret doors, buttons, and taking fall damage.
- Messages and sound: `cprint` (centre print, two seconds) and `sprint` write to `game`; `snd(ent, chan, name, vol, attn)` and `snd_at(x, y, z, ...)` append `sound_events`; `fx(kind, ...)` appends `fx_events` (explosions, blood, gunshot, teleport, lightning, lava splash…). Names picked with `IIF`/`CASE` are `TRIM`med (section 13).

## 6a. Save games (`sql/save.sql`, `src/saves.js`)

A game's whole state is rows: `game`, `player`, `ents`, `lightstyles`, and in QuakeC mode
`qc_globals`, `qc_fields`, `qc_edicts`, the run-time strings (`qc_strings` with `ofs < 0`), `qc_vm` and
`qc_saved`. Everything else is the map, the pak or `progs.dat`, which a load reads again.

- **The copies**: `savedTablesSql(db)` in `src/loader.js` reads those tables' columns from
  `RDB$RELATION_FIELDS` after the schema exists and generates `sv_<table>` (a `slot` in front of the
  same columns) and three procedures: `save_tables(slot, qc)`, `restore_tables(slot, qc)` and
  `drop_saved(slot)`, each an `INSERT … SELECT` per table. A column added to `ents` is saved without
  touching them. (DDL through `EXECUTE STATEMENT` does not take effect in this engine build, so the
  generation is in JS, as the `load_<table>` procedures are.) The list is `SAVED_TABLES`.
- **`save_game(slot)`** (`Host_Savegame_f`): refuses a dead player (`deadflag`, or QuakeC's
  `deadflag`/`health` fields) and the intermission, writes the slot's `saves` row (the map, the mode,
  the skill, the time, `world_model`, the `ent_seq` value, and `SaveGame_Comment`'s 22-column level
  name with the kills, which the menu lists), and copies the rows. Slots 0 to 11 are the menu's, 12 is
  `quick.sav` (F6, F9).
- **`load_game(slot)`** (`Host_Loadgame_f`) runs after the page has loaded the save's map (and for a
  QuakeC save entered QuakeC mode with `qc_enter`, skipping the spawn): the rows come back; the brush
  models are renumbered, because `loadMap` gives each load of a map new model ids (`res.nextModel`
  only grows), so every `model_id` at or above the saved `world_model` moves by the difference (the
  alias models, sprites and item boxes are loaded once per data set and keep theirs); `ent_seq` goes
  back with `GEN_ID`; the moment's leftovers go (`sound_events`, `fx_events`, `vis_faces` with
  `viewcfg.vis_leaf`, the VM's local stack, `checkclient`'s caches). A PSQL save leaves QuakeC mode.
- **The browser's copy**: the database is in memory, so `exportSave` (`src/saves.js`) reads a slot's
  rows into an object (`{ version, slot, meta, tables: { ents: { cols, rows } … } }`), and the page stores it
  in IndexedDB under `<data set>/<slot>`, since model ids depend on the paks. `importSave` writes it
  back into the `sv_` tables with `EXECUTE BLOCK`s of literal `INSERT`s (150 rows a block: a block may
  hold 255 table contexts). Firebird's text-to-double conversion is not correctly rounded (about one
  value in ten comes back a unit in the last place off, as a literal or as a text-bound parameter), so a
  fraction is written as its integer mantissa times a power of two, `CAST(m AS DOUBLE PRECISION) *
  POWER(2e0, e)`, which comes back bit for bit.
- **The page** (`saveGame`, `loadGame` in `src/main.js`): the menu's Load and Save list the twelve
  slots; a load switches the **Logic** and the skill to the save's and calls `startMap(map, true,
  save)`, which imports and loads after the geometry instead of spawning. `scripts/save-test.mjs` saves
  E1M1 mid-play and checks that a load brings back every entity, the client, the totals and the light
  styles exactly, in the session and after an export, another level, and E1M1 loaded again.

## 6b. Random numbers and demos (`physics.sql`'s `rnd`, `sql/demo.sql`, `src/demos.js`)

- **`rnd()`** is the game's only source of randomness: a linear congruential generator
  (`seed · 1103515245 + 12345 mod 2³¹`) kept in the one-row `rng` table, about 12 µs a call against
  `RAND()`'s 1 (a few dozen calls a tic). `init_map` seeds it from `rng.next_seed` (set by `loadMap`'s
  `seed` option) or from `RAND()`, keeps that in `rng.level_seed`, and numbers the edicts from 1 again
  (`ent_seq`). QuakeC's `random()` builtin calls it too. `rng` is one of the saved tables, so a load
  goes on with the same numbers.
- **Determinism**: with no clock (time is the tic count) and no other randomness, a level spawned with
  the same seed and fed the same tic arguments is the same game bit for bit: checked over hundreds of
  tics of fighting, in a fresh database and in one that has played other levels (row placement does
  not leak into the results), in the PSQL game and in QuakeC mode, interpreted or with every function
  compiled.
- **Recording**: `demo_record` (only at tic 0) stores the level's map, skill, logic and `level_seed` in
  the `demo` row and turns recording on; `quake_tic` and `qc_tic` first call `demo_note`, which then
  appends their nine arguments to `demo_tics`; `demo_stop`, or the next `init_map`, ends it.
- **Playback** is the page's: `loadMap` with the demo's seed (and `qc_begin_map` for a QuakeC demo),
  then `DemoPlayer.take(tics)` gives the loop the recorded calls that fill the frame's tics, in place
  of the keyboard and mouse. The page's **Demo** buttons record (the current level again, as a new
  game), stop, play, and save the demo as `<map>.dem.json`; the file picker plays one. The last demo is
  kept in IndexedDB beside the saves. `exportDemo`/`importDemo` write the doubles exactly, as the saves
  do.

## 7. The player (`sql/weapons.sql`)

`player_think(dt, fwd, side, yaw_d, pitch_d, fire, jump, run, impulse)` is `client.qc` and
`sv_user.c` in one procedure, in this order: angles; water level and drowning (air runs out after 12 s,
damage every second after); the water jump (FL_WATERJUMP: pushing against a ledge from the water
with the waist blocked and the head clear gives an upward kick); jumping with the `jump_released`
latch; friction (ground, or water); acceleration (walk, air, swim, with the swimming forward vector
following the pitch); gravity unless water-jumping; `walk_move` or `fly_move`; step smoothing; the
touch loop over triggers, items, door fields and plat fields that overlap the player's box; powerup
expiry; the weapon frame; the player model's animation. `player_fire` is each weapon from the axe to
the thunderbolt (`fire_bullets` with the spread table, `lightning_damage` as a 600-unit trace),
`player_impulse` the weapon selects, cycle and 9 (everything). `view_vectors` gives forward, right and
up from the player's angles.

`quake_tic` (in `monsters.sql`) runs `tics` of this and returns one row with everything the page
needs: position, view height, angles, health, armour, ammo, items, the current weapon and frame, the
centre print, the level message, the leaf and its ambients, exit and finale flags, kill and secret
counts, damage taken for the flash.

## 8. Monsters (`sql/monsters.sql`)

`monster_types` (from `src/gamedata.js`) describes each of the fifteen monsters: model, head model,
health, hull size, flags (fly, swim), speeds, the animation names for stand/walk/run/melee/missile,
pain and death animations, the missile kind, attack and pain chances, the sounds. The code is the
state machine from `ai.qc` with one `CASE` per monster where they differ:

- `st` is the state: `stand`, `walk`, `run`, `missile`, `melee`, `pain`, `die`, `dead`, `cruc` (the crucified zombies), `asleep` (Chthon before the rune).
- `monster_think` runs every 0.1 s (`nextthink`, compared with a 1 µs tolerance since floating-point time drifts): `set_anim`, the animation frame step, `find_target` (sight and sound), `found_target`, `change_yaw` towards `ideal_yaw`, `move_to_goal` (`new_chase_dir`, `step_direction`, `facing_ideal`), `check_attack` (range and `visible`/`infront`), then `monster_missile` (shotgun, grenade, wizard spike, zombie gib, lava ball, lightning, leap, laser, knight spike, vore ball) or `monster_melee`. A monster far from the player and out of its PVS thinks at 3 Hz and strides further.
- `monster_pain` picks a pain animation (zombies fall down from a hard hit and get up), `monster_die` the death one, drops a backpack for the soldiers and ogres, gibs below the gib health, and counts the kill.
- Specials: `boss_awake` and the `event_lightning_fire` dance (the lightning only hurts Chthon with both terminals up), `tarbaby_explode`, `vore_track` (the homing ball), the oldone's death by telefrag, the fish's water bounds, `teleporttrain_next`.
- `spawn_monster(name, dist)` is selectable: it spawns one ahead of the player and returns its id (the console's buttons and the screenshot tool use it).
- `run_pushers(dt)` moves the movers, `run_think(t)` runs due thinks (`remove`, `delayed_use`, `grenade_explode`, `fireball_think`, `shooter_think`, …), `run_physics(dt)` moves everything that flies, bounces or falls, skipping what rests.
- `init_map(name)` sets `game` from worldspawn (message, type, gravity 100 on E1M8) and spawns.

## 8a. The QuakeC VM (`src/progs.js`, `sql/qcvm.sql`)

The game in sections 6 to 8 is a rewrite of `progs.dat`; the VM is the start of running the original
bytecode instead.

- `Progs` parses `progs.dat` version 6: statements `(op, a, b, c)` with signed 16-bit operands, functions (first statement, parameter start, number of locals, name, file, parameter sizes), global and field definitions (type, offset, name), the string table split at NULs into `(offset, text)` rows, and the global image, typed by the definitions so that string, entity, field and function references load as integers and everything else as floats.
- Tables: `qc_statements`, `qc_functions`, `qc_defs` (kind 0 global, 1 field), `qc_strings` (negative offsets for strings made at run time by `ftos`/`vtos`), `qc_globals0` (pristine) and `qc_globals` (live), `qc_edicts`, `qc_fields (ent, ofs, v)`, `qc_log` (what the print builtins wrote), `qc_vm` (depth, step counter and limit, the next runtime string, and the cached offsets of `self`, `time`, `v_forward`, the `trace_*` globals and the fields the VM touches), and the temporary `qc_localstack`.
- Values: every global and field is one `DOUBLE PRECISION`; integers (entities, function and string references) are exact in it. An entity reference is the edict number (0 = world, 1 = the player). `OP_ADDRESS` makes `ent * 4096 + field`, which `OP_STOREP_*` decodes. In `OP_LOAD_*` and `OP_ADDRESS`, operand `b` is a global holding the field offset, as in `pr_exec.c`.
- `qc_exec(f, depth)` is the interpreter (`qc_call(f)` calls it one level above the current depth and adds up the statements it ran). Every global exists (the image is loaded whole, zeros included), so a statement costs one query, the opcode with both operand values by `LEFT JOIN`s on `qc_globals`, and at most one `UPDATE` of the result; branches cost nothing more. Entering a function is one `UPDATE qc_functions … RETURNING` (its entry point, locals and parameter count, and one more activation counted), one `MERGE` from `qc_parmmap` for the parameters (`OFS_PARM0` + 3·i + j into the callee's slots, precomputed at load), and leaving is one `UPDATE` of the count: the locals are saved to `qc_localstack` and restored, as sets, only when the function is already running further up the stack (recursion, such as `SUB_UseTargets` firing a relay that uses targets again), since nobody else reads a function's locals, or when its locals overlap another function's (`qc_functions.shared`, computed by `Progs`): FTEQCC lays out the locals of functions on top of each other (191 of LibreQuake's 193), counting on Quake's `PR_EnterFunction` to save the callee's range and `PR_LeaveFunction` to restore it, as id's qcc never needs. `OP_CALLn` recurses into `qc_exec`; `OP_RETURN`/`OP_DONE` copy three slots to `OFS_RETURN` (global 1) and leave. Jumps are `pc + b - 1` after the increment, as in Quake. A limit of 5 million statements per activation stops runaway loops; `qc_error` is raised for a null function, a bad opcode, `error()` and missing builtins. A builtin that calls back into QuakeC (`walkmove`, `movetogoal`, through the triggers they touch) finds the depth in `qc_vm`, set just before it runs. `npm run bench:qc` measures it: 13.5 µs a statement (33.5 before this design), 37 ms an E1M1 server frame with the monsters asleep and 43 ms with grunts awake (60 and 85 before). `qc_str` once cost 2.4 ms: `ORDER BY ofs DESC` on an ascending primary key sorted the whole string table on every call; it now looks the offset up exactly first, and a descending index (`qc_strings_down`) finds the string a mid-string offset falls in.
- **Compiled QuakeC** (`src/qcjit.js`). Each QuakeC function can become a stored procedure of its own, `QCF_<tag>_<n> (d, a0 … a3k-1) RETURNS (o0, o1, o2)`: its depth, three arguments per parameter, the three slots of `OFS_RETURN` (the tag is a hash of the statements, so another `progs.dat` gets other names). The compiler sorts every global slot a function touches. `OFS_RETURN` and the parameter slots (1 to 27) are variables `r1 … r27`, passed as procedure arguments. The function's parameters and the slots that are its own are variables `v<ofs>`: written here, and either used by no other function or read before written by none, so they never carry a value between functions (id's qcc gives each function its own temporaries, FTEQCC shares them), and, in a function whose locals overlap others' (saved and restored around every call), whatever it writes in its own range; a slot live across a call, or read before it is written, stays a global, since a QuakeC local keeps its value between calls. Every slot that no statement writes (immediates, field offsets, function numbers, named constants) is a literal. The rest (`self`, `time`, every global that carries values) stays in `qc_globals`, read by `qc_g` into a variable `m<ofs>` kept until the next call or join, and written through by `qc_sgu`. Fields go through `qc_f`/`qc_sf` when `qc_enter` routes them to `ents`, and straight to `qc_fields` (`qc_fq`, `qc_sfq`) otherwise; an `OP_ADDRESS` whose field is a constant lets the following `OP_STOREP` name it. Control flow is rebuilt from the jumps: a labelled `WHILE` loop for each backward target (to its last jump back, stretched so that overlapping loops nest), a labelled block for each forward target (opened early enough that all regions nest), `CONTINUE L<t>` and `LEAVE B<t>` for the jumps; a function whose flow does not nest that way (FTEQCC's `switch` jumps forward to a dispatch that jumps back into the cases) becomes a loop over its basic blocks with a `pc_` variable. Calls: a builtin gets its arguments in `OFS_PARM0…` (`qc_setp1` … `qc_setp8`, one `UPDATE`) and is called directly, `OFS_RETURN` read back only when the code uses it (`qc_ret`); a compiled function is called by name with its arguments; anything else (a function not compiled yet, or one called through a field such as `self.th_run`) goes through the dispatcher of its arity, `qc_inv0` … `qc_inv8`, a binary tree of branches to the compiled procedures that falls back to the interpreter. `qc_exec` itself hands a compiled function to its dispatcher, so the engine's calls (`qc_call`) reach compiled code too.
- Firebird in WASM runs no dynamic SQL from PSQL (`EXECUTE STATEMENT` does nothing), and a procedure may name at most 256 tables, so the compiled code calls only functions and procedures, and the DDL comes from JavaScript: `QcJit.compileHot()` takes the hottest functions not compiled yet (`qc_functions.calls`, counted by `qc_exec`), sends their procedures, rewrites the dispatchers of their arities and flags them `compiled = 1` (`-1` for one that cannot be compiled, left to the interpreter). The page compiles what the spawn ran more than once after loading a level, then the three hottest every second; compiling all of a `progs.dat` takes 10 to 20 s (6 to 10 ms a function). Compiled code runs a statement in about 2.5 µs (`anglemod`'s loop) against 13.5, and an E1M1 server frame takes 15 to 22 ms with the monsters asleep and 21 to 26 ms with grunts awake (25 to 35 and 33 to 44 interpreted). Profiling the frame (procedures renamed and wrapped in timing wrappers that add up `CAST('NOW' AS TIMESTAMP)` differences) found the engine's share: `link_ent` took 1.7 ms of a monster's 2.5 ms step (ten point walks of the BSP, now one box walk), `checkclient` 0.4 ms (now its offsets come with the `qc_vm` row and each caller's eye leaf is kept in `qc_eyeleaf` while it stands still), and each think set `self`, `other` and `time` and read and cleared `nextthink` with six statements (now two). What is left of a frame is the monsters' steps (`trace_move`, about 0.5 ms), the client's physics (3 to 4 ms) and the calls themselves.
- `qc_builtin(n)`: `makevectors`, `setorigin`, `setmodel` (with the model's bounds when it is loaded), `setsize`, `random`, `sound` (logged), `normalize`, `error`, `vlen`, `vectoyaw`, `spawn`, `remove`, `traceline` (against the loaded world's hull 0 through `trace_hull`, filling the `trace_*` globals), `find`, `findradius` (the `.chain` list), the `precache_*` no-ops, the prints, `ftos`/`vtos`, `walkmove` (unchecked), `droptofloor` (stays), `lightstyle` (writes `lightstyles`), `rint`/`floor`/`ceil`/`fabs`, `cvar` (a few known names), `nextent`, `changeyaw`, `vectoangles`, `pointcontents`, `makestatic`, `cvar_set`, `centerprint`, `ambientsound`; the `Write*` network builtins do nothing. Anything else raises.
- `qc_run(name, self)` sets `self` and calls by name; `qc_reset` restores the globals, makes the world and the player edicts and caches the offsets.

- `qc_spawn_map(skill, t)` is `ED_LoadFromFile`: every `map_ents` row that the skill flags keep becomes an edict (worldspawn is edict 0) with its keys written to the fields the progs declare (`classname`, `targetname`, `target`, `killtarget`, `model`, `origin`, `angles` from `angle` or `mangle`, `spawnflags`, `message`, `wait`, `delay`, `speed`, `lip`, `health`, `light_lev`, `style`, `sounds`, `dmg`, `height`, `count`, `map`, `noise`, `worldtype`; strings through `qc_newstr`), then `self` is set and the function named by the classname runs. A spawn function that raises is caught per entity (`WHEN ANY`, which also rolls back its half-written fields), logged with the engine's message, and its edict freed. E1M1: 336 functions run in about a second, 162 edicts remain (lights without a targetname remove themselves, doors rename themselves `door`, plats `plat`).
- `qc_frame(t, dt)` is the QuakeC half of `SV_Physics`: `time` and `frametime` set, `StartFrame` called, then every live edict whose `nextthink` is in `(0, t]` has it cleared and its `think` called with `self` set and `time` at the think's own time, as `SV_RunThink` does; the walk is by edict id so thinks that spawn or free others are safe. Five frames on E1M1 run `PlaceItem` for the items, `walkmonster_start_go` and the first `*_stand` frames (through `OP_STATE`) for the monsters, and `LinkDoors`.

- The client: `qc_client_connect(t)` makes edict 1 the player (`netname` set) and runs `SetNewParms`, `ClientConnect` and `PutClientInServer`, which find the `info_player_start`, set the player up and run `W_SetCurrentAmmo` and `player_stand1`. `qc_player_frame(t, dt, pitch, yaw, fire, jump, impulse)` writes the input into `button0`, `button2`, `impulse` and `v_angle`, then runs `PlayerPreThink` and `PlayerPostThink`; the engine's movement belongs between them and is not wired. `W_WeaponFrame` holds an impulse until `attack_finished`. `qc_touch(e, other)` delivers a touch (`self = e`, `other`, `e.touch()`), which the physics will call when boxes meet.

- **QuakeC mode** (`qc_enter`, `game.qc_mode = 1`): the VM owns `ents`. `qc_engine_fields` maps the offsets of the engine's own fields to `ents` columns (origin, velocity, angles, `avelocity_y`, mins, maxs, solid, movetype, flags, frame, skin, effects, modelindex as `model_id`, ltime, waterlevel, watertype, owner; absmin, absmax and size computed from the box, items growing by 15 sideways as `SV_LinkEdict` does; the `model` string stays in `qc_fields` but showing or hiding the model, as the server sends only entities with one). `qc_f`/`qc_sf` route those offsets, everything else stays in `qc_fields`; the map is empty outside QuakeC mode, so the routing costs one primary-key miss. `qc_spawn` and `qc_free` create and delete the `ents` row with the edict (the edict number is the `ents` id; the world, edict 0, has none: the traces use the world model directly), and `qc_enter` wipes the PSQL game's entities, keeps the map's geometry, and points the camera's `player` row at edict 1. `setorigin`, `setsize` and `setmodel` link the entity for the PVS; `droptofloor` traces 256 units down; `traceline` uses `trace_move` and so hits monsters (`trace_ent`); `sound` also goes to `sound_events`; `cvar_set("sv_gravity")` sets the gravity.
- **The physics** reuse the PSQL engine's procedures, which work on `ents`: `trace_move`, `fly_move`, `walk_move`, `push_entity`, `push_move`, `check_water`, `link_ent`. Their two callbacks, `impact` and `mover_blocked`, dispatch to `qc_impact` (`SV_Impact`: both sides' `touch`) and `qc_blocked` (the pusher's `blocked`) in QuakeC mode. `qc_server_frame(t, dt, forward, side, up, pitch, yaw, fire, jump, impulse)` is `Host_ServerFrame`: `qc_client_think` (`SV_ClientThink`: the input into `button0`, `button2`, `impulse`, `v_angle`; `DropPunchAngle`; the body's angles; `SV_AirMove` with `SV_UserFriction` (doubled at an edge) and `SV_Accelerate`, `SV_AirAccelerate`, or `SV_WaterMove`), then `StartFrame`, then every edict that may have work, in edict order, by movetype: `qc_physics_client` (`PlayerPreThink`, the think, gravity unless swimming or water-jumping, `walk_move`, the triggers, `PlayerPostThink`), `qc_physics_pusher` (`SV_Physics_Pusher`: the move and the think on the pusher's `ltime`), `qc_physics_step` (monsters fall when nothing holds them, landing with `demon/dland2.wav`), `qc_toss` (toss, bounce, fly and missiles, the touch's own changes to velocity and movetype respected before the bounce), noclip, and plain thinks (`qc_run_think`: due if `nextthink` is within the frame, run at its own time). `qc_touch_triggers` is `SV_TouchLinks`. An edict whose QuakeC raises is logged and skipped for that frame.
- `scripts/qcvm-play-test.mjs` plays E1M1 this way: 336 spawn functions, the items and monsters dropped to the floor, the player falling for the time `sqrt(2h/800)` predicts, walking at sv_maxspeed with each friction step matching Quake's formula (on a slope, NetQuake's creep remains), a door opened by its trigger field running to `pos2` on its own clock, shells picked up by walking over them, a rocket flying and exploding against a wall, its explosion sprite removing itself, and a grunt listed by `frame_ents`. A server frame is about 40 ms once the level has settled (the first, with every monster's first think, about 800 ms).

- **What progs.dat tells the client**: besides the temp entities, the `WriteByte` state machine in `qc_builtin` reads `svc_intermission` (the stats: `game.intermission = 1`, `completed_time` from the server's clock), `svc_finale` and the `WriteString` after it (`intermission = 2`, `finale_text`), and `svc_cdtrack` with its two bytes (`cdtrack`). `qc_tic` and `quake_tic` return the four columns (the PSQL game sets `intermission` when `changelevel` fires); the page draws `Hud.drawIntermission` (sbar.c's `Sbar_IntermissionOverlay`) or `Hud.drawFinale` (`gfx/finale.lmp` and the text at eight characters a second) in place of the status bar and the weapon, plays the track `svc_cdtrack` names, and in the PSQL game holds the stats until fire, two seconds at least, before loading the next level.
- **`makestatic`** keeps what it is given drawn: the model, frame, skin, origin and angles go into a non-solid `ents` row above the edicts (`classname = 'static'`), then the edict is freed, as `SV_MakeStatic_f` makes a baseline (the torches and flames).
- **The page in QuakeC mode** (the **Logic** setting): `startMap` calls `qc_change_parms` before a level change (`SV_SaveSpawnparms`: `SetChangeParms` on the client, parm1..16 and `serverflags` into `qc_saved`), `loadMap` for the geometry, then `qc_begin_map(skill, carry)`: `qc_enter`, the saved globals restored, `mapname` and `world.model` set (worldspawn reads them), `qc_spawn_map` at time 1, and `qc_client_join` (`SetNewParms` only for a new game, then `ClientConnect`, `PutClientInServer`). The loop calls `qc_tic` in place of `quake_tic`: the same nine arguments, 0.05 s server frames, the view angles kept by the client and replaced by the body's when the progs set `fixangle` (spawn, teleport, intermission), and `quake_tic`'s 44 columns read from the client's QuakeC fields and globals (`killed_monsters`, `total_secrets`…). The builtins feed the row: `sprint`/`bprint` build the message line from their pieces (`qc_msg`), `centerprint` is the centre print, `stuffcmd "bf"` the pickup flash, `changelevel` sets `next_map` (the first call counts), and `dmg_take`/`dmg_save` are handed over once and cleared, as `SV_WriteClientdataToMessage` does. `scripts/qcvm-tic-test.mjs` drives it as the page does.

- **The monsters** (`scripts/qcvm-ai-test.mjs`): `enemy`, `goalentity`, `ideal_yaw` and `yaw_speed` are routed to `ents` too, so the builtins can use the PSQL engine's monster movement as it is: `walkmove` is `move_step` (`SV_movestep`: the step up and down, the ledge check, flying and swimming), `movetogoal` is `move_to_goal` (`SV_MoveToGoal` with `SV_StepDirection` and `SV_NewChaseDir`), both followed by the triggers the monster touches, with `self` restored as `PF_walkmove` does. `checkclient` returns the client when it is alive, not `FL_NOTARGET`, and the caller's eye is in the PVS of the client's eye (`PF_checkclient`). `checkbottom` is `SV_CheckBottom` (the four corners on solid, or the real check of the floor under the middle and the corners). `aim` is `PF_aim`: straight ahead unless something with `takedamage == DAMAGE_AIM` is in the 0.93 cone with a clear line, then towards it. The effects: `WriteByte`/`WriteCoord` are read as a small state machine for `SVC_TEMPENTITY` (the type, then three coordinates, or an entity and six for the lightning) and become `fx_events` (gunshot, explosion, tar explosion, spike hits, lava splash, teleport, beams), and `particle` with colour 73 is blood. With the monsters awake a tic costs 60 to 80 ms (their thinks run `ai_run`, `CheckAttack`, traces); asleep, about 15.

`scripts/qcvm-test.mjs` runs the shareware `progs.dat`: `anglemod`, builtins through the function
table, `crandom`, `makevectors`, `main`, `SetNewParms` and `DecodeLevelParms` (global and field
stores), `InitBodyQue` (spawning and string fields), `info_null`, `ftos`/`vtos`, and `worldspawn`,
which sets the light styles; then E1M1 spawned through its spawn functions and five frames of thinks, then the player: connecting at the start, a frame with fire down (`W_FireShotgun` through `FireBullets` and `traceline`), touching a box of shells (`ammo_touch`), and the impulse 9 cheat. Cost: about 100 us per statement (three to six primary-key lookups each); the whole of E1M1 spawns in a second and a frame of 20 to 50 thinks takes 300 to 500 ms.
LibreQuake's `progs.dat` (an extended QuakeC) loads but stops at its own `vectoyaw`, which is not
builtin 13 there; supporting its extensions is roadmap work.

## 8b. Deathmatch, coop and bots (`sql/bots.sql`)

QuakeC mode has Quake's multiplayer rules for free, because they are progs.dat's: `ClientObituary`,
`respawn`, `SelectSpawnPoint`, `CheckRules`, the weapons that stay and the items that come back, the
monsters that remove themselves in deathmatch. The engine's share is more than one client:

- **The rules** are `game.deathmatch`, `coop`, `maxclients`, `fraglimit` and `timelimit`, set by
  `qc_setup_server(deathmatch, coop, nbots, fraglimit, timelimit)` and kept across levels. The
  `deathmatch` and `coop` QuakeC **globals** are set by `qc_begin_map` before the spawn, as
  `SV_SpawnServer` does (progs.dat reads the globals; the cvars too, through `cvar()`). The spawn drops
  what `ED_LoadFromFile` drops: in deathmatch only `NOT_DEATHMATCH` (2048), the skill bits otherwise.
- **The clients** are edicts 1..maxclients (`qc_maxclients()`): `qc_reset` reserves them, `qc_spawn`
  allocates above them, `qc_client_join_n(c, t, carry, name)` connects one (`ClientConnect`,
  `PutClientInServer`), `qc_client_think(c, …)` and `qc_physics_client(c, …)` run any of them, the
  edict loop visits all of them every frame, and `checkclient` takes turns between the live ones every
  0.1 s as `PF_newcheckclient` does. `centerprint`, `sprint` and `stuffcmd` reach the page only for
  client 1; `bprint` reaches everyone (the obituaries show on the message line).
- **The bots** are clients 2..: `qc_server_frame` asks `qc_bot_think(c, t, dt)` for each one's move (the
  same forward/side/up speeds, view angles, buttons and impulse a player's packet carries) before the
  physics. The brain keeps its state in the `bots` table: every 0.3 s it looks for the nearest enemy
  it can trace a line to (another client in deathmatch, a `FL_MONSTER` in coop), else the nearest item
  (`item_*`, `weapon_*`) not far above it; it turns at most 540° a second towards its target with a
  per-sighting aim error (20° on easy to 3° on nightmare), runs in, keeps its distance, circle-strafes
  and fires when roughly on target; without a target it runs on, turning away from walls within 64
  units and from floors more than 60 units down or under lava or slime; stuck for 7 frames, it jumps
  and turns; an item it cannot reach (4 s, or stuck) is shunned for 10 s. Dead, it lets go of fire
  and presses it again to respawn; in the intermission it touches nothing (any client's button would
  end it). Its random choices are `rnd()`, so a demo replays the bots.
- **The page**: the **Game** setting (single player, deathmatch, coop) and **Bots** (1 to 7) start a
  game in QuakeC mode with `qc_setup_server` before `qc_begin_map`; `qc_scores` (client, name, frags,
  alive) feeds the frag list drawn in the corner. Demos store the rules (the `demo` row) and saves
  keep them in the `game` row, with the `bots` table among the saved ones.

## 9. The renderer in SQL (`sql/render.sql`)

`view_setup` computes the camera from the player's row and `viewcfg`: forward/right/up, the
projection scale, the near plane and the frustum planes. `mark_faces(pvs, leaf)` runs once per leaf
change: it clears `vis_faces` and inserts every face of every leaf whose PVS bit is set (`JOIN`ing
`marksurfaces` by range, not `IN`), plus every face of every visible brush model at its origin. The
leaf is remembered in `viewcfg.vis_leaf`, so nothing is recomputed while the eye stays in a leaf.

`frame_faces_fast` (the default): fills `sel_faces` from `vis_faces` by dropping back faces (plane
test at the eye) and faces whose bounding sphere is outside the frustum, and returns one row per face
`(face, ent_id, ox, oy, oz)`. `frame_faces` does the same and then joins `face_verts`, computing the
view transform, the projection and the texel coordinates in the select list, one row per vertex. The
first costs about a quarter of the second since a frame is ~300 face rows instead of ~1400 vertex rows.

`frame_ents` lists the alias models and sprites whose `leafs` intersect the PVS, with pose, frame,
skin, effects and alpha. `frame_lightstyles` evaluates the 64 light styles at the current time.

## 10. The painter (`src/renderer.js`, `src/hud.js`)

An 8-bit framebuffer of palette indices with a 16-bit z-buffer, presented through the palette into an
`ImageData`. `setResources` keeps per-face info (the BSP's vertices, texture and lightmap) so the fast
mode needs only face ids. `drawFaceList`/`drawFaces` transform (if needed) and clip each polygon
against the near plane in view space, then `fillPolygon` scan-converts with perspective-correct
spans: 1/z, s/z and t/z are affine in screen space, so each span walks them and divides every 8 pixels.
Texels come from a **surface cache**: the miptex tiled under the face's lightmap (the four light
styles summed) and pushed through the colormap once per face and light level, up to
`SURF_CACHE_MAX` entries. Liquids are drawn with the sine warp, the sky with Quake's two scrolling
layers mapped by the pixel's direction (`skyPixel`), both as special fill modes of the same span
routine. Texture animation (`+0name`…, `+aname` for pressed buttons) is `animSequence`.

**Dynamic lights** (`src/dlights.js`, Quake's `cl_dlights`): each frame the page lists the lights:
rockets and lava balls (the model's `EF_ROCKET` flag, 200 units), explosions from the fx events
(350 units, shrinking by 300 a second for half a second), the player's muzzle flash (a shot starts
the weapon's animation) and the quad's or the pentagram's glow, and in QuakeC mode the entities'
own `EF_MUZZLEFLASH`, `EF_BRIGHTLIGHT` and `EF_DIMLIGHT` (the PSQL game uses effects 4 and 8 to mark
fullbright things; `qc_tic` clears the muzzle flash at its start, as `SV_CleanupEnts` does, so it lights
the frame drawn after the shot). A face that a light reaches (`faceDlights`: the plane within the
radius, the lit disc over its rectangle) is built for that frame alone, its lightmap block raised by
`R_AddDynamicLights`' octagonal falloff before the colormap; a brush model's faces see the light moved
into the model's frame by the origin the face list carries. Models add `radius - distance` of every
light to the light under them (`dlightAt`, R_LightPoint's dynamic part).

`drawAlias` draws an `.mdl`: the frame's vertices (or the group's frame by time) transformed by the
entity's angles, lit by the lightmap value under the entity (`lightPoint`) plus Gouraud light from
the vertex normals, each triangle clipped against the near plane and rasterised with the z-buffer;
the view model is drawn last with a cleared z-buffer. `drawSprite` is a billboard. Particles
(explosions, blood, teleport) are points with gravity and a lifetime. `present(tint)` applies the
damage, quad, pentagram and ring tints. `Hud` draws the status bar from `gfx.wad` (numbers, faces,
ammo, keys, sigils), the centre print, and a text HUD at low detail.

## 11. The page (`src/main.js`)

- **Input**: `keydown`/`keyup` into a set, pointer lock for the mouse, the wheel for weapons, touch halves for phones; `readInput(tics)` turns them into the nine `quake_tic` arguments.
- **The loop**: `frame()` computes how many tics are due (1..4 at 50 ms) so a slow frame catches up, runs `quake_tic`, then in one `Promise.all` queries `frame_faces[_fast]`, `frame_ents`, `frame_lightstyles`, the new `sound_events` and `fx_events` (by last id) and the brush models' frames, paints, plays, presents. Level changes (`EXIT_KIND`) load the next map after the stats message; the finale shows the ending text.
- **Data sets**: `DATASETS` in `boot()` are the pak combinations the site may serve (`pak/pak0.pak`, `pak/pak1.pak`, `pak/lq1/pak0.pak`, `pak/lq1/pak1.pak`), probed with `HEAD`; the **Data** selector shows those whose files exist. The file picker takes one or two paks.
- **The menu** (`src/menu.js`, menu.c): Escape, or the browser releasing the mouse, brings it up; the game pauses (no tics) and the last frame is drawn again, dimmed (`Renderer.fadeScreen`, `Draw_FadeScreen`), with the menu over it from the pak's pictures (`gfx/qplaque.lmp`, `gfx/ttl_main.lmp`, `gfx/mainmenu.lmp`, the spinning `gfx/menudotN.lmp`, `gfx/sp_menu.lmp`, `gfx/p_option.lmp`, `gfx/helpN.lmp`, the `gfx/box_*.lmp` text box) and the console font's gold half for the options (`M_Print`), with Quake's menu sounds. Single Player's Load and Save list the twelve save slots (`gfx/p_load.lmp`, `gfx/p_save.lmp`, section 6a). The options call the same setters as the page's controls (`setDetail`, `setLogic`, `setRenderer`, `setSfx`, `setMusicVolume`). When paused, `gfx/pause.lmp` is drawn as Quake does.
- **Settings** persist in `localStorage`: map, skill, detail (320×200 or 160×100), renderer mode, volumes, music mode, data set, mouse speed, always run, invert mouse.
- **Console**: any SQL against the live database, with buttons for the common queries; `window.quake` exposes `db`, `sql()`, `renderer`, `res`, `settings`, `last` (the last tic row) and `map` to the devtools console.
- **Music**: `worldspawn.sounds` names the CD track; `public/music/trackNN.ogg` or a picked folder; otherwise a synthesised drone.

## 12. Audio (`src/audio.js`)

`QuakeAudio` decodes `.wav` files from the pak on demand, plays `sound_events` with Quake's
spatialisation (volume falls off linearly with distance × attenuation, pan by the dot with the right
vector), loops entity ambients (`ambient_*` entities, torches, the hums) at their positions, plays the
leaf ambients (water, sky/wind) at the levels `quake_tic` reports, and handles the music modes.

## 13. Tooling (`scripts/`)

| script | purpose |
|---|---|
| `build.mjs` | bundles `src/main.js` with esbuild-wasm into `dist/`, copies `public/` and the engine's wasm; `--serve [--coi]` serves it |
| `fetch-pak.mjs` | the shareware `pak0.pak` from `quake106.zip` (LHA inside: 7-Zip, `lha` or `lhasa`); `--librequake` LibreQuake lite into `public/pak/lq1/` |
| `sql-check.mjs` | compiles every SQL file against the engine, reports the first error with its line |
| `sql-smoke.mjs [map]` | loads a map, walks, shoots, opens a door, renders, checks every queued and referenced sound exists; `PAK`/`PAK1` choose the paks |
| `hazard-test.mjs` | slime and lava as `WaterMove` hurts, with and without the biosuit, in both modes |
| `lq-test.mjs` | LibreQuake: every level loads and exits; lq_e0m7's boss trap (`trigger_hurt`) in both modes; `light_globe` and `makestatic` |
| `dm-test.mjs` | deathmatch and coop with bots: the spawns, a bot fragging the player and the player a bot, respawning, fraglimit, a coop bot shooting a grunt, a bot demo replaying |
| `demo-test.mjs` | demos: a game recorded and played back bit for bit, fresh and after another level, in both modes (`QCJIT=all`: the playback compiled) |
| `save-test.mjs` | save games: saved mid-play, loaded back exactly, also after an export and a reload of the map, in both modes |
| `boss-test.mjs`, `registered-test.mjs`, `e1m2`…`e1m8-test.mjs` | scene tests: load a level, place the player with `teleport`, play tics with `run`, fire procedures directly, assert on tables (see the README's table) |
| `bench.mjs` | times a tic and its parts, the traces, a monster think and the frame queries |
| `screenshot.mjs` | renders frames headlessly: `--at=x,y,z,yaw`, `--sql="…"` and `--tics=N` (repeatable, in order), `--single`, `--fast`, `--compare` (SQL-projected vs JS-projected frame, must match), `--gallery` (a view from every item spot) |
| `gen-frame-layouts.mjs` | regenerates `src/framelayouts.js` |
| `png.mjs` | a tiny PNG encoder for the screenshots |

Timings on a desktop (E1M1, `npm run bench`): a tic 6 ms idle and 12 ms walking; a player-box trace
0.8 ms; a monster think 0.4 ms standing and 5 ms running; `frame_faces_fast` 6 ms for ~270 faces and
`frame_faces` 36 ms for ~1400 vertex rows; marking a new leaf's faces 15 ms. The painter takes 30 to
150 ms per frame at 320×200 depending on the scene.

## 14. CI and deployment (`.github/workflows/pages.yml`)

Every push to `main`: install, cache or fetch the paks (shareware and LibreQuake), the SQL smoke test,
the LibreQuake smoke test, the nine scene tests one step each, headless screenshots, the build, and
the deploy to GitHub Pages at https://mariuz.github.io/firebird-quake/. The pak files are never
committed (`.gitignore`); the registered `pak1.pak` is only ever local.

## 15. Firebird lessons, in full

- **Variables in DML need the colon** (`:x`), and a reserved word such as `at` cannot be a name.
- **Forward references**: declare a stub with the identical signature first.
- **`VARCHAR` beyond 8191** needs `CHARACTER SET ASCII` (the PVS strings, the loader chunks).
- **No binary parameters** in the WASM build: bind text, parse in PSQL.
- **`INSERT ... VALUES` takes one row**; bulk goes through the generated loaders.
- **`THEN NULL;` is not a statement**: use `THEN BEGIN END`.
- **`IIF`/`CASE` over literals pad to the longest**: `TRIM` anything that is compared as a string in JavaScript or used as a file name. SQL ignores trailing blanks in `=`, so this hides until a test compares strings.
- **Floating-point time drifts**: compare `nextthink <= t + 1e-6`, or a 10 Hz think runs at 8 Hz.
- **Derived tables are inlined; `IN (subquery)` scans**: `JOIN` the small set; a predicate on the joined row still walks every vertex, so filter before joining.
- **Select-list expressions are cheap, PSQL statements are not**: the projection moved from the loop body to the cursor's select list halved the frame query.
- **Rows are the cost**: emit faces, not vertices.
- **Keep what does not change**: the PVS marking per leaf, items at rest not relinked, the surface cache in the painter.
- **A primary-key lookup is ~4 µs**, so recursion over a BSP hull is fine.
- **Selectable procedures run only when selected from**: `EXECUTE PROCEDURE spawn_monster(...)` does nothing visible; `SELECT * FROM spawn_monster(...)` does.
- **Events need a lifetime**: `sound_events`/`fx_events` are deleted after 40 tics; a test that looks for an event must look while it is still there.
- **Global temporary tables** stand in for arrays (clip planes, pushed entities, this frame's faces).

## 16. Debugging recipes

- In the page's devtools: `await quake.sql("SELECT id, mtype, st, health FROM ents WHERE mtype IS NOT NULL")`, `quake.last` for the last tic row, `quake.settings`.
- A scene headlessly: `node scripts/screenshot.mjs e1m7 out --at=-300,64,56,0 --sql="EXECUTE PROCEDURE boss_awake(2)" --tics=70 --single --fast` then open `out-e1m7-0.png`.
- Finding a view: `node scripts/screenshot.mjs e2m3 out --gallery --fast`, tile the PNGs into a contact sheet (PIL), pick the spot from the file name (`..._x_y_z_yaw.png`).
- A test's pattern: `teleport(x, y, z, yaw)` writes the player row and relinks; `run(n, args)` plays tics; `sounds('doors/%')` counts events; assert on `ents` rows after.
- When CI fails and the test passes locally, run it three times locally: the monster AI uses `RAND()`, first thinks are random within 0.6 s, and events expire. Fix the test's timing or neutralise the random actors (`UPDATE ents SET health = 0, st = 'dead', solid = 0, nextthink = NULL WHERE mtype IS NOT NULL AND …`).
- `npm run check` for a PSQL compile error with the line; `npm test` for a quick end-to-end.
