# Working on Firebird Quake

Quake 1 simulated and rendered inside Firebird SQL (WASM, in the browser). Read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before touching the engine and
[docs/ROADMAP.md](docs/ROADMAP.md) before choosing what to build. The README is the user-facing
overview; [docs/screenshots.md](docs/screenshots.md) shows every level with the command that rendered it.

## Commands

```bash
npm run fetch-pak              # shareware pak0.pak into public/pak/ (needs 7-Zip, lha or lhasa)
npm run fetch-librequake       # LibreQuake lite into public/pak/lq1/ (free pak0 + pak1)
npm run check                  # compile every sql/*.sql against the engine (first error with its line)
npm test                       # SQL smoke test on E1M1
npm run test:boss | test:registered | test:e1m2 … test:e1m8   # the scene tests, one level each
npm run test:qcvm              # the QuakeC VM runs the real progs.dat (PAK=... for another)
npm run test:qcplay            # QuakeC mode: E1M1 played by progs.dat on the engine's physics
npm run test:qctic             # the page's QuakeC mode: qc_tic's row, the intermission, a level change
npm run test:qcai              # QuakeC monsters: a grunt sees, shoots and dies; a dog runs at the player
npm run bench                  # timings of a tic, the traces, a monster think, the frame queries
npm run bench:qc               # the QuakeC VM: µs per statement, per call, ms per server frame asleep and awake
npm run serve                  # http://localhost:8080/ (add --coi for browsers without service workers)
node scripts/screenshot.mjs <map> <prefix> --at=x,y,z,yaw --sql="…" --tics=N --single --fast   # a posed frame
node scripts/screenshot.mjs <map> <prefix> --gallery --fast                                     # a view per item spot
```

`PAK=… PAK1=…` choose the paks for the smoke test and the screenshot tool. The pak files are
git-ignored and must never be committed; a registered `pak1.pak` is local only.

## Conventions

- Game logic goes in PSQL (`sql/`), never in JavaScript: the JS only reads input, paints and plays.
- Keep the file order and the forward-declaration stubs (`CREATE OR ALTER PROCEDURE x (...) AS BEGIN END^`) in each SQL file; a stub's signature must equal the real one.
- `TRIM` any name or state picked with `IIF`/`CASE` over literals (Firebird pads to the longest).
- Compare think times with a tolerance (`nextthink <= :t + 1e-6`).
- Selectable procedures (`spawn_monster`) run only through `SELECT * FROM`.
- Sources are UTF-8; the working copy is CRLF (git `autocrlf`), the repository LF. Do not re-encode files.
- Commit messages are one descriptive sentence in plain words, then a `Co-Authored-By` trailer naming the model that did the work (since 2026-10-07 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; earlier commits name Claude Fable 5.1). The owner commits with `git -c user.email="mapopa@gmail.com" -c user.name="Popa Adrian Marius"`.
- After every change: run the affected tests, commit, push to `main`, and watch CI (`gh run watch <id> --exit-status`); the push deploys the site.

## When a test is flaky

Run it three times locally. The known causes: a monster's first think is random within 0.6 s (wait
before asserting on frames), AI choices near the scene are random (set the bystanders dead and
non-solid), and `sound_events`/`fx_events` expire after 40 tics (poll each tic). Fix the test's
timing rather than loosening the assertion.

## Adding a scene test

Copy the nearest `scripts/e1mN-test.mjs`: `teleport`, `run`, `sounds`, `q1`/`qa` helpers; find
positions with the entity table (`SELECT ... FROM ents WHERE classname = ...`) and `test_position`;
fire procedures directly (`door_fire`, `button_fire`, `trigger_fire`, `boss_awake`) to stage; assert
on `ents` and the tic row. Add it to `package.json` and as a step in `.github/workflows/pages.yml`,
and a row in the README's test table.

## Adding screenshots of a level

`--gallery`, tile the PNGs into a contact sheet, pick spots, render each into `docs/<name>-<map>-0.png`
with `--single --fast`, add a section to `docs/screenshots.md` (images, numbered captions, the
commands), check every referenced image exists, commit.
