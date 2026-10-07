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
import { Pak, Wad2, loadPalette, PakSet, qpic } from './pak.js';
import { createSchema, loadResources, loadMap, loadProgs, setView } from './loader.js';
import { QcJit } from './qcjit.js';
import { frameDlights, dlightAt } from './dlights.js';
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
let interWait = 0;         // the PSQL game's intermission: when it began (the stats stay until fire)
let finaleStart = 0;       // game time the finale's text began (QuakeC's svc_finale)
let cdTrack = -1;          // the track svc_cdtrack asked for
let lastDraw = null;       // the last frame's rows, drawn again under the intermission
let muzzleUntil = 0;       // the player's muzzle flash lights the room until then (game time)
let prevWeaponFrame = 0;
let beams = [];          // lightning beams to draw briefly
let explosions = [];
const settings = { map: 'start', detail: 'high', sfx: 70, music: 50, musicMode: 'tracks', skill: 1, fov: 90, renderer: 'fast', data: 'shareware', logic: 'psql' };
let progsLoaded = false;   // the pak's progs.dat in the QuakeC VM's tables (QuakeC mode)
let jit = null;            // its hot functions compiled to PSQL procedures (src/qcjit.js)
let jitTics = 0;
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
  if (GAME_KEYS.has(e.code)) e.preventDefault();
  keys.add(e.code);
  if (e.code.startsWith('Digit')) impulse = Number(e.code.slice(5));
  if (e.code === 'Slash') impulse = 10;
  if (e.code === 'KeyP' || e.code === 'Pause') paused = !paused;
});
window.addEventListener('keyup', (e) => keys.delete(e.code));
window.addEventListener('blur', () => keys.clear());
canvas.addEventListener('click', () => {
  if (running && document.pointerLockElement !== canvas) canvas.requestPointerLock?.()?.catch?.(() => {});
});
canvas.addEventListener('mousedown', (e) => { if (document.pointerLockElement === canvas && e.button === 0) fireClick = true; });
window.addEventListener('mouseup', () => { fireClick = false; });
window.addEventListener('mousemove', (e) => {
  if (document.pointerLockElement === canvas) {
    mouseYaw -= e.movementX * 0.15;
    mousePitch += e.movementY * 0.15;
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
  const run = k('ShiftLeft') || k('ShiftRight') ? 0 : 1;     // always run; shift walks
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
async function startMap(name, newGame) {
  running = false;
  setStatus(`Loading ${name} into Firebird…`);
  const t0 = performance.now();
  // QuakeC mode: the client's parms leave with it (SetChangeParms), the level is spawned by progs.dat's own spawn
  // functions after the geometry is loaded, and the parms come back (sql/qcvm.sql: qc_change_parms, qc_begin_map)
  const qc = settings.logic === 'qc';
  if (qc && !newGame && progsLoaded) await db.exec('EXECUTE PROCEDURE qc_change_parms');
  if (!qc) await db.exec('EXECUTE PROCEDURE qc_leave');
  const bsp = await loadMap(db, pak, res, name, { skill: settings.skill, newGame });
  if (qc) {
    if (!progsLoaded) {
      setStatus('Loading progs.dat into the QuakeC VM…');
      jit = new QcJit(db, await loadProgs(db, pak));
      await jit.init();
      progsLoaded = true;
    }
    setStatus(`Spawning ${name} through QuakeC…`);
    await db.exec(`EXECUTE PROCEDURE qc_begin_map(${settings.skill}, ${newGame ? 0 : 1})`);
    // the functions the spawn ran more than once, compiled to procedures (the rest follow as they get hot)
    setStatus('Compiling QuakeC to PSQL…');
    await jit.compileHot({ min: 2, max: 32 });
  }
  map = { name, bsp };
  renderer.setResources(res);
  renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
  renderer.particles = [];
  beams = []; explosions = [];
  interWait = 0; finaleStart = 0; cdTrack = -1; lastDraw = null;
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

// ── the loop ─────────────────────────────────────────────────────────────
function nextFrame() {
  let done = false;
  const go = () => { if (!done) { done = true; frame(); } };
  requestAnimationFrame(go);
  setTimeout(go, 60);
}

const arr = { rowMode: 'array' };

async function frame() {
  if (!running || paused || document.hidden) {
    lastTic = performance.now();
    if (paused && renderer && last) { drawFrame(null, [], [], new Map(), last.TIME_); hud.drawCenter(renderer, 'paused', 80); renderer.present(); }
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
    // the PSQL game, or progs.dat in the QuakeC VM: the same input, the same row
    last = (await db.query(`SELECT * FROM ${settings.logic === 'qc' ? 'qc_tic' : 'quake_tic'}(?, ?, ?, ?, ?, ?, ?, ?, ?)`, readInput(tics), { rowMode: 'object' })).rows[0];
    perf.tic = performance.now() - t;
    // EF_MUZZLEFLASH for the player: a shot starts the weapon's animation (the axe has no flash; the
    // nailguns and the lightning gun cycle their frames, one shot a frame)
    if (last.WEAPONFRAME !== prevWeaponFrame && last.WEAPONFRAME > 0 && last.WEAPON !== 4096 && (last.WEAPONFRAME === 1 || (last.WEAPON & (4 | 8 | 64)))) muzzleUntil = last.TIME_ + 0.1;
    prevWeaponFrame = last.WEAPONFRAME;
    // QuakeC mode: about once a second, the hottest few functions still interpreted get compiled
    if (settings.logic === 'qc' && jit && (jitTics += tics) >= 20) { jitTics = 0; await jit.compileHot({ min: 3, max: 3 }); }

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

function drawFrame(faces, ents, styles, time, dt = 0.05) {
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
  await createSchema(instance, { schema: schemaSql, physics: physicsSql, game: gameSql, weapons: weaponsSql, monsters: monstersSql, render: renderSql, qcvm: qcvmSql });
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
  audio.setPak(pak);
  $('map').innerHTML = maps.map((m) => `<option>${m}</option>`).join('');
  $('pakname').textContent = label;
  const first = maps.includes(settings.map) ? settings.map : maps.includes('start') ? 'start' : maps[0];
  await startMap(first, true);
}

async function boot() {
  try {
    db = await openDatabase();
    // for the devtools console: await quake.sql('SELECT * FROM player'); quake.renderer, quake.res, quake.settings, quake.last;
    // the QuakeC VM: await quake.loadProgs(); await quake.sql("EXECUTE PROCEDURE qc_run('worldspawn', 0)"); await quake.sql('SELECT * FROM qc_log')
    window.quake = { db, audio, settings, sql: (q, p) => db.query(q, p).then((r) => r.rows), loadProgs: () => loadProgs(db, pak), get jit() { return jit; }, get renderer() { return renderer; }, get res() { return res; }, get last() { return last; }, get map() { return map; } };
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
$('detail').value = settings.detail;
$('detail').addEventListener('change', async (e) => {
  settings.detail = e.target.value; saveSettings();
  await setView(db, viewWidth(), viewHeight() - sbarLines(), settings.fov);
  renderer.sbarLines = sbarLines();
  renderer.setSize(viewWidth(), viewHeight());
});
$('logic').value = settings.logic;
$('logic').addEventListener('change', (e) => {
  settings.logic = e.target.value; saveSettings();
  if (map) startMap(map.name, true).catch((err) => setStatus(err.message, true));   // a new game under the other logic
});
$('renderer').value = settings.renderer;
$('renderer').addEventListener('change', (e) => { settings.renderer = e.target.value; saveSettings(); });
$('skill').value = String(settings.skill);
$('skill').addEventListener('change', (e) => { settings.skill = Number(e.target.value); saveSettings(); });
$('sfxvol').value = settings.sfx;
$('sfxvol').addEventListener('input', () => { settings.sfx = Number($('sfxvol').value); saveSettings(); audio.unlock(); audio.setVolume(settings.sfx / 100);
audio.setMusicVolume(settings.music / 100);
audio.musicMode = settings.musicMode; });

boot();
