# Roadmap: what is missing

What Firebird Quake does today is in [ARCHITECTURE.md](ARCHITECTURE.md). This is the list of what it
does not do yet, roughly by how much it would change the experience. Items marked *SQL* belong in
`sql/`, *JS* in `src/`, *tests* in `scripts/`.

## Next

What is left above is blocked (the registered pak) or by design; these are the next things worth doing,
in order of what they would change.

- ~~**The painter in a worker, in parallel with the SQL frame**~~ done the other way round: the engine
  already ran in a Web Worker (it has to: it blocks on mutexes), so the painter stayed and the loop was
  pipelined: a tic and its frame queries are issued as one promise and painted when they arrive, the
  painting of one frame overlapping the engine's work on the next (ARCHITECTURE section 10, the loop).
  On the way, a bug: the loop ran at least one tic per display frame, so the game ran faster than real
  time whenever a frame took under 50 ms (2.7× at 55 fps, measured in a headless browser). It now runs
  twenty tics a second and paints every display frame, the last rows again between tics with the time run
  on, so the time-driven effects move at the display's rate: E1M1 in both logics 60 fps and 20 tics/s
  where it was 51 fps and 55 tics/s (PSQL) or 29 fps and 27 tics/s (QuakeC); E1M2 in QuakeC mode 40 fps
  and 20 tics/s where it was 23 and 20. The stats line shows both rates.
- ~~**Mods, for real**~~ done (`src/zip.js`, the page's **Mod** control and **Impulse** box, `npm run
  fetch-mods`, `npm run test:mod`; ARCHITECTURE section 8c): a mod's zip as released (loose files, pak
  files, or both, the game directory at any depth) or its pak files are laid over id1 as a game directory
  is; a mod with its own `progs.dat` runs in QuakeC mode. Three released mods play E1M1: id's progs 1.06
  recompiled with the fish fix, Reinforcer 1.1 and FrikBot X, whose bots connect into spare client slots
  and roam. They found four things in the VM: client edicts must exist from worldspawn on and only
  connected clients run (FrikBot counts the slots with `nextent` and moves its bots itself), `colormap`
  and `team` are set on connect, `findradius` returned the world when a radius reached the map's centre,
  and Quake's coloured characters did not load (mapped to plain ones from the bytes). The site serves
  FrikBot X (public domain); the other two are fetched for the test only. Left: FrikBot's bots are slow,
  since each runs the whole client physics in QuakeC every frame: with two of them beside three of ours a
  tic is about 120 ms once its hot functions are compiled (33 ms without them, 24 under id's progs), so
  the game runs at a third of real time; a mod that needs a builtin the VM lacks (DarkPlaces' or FTE's
  extensions) stops at the first call.
- ~~**A Quake console**~~ done (`src/console.js`, `src/binds.js`, `sql/host.sql`, `npm run test:console`;
  ARCHITECTURE section 11): `` ` `` brings Quake's console down over `gfx/conback.lmp`, with `map`,
  `changelevel`, `restart`, `skill`, `god`, `notarget`, `noclip`, `give`, `kill`, `impulse`, `bind` and
  its kin, `sql`, the cvars and more; the game commands are `host_cmd`, host_cmd.c's in PSQL, in both
  logics (the PSQL player got `MOVETYPE_NOCLIP`, and QuakeC mode's `localcmd("restart")`, which
  `ClientKill`'s single-player `respawn` sends, restarts the level). Every key, mouse button and wheel
  turn is a binding with Quake's names, `+` buttons held and commands run, kept in `localStorage`, and the
  menu's **Customize controls** rebinds them as `M_Keys` does. ~~`alias`, `exec` of a config file, and the console's notify lines over the view~~ done (`src/console.js`,
  `npm run test:console`): `alias` names a line of commands and runs it like one (kept in `localStorage`, an alias
  that runs itself stopped at 16 deep; a key bound to `+name` runs the `+name` alias going down and `-name`
  coming up, as keys.c does), `exec` runs a config file from the paks a line at a time (`exec default.cfg`
  runs id's own, every line known: `unbindall`, its binds, its zoom aliases, `viewsize` and `gamma` accepted),
  `wait` is accepted, and the last four lines printed in three seconds show over the top of the view while the
  console is away (`Con_DrawNotify`: the game's messages, and what a bound key's command answers). `wait` holds the rest
  of a line until the next display frame, so the zoom aliases step through their fields of view. Not there:
  cvars beyond these few.
- ~~**Fast revisits**~~ done (`scripts/build.mjs`, `openDatabase` and `cachedBuffer` in `src/main.js`,
  `npm run test:image`; ARCHITECTURE section 2): the build runs `createSchema` once and ships the database
  as a gzipped image (0.7 MB, named by a hash of what built it), which the page opens instead of
  compiling the PSQL, and the paks are kept in the Cache API after the first download, keyed by the
  server's validator. Measured in a headless browser against the local server: a first visit is playing
  after 5.0 s instead of 7.9 (the database ready in 1.6 s instead of 5.7), a revisit after 3.1 s instead
  of 6.0 (0.8 s instead of 4.1, no pak downloaded). What is left is the engine's start (about 0.7 s,
  the WASM compiled again) and loading the map (1.3 s).
- **Episodes 2 to 4 scene tests that run where the pak is** (*tests*): begun with `npm run test:levels`
  (`scripts/levels-test.mjs`), which checks every level of the paks it is given in both logics: the
  player standing at full health, the monsters there, every exit leading to a map the paks have and
  ending the level, progs.dat counting the same monsters to kill as the PSQL game (`total_monsters`), a
  second played without a QuakeC error. CI runs it on the shareware levels, where it passes;
  `PAK1=/path/to/pak1.pak npm run test:levels` runs episodes 2 to 4, the end and dm1 to dm6, which has not
  been run here (no registered pak in this environment), so its first run on them is still to come. Set
  pieces per episode (E2's runes, E3's and E4's traps) would follow the same way, gated on the pak.
- ~~**Split `qcvm.sql` as `game.sql` was**~~ done (ARCHITECTURE section 8a): six files of 140 to 560
  lines in load order, `qcvm.sql` (globals, fields, strings, edicts), `qcbuiltins.sql`, `qcexec.sql`
  (the interpreter), `qcserver.sql` (spawning, the client), `qcphysics.sql` (the server frame) and
  `qcpage.sql` (the page's tic). The builtins became five procedures by kind (math, move, trace, ent,
  io), each declaring only the locals it uses, behind a `qc_builtin` that dispatches on `qc_bi_group(n)`;
  the JIT calls the group's procedure directly. Measured in the engine, the fixed cost of a builtin call
  was 5.5 µs of locals (sixty, about 0.1 µs each), 3.4 µs of the prelude's `SELECT` and up to 7 µs of
  the `IF` chain: `break` went from 10.7 µs to 3.6 called directly, the last builtin from 17.7 to 6.5,
  `vlen` from 50 to 35. `bench:qc` with every function compiled: a server frame 18 → 16 ms asleep,
  27 → 24 awake; interpreted, 30 → 26 asleep.
- ~~**Performance numbers in CI**~~ done (`npm run perf`, the workflow's `perf` job): `bench`, `bench:qc`
  (interpreted and with every function compiled) and `bench:paint` write their numbers to a JSON
  (`BENCH_JSON`), and `scripts/perf.mjs` sets each against the median of the last five runs in the
  history the site serves (`perf-history.json`, the last 200 runs, each with its commit and runner),
  puts the table in the job summary, flags a number more than 50 % and 1 ms slower as a warning, and
  hands the history with the run added to the build to deploy. Warnings, not failures: on one machine a
  number moves by 10 to 35 % from one run to the next. The microsecond timings (a builtin, a statement)
  still need to be taken inside the engine, as `qc_builtin`'s were for the split above.
- ~~**Touch controls**~~ done (`src/touch.js`, `npm run test:touch`): from the first touch the view
  carries a stick that appears where the left thumb lands (forward and sideways as far as it is pushed,
  a dead zone of an eighth, full speed at 56 px), the right side to look by dragging (0.4° a pixel at the
  default mouse speed; a quick tap fires once), buttons for fire and jump (held, and a touch shorter
  than a tic still read once), the next weapon, the menu and full screen (letterboxed at 4:3, turned to
  landscape where the phone allows), and while the menu is up a pad of arrows, OK and back that sends it
  the keys. Driven in a phone-sized headless Chromium against the built page: the stick walked the
  player 500 units in a second and a half, a drag turned it 32°, a tap on fire spent a shell, the pad
  moved the menu's cursor and closed it. Not tried on a real phone here.
- ~~Smaller: a `.sav` file export; a note in the README of what is not a goal~~ done: the **Save** controls
  download the last game saved or loaded as a `.sav.json` (the exported slot with the data set it was
  made on, since its model ids are that data's) and load one back, refused with the reason when it is of
  other game data or not a save (`saveFile`, `readSaveFile` in `src/saves.js`, `npm run test:save`;
  tried in a headless browser: saved at 77 health, downloaded, loaded into a fresh browser at 77). The
  README's "What it does not try to be" names multiplayer between people, GLQuake, Quake's own file
  formats and speed.

## The game

- ~~**Dynamic lights**~~ done (`src/dlights.js`, ARCHITECTURE section 10): rockets, explosions, the muzzle flashes and the powerup glows light the world and the models, the lit faces rebuilt for the frame as Quake's `R_AddDynamicLights` does. ~~Left: the slow renderer (`frame_faces`) lights world faces only~~ done (`npm run test:compare`): its rows carry each face's brush model origin, so a door is lit in both renderers (15500 pixels differed before), and an edge exactly on a scanline's centre no longer takes another row in each (the painter rounds screen positions to a millionth of a pixel; E1M1's start differed in 84 pixels); ~~and the PSQL game has no muzzle flash for monsters~~ done: a grunt's and an enforcer's shot set `EF_MUZZLEFLASH` (bit 2, which the PSQL game's fullbright marks leave free), `quake_tic` clears it at the next call, and the page lights it as the player's (`npm run test:infight`).
- ~~**Monster infighting**~~ done (`npm run test:infight`): `t_damage` follows `T_Damage` (mad at any attacker but the world, itself and its current enemy, never at its own class except soldiers, the player kept in `oldenemy_id`), and `monster_think` goes back to the player when the enemy dies. ~~Left: a monster's attacks aim at a monster as at the player~~ done: sight (`visible`) and `check_attack` go from eye to eye, `origin + view_ofs` as Quake has it (`eye_height`: the player 22, walking and flying monsters 25, swimmers 10, anything else 0), where they used the player's 22 for any target and a monster's height less 8 for its own eye.
- ~~**Skill 3 (nightmare)**~~ done (`npm run test:skill`): no wait before attacks, pain at most every five seconds, the hard skill's entities; the page offers it, and the start map's halls (`trigger_setskill`, nightmare's hidden one included) choose the skill for the next level in both modes.
- ~~**Intermission**~~ done: the stats screen is drawn as Quake's (`Sbar_IntermissionOverlay`, `gfx/complete.lmp`, `gfx/inter.lmp`, the time, secrets and kills) until fire, in both modes, from an `info_intermission` camera (in the PSQL game `changelevel` does what `execute_changelevel` does: a random camera, else the start, its `mangle` as the view, the eye at the spot, the player frozen, the intermission music).
- ~~**The menu**~~ done (`src/menu.js`): Quake's menu in the frame (Escape): Single Player (New Game, Load, Save), Options (the sliders and checkboxes of `M_Options_Draw` over the page's settings: screen size, mouse speed, music and sound volume, always run, invert mouse, and this game's logic and renderer), Help (the help pages), Quit (a new game from the start map); the game pauses under it, and the PAUSE plaque shows when paused. Multiplayer starts a deathmatch with bots; Customize controls and the console came later (Next).
- ~~**Save and load**~~ done (`sql/save.sql`, `src/saves.js`, `npm run test:save`; ARCHITECTURE section 6a): `save_game(slot)` copies the state's rows (`game`, `player`, `ents`, `lightstyles`, and in QuakeC mode the VM's globals, fields, edicts, run-time strings and parms) into `sv_<table>` copies generated from the live tables' columns; `load_game(slot)` puts them back over a freshly loaded copy of the map, renumbering its brush models. The page keeps each slot in IndexedDB per data set, so saves outlive the page; the menu's Load and Save show Quake's twelve slots, F6 and F9 quick save and load. Left: saves are tied to the data set they were made with (model ids follow the paks' order), and there is no file export (a `.sav` download would be the JSON).
- ~~**Demos**~~ done (`sql/demo.sql`, `src/demos.js`, `npm run test:demo`; ARCHITECTURE section 6b): every random choice goes through `rnd()`, a seeded generator in the `rng` table (`init_map` seeds it, from `loadMap`'s `seed` option or at random), and the edicts are numbered from 1 each level, so a level spawned with the same seed and fed the same `quake_tic`/`qc_tic` arguments replays bit for bit, in either logic, in a fresh database or a used one, and with QuakeC interpreted or compiled. The page records a level (Record demo restarts it as a new game), plays a demo back, keeps the last one in IndexedDB and saves or opens it as a `.dem.json` file. ~~A demo starts from a new game~~ done: recorded mid-level, a demo carries a save of the moment it starts (slot 13, `rng` with it) and plays back from it bit for bit in both logics (`npm run test:demo`; on the page, 67 tics of a recording and its playback compared equal). Left: a demo is one level; the scene tests could pass a seed to `loadMap` and drop their timing margins.
- ~~**Deathmatch and coop**~~ done in QuakeC mode, against bots (`sql/bots.sql`, `npm run test:dm`; ARCHITECTURE section 8b): the server has `game.maxclients` clients in edicts 1..maxclients, progs.dat's own rules run them (frags and obituaries, respawning, `info_player_deathmatch`/`info_player_coop`, the monsters gone in deathmatch, the items coming back, fraglimit and timelimit), and clients 2.. are bots whose moves `qc_bot_think` makes in PSQL: they see by tracing, fight the nearest enemy they can see (a client in deathmatch, a monster in coop) circle-strafing with a skill's aim error, run for items they can see, and wander away from walls and drops otherwise. The page's **Game** setting (and the menu's Multiplayer) starts one; a frag list shows in the corner; demos and saves carry the rules. ~~The bots all wore the same colours~~ done: each client has Quake's colours (`top * 16 + bottom`: the bots red, blue, green, yellow, magenta, orange and light blue, the player whatever the console's `color` sets), `colormap` is routed to `ents` so a client and its corpse carry the client's number, `frame_ents` returns the colours and the painter recolours the shirt and pants as `R_TranslatePlayerSkin` does; the team is the bottom colour + 1 (`npm run test:dm`). Left: the PSQL game is still single player, and is likely to stay so: counted again, 127 places pin `player.id = 1`, 93 statements update the `player` table and 32 read it, and 22 call `player_ent()`, so a second player would thread a player id through nearly every procedure of the player, the weapons, the items and the monsters, while QuakeC mode already plays deathmatch and coop by progs.dat's own rules; ~~the bots had no route finding~~ done (`npm run test:nav`): they learn the level as FrikBot's bots do, every client on the floor dropping linked nodes where it goes, and with nothing in sight a bot runs a way through the links to a pickup it has not in view, striking off a link it cannot cross; each bot costs roughly 7 ms a tic in Node and more in the browser (three bots: a 54 ms `qc_tic` in Chromium, 20 frames a second); there is no network play (a second human would need a transport between browsers).
- **Mods**: the game is a rewrite of `progs.dat` in PSQL, so mods do not run. The faithful route, a QuakeC VM in PSQL, is started (`sql/qcvm.sql`, ARCHITECTURE section 8a): the interpreter runs the real `progs.dat`'s functions, including `worldspawn`. What remains to play a level through it:
  1. ~~**Spawning through QuakeC**~~ done: `qc_spawn_map(skill, t)` spawns every map entity through its classname function (E1M1: 336 functions, 0 failures, 1 s).
  2. ~~**The tic through QuakeC**~~ done as procedures: `qc_frame(t, dt)` runs `StartFrame` and the due thinks; `qc_client_connect(t)` and `qc_player_frame(...)` run the client's `ClientConnect`, `PutClientInServer`, `PlayerPreThink` and `PlayerPostThink` with the input in the fields; `qc_touch(e, other)` delivers a touch. What is still missing is calling them from `quake_tic` in place of the PSQL game, which needs item 3 first (the engine's movement between the two player thinks, and the touches from the physics).
  3. ~~**The engine's physics on QC edicts**~~ done: QuakeC mode (`qc_enter`) makes `ents` the store of the engine's fields, routed by `qc_engine_fields`, and `qc_server_frame` runs `Host_ServerFrame` on the PSQL engine's traces and movers (ARCHITECTURE section 8a). E1M1 plays: doors, pickups, rockets, gravity and friction as Quake's.
  3a. ~~**The page in QuakeC mode**~~ done: the **Logic** setting; `qc_begin_map`, `qc_change_parms` and `qc_tic` (ARCHITECTURE section 8a). Left for later: the temp-entity effects (explosions, gunshots, blood, lightning come through `WriteByte`, ignored for now, so only the explosion sprite shows), the intermission's stats screen, and the episode-end texts.
  4. ~~**The remaining builtins**~~ done: `walkmove`, `movetogoal`, `checkclient`, `checkbottom`, `aim`, `particle` and the temp entities written with `WriteByte`/`WriteCoord` (ARCHITECTURE section 8a); the monsters see, chase, shoot and die. The client messages followed: `svc_intermission` (the stats screen), `svc_finale` (its text, typed out under `gfx/finale.lmp`) and `svc_cdtrack` (the music) come through the `WriteByte` state machine into `game` and `qc_tic`'s row (`npm run test:qctic` stages E1M7's ending). ~~Still approximate: `lightning`'s beam~~ done: a beam's `WriteEntity` is kept as the effect's owner (`qc_vm.te_ent`), and the page moves the player's own beam to the player each frame as `CL_UpdateTEnts` does, so the thunderbolt follows the player who holds it; the monsters' beams start where their message said (`npm run test:qcplay` fires the thunderbolt in QuakeC mode).
  5. **Speed**: **QuakeC is compiled to PSQL** (`src/qcjit.js`, `npm run test:qcjit`): the hot functions become stored procedures with their temporaries, locals and parameters in variables, compiled between frames; every function of id's and LibreQuake's `progs.dat` compiles. Then the engine's share of a frame went down: `link_ent` walks the BSP once with the box (`box_leafs`) instead of ten times with points, `checkclient` keeps each caller's eye leaf, a think is set up in two statements instead of six. An E1M1 frame takes 15 to 22 ms asleep and 21 to 26 ms awake (the PSQL game's tic went from 7 to 5 ms idle, a running monster's think from 4.7 to 2.3 ms). A 10 Hz server was measured and left out: with 0.1 s frames a game second costs 250 to 300 ms of server time against 300 to 400 at 20 Hz (the thinks are 10 Hz either way; only the client's physics, `StartFrame` and the edict loop are saved), but the page is render-bound (a tic of about 17 ms against 20 to 150 ms of frame queries and painting), so skipping every other tic would gain a few percent of frame rate for a departure from Quake's 20 Hz physics and an interpolating renderer. What is left of a frame is spread thin: a monster's think is about 1.3 ms (0.6 in builtins, `movetogoal` 1.6 ms a patrolling one, `checkclient` 0.2; 0.3 in compiled QuakeC, mostly field reads of 10 µs; the rest the call's plumbing), the client 3 to 4 ms; the monsters' `trace_move` (0.5 ms a step) and the edict loop's query (0.1 ms an edict) are the next candidates. Measured again inside the engine (timings taken from JavaScript carry 50 µs of round trip each, which had inflated every number): a settled E1M1 frame of 13 to 15 ms is the monsters' thinks (about fifteen a frame at 0.35 ms: a standing grunt's `checkclient` 67 µs, `FindTarget`'s own statements about 70, the think's run and call plumbing about 110), the client 2.5 ms (`PlayerPreThink` 0.7, `PlayerPostThink` 0.4, `link_ent` 0.16, `check_water` 0.1), the edict loop's query 1.5, two moving doors 1.4 each and `StartFrame` 0.2 (three `cvar` builtins at 45 µs). Nothing is big; every builtin pays about 30 µs of dispatch, a routed field write cost 21 µs and a read 6. The accessors are cheaper now (`qc_sf` writes one column, 15 µs; compiled code reads and writes a known engine field's column directly, 2.6 and 12 µs; the loop's query joins once instead of four `EXISTS`), which the frame does not show above its noise. The page is render-bound in any case: the frame queries and the painter cost more than a tic, so that is where a frame goes (the Performance section). Before the compiler: the interpreter is 2.5 times faster (13.5 µs a statement: one joined query and one `UPDATE`; locals saved only on recursion; parameters by one `MERGE`; `checkclient`'s PVS kept for 0.1 s; only edicts with a think due are visited), and a server frame went from 60 to 37 ms with the monsters asleep and from 85 to 43 ms awake (`npm run bench:qc`). That is still short of 20 frames a second. A frame now spends about 5 ms in statements and the rest in about 60 QuakeC calls (some 0.15 ms each with the engine around them) and the engine's per-edict work, so the next steps are, in order of yield: **compile QuakeC to PSQL** (one procedure per function, locals and temporaries as PSQL variables, globals and fields as today: most statements become assignments of a microsecond; compile the functions a level calls, on first call, since compiling all 2000 would take long); run the server at 10 Hz with the page interpolating; and fold the engine's per-edict queries (`qc_physics_ent`, `qc_run_think`) into the edict loop's query. The old notes: ~100 us per statement is 10x too slow for a full frame (`StartFrame` plus ~50 thinks is ~20 k statements). Keep the running function's hot globals in PSQL variables instead of rows, batch `OP_STORE` sequences, and drop the `qc_vm` round trips inside `qc_call`. A seeded `random` would make it deterministic.
  6. ~~**LibreQuake's QuakeC**~~ done (`npm run test:qclq`): its `progs.dat` declares no builtin the VM lacks (FTEQCC strips their names; the numbers are Quake's). What broke it was FTEQCC's layout: it overlaps the locals of different functions (191 of 193 with locals share slots), relying on Quake's VM saving a callee's locals on entry and restoring them on exit, and the interpreter saved them only on recursion, so `EntitiesTouching` overwrote `LinkDoors`' loop variable and the door chain never ended (a tic of 20 minutes, cut by the runaway limit edict after edict). `qc_functions.shared` marks those functions, which now save and restore their locals on every call; the compiler keeps what such a function writes in its range in variables. LibreQuake's levels spawn and play in QuakeC mode, interpreted or compiled to the same positions. (An `item_shells` in `lq_e0m1` drops out of the level: its box starts in a wall, which QuakeSpasm's `droptofloor` rejects too.)
- **Episodes 2 to 4** have no scene tests of their own (they need the registered `pak1.pak`, which CI does not have; `npm run test:levels` covers every level where the pak is, see Next); episode 1 and LibreQuake are covered. ~~**LibreQuake's levels**~~ done (`npm run test:lq`): every level of LibreQuake lite loads with the player on the floor (or swimming) at full health, its monsters spawned, every exit naming a map the pak has (but lq_e0m2's dangling `e0-level-trans`, LibreQuake's own) and ending the level; and lq_e0m7's boss trap in both modes: two buttons count down a `trigger_counter`, the vore's pillar sinks into the lava and a `trigger_hurt` of 50000 kills it through its 3000 armour. ~~**`trigger_hurt` and lava/slime**~~ done (`npm run test:hazard`, and the trap above): slime 4 × waterlevel a second and nothing in the biosuit, lava 10 × waterlevel every 0.2 s (a hit every fifth tic at 20 Hz) and every second in the suit, the same in the PSQL game as progs.dat's `WaterMove` gives in QuakeC mode. The tests found and fixed: the PSQL game's slime hit five times a second and the suit stopped lava; health over 100 rotted without a megahealth; gravity was skipped on the ground, so `FL_ONGROUND` went off every other frame (half the friction, dropped jumps); the player spawned on the floor instead of a unit above it; a sinking pusher left monsters hanging in the air (`push_move` now carries all but walkers, with a unit more of slack for brush models' padded bounds) and what it carried touched no triggers; `trigger_hurt` hurt only the player; a fractional `dmg` (0.1) became 5; QuakeC entities lost every map key the loader had no column for (now `map_keys` and `ED_ParseEpair`, so the boss has its armour); and `makestatic` freed QuakeC statics instead of keeping them drawn (every torch was invisible in QuakeC mode).
- **Small gaps found in the maps**: ~~`light_globe`~~ done (its `s_light` sprite); `ambient_suck_wind` is not silent after all (the page plays the map's ambients from its entity list, and `ambience/suck1.wav` is in the shareware pak); ~~the `misc_fireball` arc and the shambler's lightning~~ done (`npm run test:fire`): a fireball spawner without a speed key keeps speed 0 and throws its lava ball only up to 200 high, as misc.qc's `self.speed == 1000` (a comparison, not an assignment) leaves it; the shambler casts on `sham_magic6`, skips magic7 and magic8, casts on magic9 and magic10 and, on nightmare, magic11, and its trace ends at `self.origin + dir * 600` as `CastLightning` has it.

## The renderer

- ~~**Resolution and scaling**~~ done: the **Detail** setting (and the menu's Screen size) has 640×400 beside 320×200 and 160×100; above 320 the status bar stays 320×24 and centred, as in Quake's higher video modes. The painter was already fast enough (`npm run bench:paint`: 4 to 7 ms a frame with the surface cache warm at 640×400); building surfaces was the cost, and `buildSurface` now steps the light across each 16-texel block as `R_DrawSurfaceBlock` does instead of blending four luxels per texel, three times faster (E1M4's lake, every surface built: 44 → 15 ms at 640×400, 29 → 10 at 320×200) and pixel for pixel the same. In Chromium E1M1's start runs at 41 frames a second at 640×400 (49 at 320×200).
- ~~**Underwater warp**~~ done (`Renderer.warpView`, `D_WarpScreen`): with the eye in water, slime or lava the finished 3D view is resampled through Quake's sine table. ~~**View roll** when strafing~~ done (`V_CalcRoll`: 2° at 200 units a second sideways, from the player's motion between frames). **Fullbright texture pixels** need nothing: Quake's colormap keeps colours 224–255 unchanged at every light level (all 2048 entries), and the surface cache goes through it. **Coloured lighting** (not Quake, not needed).
- ~~**Mip levels**~~ done: each face picks its mip by `D_MipLevelForScale` (its nearest point, the view's pixels per unit, the texinfo's `mipadjust`; thresholds 1, 0.4, 0.2), and the surface cache builds it at 1/2^mip the size from the texture's mip with the lightmap sampled 16 >> mip texels apart. Distant faces no longer shimmer, and the raster got faster (E1M1's start view: 50 ms against 77). The nearest distance is rounded to a thousandth before the thresholds: the grid puts many faces exactly 160, 400 or 800 units away, where the SQL projection's last digits would otherwise pick another level than the JS one (`--compare`).
- ~~**BSP2 / 2PSB and large maps**~~ done (`npm run test:bsp2`): `Bsp` reads BSP2 and 2PSB beside BSP 29, and PVS strings are a `d_pvs` domain of 8192 characters (32768 leaves, against 8192 before). No free map at hand uses the formats, so the test rewrites E1M1 in both and requires the same parse, the same rows, the same frame query and the same 150 tics of play. Left: maps past 32768 leaves would need a longer `d_pvs`; ~~BSP 29 maps with more than 32767 clipnodes~~ done: BSP 29's 16-bit node and clipnode children are read unsigned, an index below the count a node and above it a leaf or contents, as QuakeSpasm's `Mod_LoadNodes_S` and `Mod_LoadClipnodes` do (no free map that large was at hand: id's and LibreQuake's maps parse exactly as before); `.lit` coloured light is not handled; a real BSP2 map (a modern release in a pak) has not been tried.
- ~~**Transparent water**~~ done (`npm run test:water`): the **Liquids** setting (and the menu) draws water, slime and lava see-through at half, as GLQuake's and QuakeSpasm's `r_wateralpha` do, but only the liquids the map was vised for (an open leaf's PVS holds leaves of them: all of LibreQuake's maps, none of id's, which stay opaque rather than show the void). The 8-bit frame blends through a 64 KB table of nearest palette colours (`blendTable`); the liquids are drawn after the models, depth-tested, without writing depth. ~~Teleporters stay opaque. Left: one alpha for every liquid~~ done: each kind has its own as QuakeSpasm's `GL_WaterAlphaForSurface` gives it (`Renderer.alphaFor`): the map's worldspawn keys first (`wateralpha`, `lavaalpha`, `slimealpha`, `telealpha`: LibreQuake's lq_e0m4 asks for water at 0.6 and opaque lava, which it now gets), then the console's `r_lavaalpha`, `r_slimealpha`, `r_telealpha`, 0 meaning as the water (`r_wateralpha`, 0.5); teleporters go by the water's vis, as they sit in water leaves; Liquids **Opaque** still keeps every liquid opaque. ~~Left: an opaque liquid's back side is not drawn from below~~ not a gap after all: qbsp makes every liquid face both ways (E1M1: 121 slime and 30 water faces up, as many down), so from under the surface its underside is drawn as a face of its own, warped (`npm run test:water` looks up from under E1M1's water).

## Fidelity audit (QuakeC mode against id's engine)

Going through the engine's side of QuakeC mode function by function against WinQuake's source, each
difference fixed with a test that fails without it:

- ~~**`SV_ClientThink`**~~ done (`npm run test:qcplay`): there was no `SV_WaterJump`, so the push `CheckWaterJump`
  puts in `movedir` to climb out of the water over a ledge was lost to the air move; now the velocity is
  `movedir` while `FL_WATERJUMP` holds, and the flag and `teleport_time` clear after it or out of the water.
  The body's roll was always 0 where Quake leans the model into a strafe (`V_CalcRoll(angles, velocity) * 4`:
  8° at 200 units/s and over), so the bots now lean as players did; and its pitch and yaw take the punch
  (`v_angle + punchangle`).
- ~~**`SV_Physics_Client`**~~ done (`npm run test:qcplay`): there was no `SV_CheckStuck`, so a walking client left
  inside something solid (a `setorigin`, a spawn) stayed there; now it goes back to its last free place
  (`oldorigin`) or to the first free spot within a unit sideways and 17 up. The check is skipped while the
  client is where its last move left it (`oldorigin` is stored after `walk_move`, whose traces only end in
  room), which is what kept it from costing 2 ms a frame. And a noclipping client touched no triggers, where
  `SV_LinkEdict(ent, true)` touches them for every movetype (only `SOLID_NOT` skips): noclip now picks up
  items and walks into teleporters and level exits as in Quake.
- ~~**`SV_CheckWaterTransition`**~~ done (`npm run test:qcplay`): monsters (after their step and think) and tossed
  things (after a move that hit something, where Quake's toss reaches it) never noticed water: no splash
  (`misc/h2ohit1.wav`) going in or out, and `watertype`/`waterlevel` stayed as spawned. Now they splash and keep
  both as Quake does (out of the water `waterlevel` is the contents, -1), and QuakeC edicts start with
  `watertype` 0 as id's fresh edicts do, so one spawned in water takes it silently.
- ~~**`SV_Physics`' `force_retouch`**~~ done (`npm run test:qcplay`): the frame loop ignored it, so what already
  stood in a trigger when it came to life (a teleporter switched on by its targetname sets `force_retouch = 2`
  for this) was never touched. Now, while it is set, every edict is linked again with its touches before its
  physics, and it counts down by one at each frame's end, as Quake does.
- ~~**`SV_PushEntity`'s clip**~~ done (`npm run test:qcplay`): every pushed thing clipped as `MOVE_NORMAL`. Now a flying
  missile clips as `MOVE_MISSILE` (a monster is hit by a box 15 units each way, so a rocket or a nail that grazes
  a grunt hits it) and a trigger or non-solid thing as `MOVE_NOMONSTERS` (a backpack falls through monsters and
  players). `trace_move`'s `nomonsters` = 2 is the missile clip. The PSQL game's missiles share `push_entity`
  and clip the same way. And in QuakeC mode the mover is now linked with its trigger touches before the
  impact, as `SV_LinkEdict(ent, true)` comes before `SV_Impact` there: a rocket stopped by a wall inside a
  trigger touches the trigger, then explodes (with the impact first it was gone before the trigger saw it).
- ~~**`SV_WalkMove`**~~ done (`npm run test:qcplay`): there was no `SV_WallFriction`, so running into a wall nearly
  head-on slid along it at full speed; now the speed along it is cut by how squarely the view faces it (facing it,
  half is kept). There was no `SV_TryUnstick` either, so a run caught on a jamb's edge by a unit stopped dead; now a
  step-up that made no headway is nudged 2 units each way in turn and the move tried again. The step-up is also
  skipped for a water jump and for a client whose touch changed its movetype, and `fly_move` returns 7 when it is
  stopped in a corner, as `SV_FlyMove` does. Both games give `walk_move` the view's forward vector, so the PSQL
  game's player has the wall friction and the unsticking too (`npm test` checks the friction through `quake_tic`).
- ~~**`SV_movestep`**~~ done (`npm run test:qcplay`): there was no `SV_CheckBottom` after the step, so a monster
  walked on towards a drop for as long as any part of its box's trace down found floor, until a corner was all
  that stood on the edge; now the step is refused when the floor under its middle or a corner is more than a step
  down (one whose floor was pulled out, `FL_PARTIALGROUND`, may still take it to correct). The retry from the
  wished height after a start in something solid traced 36 units down instead of to the same end, 18. The check is
  `check_bottom`, which the `checkbottom` builtin uses too; the PSQL game's monsters walk by the same `move_step`.
- ~~**`SV_MoveToGoal`**~~ done (`npm run test:qcplay`): `SV_CloseEnough` stopped the move only when the goal was the
  enemy itself, where Quake stops it for any enemy once the goal is in reach (a grunt with the player for its enemy
  and a path corner or item for its goal), and its y test used the x bound; the boxes are now padded as
  `SV_LinkEdict`'s `absmin`/`absmax` are (a unit, an item 15). `SV_StepDirection` compares `yaw - ideal_yaw` as it
  comes, unwrapped, so a monster turning anticlockwise steps while still turning and one turning clockwise first
  turns; ours wrapped it and neither stepped. `SV_NewChaseDir`'s search round all eight directions now skips the
  turnaround, and a monster that can step nowhere while hanging over a drop is marked `FL_PARTIALGROUND`
  (`SV_FixCheckBottom`), which lets its next step take it off the edge.
- ~~**The builtins (`pr_cmds.c`)**~~ done (`npm run test:qcplay`): `traceline` set `trace_inopen` to "hit something",
  where Quake sets it when the line went through open air; id's `visible()` takes a line through air and water both
  for a crossed surface, so monsters saw across the top of water that hides the player from them in Quake. Now it is
  the trace's own `inopen`. `vectoyaw` and `vectoangles` kept fractions of a degree where Quake casts them to whole
  degrees (with the exact `180 / π`, so straight along y is 90 and not 89). `findradius`'s chain ran from the lowest
  edict up, where Quake's runs from the highest down (it walks up and puts each in front): a blast's
  `T_RadiusDamage` now hurts things in Quake's order.
- ~~**`SV_Impact` and `SV_TouchLinks`**~~ done (`npm run test:qcplay`): both left `self` and `other` set to the last
  touch they ran, where Quake puts them back; a monster's `walkmove` into a trigger came back with `other` changed
  (`PF_walkmove` restores only `self`, relying on the touch to restore `other`). `aim` now looks through the edicts in
  order, as `PF_aim` does, so a tie goes to the later one.
- ~~**`PF_setmodel`**~~ done (`npm run test:qcplay`): an alias model left the edict's size as it was, where Quake gives it
  the fixed box `Mod_LoadAliasModel` sets, 16 units each way, until a `setsize`, and a sprite the box
  `Mod_LoadSpriteModel` gives it: half its widest frame across and half its tallest up and down.
- ~~**`groundentity`**~~ done (`npm run test:qcplay`): only a landing toss set it; `SV_FlyMove` sets it to the
  `SOLID_BSP` thing or the world a fall stops on, and `SV_movestep` to what a monster's step stands on. Of the
  progs at hand only LibreQuake's reads it (its `ClientObituary`). Left different on purpose: `SV_WalkMove`'s step down
  sets `FL_ONGROUND` only for a `SOLID_BSP` mover, which a player never is (an id bug); here a step down lands the
  player on the ground, one frame sooner than Quake would.
- Checked and found faithful: `SV_Physics_Pusher` (the move limited to the think's time, the think on the
  pusher's `ltime`), `SV_RunThink` (due within the frame, run at its own time, `other` the world), `droptofloor`, `walkmove`,
  `makevectors`, `rint`, `normalize`, `setorigin`, `setsize`, `checkclient` (`PF_newcheckclient`'s turn every
  0.1 s and the PVS of the client's eye; `FL_NOTARGET` is the progs' own test), `SV_Physics_Toss` (gravity but
  for fly and missiles, the touch's velocity and movetype used for the bounce, 60 units/s to stop a bounce),
  `SV_Physics_Step` (the fall, `demon/dland2.wav` on landing, then the think).

## The PSQL game against QuakeC mode

The fidelity audit above fixed QuakeC mode; where the PSQL game has its own copy of the same rule, it is brought
to the same behaviour, with a test of its own:

- ~~**`SV_WalkMove`**~~ done (`npm test`): the PSQL player's walk is given the view's forward vector, so it has
  `SV_WallFriction` and `SV_TryUnstick` as QuakeC mode does.
- ~~**`T_RadiusDamage`**~~ done (`npm run test:infight`): the blast reached a box of `damage + 40` around it (a
  grunt 200 units off a rocket took 20), where `findradius` takes the middles within a sphere of that radius and
  skips `SOLID_NOT`; `CanDamage` traced once to the middle (and let a trace that started in a wall through), where
  Quake tries the origin and four points 15 units off it across, or the middle of a brush model's bounds; the
  shambler takes half of every blast; and the blast goes from the highest edict down, as the chain does.
- ~~**Noclip touches triggers**~~ done (`npm run test:console`): the PSQL game's noclip linked the player without
  its touches; now `player_touch_triggers` (the triggers, items and door and plat fields the player is in) runs for
  noclip as for walking, so noclip picks up items and goes through teleporters and exits as in Quake.
- ~~**`SV_CheckWaterTransition` and the landing thud**~~ done (`npm run test:infight`): the PSQL game's monsters and
  tossed things never splashed going into or out of water; now `water_transition` (one procedure for both games, in
  `game.sql`) runs after a monster's think and after a toss that hit something. And a monster landing thudded
  (`demon/dland2.wav`) after any fall, where Quake thuds only after one faster than a tenth of gravity.
- ~~**`SV_CheckStuck`**~~ done (`npm test`): the PSQL player left inside something solid stayed there; now
  `player_check_stuck` puts it back at the last place a move ended free (`player.free_x/y/z`, QuakeC's `oldorigin`,
  cleared at each spawn) or the first free spot within a unit across and 17 up, untested while the player is where
  its last move left it.
- ~~**Swimming walks**~~ done (`npm test`): the PSQL player swam with a plain `fly_move`, where Quake's
  `MOVETYPE_WALK` player always moves by `SV_WalkMove`, whose step-up is allowed in the water: waist-deep against a
  ledge a step above, the player now stairs up onto it without a water jump, as in Quake and QuakeC mode.
- ~~**Autoaim**~~ done (`npm run test:infight`): the PSQL game's weapons fired straight along the view, where id's
  shotguns, nailguns and rocket launcher take `aim(self, …)`: `aim_dir` is `PF_aim` (`sv_aim` 0.93), so a shot
  bends up or down onto a monster near the crosshair, as in Quake and QuakeC mode (the grenade launcher, the
  thunderbolt and the axe fire straight, as id's do).
- ~~**`T_Damage`'s order**~~ done (`npm test`): the PSQL game returned at god mode and invulnerability before the
  armor and the push; Quake spends the armor and gives the push first, so in god mode a rocket still throws the
  player (a rocket jump) and the armor still goes. The invulnerability's sound has its own 2-second timer
  (`player.invincible_sound`) instead of borrowing the pain timer, and on nightmare the player's next pain waits
  five seconds, as `T_Damage` does after any `th_pain`.
- ~~**The jump after the input**~~ done (`npm test`): the PSQL game jumped before `SV_ClientThink`'s friction and
  acceleration, where `PlayerJump` runs in `PlayerPreThink`, after them: a running jump skipped its frame's ground
  friction (300 kept where Quake leaves 240), and water friction cut the liquid's swim-up speed (100 in water) by a fifth.
- ~~**`SV_AirMove`'s input**~~ done (`npm test`): the PSQL game capped every wish at the walk's 200 or the run's
  320, flat along the yaw, with friction always 4; Quake's client sends 200 forward and 350 to the side (twice
  running) and the server takes the body's angles, whose pitch is a third of the view's, caps the wish at 320,
  refuses backing into a teleporter just used and doubles the friction at an edge. The PSQL game's input now
  follows QuakeC mode's `SV_ClientThink`: a walking strafe is as fast as a run, looking far down slows the walk, and
  the swim's wish takes the same speeds.
- ~~**The water jump**~~ done (`npm run test:e1m3`): the PSQL game hopped out of the water only with forward held and
  looked for the open space at 24 up; `CheckWaterJump` runs whenever the player is waist deep, whatever the input,
  looks at the head (`maxs_z`, 32), and keeps the push into the ledge (the wall's normal × -50, `player.wj_dx/dy`)
  that `SV_WaterJump` then holds as the velocity across. A swimming jump no longer overrides the hop (`PlayerJump`
  returns during it), the check comes after the frame's move as `PlayerPreThink` does, and the jump ends by the
  water level the last frame left, as `SV_ClientThink` sees it, which is what lets the push carry the player over.
- Already the same: `visible` (a line through air and water is no sight), the monsters' stepping and chasing
  (`move_step`, `move_to_goal`: one copy for both games), the pushed things' clip (`push_entity`).

## Performance

- **The physics write only what changes, too**: of a deathmatch frame's 46 `ents` updates, 11 changed nothing (found with a trigger recording the columns each update changed): the client's angles and velocity set again unchanged while standing or not turning, the water level stored by `check_water` and then again by `qc_physics_client`, and `walk_move` clearing an on-ground flag that was already clear. Those are now conditional or gone (2 a frame left), and the frame went from 23.3 to 22.0 ms (four alternating rounds). The last unchanged global writes (34 a frame, all `OFS_RETURN` written by `qc_exec` after a think or touch it ran compiled) and the VM's depth are conditional as well, about 0.2 ms more. What remains are real changes: `flags` (`walk_move` clears the on-ground flag and `fly_move` sets it again, 6.7 a frame), gravity's `vz`, positions and frames.
- **QuakeC writes only what changes**: an `UPDATE` is mostly the new version of the row it writes (8 to 10 µs for a `qc_globals` or `qc_fields` row, 16 for a wide `ents` row, 25 for `qc_vm`'s), and half of a deathmatch frame's global writes, three fifths of its field writes and a sixth of its `ents` column writes stored the value already there. `qc_sg`, `qc_sgu`, `qc_sfq`, `qc_sf`'s columns and fields, the parameter setters and `qc_run_think` now write only a different value (`IS DISTINCT FROM`; a missing row is still inserted), as does the compiled code's own column store: global writes 226 → 145 a frame, field writes 44 → 17, `ents` 55 → 46, and the frame 24.6 → 23.2 ms (four alternating rounds of 300 frames each). Measured on the way: a call costs 2 µs, a read through `qc_fq` or `qc_g` 5 (the same subquery inline 3.5). Tried and left: the compiled code reading globals and fields by subqueries in place instead of through `qc_g` and `qc_fq` (about 300 reads a frame at 1.5 µs less each, which four alternating rounds could not tell from the noise: 23.1 against 23.0 ms), and a narrow table for `qc_vm`'s counters (its 15 updates a frame cost 15 µs against 8, 0.1 ms in all).
- **The compiled QuakeC reads its globals less**: a global read once stays read past a call that cannot write it (`QcJit.callWrites`: the globals each function may write, through its static calls, with the builtins' own) and through an `if`'s join when every way in had it; `self` was read again after every call and every join. A deathmatch frame with three bots reads globals 143 times instead of 263, which is about half a millisecond of the frame, inside its noise (23 to 25 ms); what the compiled player code spends now is mostly its field reads and writes (`qc_fq` 155 a frame, `qc_sg`/`qc_sgu` 120, `qc_f` 80, each a function call and a query of 3 to 10 µs).
- **The bots' sight tests** skip the trace when the target is outside the PVS of the bot's eye (`pvs_leafs`: none of the leaves `link_ent` listed for it is in the PVS; never in sight, so the result is the same, and the bot demo still replays bit for bit). A long sight line between players is a 1.2 ms trace; the bots' looks went from 2.4 to 0.5 ms a frame and their brains from 3.9 to 1.9 ms (inside the engine, with timing wrappers), which is about 0.5 ms of a 25 ms deathmatch frame on average, since a bot looks only every 0.3 s. Tried and left: walking `box_leafs` two levels a row as the traces do (the same leaves, but each extra branch of the recursive query is another join, so it was slightly slower). What a deathmatch frame with three bots spends now (wrapped, so inflated): the clients' physics 15 ms of which the QuakeC player code is 7 (its builtins only 1.5: the rest is the compiled code itself), `trace_move` 5.5 (19 a frame: the world walk about 250 µs each, the scan of the 32 solid entities 40), `walk_move` 3.6, `link_ent` 2.
- **firebird-wasm 0.7** (from 0.3), and the page on its build without threads: a call costs less (a trivial query 45 → 17 µs from Node; kept prepared statements, column shapes sent once, values written without `snprintf`), DDL is quicker (the schema built in 2.3 s against 3.2 to 4.9, all of `progs.dat` compiled in 11.5 s against 15), and the page needs no cross-origin isolation, so the first visit no longer reloads; in Chromium it plays 0.7 to 0.9 s sooner (the database open from the image 344 ms against 735, the start map loaded in 0.96 s against 1.34). The game's own work is unchanged: a PSQL tic, the frame queries and a QuakeC deathmatch frame with three bots take the same in either build and in 0.3, since they are spent inside the engine running PSQL. Left off: `sharedReads` (a QuakeC frame got slower, 18 → 21 ms, its `SELECT`s from procedures that write being run twice). Measuring it found two page bugs the Node tests could not see, fixed first: the page stopped at start-up since the per-liquid alpha commands (a `const` used before its line), and QuakeC mode failed to spawn on the schema image (the compiler's first rewrite of the dispatchers, before any QuakeC had run).
- **The world's traces** are twice as fast: `rhc` loops through the nodes a segment does not cross and through the far side of a split (only the near side is a call), each `hulls` row carries its children's planes so a lookup descends two levels, and the lookups are `FOR SELECT`s (no check for a second row). E1M1's hull‑0 trace went from 560 to 220 µs, the player hull's from 240 to 120, a point's contents and leaf from 220 to 175 µs the pair (E1M3: 900 → 320, 280 → 130, 370 → 270), and a QuakeC deathmatch frame with three bots from 26 to 20 ms (median of 300). The traces' results are unchanged to the millionth. Next in a trace: the scan of `ents` for brush models and boxes, about 50 µs.
- **QuakeC mode with bots** (a deathmatch, three PSQL bots and the player, measured inside the engine with timing wrappers): a server frame went from 30.6 to 25.8 ms. `link_ent` skips the BSP walk when the origin, box and touch margin are those it last linked (`ents.lk_*`), and `nav_mark` skips a client that has not moved 4 units since its last mark (the four clients' marks 2.3 → 0.16 ms when idle). What is left of a frame: `walk_move` 5.4 ms, `PlayerPostThink` 4.1, the bots' brains 4.0, `PlayerPreThink` 3.1, the bots' client thinks 2.8, `link_ent` 1.8 (the moving clients), `check_water` 0.9. A trace costs about 250 µs for a box over 20 units, of which the world hull's walk is 190; `point_contents` and `point_leaf` about 90 each. The world BSP walk is the next target.
- A tic is 5 to 12 ms and a frame's queries about 4 ms (`frame_faces_fast` 2.4 in a leaf seen before, 16 on a leaf's first visit; `frame_ents` 1, the light styles and the events under 1), and the painter 2 to 7 ms with the surface cache warm (`npm run bench:paint`), up to 15 ms when a scene's surfaces are all built afresh. ~~The frame queries were 7 to 15 ms~~ done: `leaf_faces` and `vis_faces` carry each face's plane and sphere, so the culling scans them without a join to `faces` per candidate (the fast query 5.0 → 2.4 ms, the slow mode 28 → 24), and `vis_faces` is rebuilt only when the view leaf changed or a brush entity moved, appeared, went or changed model (`vis_ents` remembers them; the check is a few probes where the rebuild was 0.8 ms a frame; the smoke test watches a door move and go).
- ~~`mark_faces` on a leaf change is 15 ms~~ done: a view leaf's world faces are marked once into `leaf_faces` (keyed by leaf) and read from there by the frame queries, so returning to a leaf costs nothing (`npm run bench`: a frame in a leaf seen before 5 ms, against about 21 when it was marked again; the first visit 16 ms; the same leaf 5 ms, from 6). The cache grows with the leaves visited (a few hundred rows each) and is emptied with the map.
- `frame_faces` (the slow mode) remains four times the fast mode; it exists to prove the projection in SQL and for `--compare`.
- ~~The loaders~~ done: the `LOAD_<table>` procedures read fixed-width fields (each chunk starts with its columns' widths, a string carries its length) instead of searching for `|` with `POSITION`, which was most of their cost: E1M1 loads in 1.2 s instead of 2, E1M3 1.3 s instead of 2.2, LibreQuake's lq_e0m2 1.8 s instead of 3.5, progs.dat 0.65 s instead of 1.2, the rows identical (`npm run bench` prints the load). What is left is the `CAST` of each number (about 1.3 µs, the same for an integer as a double) and the `INSERT`; binary parameters, if the engine ever binds them, would remove the first.

## Tooling and tests

- ~~**Nothing opened the page**~~ done (`npm run test:page`, in the build job before the deploy): every test ran the SQL under Node, so the page stopping at start-up (a `const` used above its line) and QuakeC failing to spawn on the schema image both went out with CI green. The test serves `dist/` without COOP/COEP, opens it in headless Chromium and waits for tics in the PSQL game and in a QuakeC deathmatch with three bots, failing on any page error; put back, each of the two bugs fails it.
- ~~**CI takes about three minutes**~~ (it had grown to eight in one job) done: the tests run as a matrix of five groups side by side after one job caches the paks, and the site is built when they all pass.
- ~~**Flakiness**~~ done: every scene test loads its levels with `seed: 1` (only the demo test records from a random seed, on purpose), so random first thinks and AI choices are the same every run; the last flake (the QuakeC dog's `movetogoal` detours in `test:qcai`, which failed once in CI) is gone with it. Event expiry (look each tic) is still the tests' own care.
- ~~`bench.mjs` should also time the painter~~ done: `scripts/paint-bench.mjs` (`npm run bench:paint`) paints four scenes at both resolutions, warm and cold.
- The screenshots page has every level of episodes 1 and 2, the first three of episode 3, and (from where the player starts) every LibreQuake lite level; E3M4 to E3M7 and episode 4 are not pictured (they need the registered pak).
- ~~A **LibreQuake scene test**~~ done: `npm run test:lq` (every level, and lq_e0m7's boss trap).

## Code and repository hygiene

- ~~`sql/game.sql` is 1600 lines~~ done: it is six files, run in the order they were cut from it (`SQL_FILES`), so the statements are the same: `game.sql` (the stubs, utilities and entity helpers, 270 lines), `movers.sql`, `triggers.sql`, `items.sql`, `combat.sql` and `spawn.sql` (170 to 400 lines each).
- Line endings: the working copy is CRLF under `core.autocrlf=true`, the repository LF; an earlier cp1252 round trip doubled lines and broke UTF-8 in three files, since repaired. Keep sources UTF-8 and let git normalise.
- ~~The monster `CASE` branches in `monsters.sql` could move into `monster_types` columns~~ done: the melee and missile start sounds, the leap's landing sound, damage, upward speed and shortest range, the gib sound, the nightmare-only missile frames and the frames never shown are columns (`src/gamedata.js`), and the zombie always gibs by a `gib_health` of 1. The branches left are behaviour (the zombie's pain, the spawn's explosion, Chthon, Shub-Niggurath). Found on the way: a comment had swallowed the shambler's `attack_chance: 0.4, pain_chance: 0.5`, so it attacked and flinched at the defaults (0.3, 1).
- ~~The page's SQL console has no history or completion~~ done: ↑ and ↓ walk the last hundred statements run (kept in `localStorage`; from the first or last line of the text, or Alt+↑/↓), and Tab completes the word before the caret from the tables, columns, procedures and functions (`RDB$RELATIONS`, `RDB$RELATION_FIELDS`, `RDB$PROCEDURES`, `RDB$FUNCTIONS`, read once) and the keywords, cycling the matches and listing them in the output.
