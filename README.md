# Firebird Quake

![E1M1, the Slipgate Complex, from the start](docs/screenshot-e1m1-0.png) ![a grunt](docs/grunt-e1m1-0.png)

![the slime hall, its teleporter and the yellow armour](docs/slime-e1m1-0.png) ![two grunts on the bridge](docs/grunts-e1m1-0.png) ![the exit slipgate](docs/slipgate-e1m1-0.png)

![E1M7, the House of Chthon](docs/screenshot-e1m7-0.png) ![Chthon risen from the lava](docs/chthon-e1m7-0.png)

![E1M8, Ziggurat Vertigo: the lava hall](docs/lavahall-e1m8-0.png) ![a scrag over the lava river](docs/scrag-e1m8-0.png) ![three seconds into a jump, looking down](docs/jump-e1m8-0.png)

E1M1 from the start, a grunt, the slime hall with its teleporter and armour, two grunts coming over the
bridge, the exit slipgate; E1M7 from the start, and Chthon risen from the lava; Ziggurat Vertigo's lava
hall, a scrag over its lava river, and the view down from a jump that is still rising three seconds in,
since gravity there is an eighth of normal. Every frame is the result of a query, painted headlessly by
`scripts/screenshot.mjs`.

Quake, simulated and rendered inside the [Firebird](https://firebirdsql.org) SQL database, running
entirely in your browser on Firebird 6 compiled to WebAssembly. A port of the idea behind
[Firebird DOOM](https://github.com/mariuz/firebird-doom) to a true 3D engine.

**Play it:** https://mariuz.github.io/firebird-quake/

Every game tic is a PSQL procedure call. Every frame is a `SELECT`. JavaScript handles the keyboard,
the mouse and the canvas; everything else — collision against the BSP hulls, the player's physics,
doors, platforms, triggers, items, weapons, damage, the monster AI, and the visibility and projection of
every polygon on screen — happens in SQL.

```
keyboard/mouse → SELECT * FROM quake_tic(...)      game logic: 20 Hz, PSQL
               → SELECT * FROM frame_faces_fast    the faces on screen this frame (SQL picks, JS projects)
               → SELECT * FROM frame_ents          alias models and sprites in the PVS, with their pose
               → SELECT * FROM frame_lightstyles   this frame's light animation
               → SELECT ... FROM sound_events      what to play, and where
               → JS rasterises polygons and models through the colormap → canvas
```

## Running it

```bash
npm install
npm run fetch-pak      # downloads the Quake shareware episode (quake106.zip) and extracts id1/pak0.pak
npm run serve          # http://localhost:8080/ — add --coi if your browser blocks service workers
```

`fetch-pak` needs a tool that can read the LHA archive inside the shareware zip: 7-Zip, `lha` or
`lhasa` (`sudo apt-get install lhasa` on Debian/Ubuntu). If you own Quake, you can instead point the
page at your own `pak0.pak`/`pak1.pak` with the file picker, or copy it with
`PAK=/path/to/pak0.pak npm run fetch-pak`. With the registered `pak1.pak` loaded the page offers the
other three episodes and the registered monsters (enforcer, hell knight, vore, spawn, rotfish, Shub-Niggurath).

Firebird WASM uses pthreads, so the page must be cross-origin isolated. The dev server sends the
COOP/COEP headers with `--coi`; a static host like GitHub Pages cannot, so `coi-serviceworker.js`
re-issues responses with the headers after a one-time reload. Node 20 or later is required for the
scripts.

### Playing

Click the view to capture the mouse.

| keys | |
|---|---|
| `W` `A` `S` `D` or the arrows | move (always running; `Shift` walks) |
| mouse, `PgUp`/`PgDn` | look |
| `Ctrl`, `F` or click | fire |
| `Space` or `E` | jump, or swim up |
| `1`–`8`, `/` or the wheel | choose a weapon, cycle weapons |
| `9` | all weapons and ammo (impulse 9) |
| `P` | pause |

On touch screens the left half of the view moves, the right half looks, and a tap fires.

The page's settings: the **map** (every `.bsp` in the pak), the **skill**, the **detail**
(320×200 or 160×100), the **renderer** mode (below), the sound volume and the **music**. Quake's
music was CD audio and is not in the pak: put `track02.ogg`…`track11.ogg` (or `.mp3`) in
`public/music/`, or pick that folder in the page, and each map plays its `worldspawn` track; without
them a synthesised drone fills in, or turn it off.

### The SQL console

The page has a console onto the live game database. Everything is a table, so everything can be read
or changed while playing:

```sql
SELECT * FROM player;
SELECT id, mtype, st, health, enemy_id FROM ents WHERE mtype IS NOT NULL ORDER BY st;
SELECT classname, COUNT(*) FROM ents GROUP BY classname ORDER BY 2 DESC;
SELECT FIRST 40 * FROM frame_faces_fast;          -- what the painter is about to draw
EXECUTE PROCEDURE player_impulse(9);              -- all weapons
SELECT * FROM spawn_monster('shambler', 300);     -- one, 300 units ahead
UPDATE ents SET health = 1 WHERE mtype IS NOT NULL AND health > 0;
UPDATE ents SET flags = BIN_OR(flags, 64) WHERE classname = 'player';   -- god mode
```

`window.quake` exposes the database, the renderer, the audio and the settings to the browser's own
console as well.

## How it works

### The BSP becomes tables (`sql/schema.sql`, `src/loader.js`)

A BSP file is a relational database in disguise. `loader.js` parses it (`src/bsp.js`) and copies it in,
denormalised so the hot loops never need a second lookup:

| table | from |
|---|---|
| `faces` | FACES + PLANES (flipped for `side`) + TEXINFO, plus a bounding sphere |
| `face_verts` | EDGES and SURFEDGES resolved to an ordered vertex list per face |
| `leaves` | LEAVES with the PVS decompressed to a hex string (leaf *j* visible ⇔ bit *j−1*) |
| `marksurfaces`, `hulls` | MARKSURFACES; NODES (hull 0) and CLIPNODES (hulls 1 and 2), planes copied in |
| `models`, `anims` | the world, its submodels (`*N`), the `b_*.bsp` boxes, every `.mdl` with its frame runs |
| `map_ents` | the entity lump, which `SPAWN_MAP_ENTS` turns into rows of `ents` |

`ents` is the edict table: one wide row per entity with its origin, velocity, angles, bounding box,
model, frame, health, flags, think time, movement state and targets — the fields of `entvars_t`.

The WASM build binds parameters as text, so each table has a generated `LOAD_<table>` procedure that
parses 30 KB chunks of `|`-separated lines in PSQL — about 2.5× faster than a block of `INSERT`s.
E1M1 (70 k rows) loads in about two seconds.

### Collision is a recursive procedure (`sql/physics.sql`)

`RHC` is `SV_RecursiveHullCheck`: it splits the segment at every plane it crosses and recurses into both
sides, threading the trace state (`allsolid`, `startsolid`, `inopen`, `inwater`, the fraction and the hit
plane) through its parameters, because PSQL procedures can call themselves. `TRACE_MOVE` picks the hull
by the moving box's size, runs it against the world and against every brush-model entity at its own
origin, and clips against monsters and the player with a Minkowski slab test. `FLY_MOVE`, `WALK_MOVE`
(with the 18-unit step), `MOVE_STEP` (monsters), `TOSS_MOVE` and `PUSH_MOVE` (doors crushing and
carrying) are sv_phys.c; the clip planes and the pushed entities live in global temporary tables
because PSQL has no arrays. A primary-key lookup costs about 4 µs in the WASM engine, so a trace is
well under a millisecond.

### The game is PSQL (`sql/game.sql`, `sql/weapons.sql`, `sql/monsters.sql`)

`QUAKE_TIC` runs the player (client.qc: water, jumping, the water jump, friction, acceleration, the
trigger and item touches, powerups, drowning), the pushers (with `SUB_CalcMove` semantics), the thinks
that are due, and the physics of everything that flies, bounces or falls. Doors link by touching boxes
and need keys; platforms, buttons, trains with path corners and secret doors move as in doors.qc and
plats.qc. Items and weapons from the axe to the thunderbolt, armour, damage momentum, gibs and backpacks
are items.qc, weapons.qc and combat.qc. The monsters run ai.qc's state machine — `FIND_TARGET`,
`MOVE_TO_GOAL`, `NEW_CHASE_DIR`, `CHECK_ATTACK` — with each monster's attacks and sounds defined in
`monster_types` and a few `CASE` branches: the grunt, dog, knight, ogre, scrag, fiend, zombie, shambler
and Chthon of the shareware episode, and the enforcer, hell knight, vore, spawn, rotfish and
Shub-Niggurath of the registered one. Per-map gravity (Ziggurat Vertigo), the level's `worldspawn`
message and type, the intermission and the finale live in `game`. Everything the simulation wants heard
is a row in `sound_events`; visual effects are rows in `fx_events`.

### The renderer is a query (`sql/render.sql`)

`FRAME_FACES` finds the leaf the eye is in and, once per leaf, marks every face of every leaf in its PVS
into `vis_faces` (Quake's `visframe`). Visible brush models are marked too, at their origin. One cursor
then joins the marked faces to their vertices, dropping back faces and faces whose bounding sphere is
outside the frustum in the `WHERE` clause and computing the view transform, the projection and the texel
coordinates in the select list — evaluated by the engine rather than as PSQL statements, which cost
several times more. Edges that cross the near plane are clipped by the painter in view space; the
`(face, seq)` primary key yields each polygon's vertices in order, so no sort is needed.
`FRAME_ENTS` lists the alias models and sprites whose leaves are in the PVS.

Two renderer modes are selectable in the page. **SQL picks faces, JS projects** (the default,
`FRAME_FACES_FAST`): SQL does the visibility work — PVS marking, back faces, frustum — and emits one row
per visible face; the painter transforms the vertices it already holds from the BSP. **SQL projects every
vertex** (`FRAME_FACES`): the view transform and projection happen in the select list too, one row per
polygon vertex. Both paint the same pixels (the headless screenshot tool checks with `--compare`); the
first costs about a quarter of the second, since a frame is ~400 face rows instead of ~2000 vertex rows.

### JavaScript only paints (`src/renderer.js`)

An 8-bit framebuffer of palette indices and a z-buffer, like Quake's. Polygons are scan-converted
with perspective-correct spans (1/z, s/z, t/z) over a surface cache: the miptex tiled under the face's
lightmap, run through the colormap — r_surf.c. Alias models are drawn with the lightmap value under
the entity and Gouraud light from the vertex normals, clipped against the near plane triangle by
triangle; sprites are billboards; the sky is Quake's two scrolling layers mapped by the pixel's
direction; explosions and blood are particles. The status bar comes from `gfx.wad`.

### Sound (`src/audio.js`)

`sound_events` rows are played with the Web Audio API, attenuated and panned from where they
happened. Entity ambients (drips, hums, torches) loop at their entities; the water and wind ambients come
from the BSP leaf the player is in, which `QUAKE_TIC` reports each frame. The music is the CD track
named by the map's `worldspawn`, from the files described above.

## Tests

Each test boots the real Firebird WASM engine under Node, loads a level from the pak, and plays a
scene through `QUAKE_TIC`, asserting on the tables afterwards. They are the regression suite for the
physics, the movers and the AI, and they run in CI before every deploy.

| command | what it plays |
|---|---|
| `npm test` | SQL smoke test: every procedure compiles, E1M1 loads, tics and frames run, every sound the game queued exists in the pak |
| `npm run test:boss` | E1M7: the rune wakes Chthon, he rises and throws lava, the lightning does nothing until both terminals are up, three bolts kill him, the exit opens |
| `npm run test:registered` | the pak1 monsters' AI, spawned into E1M1 without their models: each is made to see the player and watched for its signature behaviour |
| `npm run test:e1m8` | Ziggurat Vertigo: gravity 100, so jumps and grenades go far and falls are gentle; the exit leads to E1M5 |
| `npm run test:e1m5` | the crucified zombies on the start map, and Gloom Keep's flooded moat: swimming, breath, drowning, surfacing |
| `npm run test:e1m2` | Castle of the Damned: the drawbridge slab sinks into the moat, and the player wades across on it |
| `npm run test:e1m3` | the Necropolis: the gold key springs the zombie pits; zombies shrug off pellets, fall and rise, throw flesh, and die only when gibbed |
| `npm run test:e1m4` | the Grisly Grotto: two buttons open the underwater door; swim through, surface for the secret, water-jump onto the ledge, exit to E1M8 |
| `npm run test:e1m6` | The Door To Chthon: the gold runekey doors refuse, the key wakes its guard, the doors take the key and open, the silver doors stay shut, the exit to E1M7 |

Tools for the same purpose:

```bash
npm run check          # compile every sql/*.sql against the engine, nothing else
npm run bench          # where a tic and a frame spend their time
npm run screenshots    # headless frames to docs/ (node scripts/screenshot.mjs e1m1 --at=x,y,z,yaw [--fast] [--compare])
```

The screenshot tool can also start from a spot, run SQL first and let the world turn, which is how the
pictures above were taken:

```bash
node scripts/screenshot.mjs e1m1 docs/slime    --at=1392,824,-402,90  --tics=8  --single --fast
node scripts/screenshot.mjs e1m1 docs/grunts   --at=1150,1030,-250,330 --tics=12 --single --fast
node scripts/screenshot.mjs e1m1 docs/slipgate --at=1312,800,-240,270 --tics=10 --single --fast
node scripts/screenshot.mjs e1m7 docs/chthon   --at=-300,64,56,0 --sql="EXECUTE PROCEDURE boss_awake((SELECT id FROM ents WHERE mtype = 'boss'))" --tics=70 --single --fast
node scripts/screenshot.mjs e1m8 docs/lavahall --at=992,-96,-706,270 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/scrag    --at=96,-120,-594,315 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/jump     --at=992,-96,-676,270 --sql="UPDATE ents SET vz = 300 WHERE id = (SELECT ent_id FROM player); UPDATE player SET pitch = 45" --tics=55 --single --fast
node scripts/screenshot.mjs e1m8 docs/g --gallery --fast     # a shot from every item spot: how to find views of a level
```

## Layout

```
sql/schema.sql     tables: the BSP, the models, the edicts, the player, the game, the events
sql/physics.sql    traces against the hulls, linking, water, the movement procedures
sql/game.sql       spawning, movers, triggers, items, damage, projectiles, the entity lump
sql/weapons.sql    the player's tic: movement, firing, impulses
sql/monsters.sql   the AI, the pushers, the think and physics loops, QUAKE_TIC, INIT_MAP
sql/render.sql     visibility and projection
src/loader.js      BSP and MDL to tables, the generated bulk loaders
src/main.js        the page: input, the game loop, settings, the console
src/renderer.js    the painter
src/audio.js       sound events, ambients, music
scripts/           the tests, the benchmark, the screenshot tool, the pak fetcher, the build
```

## Firebird lessons

- **Derived tables are inlined** and `IN (subquery)` can scan the whole table: `JOIN` the marked set
  instead, and the join to the vertices becomes an index walk.
- **Expressions in the select list are cheap; PSQL statements are not.** Moving the per-vertex
  arithmetic out of the loop body and into the cursor's select list cut the frame query by half.
- **Rows are the cost.** Emitting ~2000 vertex rows costs ~35 ms; emitting the ~400 face rows they
  belong to costs ~8 ms. Filter before you join: a predicate on the joined row still walks every vertex.
- **Keep what does not change.** The PVS marking is kept until the eye enters another leaf; items at
  rest are not relinked.
- **Bind as text.** The WASM build cannot bind binary parameters, so bulk data goes in as text and is
  parsed by generated PSQL loaders, which beat `EXECUTE BLOCK`s of `INSERT`s.
- **Recursion works**, and deep enough for a BSP hull: `RHC` calls itself for each side of each plane.
- **`CASE` and `IIF` over string literals pad the result** to the longest branch, so a sound name
  picked that way wants a `TRIM` before it reaches the pak.
- **Floating-point time drifts.** Thinks scheduled at `time + 0.1` are compared with a small
  tolerance, or a monster thinks at 8 Hz instead of 10.
- **Smaller things:** a `VARCHAR` longer than 8191 needs `CHARACTER SET ASCII`; `INSERT ... VALUES`
  takes one row; a procedure that calls one declared later needs a stub with the same signature
  first; `at` is a reserved word.

## Licence

MIT for the code here. Firebird and Electric Firebird are Apache-2.0. The Quake shareware episode is
freely redistributable; Quake is a trademark of id Software.
