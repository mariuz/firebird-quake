# Roadmap: what is missing

What Firebird Quake does today is in [ARCHITECTURE.md](ARCHITECTURE.md). This is the list of what it
does not do yet, roughly by how much it would change the experience. Items marked *SQL* belong in
`sql/`, *JS* in `src/`, *tests* in `scripts/`.

## The game

- **Dynamic lights** (*JS*). Rockets, explosions, the muzzle flash and the quad glow light the world in Quake (`R_PushDlights`). The painter has no dynamic lights: the surface cache would need a per-frame overlay for the faces within a light's radius, or a cheaper per-span brightening.
- **Monster infighting** (*SQL*). `t_damage` sets the victim's enemy to the attacker, but the ogre-vs-knight logic of `combat.qc` (`T_Damage`'s `enemy` switch for monsters hurt by monsters, with the exceptions for same-class) is not complete. Verify and finish.
- **Skill 3 (nightmare)** (*SQL/JS*): no attack-rate changes, no pain-skip; the page offers skills 0..2.
- **Intermission** (*JS*): the level's stats are a status line for two seconds; Quake shows the intermission camera (`info_intermission`) with the stats until a key is pressed.
- **The menu**: no menu, no options screen, no episode select other than walking through the start map's gates.
- **Save and load**: not present, and a natural fit: the whole state is the dynamic tables (`ents`, `player`, `game`, `lightstyles`, `vis_faces`), so a save is a copy of those rows (into `*_saved` tables, or a JSON export through `SELECT`) and a load is a restore, with `viewcfg.vis_leaf` cleared.
- **Demos**: recording the nine `quake_tic` arguments per tic reproduces a game exactly (the only randomness is `RAND()`, which would need a seeded replacement in `monsters.sql`). Playback would make the scene tests reproducible too.
- **Deathmatch and coop**: the spawn points are read but there is one player row. A second player is a second `player` row and a second `ents` row with the same `player_think`; the loop would need two clients, which is a real multiplayer transport question (the page could run bots in SQL, as Firebird Quake III Arena does).
- **Mods**: the game is a rewrite of `progs.dat` in PSQL, not a QuakeC interpreter, so mods do not run. A QuakeC-to-PSQL compiler is the ambitious route; a QuakeC VM in PSQL (the bytecode is simple: 16 instructions, globals and fields as tables) is the faithful one.
- **Episodes 2 to 4 and LibreQuake's levels** have no scene tests; only episode 1 is covered. The maps load and play (every entity class in all 38 maps is spawned except `ambient_suck_wind`, `light_globe` and the deathmatch `item_weapon`), but nothing asserts on their set pieces. `trigger_hurt` and the lava/slime damage path deserve a test.
- **Small gaps found in the maps**: `ambient_suck_wind` (13 uses, E2/E3) is silent; `light_globe` (2) draws nothing; the `misc_fireball` arc and the shambler's lightning placement are approximate.

## The renderer

- **Resolution and scaling**: the view is 320×200 or 160×100 scaled by CSS. A 640×400 mode would need the painter's per-pixel loops to get faster first (the span loop is the hot path; typed-array tricks and avoiding per-pixel divides beyond the 8-pixel step would help), or a second Worker for the painter.
- **Underwater warp**, **view roll** when strafing, **fullbright texture pixels** (the colormap handles them, but the surface cache does not mark them), **coloured lighting** (not Quake, not needed).
- **Mip levels**: one mip level is used; distant faces shimmer. Picking the mip by the span's 1/z is cheap.
- **BSP2 / 2PSB and large maps**: the parser accepts BSP 29 only, so many modern maps will not load. The loader's `TABLES` are not the limit; `Bsp` is.
- **Transparent water**: Quake did not have it; `alpha` on `ents` exists for the oldone's gates and could carry it.

## Performance

- A tic is 6 to 12 ms and a frame's queries 8 to 15 ms, so the SQL side runs at 30+ Hz; the painter is the bottleneck in open scenes (up to 150 ms at 320×200). Profile `fillPolygon`'s span loop first.
- `mark_faces` on a leaf change is 15 ms: a spike when crossing doors. Marking by PVS could be cached per leaf in a table keyed by leaf id (space: faces × leaves, too much for a full table, fine for the leaves visited).
- `frame_faces` (the slow mode) remains four times the fast mode; it exists to prove the projection in SQL and for `--compare`.
- The loaders: E1M1 loads in two seconds, the registered episodes' big maps in four to five; the per-row parsing in PSQL could be replaced by `EXECUTE BLOCK`s with many parameters if the engine ever binds binary.

## Tooling and tests

- **CI takes about three minutes** because the nine scene tests run one after another; a matrix job per test would halve it.
- **Flakiness** has three sources, all seen: random first thinks (wait 0.75 s before asserting on monsters), random AI choices near the scene (kill the bystanders), and event expiry (look each tic). A seeded `RAND()` replacement in PSQL would remove the first two.
- `bench.mjs` should also time the painter (it has a stub canvas in `screenshot.mjs` to borrow).
- The screenshots page has every level of episodes 1 and 2 and the first three of episode 3; E3M4 to E3M7, episode 4, and LibreQuake's levels are not pictured.
- A **LibreQuake scene test**: its start map passes the smoke test; nothing checks its own levels' set pieces.

## Code and repository hygiene

- `sql/game.sql` is 1600 lines; splitting movers, triggers, items and combat into their own files (keeping the stub order in `SQL_FILES`) would help navigation.
- Line endings: the working copy is CRLF under `core.autocrlf=true`, the repository LF; an earlier cp1252 round trip doubled lines and broke UTF-8 in three files, since repaired. Keep sources UTF-8 and let git normalise.
- `monster_types` lives in `src/gamedata.js` and is loaded as rows; the monster `CASE` branches in `monsters.sql` could move into more columns there.
- The page's SQL console has no history or completion.
