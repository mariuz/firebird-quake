# Firebird Quake



![E1M1 rendered from Firebird query results](docs/screenshot-e1m1-0.png) ![a grunt](docs/grunt-e1m1-0.png)



Quake, simulated and rendered inside the [Firebird](https://firebirdsql.org) SQL database, running

entirely in your browser on Firebird 6 compiled to WebAssembly. A port of the idea behind

[Firebird DOOM](https://github.com/mariuz/firebird-doom) to a true 3D engine.



Every game tic is a PSQL procedure call. Every frame is a `SELECT`. JavaScript handles the keyboard,

the mouse and the canvas; everything else â€” collision against the BSP hulls, the player's physics,

doors, platforms, triggers, items, weapons, damage, the monster AI, and the visibility and projection of

every polygon on screen â€” happens in SQL.



```

keyboard/mouse â†’ SELECT * FROM quake_tic(...)     game logic: 20 Hz, PSQL

               â†’ SELECT * FROM frame_faces        visible polygons, projected, with texel coordinates

               â†’ SELECT * FROM frame_ents         alias models and sprites in the PVS, with their pose

               â†’ SELECT * FROM frame_lightstyles  this frame's light animation

               â†’ SELECT ... FROM sound_events     what to play, and where

               â†’ JS rasterises polygons and models through the colormap â†’ canvas

```



## Running it



```bash

npm install

npm run fetch-pak      # downloads the Quake shareware episode (quake106.zip) and extracts id1/pak0.pak

npm test               # SQL smoke test in Node against the real Firebird WASM engine

npm run test:boss      # E1M7: the rune wakes Chthon, lava, both terminals, three bolts, the exit opens
npm run test:registered # the pak1 monsters' AI, spawned into E1M1 without their models
npm run test:e1m8      # Ziggurat Vertigo: sv_gravity 100, so jumps and grenades go far; the exit leads to E1M5
npm run test:e1m5      # the crucified zombies (start map) and Gloom Keep's flooded moat: swimming, breath, drowning
npm run test:e1m2      # Castle of the Damned: the drawbridge slab sinks into the moat, the player wades across
npm run test:e1m3      # the Necropolis: the gold key springs the zombie pits; zombies die only when gibbed
npm run test:e1m4      # the Grisly Grotto: two buttons open the underwater door; swim through, surface for the secret, water-jump out, exit to E1M8

npm run serve          # http://localhost:8080/ â€” add --coi if your browser blocks service workers

npm run screenshots    # headless frames to docs/ (node scripts/screenshot.mjs e1m1 --at=x,y,z,yaw)

```



`fetch-pak` needs a tool that can read the LHA archive inside the shareware zip: 7-Zip, `lha` or

`lhasa` (`sudo apt-get install lhasa` on Debian/Ubuntu). If you own Quake, you can instead point the

page at your own `pak0.pak`/`pak1.pak` with the file picker, or copy it with

`PAK=/path/to/pak0.pak npm run fetch-pak`.



Firebird WASM uses pthreads, so the page must be cross-origin isolated. The dev server sends the

COOP/COEP headers with `--coi`; a static host like GitHub Pages cannot, so `coi-serviceworker.js`

re-issues responses with the headers after a one-time reload.



## How it works



### The BSP becomes tables (`sql/schema.sql`, `src/loader.js`)



A BSP file is a relational database in disguise. `loader.js` parses it (`src/bsp.js`) and copies it in,

denormalised so the hot loops never need a second lookup:



| table | from |

|---|---|

| `faces` | FACES + PLANES (flipped for `side`) + TEXINFO, plus a bounding sphere |

| `face_verts` | EDGES and SURFEDGES resolved to an ordered vertex list per face |

| `leaves` | LEAVES with the PVS decompressed to a hex string (leaf *j* visible â‡” bit *jâˆ’1*) |

| `marksurfaces`, `hulls` | MARKSURFACES; NODES (hull 0) and CLIPNODES (hulls 1 and 2), planes copied in |

| `models`, `anims` | the world, its submodels (`*N`), the `b_*.bsp` boxes, every `.mdl` with its frame runs |

| `map_ents` | the entity lump |



The WASM build binds parameters as text, so each table has a generated `LOAD_<table>` procedure that

parses 30 KB chunks of `|`-separated lines in PSQL â€” about 2.5Ã— faster than a block of `INSERT`s.

E1M1 (70 k rows) loads in about two seconds.



### Collision is a recursive procedure (`sql/physics.sql`)



`RHC` is `SV_RecursiveHullCheck`: it splits the segment at every plane it crosses and recurses into both

sides, threading the trace state (`allsolid`, `startsolid`, `inopen`, `inwater`, the fraction and the hit

plane) through its parameters, because PSQL procedures can call themselves. `TRACE_MOVE` picks the hull

by the moving box's size, runs it against the world and against every brush-model entity at its own

origin, and clips against monsters and the player with a Minkowski slab test. `FLY_MOVE`, `WALK_MOVE`

(with the 18-unit step), `MOVE_STEP` (monsters), `TOSS_MOVE` and `PUSH_MOVE` (doors crushing and

carrying) are sv_phys.c; the clip planes and the pushed entities live in global temporary tables

because PSQL has no arrays. A primary-key lookup costs about 4 Âµs in the WASM engine, so a trace is

well under a millisecond.



### The game is PSQL (`sql/game.sql`, `sql/weapons.sql`, `sql/monsters.sql`)



`QUAKE_TIC` runs the player (client.qc: water, jumping, friction, acceleration, the trigger and item

touches, powerups), the pushers (with `SUB_CalcMove` semantics), the thinks that are due, and the

physics of everything that flies, bounces or falls. Doors link by touching boxes and need keys;

platforms, buttons, trains with path corners and secret doors move as in doors.qc and plats.qc. Items and

weapons from the axe to the thunderbolt, armour, damage momentum, gibs and backpacks are items.qc,

weapons.qc and combat.qc. The monsters run ai.qc's state machine â€” `FIND_TARGET`, `MOVE_TO_GOAL`,

`NEW_CHASE_DIR`, `CHECK_ATTACK` â€” with the grunt, dog, knight, ogre, scrag, fiend, zombie, shambler and

Chthon's attacks defined in `monster_types` and a few `CASE` branches. Everything the simulation wants

heard is a row in `sound_events`; visual effects are rows in `fx_events`.



### The renderer is a query (`sql/render.sql`)



`FRAME_FACES` finds the leaf the eye is in and, once per leaf, marks every face of every leaf in its PVS

into `vis_faces` (Quake's `visframe`). Visible brush models are marked too, at their origin. One cursor

then joins the marked faces to their vertices, dropping back faces and faces whose bounding sphere is

outside the frustum in the `WHERE` clause and computing the view transform, the projection and the texel

coordinates in the select list â€” evaluated by the engine rather than as PSQL statements, which cost

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

lightmap, run through the colormap â€” r_surf.c. Alias models are drawn with the lightmap value under

the entity and Gouraud light from the vertex normals, clipped against the near plane triangle by

triangle; sprites are billboards; the sky is Quake's two scrolling layers mapped by the pixel's

direction; explosions and blood are particles. The status bar comes from `gfx.wad`.



Sound: `sound_events` rows are played with the Web Audio API, attenuated and panned from where they

happened. Entity ambients (drips, hums, torches) loop at their entities; the water and wind ambients come

from the BSP leaf the player is in, which `QUAKE_TIC` reports each frame. Quake's music was CD audio, not

in the pak: put `track02.ogg`…`track11.ogg` (or `.mp3`) in `public/music/`, or pick that folder in the

page, and each map plays its `worldspawn` track; without them a synthesised drone fills in.



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



## Licence



MIT for the code here. Firebird and Electric Firebird are Apache-2.0. The Quake shareware episode is

freely redistributable; Quake is a trademark of id Software.

