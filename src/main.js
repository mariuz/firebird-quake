// main.js – boot Firebird in a Worker, load the PAK into it, run the loop.
//
// Per frame the browser does a handful of queries:
//   SELECT * FROM quake_tic(...)      – advance the game by N tics
//   SELECT * FROM frame_faces         – the polygons on screen
//   SELECT * FROM frame_ents          – the models in view
//   SELECT * FROM frame_lightstyles   – this frame's light animation
//   SELECT ... FROM sound_events / fx_events
// and then paints. All game state lives in Firebird tables.

import { FirebirdBrowser } from 'firebird-wasm/browser';
import schemaSql from '../sql/schema.sql';
import physicsSql from '../sql/physics.sql';
import gameSql from '../sql/game.sql';
import weaponsSql from '../sql/weapons.sql';
import monstersSql from '../sql/monsters.sql';
import renderSql from '../sql/render.sql';
import qcvmSql from '../sql/qcvm.sql';
import saveSql from '../sql/save.sql';
import demoSql from '../sql/demo.sql';
import { Pak, Wad2, loadPalette, PakSet, qpic } from './pak.js';
import { createSchema, loadResources, loadMap, loadProgs, setView } from './loader.js';
import { QcJit } from './qcjit.js';
import { exportSave, importSave, SaveStore } from './saves.js';
import { exportDemo, importDemo, DemoPlayer } from './demos.js';
import { frameDlights, dlightAt } from './dlights.js';
import { Menu } from './menu.js';
import { Renderer, lightPoint } from './renderer.js';
import { Hud, VIEW_MODELS } from './hud.js';
import { QuakeAudio } from './audio.js';

const $ = (id) => document.getElementById(id);
const canvas = $('screen');
const statusEl = $('status');
const statsEl = $('stats');
const TIC_MS = 50;

let db, pak, res, renderer, hud, wad;
let map = null;          // { name, bsp }
let last = null;         // last QUAKE_TIC row
let running = false;
let paused = false;
let lastTic = 0;
let lastSoundId = 0;
let lastFxId = 0;
let finaleShown = false;
let menu = null;           // Quake's menu (src/menu.js): up, the game pauses
let interWait = 0;         // the PSQL game's intermission: when it began (the stats stay until fire)
let finaleStart = 0;       // game time the finale's text began (QuakeC's svc_finale)
let cdTrack = -1;          // the track svc_cdtrack asked for
let lastDraw = null;       // the last frame's rows, drawn again under the intermission
let muzzleUntil = 0;       // the player's muzzle flash lights the room until then (game time)
let prevWeaponFrame = 0;
let beams = [];          // lightning beams to draw briefly
let explosions = [];
const settings = { map: 'start', detail: 'high', sfx: 70, music: 50, musicMode: 'tracks', skill: 1, fov: 90, renderer: 'fast', data: 'shareware', logic: 'psql',
  sensitivity: 3, alwaysRun: true, invertMouse: false };
let progsLoaded = false;   // the pak's progs.dat in the QuakeC VM's tables (QuakeC mode)
let jit = null;            // its hot functions compiled to PSQL procedures (src/qcjit.js)
let jitTics = 0;
let pakKey = '';           // the paks in use: saves are kept per data set (model ids depend on the paks)
let saveSlots = new Array(12).fill(null);   // the menu's slot names (SaveGame_Comment), from the browser's store
const QUICK_SLOT = 12;     // F6 / F9: Quake's quick.sav, not in the menu's list
let recording = false;     // a demo is being recorded (sql/demo.sql)
let demoPlayer = null;     // a demo playing back: its recorded calls replace the input (src/demos.js)
let demo = null;           // the last demo recorded or opened
try { Object.assign(settings, JSON.parse(localStorage.getItem('firebird-quake:settings') || '{}')); } catch { /* defaults */ }
const saveSettings = () => { try { localStorage.setItem('firebird-quake:settings', JSON.stringify(settings)); } catch { /* ignore */ } };
const viewWidth = () => (settings.detail === 'high' ? 320 : 160);
const viewHeight = () => (settings.detail === 'high' ? 200 : 100);
const sbarLines = () => (settings.detail === 'high' ? 24 : 12);   // the 3D view is the part above the status bar
const audio = new QuakeAudio();
audio.setVolume(settings.sfx / 100);
audio.setMusicVolume(settings.music / 100);
audio.musicMode = settings.musicMode;
for (const ev of ['keydown', 'pointerdown', 'touchstart']) window.addEventListener(ev, () => audio.unlock(), { capture: true });
document.addEventListener('visibilitychange', () => audio.suspend(document.hidden));
const perf = { tic: 0, faces: 0, ents: 0, draw: 0, rows: 0, nfaces: 0 };

function setStatus(msg, isError = false) {
  statusEl.textContent = msg;
  statusEl.classList.toggle('error', isError);
  statusEl.hidden = !msg;
}

// ── input ────────────────────────────────────────────────────────────────
const keys = new Set();
let mouseYaw = 0, mousePitch = 0;
let fireClick = false;
let impulse = 0;
const GAME_KEYS = new Set(['KeyW', 'KeyA', 'KeyS', 'KeyD', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space', 'KeyE',
  'ControlLeft', 'ControlRight', 'ShiftLeft', 'ShiftRight', 'Tab', 'Digit1', 'Digit2', 'Digit3', 'Digit4', 'Digit5', 'Digit6', 'Digit7',
  'Digit8', 'KeyF', 'Comma', 'Period', 'PageUp', 'PageDown', 'Slash']);
window.addEventListener('keydown', (e) => {
  if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return;
  if (!running) return;
  // the menu takes every key while it is up; Escape brings it up (and lets the mouse go)
  if (menu?.active) {
    if (e.code === 'Escape' && performance.now() - menuOpened < 400) { e.preventDefault(); return; }   // the Escape that released the mouse
    if (menu.key(e.code)) e.preventDefault();
    if (!menu.active && running) canvas.requestPointerLock?.()?.catch?.(() => {});
    return;
  }
  if (e.code === 'Escape') { e.preventDefault(); openMenu(); document.exitPointerLock?.(); return; }
  if (GAME_KEYS.has(e.code)) e.preventDefault();
  keys.add(e.code);
  if (e.code.startsWith('Digit')) impulse = Number(e.code.slice(5));
  if (e.code === 'Slash') impulse = 10;
  if (e.code === 'KeyP' || e.code === 'Pause') paused = !paused;
  if (e.code === 'F6') { e.preventDefault(); saveGame(QUICK_SLOT); }
  if (e.code === 'F9') { e.preventDefault(); loadGame(QUICK_SLOT); }
});
window.addEventListener('keyup', (e) => keys.delete(e.code));
let menuOpened = 0;
function openMenu() { if (!menu || menu.active) return; menu.open(); menuOpened = performance.now(); keys.clear(); }
// the browser's Escape releases the mouse before the page hears the key: bring the menu up then, as Quake's Escape does
document.addEventListener('pointerlockchange', () => { if (document.pointerLockElement !== canvas && running && !paused && !interWait) openMenu(); });
window.addEventListener('blur', () => keys.clear());
canvas.addEventListener('click', () => {
  if (running && document.pointerLockElement !== canvas) canvas.requestPointerLock?.()?.catch?.(() => {});
});
canvas.addEventListener('mousedown', (e) => { if (document.pointerLockElement === canvas && e.button === 0) fireClick = true; });
window.addEventListener('mouseup', () => { fireClick = false; });
window.addEventListener('mousemove', (e) => {
  if (document.pointerLockElement === canvas) {
    mouseYaw -= e.movementX * 0.05 * settings.sensitivity;
    mousePitch += e.movementY * 0.05 * settings.sensitivity * (settings.invertMouse ? -1 : 1);
  }
});
window.addEventListener('wheel', (e) => { if (document.pointerLockElement === canvas) impulse = 10; });
// touch: left half moves, right half looks, tap fires
const touch = { move: null, look: null };
canvas.addEventListener('touchstart', (e) => {
  const r = canvas.getBoundingClientRect();
  for (const t of e.changedTouches) {
    const rec = { id: t.identifier, x: t.clientX, y: t.clientY, dx: 0, dy: 0, t: performance.now() };
    if (t.clientX - r.left < r.width / 2) touch.move = rec; else touch.look = rec;
  }
  e.preventDefault();
}, { passive: false });
canvas.addEventListener('touchmove', (e) => {
  for (const t of e.changedTouches) for (const k of ['move', 'look']) {
    const rec = touch[k];
    if (rec && rec.id === t.identifier) {
      if (k === 'look') { mouseYaw -= (t.clientX - rec.x - rec.dx) * 0.4; mousePitch += (t.clientY - rec.y - rec.dy) * 0.4; }
      rec.dx = t.clientX - rec.x; rec.dy = t.clientY - rec.y;
    }
  }
  e.preventDefault();
}, { passive: false });
canvas.addEventListener('touchend', (e) => {
  for (const t of e.changedTouches) for (const k of ['move', 'look']) {
    const rec = touch[k];
    if (rec && rec.id === t.identifier) {
      if (k === 'look' && Math.abs(rec.dx) < 10 && Math.abs(rec.dy) < 10 && performance.now() - rec.t < 250) fireClick = 'tap';
      if (k === 'move' && Math.abs(rec.dx) < 10 && Math.abs(rec.dy) < 10 && performance.now() - rec.t < 250) keys.add('TapJump');
      touch[k] = null;
    }
  }
}, { passive: false });

function readInput(tics) {
  const k = (c) => keys.has(c);
  let fwd = (k('KeyW') || k('ArrowUp') ? 1 : 0) - (k('KeyS') || k('ArrowDown') ? 1 : 0);
  let side = (k('KeyD') || k('Period') ? 1 : 0) - (k('KeyA') || k('Comma') ? 1 : 0);
  const turnKeys = (k('ArrowLeft') ? 1 : 0) - (k('ArrowRight') ? 1 : 0);
  const lookKeys = (k('PageDown') ? 1 : 0) - (k('PageUp') ? 1 : 0);
  const shift = k('ShiftLeft') || k('ShiftRight');
  const run = (settings.alwaysRun ? !shift : shift) ? 1 : 0;     // always run (shift walks), or shift runs
  if (touch.move) {
    fwd = Math.max(-1, Math.min(1, -touch.move.dy / 40));
    side = Math.max(-1, Math.min(1, touch.move.dx / 40));
  }
  const yaw = turnKeys * 7 * tics + mouseYaw;
  const pitch = lookKeys * 5 * tics + mousePitch;
  mouseYaw = 0; mousePitch = 0;
  const fire = k('ControlLeft') || k('ControlRight') || k('KeyF') || fireClick ? 1 : 0;
  if (fireClick === 'tap') fireClick = false;
  const jump = k('Space') || k('KeyE') || k('TapJump') ? 1 : 0;
  keys.delete('TapJump');
  const imp = impulse;
  impulse = 0;
  return [tics, fwd, side, yaw, pitch, fire, jump, run, imp];
}

// ── maps ─────────────────────────────────────────────────────────────────
// save: an exported save game (src/saves.js) to put back on the freshly loaded map instead of a new spawn;
// seed: the level's random seed (a demo's), else init_map picks one
async function startMap(name, newGame, { save = null, seed = null } = {}) {
  running = false;
  if (recording) await stopRecording();   // a demo is one level
  if (!seed) demoPlayer = null;
  setStatus(`Loading ${name} into Firebird…`);
  const t0 = performance.now();
  // QuakeC mode: the client's parms leave with it (SetChangeParms), the level is spawned by progs.dat's own spawn
  // functions after the geometry is loaded, and the parms come back (sql/qcvm.sql: qc_change_parms, qc_begin_map)
  const qc = settings.logic === 'qc';
  if (qc && !newGame && progsLoaded) await db.exec('EXECUTE PROCEDURE qc_change_parms');
  if (!qc) await db.exec('EXECUTE PROCEDURE qc_leave');
  const bsp = await loadMap(db, pak, res, name, { skill: settings.skill, newGame, seed });
  if (qc) {
    if (!progsLoaded) {
      setStatus('Loading progs.dat into the QuakeC VM…');
      jit = new QcJit(db, await loadProgs(db, pak));
      await jit.init();
      progsLoaded = true;
    }
    if (save) await db.exec('EXECUTE PROCEDURE qc_enter');   // the save's edicts replace the spawn
    else {
      setStatus(`Spawning ${name} through QuakeC…`);
      await db.exec(`EXECUTE PROCEDURE qc_begin_map(${settings.skill}, ${newGame ? 0 : 1})`);
    }
    // the functions the spawn ran more than once, compiled to procedures (the rest follow as they get hot)
    setStatus('Compiling QuakeC to PSQL…');
    await jit.compileHot({ min: 2, max: 32 });
  }
  if (save) {
    setStatus(`Loading the saved game…`);
    await importSave(db, save);
    await db.exec(`EXECUTE PROCEDURE load_game(${save.slot})`);
  }
  map = { name, bsp };
  renderer.setResources(res);
  renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
  renderer.particles = [];
  beams = []; explosions = [];
  interWait = 0; finaleStart = 0; cdTrack = -1; lastDraw = null; muzzleUntil = 0; prevWeaponFrame = 0;
  audio.setAmbients(bsp.entities);
  const world = bsp.entities.find((e) => e.classname === 'worldspawn');
  audio.playMusic(Number(world?.sounds ?? 0));
  const { rows } = await db.query('SELECT MAX(id) m FROM sound_events');
  lastSoundId = rows[0].M ?? 0;
  lastFxId = 0;
  console.log(`[firebird-quake] ${name} loaded in ${(performance.now() - t0).toFixed(0)} ms`);
  setStatus('');
  $('mapname').textContent = name;
  $('map').value = name;
  lastTic = performance.now();
  running = true;
}

// ── save games (sql/save.sql, src/saves.js) ───────────────────────────────
// Host_Savegame_f: save_game copies the state's rows into the slot, and the browser keeps them
async function saveGame(slot) {
  if (!running || !db) return;
  try {
    await db.exec(`EXECUTE PROCEDURE save_game(${slot})`);
    const save = await exportSave(db, slot);
    if (SaveStore.available()) await SaveStore.put(pakKey, slot, save);
    if (slot < 12) saveSlots[slot] = save.meta.COMMENT;
    flash(`Saving game to s${slot === QUICK_SLOT ? 'quick' : slot}.sav... ${save.meta.COMMENT.replace(/ +/g, ' ')}`);
  } catch (err) {
    flash(sqlMessage(err), true);
  }
}

// Host_Loadgame_f: the save's map loaded under the save's logic, then load_game puts the rows back
async function loadGame(slot) {
  if (!db || !pak) return;
  try {
    const save = SaveStore.available() ? await SaveStore.get(pakKey, slot) : null;
    if (!save) { flash('no saved game in that slot', true); return; }
    const logic = save.meta.QC_MODE === 1 ? 'qc' : 'psql';
    if (logic !== settings.logic) { settings.logic = logic; $('logic').value = logic; }
    settings.skill = save.meta.SKILL; $('skill').value = String(save.meta.SKILL); saveSettings();
    await startMap(save.meta.MAP_NAME, true, { save });
  } catch (err) {
    console.error(err);
    setStatus(sqlMessage(err), true);
  }
}

const refreshSaves = async () => { try { saveSlots = SaveStore.available() ? await SaveStore.list(pakKey) : new Array(12).fill(null); } catch { saveSlots = new Array(12).fill(null); } };
// the line Firebird's exception carries (save_error's text), not the whole report
const sqlMessage = (err) => {
  const lines = String(err.message).split('\n').map((l) => l.replace(/^-/, ''));
  const i = lines.findIndex((l) => l.includes('SAVE_ERROR'));   // -"PUBLIC"."SAVE_ERROR", then its text
  return i >= 0 && lines[i + 1] ? lines[i + 1] : err.message;
};
let flashTimer = 0;
function flash(msg, isError = false) {
  setStatus(msg, isError);
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => { if (running) setStatus(''); }, 2500);
}

// ── demos (sql/demo.sql, src/demos.js) ─────────────────────────────────────
// Record: the level again as a new game, then every quake_tic call's arguments; Play: the level with the
// demo's seed, skill and logic, fed the recorded calls. The last demo is kept in the browser and can be
// saved as a file.
async function startRecording() {
  if (!map || demoPlayer) return;
  await startMap(map.name, true);
  await db.exec('EXECUTE PROCEDURE demo_record');
  recording = true;
  updateDemoButtons();
  flash(`recording a demo of ${map.name}`);
}

async function stopRecording() {
  recording = false;
  await db.exec('EXECUTE PROCEDURE demo_stop');
  demo = await exportDemo(db);
  if (demo && SaveStore.available()) await SaveStore.put(pakKey, 'demo', demo).catch(() => {});
  updateDemoButtons();
  if (demo) flash(`demo of ${demo.map} recorded: ${demo.tics.reduce((n, r) => n + r[0], 0)} tics`);
}

async function playDemo(d = demo) {
  if (!d || !db) return;
  try {
    if (!pak.has(`maps/${d.map}.bsp`)) throw new Error(`${d.map} is not in this pak`);
    if (recording) await stopRecording();
    await importDemo(db, d);
    settings.logic = d.qc === 1 ? 'qc' : 'psql'; $('logic').value = settings.logic;
    settings.skill = d.skill; $('skill').value = String(d.skill); saveSettings();
    await startMap(d.map, true, { seed: d.seed });
    demoPlayer = new DemoPlayer(d);
    updateDemoButtons();
  } catch (err) {
    setStatus(err.message, true);
  }
}

function updateDemoButtons() {
  $('demo-record').textContent = recording ? 'Stop recording' : 'Record demo';
  $('demo-play').disabled = !demo || recording;
  $('demo-save').disabled = !demo;
}

// ── the loop ─────────────────────────────────────────────────────────────
function nextFrame() {
  let done = false;
  const go = () => { if (!done) { done = true; frame(); } };
  requestAnimationFrame(go);
  setTimeout(go, 60);
}

const arr = { rowMode: 'array' };

async function frame() {
  if (!running || paused || document.hidden || menu?.active) {
    lastTic = performance.now();
    // the game waits: the last frame again, under the menu (dimmed) or Quake's PAUSE plaque
    if ((paused || menu?.active) && renderer && last && !document.hidden) {
      drawFrame(lastDraw?.faces ?? null, lastDraw?.ents ?? [], lastDraw?.styles ?? new Float32Array(64), last.TIME_, 0, (r) => {
        if (menu?.active) { r.fadeScreen(); menu.draw(r, performance.now() / 1000); return; }
        const p = menu?.pic('gfx/pause.lmp');
        if (p) r.drawPic(p, (r.w - p.w) >> 1, (r.h - 48 - p.h) >> 1); else hud.drawCenter(r, 'paused', 80);
      });
    }
    nextFrame();
    return;
  }
  try {
    const now = performance.now();
    const tics = Math.max(1, Math.min(4, Math.round((now - lastTic) / TIC_MS)));
    lastTic += tics * TIC_MS;
    if (now - lastTic > 200) lastTic = now;

    // the PSQL game's intermission: no more tics; the last frame and the stats, until fire after two seconds
    if (interWait) {
      const [, , , , , fire, jump] = readInput(tics);
      if (lastDraw) drawFrame(lastDraw.faces, lastDraw.ents, lastDraw.styles, last.TIME_, 0);
      if ((fire || jump) && now - interWait > 2000) { interWait = 0; await nextLevel(); }
      nextFrame();
      return;
    }

    let t = performance.now();
    // the PSQL game, or progs.dat in the QuakeC VM: the same input, the same row; a demo's recorded calls
    // when one is playing (the keyboard and mouse are read and dropped)
    const ticSql = `SELECT * FROM ${settings.logic === 'qc' ? 'qc_tic' : 'quake_tic'}(?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    const input = readInput(tics);
    for (const args of demoPlayer ? demoPlayer.take(tics) : [input]) last = (await db.query(ticSql, args, { rowMode: 'object' })).rows[0];
    if (demoPlayer?.done) { demoPlayer = null; updateDemoButtons(); flash('the demo has ended: the game is yours'); }
    perf.tic = performance.now() - t;
    // EF_MUZZLEFLASH for the player: a shot starts the weapon's animation (the axe has no flash; the
    // nailguns and the lightning gun cycle their frames, one shot a frame)
    if (last.WEAPONFRAME !== prevWeaponFrame && last.WEAPONFRAME > 0 && last.WEAPON !== 4096 && (last.WEAPONFRAME === 1 || (last.WEAPON & (4 | 8 | 64)))) muzzleUntil = last.TIME_ + 0.1;
    prevWeaponFrame = last.WEAPONFRAME;
    // QuakeC mode: about once a second, the hottest few functions still interpreted get compiled
    if (settings.logic === 'qc' && jit && (jitTics += tics) >= 20) { jitTics = 0; await jit.compileHot({ min: 3, max: 3 }); }

    // the start map's halls (trigger_setskill) choose the skill, as Quake's do: the next level is spawned with it
    if (last.SKILL != null && last.SKILL !== settings.skill) { settings.skill = last.SKILL; $('skill').value = String(last.SKILL); saveSettings(); }
    // what progs.dat told the client: the finale's text starts typing; svc_cdtrack changes the music
    if (last.INTERMISSION === 2 && !finaleStart) finaleStart = last.TIME_;
    if (last.CDTRACK >= 0 && last.CDTRACK !== cdTrack) { cdTrack = last.CDTRACK; audio.playMusic(cdTrack); }

    if (last.EXIT_KIND === 1 && last.NEXT_MAP) {
      // QuakeC mode has shown its intermission and waited for fire already; the PSQL game shows it now
      if (settings.logic === 'qc') { await nextLevel(); nextFrame(); return; }
      interWait = performance.now();
    }
    if (last.FINALE === 1 && !finaleShown) {
      // Shub-Niggurath is dead: the ending, then back to the start map
      finaleShown = true;
      setStatus('Congratulations and well done! You have beaten the hideous Shub-Niggurath, and its hordes of spawn. The Quake realm is free.');
      await new Promise((r) => setTimeout(r, 12000));
      finaleShown = false;
      await startMap('start', true);
      nextFrame();
      return;
    }
    if (last.EXIT_KIND === 3) {
      await startMap(map.name, true);
      nextFrame();
      return;
    }

    t = performance.now();
    const q = (sql) => db.query(sql, [], arr).then((r) => r.rows);
    const [faces, ents, styles, sounds, fx, bframes] = await Promise.all([
      q(settings.renderer === 'sql' ? 'SELECT * FROM frame_faces' : 'SELECT * FROM frame_faces_fast'), q('SELECT * FROM frame_ents'), q('SELECT * FROM frame_lightstyles'),
      q(`SELECT id, tic, ent_id, chan, snd, vol, attn, x, y, z FROM sound_events WHERE id > ${lastSoundId} ORDER BY id`),
      q(`SELECT id, kind, x, y, z, x2, y2, z2, n FROM fx_events WHERE id > ${lastFxId} ORDER BY id`),
      q("SELECT e.id, e.frame FROM ents e JOIN models m ON m.id = e.model_id WHERE m.kind = 'B' AND e.frame <> 0"),
    ]);
    brushFrames.clear();
    for (const [id, f] of bframes) brushFrames.set(id, f);
    perf.faces = performance.now() - t;
    perf.rows = faces.length;
    const styleMap = new Float32Array(64);
    for (const [s, v] of styles) if (s < 64) styleMap[s] = v;
    const listener = { x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW };
    if (sounds.length) { lastSoundId = sounds[sounds.length - 1][0]; audio.playEvents(sounds, listener); }
    audio.update(listener, [last.AMB_WATER, last.AMB_SKY], tics * 0.05);
    if (fx.length) { lastFxId = fx[fx.length - 1][0]; handleFx(fx, last.TIME_); }

    t = performance.now();
    drawFrame(faces, ents, styleMap, last.TIME_, tics * 0.05);
    lastDraw = { faces, ents, styles: styleMap };
    perf.draw = performance.now() - t;
    updateStats();
  } catch (err) {
    console.error(err);
    setStatus(`Error: ${err.message}`, true);
    running = false;
    return;
  }
  nextFrame();
}

// the level is over (changelevel): the next map, carrying the player, or the start map past the pak's last
async function nextLevel() {
  const next = last.NEXT_MAP.toLowerCase();
  setStatus(`${map.name} completed — kills ${last.KILLED}/${last.TOTAL_MONSTERS}, secrets ${last.FOUND_SECRETS}/${last.TOTAL_SECRETS}`);
  if (pak.has(`maps/${next}.bsp`)) await startMap(next, false);
  else { setStatus(`${next} is not in this pak (shareware ends here)`); await new Promise((r) => setTimeout(r, 2500)); await startMap('start', false); }
}

function handleFx(rows, time) {
  for (const [, kind, x, y, z, x2, y2, z2, n] of rows) {
    switch (kind) {
      case 1: renderer.spawnParticles('gunshot', x, y, z, 20, [0, 0, 0], 0); break;
      case 2: renderer.spawnParticles('explosion', x, y, z, 0); explosions.push({ x, y, z, t0: time }); break;
      case 3: renderer.spawnParticles('blood', x, y, z, Math.min(n * 2, 60), [0, 0, 0], 73); break;
      case 4: beams.push({ a: [x, y, z], b: [x2, y2, z2], until: time + 0.2, owner: n }); break;
      case 5: renderer.spawnParticles('teleport', x, y, z, 0); break;
      case 6: renderer.spawnParticles('gunshot', x, y, z, n ? 20 : 10, [0, 0, 0], 0); break;
      case 7: renderer.spawnParticles('lava', x, y, z, 0); explosions.push({ x, y, z, t0: time }); break;
      default: break;
    }
  }
}

function drawFrame(faces, ents, styles, time, dt = 0.05, overlay = null) {
  const r = renderer;
  const view = { x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW, pitch: last.PITCH, roll: last.DEAD ? 60 : 0, fov: settings.fov };
  r.beginFrame(view);
  const dl = r.dlights = frameDlights({ ents, models: res.models, explosions, qc: settings.logic === 'qc', time,
    player: { x: last.PX, y: last.PY, z: last.PZ, yaw: last.YAW, muzzle: muzzleUntil > time - 0.05 && !last.DEAD, glow: !!(last.QUAD || last.INVINCIBLE) } });
  const entFrames = new Map();
  for (const e of ents) if (e[12] === 'B') entFrames.set(e[0], e[2]);
  if (faces) {
    // brush-model frames (button textures) come from the ents table via frame_ents? Brush ents are
    // not in FRAME_ENTS; their frame is in the faces' ent rows only via a side query — keep a cache.
    if (settings.renderer === 'sql') r.drawFaces(faces, styles, time, brushFrames);   // vertex rows from FRAME_FACES
    else r.drawFaceList(faces, styles, time, brushFrames);                             // face rows from FRAME_FACES_FAST
  }
  // alias models and sprites
  const bsp = map.bsp;
  for (const e of ents) {
    const [, mid, frame, skin, x, y, z, pitch, yaw, roll, effects, alpha, kindRaw] = e;
    const kind = String(kindRaw).trim();   // CHAR(1) comes back padded
    const m = res.models.get(mid);
    if (!m) continue;
    if (kind === 'M') {
      const light = effects & 8 ? 255 : Math.min(255, Math.max(lightPoint(bsp, x, y, z + 8), effects & 4 ? 160 : 0) + dlightAt(dl, x, y, z));
      const spin = m.mdl.flags & 8 ? (time * 100) % 360 : 0;   // EF_ROTATE items spin
      r.drawAlias(m.mdl, frame, skin, [x, y, z], [pitch, yaw + spin, roll], light, { time, alpha: alpha === 1 });
    } else if (kind === 'S') {
      r.drawSprite(m.spr, frame, [x, y, z]);
    }
  }
  // lightning beams: bolt segments every 30 units
  const bolt = res.models.get(res.byName.get('progs/bolt2.mdl'));
  beams = beams.filter((b) => b.until > time);
  for (const b of beams) {
    const d = [b.b[0] - b.a[0], b.b[1] - b.a[1], b.b[2] - b.a[2]];
    const len = Math.hypot(...d) || 1;
    const yaw = (Math.atan2(d[1], d[0]) * 180) / Math.PI;
    const pitch = (Math.atan2(d[2], Math.hypot(d[0], d[1])) * 180) / Math.PI;
    for (let k = 0; k < len; k += 30) {
      const p = [b.a[0] + (d[0] * k) / len, b.a[1] + (d[1] * k) / len, b.a[2] + (d[2] * k) / len];
      if (bolt) r.drawAlias(bolt.mdl, 0, 0, p, [pitch, yaw, Math.random() * 360], 255, { time });
    }
  }
  // explosion sprites: 6 frames at 10 Hz
  const explod = res.models.get(res.byName.get('progs/s_explod.spr'));
  explosions = explosions.filter((x) => time - x.t0 < 0.6);
  for (const x of explosions) if (explod) r.drawSprite(explod.spr, Math.floor((time - x.t0) * 10), [x.x, x.y, x.z]);
  r.runParticles(dt, time);
  r.drawParticles();
  // the weapon in hand (depth hack: drawn over everything near)
  if (!last.DEAD && !last.INTERMISSION && last.WEAPON && VIEW_MODELS[last.WEAPON]) {
    const vm = res.models.get(res.byName.get(VIEW_MODELS[last.WEAPON]));
    if (vm) {
      const bob = Math.sin(time * 8) * Math.min(1, Math.hypot(last.PX - (prevPos?.x ?? last.PX), last.PY - (prevPos?.y ?? last.PY)) / 8) * 1.5;
      const light = Math.min(255, Math.max(lightPoint(bsp, last.PX, last.PY, last.PZ), 32) + dlightAt(dl, last.PX, last.PY, last.PZ));
      r.zb.fill(0, 0, r.w * r.h);   // the gun is always in front
      r.drawAlias(vm.mdl, Math.min(last.WEAPONFRAME, vm.mdl.frames.length - 1), 0, [last.PX, last.PY, last.VIEW_Z + 2 + bob], [-last.PITCH, last.YAW, 0], light, { near: 1, time });
    }
  }
  prevPos = { x: last.PX, y: last.PY };

  // 2D
  // the intermission (the stats, or the finale's text) replaces the status bar, as in Sbar_Draw
  if (last.INTERMISSION === 2) hud.drawFinale(r, last.FINALE_TEXT ?? '', time - finaleStart);
  else if (last.INTERMISSION === 1) hud.drawIntermission(r, last);
  else hud.draw(r, last, time);
  if (last.CPRINT && !last.INTERMISSION) hud.drawCenter(r, last.CPRINT, Math.floor(r.h * 0.35));
  if (last.MSG) r.drawString(hud.conchars, last.MSG, 0, 0);
  if (last.DEAD) hud.drawCenter(r, 'you died\n\npress fire to restart', 60);
  // the palette blend: damage, bonus, water
  let tint = null;
  const since = time - last.DMG_TIME;
  if (since >= 0 && since < 0.5 && (last.DMG_TAKE || last.DMG_SAVE)) {
    const a = Math.min(0.6, (last.DMG_TAKE * 0.03 + last.DMG_SAVE * 0.01) * (1 - since / 0.5) + 0.1);
    tint = [255, 0, 0, a];
  } else if (time - last.BONUS_TIME >= 0 && time - last.BONUS_TIME < 0.4) tint = [215, 186, 69, 0.3 * (1 - (time - last.BONUS_TIME) / 0.4)];
  else if (last.QUAD) tint = [0, 0, 255, 0.2];
  else if (last.INVINCIBLE) tint = [255, 255, 0, 0.3];
  else if (last.SUIT) tint = [0, 255, 0, 0.2];
  else if (last.WATERLEVEL >= 3) tint = last.WATERTYPE === -5 ? [255, 80, 0, 0.6] : last.WATERTYPE === -4 ? [0, 25, 5, 0.6] : [130, 80, 50, 0.5];
  if (overlay) overlay(r);
  r.present(tint);
}
let prevPos = null;
const brushFrames = new Map();

let fpsT = performance.now(), fpsN = 0, fps = 0;
function updateStats() {
  fpsN++;
  const now = performance.now();
  if (now - fpsT > 500) { fps = (fpsN * 1000) / (now - fpsT); fpsT = now; fpsN = 0; }
  statsEl.textContent = `${fps.toFixed(1)} fps · ${settings.logic === 'qc' ? `qc_tic (${jit?.compiled.size ?? 0} functions compiled)` : 'quake_tic'} ${perf.tic.toFixed(0)} ms · frame queries ${perf.faces.toFixed(0)} ms (${perf.rows} vertex rows) · raster ${perf.draw.toFixed(0)} ms · ${renderer.particles.length} particles`;
}

// ── SQL console ─────────────────────────────────────────────────────────
async function runConsole() {
  const sqlText = $('sql').value.trim();
  if (!sqlText || !db) return;
  const out = $('sql-out');
  const t0 = performance.now();
  try {
    const r = /^\s*(select|with|execute\s+block)/i.test(sqlText)
      ? await db.query(sqlText, [], { rowMode: 'object' })
      : { rows: [], exec: await db.exec(sqlText) };
    const ms = (performance.now() - t0).toFixed(1);
    if (!r.rows.length) { out.textContent = `OK (${ms} ms)`; return; }
    const cols = Object.keys(r.rows[0]);
    const lines = [cols.join('\t'), ...r.rows.slice(0, 200).map((row) => cols.map((c) => fmt(row[c])).join('\t'))];
    out.textContent = `${r.rows.length} row(s), ${ms} ms\n${lines.join('\n')}`;
  } catch (err) {
    out.textContent = err.message;
  }
}
const fmt = (v) => (typeof v === 'number' && !Number.isInteger(v) ? v.toFixed(2) : String(v));
$('run-sql').addEventListener('click', runConsole);
$('sql').addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) runConsole(); });
for (const b of document.querySelectorAll('[data-sql]')) b.addEventListener('click', () => { $('sql').value = b.dataset.sql; runConsole(); });

// ── boot ────────────────────────────────────────────────────────────────
async function openDatabase() {
  if (!window.crossOriginIsolated && window.isSecureContext && 'serviceWorker' in navigator &&
      Number(sessionStorage.getItem('firebird-quake:coi-reloads') || '0') < 2) {
    setStatus('Enabling cross-origin isolation for Firebird WASM (one-time reload)…');
    return new Promise(() => {});
  }
  if (!window.crossOriginIsolated) {
    throw new Error('This page is not cross-origin isolated, so Firebird WASM cannot start. Reload once (the service worker enables it), and use HTTPS or localhost.');
  }
  setStatus('Starting Firebird 6 (WebAssembly)…');
  const instance = new FirebirdBrowser('memory://quake', {
    worker: new Worker(new URL('./firebird-engine-worker.js', import.meta.url)),
    multiTab: 'allow-unsafe',
    autoPersist: false,
  });
  const v = await instance.query("SELECT rdb$get_context('SYSTEM', 'ENGINE_VERSION') AS v FROM rdb$database");
  $('engine').textContent = `Firebird ${v.rows[0].V}`;
  setStatus('Creating the Quake schema (PSQL)…');
  await createSchema(instance, { schema: schemaSql, physics: physicsSql, game: gameSql, weapons: weaponsSql, monsters: monstersSql, render: renderSql, qcvm: qcvmSql, save: saveSql, demo: demoSql });
  return instance;
}

async function usePak(buffers, label) {
  running = false;
  progsLoaded = false;
  pak = new PakSet(buffers.map((b) => new Pak(b)));     // pak0.pak, and pak1.pak if you own Quake
  const maps = pak.mapNames();
  if (!maps.length) throw new Error(`${label} has no maps`);
  setStatus(`Copying ${label} models into Firebird…`);
  res = await loadResources(db, pak, { width: viewWidth(), height: viewHeight() - sbarLines(), fov: settings.fov });
  const palette = loadPalette(pak.get('gfx/palette.lmp'));
  const colormap = pak.get('gfx/colormap.lmp');
  wad = new Wad2(pak.get('gfx.wad'));
  renderer = new Renderer(canvas, { palette, colormap });
  renderer.sbarLines = sbarLines();
  renderer.setSize(viewWidth(), viewHeight());
  hud = new Hud(wad, (n) => (pak.has(n) ? qpic(pak.get(n)) : null));
  menu = new Menu({ lmp: (n) => (pak.has(n) ? qpic(pak.get(n)) : null), conchars: hud.conchars, play: (snd) => audio.playLocal(snd), actions: menuActions() });
  audio.setPak(pak);
  $('map').innerHTML = maps.map((m) => `<option>${m}</option>`).join('');
  $('pakname').textContent = label;
  pakKey = label;
  await refreshSaves();
  try { demo = SaveStore.available() ? (await SaveStore.get(pakKey, 'demo')) ?? null : null; } catch { demo = null; }
  updateDemoButtons();
  const first = maps.includes(settings.map) ? settings.map : maps.includes('start') ? 'start' : maps[0];
  await startMap(first, true);
}

async function boot() {
  try {
    db = await openDatabase();
    // for the devtools console: await quake.sql('SELECT * FROM player'); quake.renderer, quake.res, quake.settings, quake.last;
    // the QuakeC VM: await quake.loadProgs(); await quake.sql("EXECUTE PROCEDURE qc_run('worldspawn', 0)"); await quake.sql('SELECT * FROM qc_log')
    window.quake = { db, audio, settings, sql: (q, p) => db.query(q, p).then((r) => r.rows), loadProgs: () => loadProgs(db, pak), get jit() { return jit; }, get menu() { return menu; }, get renderer() { return renderer; }, get res() { return res; }, get last() { return last; }, get map() { return map; } };
    // which game data the site serves: the shareware pak, the registered pak1.pak beside it, LibreQuake
    // (public/pak/lq1/, `npm run fetch-pak -- --librequake`), or the shareware pak with LibreQuake's
    // pak1.pak, which gives the registered monsters free models
    const DATASETS = {
      shareware: { label: 'Quake shareware', paks: ['pak/pak0.pak'] },
      registered: { label: 'Quake (registered pak1.pak)', paks: ['pak/pak0.pak', 'pak/pak1.pak'] },
      'shareware+lq1': { label: 'Quake shareware + LibreQuake monsters', paks: ['pak/pak0.pak', 'pak/lq1/pak1.pak'] },
      librequake: { label: 'LibreQuake', paks: ['pak/lq1/pak0.pak', 'pak/lq1/pak1.pak'] },
    };
    const served = async (rel) => {
      try { const r = await fetch(new URL('./' + rel, location.href), { method: 'HEAD' }); return r.ok && (r.headers.get('content-type') ?? '').indexOf('text/html') < 0; } catch { return false; }
    };
    const have = Object.fromEntries(await Promise.all([...new Set(Object.values(DATASETS).flatMap((d) => d.paks))].map(async (p) => [p, await served(p)])));
    const sets = Object.entries(DATASETS).filter(([, d]) => d.paks.every((p) => have[p]));
    $('data').innerHTML = sets.map(([k, d]) => `<option value="${k}">${d.label}</option>`).join('');
    $('data').parentElement.hidden = sets.length <= 1;
    const loadDataset = async (key) => {
      const d = DATASETS[key];
      setStatus(`Downloading ${d.paks.map((p) => p.slice(4)).join(' + ')}…`);
      const buffers = await Promise.all(d.paks.map(async (p) => { const r = await fetch(new URL('./' + p, location.href)); if (!r.ok) throw new Error(`could not fetch ${p} (${r.status})`); return r.arrayBuffer(); }));
      await usePak(buffers, d.paks.map((p) => p.slice(4)).join(' + '));
    };
    $('data').addEventListener('change', (e) => { settings.data = e.target.value; saveSettings(); loadDataset(e.target.value).catch((err) => setStatus(err.message, true)); });   // the frame loop keeps running; usePak pauses it while loading
    if (!sets.length) throw new Error('could not fetch pak0.pak; pick a PAK file instead');
    const key = sets.some(([k]) => k === settings.data) ? settings.data : sets[0][0];
    $('data').value = key;
    await loadDataset(key);
    nextFrame();
  } catch (err) {
    console.error(err);
    setStatus(err.message, true);
  }
}

$('pakfile').addEventListener('change', async (e) => {
  const files = [...e.target.files].sort((a, b) => a.name.localeCompare(b.name));   // pak0.pak before pak1.pak
  if (!files.length || !db) return;
  try { await usePak(await Promise.all(files.map((f) => f.arrayBuffer())), files.map((f) => f.name).join(' + ')); } catch (err) { setStatus(err.message, true); }
});
$('map').addEventListener('change', (e) => { settings.map = e.target.value; saveSettings(); startMap(e.target.value, true).catch((err) => setStatus(err.message, true)); });
// the settings, changed from the page's controls or from the menu's options
async function setDetail(v) {
  settings.detail = v; saveSettings(); $('detail').value = v;
  await setView(db, viewWidth(), viewHeight() - sbarLines(), settings.fov);
  renderer.sbarLines = sbarLines();
  renderer.setSize(viewWidth(), viewHeight());
}
function setLogic(v) {
  settings.logic = v; saveSettings(); $('logic').value = v;
  if (map) startMap(map.name, true).catch((err) => setStatus(err.message, true));   // a new game under the other logic
}
function setRenderer(v) { settings.renderer = v; saveSettings(); $('renderer').value = v; }
function setSfx(v) { settings.sfx = v; saveSettings(); $('sfxvol').value = v; audio.unlock(); audio.setVolume(v / 100); }
function setMusicVolume(v) { settings.music = v; saveSettings(); $('musicvol').value = v; audio.setMusicVolume(v / 100); }
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

// M_Menu_Options and the rest of the menu's actions: New Game is Quake's "map start"
function menuActions() {
  const newGame = () => startMap('start', true).catch((err) => setStatus(err.message, true));
  return {
    newGame,
    quit: newGame,
    saves: () => saveSlots,
    save: (slot) => saveGame(slot),
    load: (slot) => loadGame(slot),
    options: [
      { label: 'Reset to defaults', kind: 'action', change: () => { Object.assign(settings, { sensitivity: 3, alwaysRun: true, invertMouse: false }); setSfx(70); setMusicVolume(50); } },
      { label: 'Screen size', kind: 'value', get: () => (settings.detail === 'high' ? '320x200' : '160x100'), change: () => setDetail(settings.detail === 'high' ? 'low' : 'high') },
      { label: 'Mouse Speed', kind: 'slider', get: () => (settings.sensitivity - 1) / 10, change: (d) => { settings.sensitivity = clamp(settings.sensitivity + d * 0.5, 1, 11); saveSettings(); } },
      { label: 'CD Music Volume', kind: 'slider', get: () => settings.music / 100, change: (d) => setMusicVolume(clamp(settings.music + d * 10, 0, 100)) },
      { label: 'Sound Volume', kind: 'slider', get: () => settings.sfx / 100, change: (d) => setSfx(clamp(settings.sfx + d * 10, 0, 100)) },
      { label: 'Always Run', kind: 'check', get: () => settings.alwaysRun, change: () => { settings.alwaysRun = !settings.alwaysRun; saveSettings(); } },
      { label: 'Invert Mouse', kind: 'check', get: () => settings.invertMouse, change: () => { settings.invertMouse = !settings.invertMouse; saveSettings(); } },
      { label: 'Game logic', kind: 'value', get: () => (settings.logic === 'qc' ? 'QuakeC VM' : 'PSQL'), change: () => setLogic(settings.logic === 'qc' ? 'psql' : 'qc') },
      { label: 'Renderer', kind: 'value', get: () => (settings.renderer === 'sql' ? 'all in SQL' : 'fast'), change: () => setRenderer(settings.renderer === 'sql' ? 'fast' : 'sql') },
    ],
  };
}

$('demo-record').addEventListener('click', () => (recording ? stopRecording() : startRecording()).catch((err) => setStatus(err.message, true)));
$('demo-play').addEventListener('click', () => playDemo());
$('demo-save').addEventListener('click', () => {
  if (!demo) return;
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(demo)], { type: 'application/json' }));
  a.download = `${demo.map}.dem.json`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
});
$('demo-file').addEventListener('change', async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  try { demo = JSON.parse(await f.text()); await playDemo(demo); } catch (err) { setStatus(`not a demo: ${err.message}`, true); }
});
$('detail').value = settings.detail;
$('detail').addEventListener('change', (e) => setDetail(e.target.value));
$('logic').value = settings.logic;
$('logic').addEventListener('change', (e) => setLogic(e.target.value));
$('renderer').value = settings.renderer;
$('renderer').addEventListener('change', (e) => setRenderer(e.target.value));
$('musicvol').value = settings.music;
$('musicvol').addEventListener('input', () => setMusicVolume(Number($('musicvol').value)));
$('skill').value = String(settings.skill);
$('skill').addEventListener('change', (e) => { settings.skill = Number(e.target.value); saveSettings(); });
$('sfxvol').value = settings.sfx;
$('sfxvol').addEventListener('input', () => { settings.sfx = Number($('sfxvol').value); saveSettings(); audio.unlock(); audio.setVolume(settings.sfx / 100);
audio.setMusicVolume(settings.music / 100);
audio.musicMode = settings.musicMode; });

boot();
