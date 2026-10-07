# Screenshots

Every frame here is the result of a query: the SQL ran in Firebird WASM under Node and the painter
drew the rows headlessly, with `scripts/screenshot.mjs`. The command block under each level reproduces
its pictures. `--at` places the player, `--sql` runs statements (wake a boss, fire a button or a
trigger), `--tics` lets the world run, in as many steps as a scene needs; `--gallery` renders a view
from every item spot in a level, which is how most of these spots were found:

```bash
node scripts/screenshot.mjs e1m8 docs/g --gallery --fast     # docs/g-e1m8-gallery-NN_<item>_<x>_<y>_<z>_<yaw>.png
```

## The start map

![the hall of the skill doors](skills-start-0.png) ![the crucified zombies twitching over the lava, the decoration the E1M5 test checks first](crucified-start-0.png) ![the slipgate to episode 1](episode1-start-0.png) ![the slipgate to episode 3](episode3-start-0.png) ![the slipgate to episode 4](episode4-start-0.png)

1. the hall of the skill doors
2. the crucified zombies twitching over the lava, the decoration the E1M5 test checks first
3. the slipgate to episode 1
4. the slipgate to episode 3
5. the slipgate to episode 4

The start map has no items, so these views were posed from the entity list: the zombies on the walls and the four episode gates. The gate to episode 2 is behind bars in the shareware version.

```bash
node scripts/screenshot.mjs start docs/skills    --single --fast
node scripts/screenshot.mjs start docs/crucified --at=856,840,60,90 --tics=4 --single --fast
node scripts/screenshot.mjs start docs/episode1  --at=-64,1250,130,90 --tics=4 --single --fast
node scripts/screenshot.mjs start docs/episode3  --at=1536,2830,255,90 --tics=4 --single --fast
node scripts/screenshot.mjs start docs/episode4  --at=1700,1728,-200,0 --tics=4 --single --fast
```

## E1M1, the Slipgate Complex

![from the start](screenshot-e1m1-0.png) ![a grunt](grunt-e1m1-0.png) ![the slime hall, its teleporter and the yellow armour](slime-e1m1-0.png) ![two grunts coming over the bridge, twelve tics after they spot the player](grunts-e1m1-0.png) ![the exit slipgate](slipgate-e1m1-0.png)

1. from the start
2. a grunt
3. the slime hall, its teleporter and the yellow armour
4. two grunts coming over the bridge, twelve tics after they spot the player
5. the exit slipgate

```bash
node scripts/screenshot.mjs e1m1 docs/screenshot --single --fast
node scripts/screenshot.mjs e1m1 docs/slime    --at=1392,824,-402,90  --tics=8  --single --fast
node scripts/screenshot.mjs e1m1 docs/grunts   --at=1150,1030,-250,330 --tics=12 --single --fast
node scripts/screenshot.mjs e1m1 docs/slipgate --at=1312,800,-240,270 --tics=10 --single --fast
```

## E1M2, Castle of the Damned

![the drawbridge slab standing in the moat channel, from the near bank](bridgeup-e1m2-0.png) ![the same spot four seconds later: stepping onto the bank has sunk the slab, and the moat can be waded (the E1M2 test)](bridgedown-e1m2-0.png) ![the gold key between its two demon torches](keyroom-e1m2-0.png) ![grunts in the beamed hall](hall-e1m2-0.png)

1. the drawbridge slab standing in the moat channel, from the near bank
2. the same spot four seconds later: stepping onto the bank has sunk the slab, and the moat can be waded (the E1M2 test)
3. the gold key between its two demon torches
4. grunts in the beamed hall

The bank in front of the slab is the trigger that lowers it, so the second frame needed no SQL, only time.

```bash
node scripts/screenshot.mjs e1m2 docs/bridgeup   --at=1400,-564,229,0 --tics=2  --single --fast
node scripts/screenshot.mjs e1m2 docs/bridgedown --at=1400,-564,229,0 --tics=80 --single --fast   # the bank is the trigger
node scripts/screenshot.mjs e1m2 docs/keyroom    --at=880,-300,470,270 --tics=8 --single --fast
node scripts/screenshot.mjs e1m2 docs/hall       --at=536,-1264,438,90 --tics=8 --single --fast
```

## E1M3, the Necropolis

![zombies up out of the pits, four seconds after the trap springs (the E1M3 test)](pits-e1m3-0.png) ![zombies in the arched hall](zombies-e1m3-0.png) ![a zombie shambling down a corridor](corridor-e1m3-0.png)

1. zombies up out of the pits, four seconds after the trap springs (the E1M3 test)
2. zombies in the arched hall
3. a zombie shambling down a corridor

The trap is the trigger the gold key lies on; the first frame fires it through SQL with the player standing between the key and the nearest pit.

```bash
node scripts/screenshot.mjs e1m3 docs/pits     --at=-900,-240,-330,90 --sql="UPDATE player SET pitch = 5; EXECUTE PROCEDURE trigger_fire((SELECT id FROM ents WHERE classname = 'trigger_once' AND target = 't83'), (SELECT ent_id FROM player))" --tics=80 --single --fast
node scripts/screenshot.mjs e1m3 docs/zombies  --at=-128,-824,-322,0 --tics=8 --single --fast
node scripts/screenshot.mjs e1m3 docs/corridor --at=1352,120,-130,0 --tics=8 --single --fast
```

## E1M4, the Grisly Grotto

![the carved gate](arch-e1m4-0.png) ![knights across the lake](lake-e1m4-0.png) ![the super nailgun in its chamber](tunnel-e1m4-0.png) ![the ledge with the secret slipgate to Ziggurat Vertigo, seen from the water, where the E1M4 test surfaces](ledge-e1m4-0.png)

1. the carved gate
2. knights across the lake
3. the super nailgun in its chamber
4. the ledge with the secret slipgate to Ziggurat Vertigo, seen from the water, where the E1M4 test surfaces

The underwater door the test swims through was rendered too, shut and then open, but the lake bottom has no light and both frames came out black.

```bash
node scripts/screenshot.mjs e1m4 docs/arch     --at=-472,2080,1230,45 --tics=8 --single --fast
node scripts/screenshot.mjs e1m4 docs/lake     --at=1088,-784,846,135 --tics=8 --single --fast
node scripts/screenshot.mjs e1m4 docs/tunnel   --at=704,1408,542,270 --tics=8 --single --fast
node scripts/screenshot.mjs e1m4 docs/ledge    --at=1288,1350,845,90 --tics=4 --single --fast
```

## E1M5, Gloom Keep

![under the water of the flooded moat, where the E1M5 test holds its breath](flooded-e1m5-0.png) ![the moat courtyard with its round window](moat-e1m5-0.png) ![the stained-glass hall](glass-e1m5-0.png) ![a knight on the checkered floor](knight-e1m5-0.png) ![an ogre at the wooden gate](goldkey-e1m5-0.png)

1. under the water of the flooded moat, where the E1M5 test holds its breath
2. the moat courtyard with its round window
3. the stained-glass hall
4. a knight on the checkered floor
5. an ogre at the wooden gate

```bash
node scripts/screenshot.mjs e1m5 docs/flooded  --at=-312,314,-12,0 --tics=4 --single --fast
node scripts/screenshot.mjs e1m5 docs/moat     --at=-792,1608,158,315 --tics=2 --single --fast
node scripts/screenshot.mjs e1m5 docs/glass    --at=128,1840,-18,180 --tics=8 --single --fast
node scripts/screenshot.mjs e1m5 docs/knight   --at=-1128,1344,162,180 --tics=8 --single --fast
node scripts/screenshot.mjs e1m5 docs/goldkey  --at=-760,2248,330,315 --tics=2 --single --fast
```

## E1M6, The Door To Chthon

![a second and a half after taking the gold runekey: the fiend that guards it is awake across the lava](runekey-e1m6-0.png) ![the gold runekey doors, shut](golddoors-e1m6-0.png) ![the doors take the key and slide aside (the E1M6 test)](goldopen-e1m6-0.png) ![a slipgate between its red torches](slipgate-e1m6-0.png) ![the pillared hall](pillars-e1m6-0.png) ![the banner hall](banners-e1m6-0.png)

1. a second and a half after taking the gold runekey: the fiend that guards it is awake across the lava
2. the gold runekey doors, shut
3. the doors take the key and slide aside (the E1M6 test)
4. a slipgate between its red torches
5. the pillared hall
6. the banner hall

The hallway to the exit for E1M7 is held by a shambler who charges the moment the player appears, so that view is a shambler's back.

```bash
node scripts/screenshot.mjs e1m6 docs/runekey   --at=224,120,62,90 --sql="UPDATE player SET pitch = 10" --tics=30 --single --fast
node scripts/screenshot.mjs e1m6 docs/golddoors --at=250,704,31,0 --tics=4 --single --fast
node scripts/screenshot.mjs e1m6 docs/goldopen  --at=250,704,31,0 --sql="EXECUTE PROCEDURE door_fire(6, (SELECT ent_id FROM player))" --tics=40 --single --fast
node scripts/screenshot.mjs e1m6 docs/slipgate  --at=-472,136,110,250 --tics=8 --single --fast
node scripts/screenshot.mjs e1m6 docs/pillars   --at=-40,1184,-306,135 --tics=8 --single --fast
node scripts/screenshot.mjs e1m6 docs/banners   --at=672,152,30,135 --tics=8 --single --fast
```

## E1M7, the House of Chthon

![from the start](screenshot-e1m7-0.png) ![the rune on the floor of the hall](rune-e1m7-0.png) ![Chthon risen from the lava](chthon-e1m7-0.png) ![Chthon winds up a lava ball, both lightning terminals raised](lavathrow-e1m7-0.png) ![Chthon from the far end of the hall, where the lightning button is](behind-e1m7-0.png) ![eight tics after the third bolt: Chthon sinks back into the lava (the E1M7 test)](death-e1m7-0.png)

1. from the start
2. the rune on the floor of the hall
3. Chthon risen from the lava
4. Chthon winds up a lava ball, both lightning terminals raised
5. Chthon from the far end of the hall, where the lightning button is
6. eight tics after the third bolt: Chthon sinks back into the lava (the E1M7 test)

The death frame is staged in steps: wake Chthon and raise the terminals, wait six seconds, fire three bolts a few tics apart, wait eight tics. A second later the pit is empty.

```bash
node scripts/screenshot.mjs e1m7 docs/screenshot --single --fast
node scripts/screenshot.mjs e1m7 docs/rune     --at=-120,64,20,0 --tics=2 --single --fast
node scripts/screenshot.mjs e1m7 docs/chthon   --at=-300,64,56,0 --sql="EXECUTE PROCEDURE boss_awake((SELECT id FROM ents WHERE mtype = 'boss'))" --tics=70 --single --fast
node scripts/screenshot.mjs e1m7 docs/lavathrow --at=-300,64,56,0 --sql="EXECUTE PROCEDURE boss_awake(2); EXECUTE PROCEDURE button_fire(22, (SELECT ent_id FROM player)); EXECUTE PROCEDURE button_fire(24, (SELECT ent_id FROM player))" --tics=120 --single --fast
node scripts/screenshot.mjs e1m7 docs/behind   --at=824,64,180,180 --sql="EXECUTE PROCEDURE boss_awake(2)" --tics=70 --single --fast
node scripts/screenshot.mjs e1m7 docs/death    --at=-300,64,56,0 --sql="EXECUTE PROCEDURE boss_awake(2); EXECUTE PROCEDURE button_fire(22, (SELECT ent_id FROM player)); EXECUTE PROCEDURE button_fire(24, (SELECT ent_id FROM player))" --tics=120 --sql="EXECUTE PROCEDURE event_lightning_fire(15)" --tics=3 --sql="EXECUTE PROCEDURE event_lightning_fire(15)" --tics=3 --sql="EXECUTE PROCEDURE event_lightning_fire(15)" --tics=8 --single --fast
```

## E1M8, Ziggurat Vertigo

![the lava hall at the bottom of the level](lavahall-e1m8-0.png) ![a scrag over the lava river](scrag-e1m8-0.png) ![the view down from a jump that is still rising three seconds in: gravity here is an eighth of normal (the E1M8 test)](jump-e1m8-0.png) ![the lava channel by the pentagram](pentagram-e1m8-0.png) ![the silver key room, an ogre on the ledge above](silverkey-e1m8-0.png) ![the exit slipgate to E1M5](exit-e1m8-0.png)

1. the lava hall at the bottom of the level
2. a scrag over the lava river
3. the view down from a jump that is still rising three seconds in: gravity here is an eighth of normal (the E1M8 test)
4. the lava channel by the pentagram
5. the silver key room, an ogre on the ledge above
6. the exit slipgate to E1M5

Ziggurat Vertigo is a dark level by design; the lava is the light in most of these.

```bash
node scripts/screenshot.mjs e1m8 docs/lavahall --at=992,-96,-706,270 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/scrag    --at=96,-120,-594,315 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/jump     --at=992,-96,-676,270 --sql="UPDATE ents SET vz = 300 WHERE id = (SELECT ent_id FROM player); UPDATE player SET pitch = 45" --tics=55 --single --fast
node scripts/screenshot.mjs e1m8 docs/pentagram --at=672,536,-706,0 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/silverkey --at=672,152,38,270 --tics=8 --single --fast
node scripts/screenshot.mjs e1m8 docs/exit      --at=1400,-240,31,0 --tics=4 --single --fast
```

## The registered monsters

The enforcer, the hell knight, the vore, the spawn, the rotfish and Shub-Niggurath live in `pak1.pak`,
the registered half of Quake, which the shareware episode does not include; `npm run test:registered`
runs their game logic in E1M1 without their models. With a registered `pak1.pak` beside `pak0.pak` in
`public/pak/` (the page and the screenshot tool pick it up; the page's file picker also takes the two
files together) they can be drawn: here each is spawned a few steps ahead of the player in E1M1's slime
hall and given a moment to notice him.

![an enforcer](enforcer-e1m1-0.png) ![a hell knight](hell_knight-e1m1-0.png) ![a vore](shalrath-e1m1-0.png) ![a spawn: the black blob in front](tarbaby-e1m1-0.png) ![a rotfish, out of its water](fish-e1m1-0.png) ![Shub-Niggurath](oldone-e1m1-0.png)

1. an enforcer
2. a hell knight, sword raised
3. a vore
4. a spawn: the black blob bounding at the player
5. a rotfish, flopping out of its water
6. Shub-Niggurath, filling the hall

```bash
node scripts/screenshot.mjs e1m1 docs/enforcer    --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('enforcer', 160)"    --tics=16 --single --fast
node scripts/screenshot.mjs e1m1 docs/hell_knight --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('hell_knight', 160)" --tics=16 --single --fast
node scripts/screenshot.mjs e1m1 docs/shalrath    --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('shalrath', 130)"    --tics=10 --single --fast
node scripts/screenshot.mjs e1m1 docs/tarbaby     --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('tarbaby', 90)"      --tics=3  --single --fast
node scripts/screenshot.mjs e1m1 docs/fish        --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('fish', 100)"        --tics=6  --single --fast
node scripts/screenshot.mjs e1m1 docs/oldone      --at=1150,1030,-250,330 --sql="SELECT * FROM spawn_monster('oldone', 300)"      --tics=8  --single --fast
```

`spawn_monster` is a selectable procedure, so it is run with `SELECT`; the tool runs a `--sql`
statement that starts with `SELECT` as a query and anything else as a statement. Without `pak1.pak`
the commands still run and the frame shows the hall with an invisible monster in it, which is also
what the registered test sees.

## E2M1, the Installation

The first level of the registered game, from the same `pak1.pak`.

![the flooded entrance hall](entrance-e2m1-0.png) ![the control room](control-e2m1-0.png) ![an enforcer in the corridor](enforcer-e2m1-0.png) ![the gold key room](goldkey-e2m1-0.png) ![the pillared hall](pillars-e2m1-0.png) ![the exit room](exitroom-e2m1-0.png)

1. the flooded entrance hall, a grunt on the far side
2. the control room under its yellow lights
3. an enforcer in the corridor, firing
4. the gold key room with its red lights
5. the pillared hall
6. the exit room, its red machinery and the way to E2M2

```bash
node scripts/screenshot.mjs e2m1 docs/entrance --at=1632,-288,-2,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m1 docs/control  --at=944,1064,158,180 --tics=8 --single --fast
node scripts/screenshot.mjs e2m1 docs/enforcer --at=272,560,30,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m1 docs/goldkey  --at=1848,1320,78,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m1 docs/pillars  --at=576,216,-66,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m1 docs/exitroom --at=60,-24,0,180 --tics=4 --single --fast
```

## E2M2, the Ogre Citadel

![a knight in the stained-glass hall](glass-e2m2-0.png) ![an ogre at the gate](gate-e2m2-0.png) ![the shambler](shambler-e2m2-0.png) ![an ogre in the window](window-e2m2-0.png) ![the gold key's walkway over the pit](walkway-e2m2-0.png) ![an ogre before the exit gate to E2M3](exitogre-e2m2-0.png)

1. a knight in the stained-glass hall
2. an ogre at the gate under its lit lintel
3. the citadel's shambler
4. an ogre in the window
5. the gold key's walkway over the pit
6. an ogre before the red-bannered exit gate to E2M3

```bash
node scripts/screenshot.mjs e2m2 docs/glass    --at=80,480,30,0 --tics=8 --single --fast
node scripts/screenshot.mjs e2m2 docs/gate     --at=152,1608,166,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m2 docs/shambler --at=-296,208,-34,75 --tics=6 --single --fast
node scripts/screenshot.mjs e2m2 docs/window   --at=-208,992,134,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m2 docs/walkway  --at=-552,192,-34,225 --tics=8 --single --fast
node scripts/screenshot.mjs e2m2 docs/exitogre --at=1880,-180,200,0 --tics=6 --single --fast
```

## E2M3, the Crypt of Decay

![the red carved doorway](altar-e2m3-0.png) ![a rotfish under the water](rotfish-e2m3-0.png) ![the shambler at the grated gate](grate-e2m3-0.png) ![an ogre leaping by the window lights](lights-e2m3-0.png) ![the secret slipgate to E2M7](secretgate-e2m3-0.png)

1. the red carved doorway at the end of the hall
2. a rotfish under the surface of the flooded crypt
3. a shambler at the grated gate
4. an ogre leaping by the window lights
5. the secret slipgate to the Underearth, E2M7

```bash
node scripts/screenshot.mjs e2m3 docs/altar      --at=184,-1520,-242,0 --tics=8 --single --fast
node scripts/screenshot.mjs e2m3 docs/rotfish    --at=-56,576,-354,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m3 docs/grate      --at=-1256,1448,-50,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m3 docs/lights     --at=-800,1504,-50,315 --tics=8 --single --fast
node scripts/screenshot.mjs e2m3 docs/secretgate --at=880,1776,-220,0 --tics=4 --single --fast
```

## E2M4, the Ebon Fortress

![the red carved gate](redgate-e2m4-0.png) ![a hell knight](hellknight-e2m4-0.png) ![the moat courtyard, an ogre in the window above](moat-e2m4-0.png) ![the fortress gate](fortgate-e2m4-0.png) ![the stained-glass hall](glass-e2m4-0.png)

1. the red carved gate in the mossy wall
2. a hell knight, sword drawn
3. the moat courtyard, an ogre in the window above
4. the fortress gate, the yellow armour before it
5. the stained-glass hall

```bash
node scripts/screenshot.mjs e2m4 docs/redgate    --at=-1104,1968,158,180 --tics=8 --single --fast
node scripts/screenshot.mjs e2m4 docs/hellknight --at=752,1504,62,15 --tics=10 --single --fast
node scripts/screenshot.mjs e2m4 docs/moat       --at=680,2200,302,45 --tics=8 --single --fast
node scripts/screenshot.mjs e2m4 docs/fortgate   --at=2216,2184,-2,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m4 docs/glass      --at=1024,1408,182,180 --tics=8 --single --fast
```

## E2M5, the Wizard's Manse

![an ogre under the orange windows](windows-e2m5-0.png) ![a fiend leaping in the pillared hall](fiend-e2m5-0.png) ![the water pool](pool-e2m5-0.png) ![the red carved gate](redgates-e2m5-0.png) ![the great hall](greathall-e2m5-0.png) ![the thunderbolt, over the flooded hall](thunderbolt-e2m5-0.png)

1. an ogre under the manse's orange windows
2. a fiend leaping in the pillared hall, an ogre below
3. the water pool and the doorway beyond it
4. the red carved gate
5. the great hall and its steps
6. the thunderbolt, picked up over the flooded hall

```bash
node scripts/screenshot.mjs e2m5 docs/windows     --at=704,704,-18,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m5 docs/fiend       --at=112,1408,30,90 --tics=8 --single --fast
node scripts/screenshot.mjs e2m5 docs/pool        --at=-600,2032,-106,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m5 docs/redgates    --at=-1024,3152,-42,225 --tics=8 --single --fast
node scripts/screenshot.mjs e2m5 docs/greathall   --at=-520,3160,-106,270 --tics=8 --single --fast
node scripts/screenshot.mjs e2m5 docs/thunderbolt --at=-672,1392,-74,270 --tics=8 --single --fast
```
