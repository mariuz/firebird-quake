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
import { Pak, Wad2, loadPalette } from './pak.js';
import { createSchema, loadResources, loadMap, setView } from './loader.js';
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
let beams = [];          // lightning beams to draw briefly
let explosions = [];
const settings = { map: 'start', detail: 'high', sfx: 70, skill: 1, fov: 90 };
try { Object.assign(settings, JSON.parse(localStorage.getItem('firebird-quake:settings') || '{}')); } catch { /* defaults */ }
const saveSettings = () => { try { localStorage.setItem('firebird-quake:settings', JSON.stringify(settings)); } catch { /* ignore */ } };
const viewWidth = () => (settings.detail === 'high' ? 320 : 160);
const viewHeight = () => (settings.detail === 'high' ? 200 : 100);
const audio = new QuakeAudio();
audio.setVolume(settings.sfx / 100);
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
  const bsp = await loadMap(db, pak, res, name, { skill: settings.skill, newGame });
  map = { name, bsp };
  renderer.setResources(res);
  renderer.skyTex = bsp.textures.find((t) => t && t.name.startsWith('sky')) ?? null;
  renderer.particles = [];
  beams = []; explosions = [];
  audio.setAmbients(bsp.entities);
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

    let t = performance.now();
    last = (await db.query('SELECT * FROM quake_tic(?, ?, ?, ?, ?, ?, ?, ?, ?)', readInput(tics), { rowMode: 'object' })).rows[0];
    perf.tic = performance.now() - t;

    if (last.EXIT_KIND === 1 && last.NEXT_MAP) {
      const next = last.NEXT_MAP.toLowerCase();
      setStatus(`${map.name} completed — kills ${last.KILLED}/${last.TOTAL_MONSTERS}, secrets ${last.FOUND_SECRETS}/${last.TOTAL_SECRETS}`);
      await new Promise((r) => setTimeout(r, 2000));
      if (pak.has(`maps/${next}.bsp`)) await startMap(next, false);
      else { setStatus(`${next} is not in this pak (shareware ends here)`); await new Promise((r) => setTimeout(r, 2500)); await startMap('start', false); }
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
    const [faces, ents, styles, sounds, fx] = await Promise.all([
      q('SELECT * FROM frame_faces'), q('SELECT * FROM frame_ents'), q('SELECT * FROM frame_lightstyles'),
      q(`SELECT id, tic, ent_id, chan, snd, vol, attn, x, y, z FROM sound_events WHERE id > ${lastSoundId} ORDER BY id`),
      q(`SELECT id, kind, x, y, z, x2, y2, z2, n FROM fx_events WHERE id > ${lastFxId} ORDER BY id`),
    ]);
    perf.faces = performance.now() - t;
    perf.rows = faces.length;
    const styleMap = new Float32Array(64);
    for (const [s, v] of styles) if (s < 64) styleMap[s] = v;
    const listener = { x: last.PX, y: last.PY, z: last.VIEW_Z, yaw: last.YAW };
    if (sounds.length) { lastSoundId = sounds[sounds.length - 1][0]; audio.playEvents(sounds, listener); }
    audio.updateAmbients(listener);
    if (fx.length) { lastFxId = fx[fx.length - 1][0]; handleFx(fx, last.TIME_); }

    t = performance.now();
    drawFrame(faces, ents, styleMap, last.TIME_, tics * 0.05);
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
  const entFrames = new Map();
  for (const e of ents) if (e[12] === 'B') entFrames.set(e[0], e[2]);
  if (faces) {
    // brush-model frames (button textures) come from the ents table via frame_ents? Brush ents are
    // not in FRAME_ENTS; their frame is in the faces' ent rows only via a side query — keep a cache.
    r.drawFaces(faces, styles, time, brushFrames);
  }
  // alias models and sprites
  const bsp = map.bsp;
  for (const e of ents) {
    const [id, mid, frame, skin, x, y, z, pitch, yaw, roll, effects, alpha, kind, flags] = e;
    const m = res.models.get(mid);
    if (!m) continue;
    if (kind === 'M') {
      const light = effects & 8 ? 255 : Math.max(lightPoint(bsp, x, y, z + 8), effects & 4 ? 160 : 0);
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
  if (!last.DEAD && last.WEAPON && VIEW_MODELS[last.WEAPON]) {
    const vm = res.models.get(res.byName.get(VIEW_MODELS[last.WEAPON]));
    if (vm) {
      const bob = Math.sin(time * 8) * Math.min(1, Math.hypot(last.PX - (prevPos?.x ?? last.PX), last.PY - (prevPos?.y ?? last.PY)) / 8) * 1.5;
      const light = Math.max(lightPoint(bsp, last.PX, last.PY, last.PZ), 32);
      r.zb.fill(0, 0, r.w * r.h);   // the gun is always in front
      r.drawAlias(vm.mdl, Math.min(last.WEAPONFRAME, vm.mdl.frames.length - 1), 0, [last.PX, last.PY, last.VIEW_Z + bob], [-last.PITCH, last.YAW, 0], light, { near: 1, time });
    }
  }
  prevPos = { x: last.PX, y: last.PY };

  // 2D
  hud.draw(r, last, time);
  if (last.CPRINT) hud.drawCenter(r, last.CPRINT, Math.floor(r.h * 0.35));
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
  statsEl.textContent = `${fps.toFixed(1)} fps · quake_tic ${perf.tic.toFixed(0)} ms · frame queries ${perf.faces.toFixed(0)} ms (${perf.rows} vertex rows) · raster ${perf.draw.toFixed(0)} ms · ${renderer.particles.length} particles`;
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
  await createSchema(instance, { schema: schemaSql, physics: physicsSql, game: gameSql, weapons: weaponsSql, monsters: monstersSql, render: renderSql });
  return instance;
}

async function usePak(buffer, label) {
  running = false;
  pak = new Pak(buffer);
  const maps = pak.mapNames();
  if (!maps.length) throw new Error(`${label} has no maps`);
  setStatus(`Copying ${label} models into Firebird…`);
  res = await loadResources(db, pak, { width: viewWidth(), height: viewHeight(), fov: settings.fov });
  const palette = loadPalette(pak.get('gfx/palette.lmp'));
  const colormap = pak.get('gfx/colormap.lmp');
  wad = new Wad2(pak.get('gfx.wad'));
  renderer = new Renderer(canvas, { palette, colormap });
  renderer.setSize(viewWidth(), viewHeight());
  hud = new Hud(wad);
  audio.setPak(pak);
  $('map').innerHTML = maps.map((m) => `<option>${m}</option>`).join('');
  $('pakname').textContent = label;
  const first = maps.includes(settings.map) ? settings.map : maps.includes('start') ? 'start' : maps[0];
  await startMap(first, true);
}

async function boot() {
  try {
    db = await openDatabase();
    window.quake = { db, audio, sql: (q, p) => db.query(q, p).then((r) => r.rows) };
    setStatus('Downloading pak0.pak…');
    const resp = await fetch(new URL('./pak/pak0.pak', location.href));
    if (!resp.ok) throw new Error(`could not fetch pak0.pak (${resp.status}); pick a PAK file instead`);
    await usePak(await resp.arrayBuffer(), 'pak0.pak');
    nextFrame();
  } catch (err) {
    console.error(err);
    setStatus(err.message, true);
  }
}

$('pakfile').addEventListener('change', async (e) => {
  const f = e.target.files[0];
  if (!f || !db) return;
  try { await usePak(await f.arrayBuffer(), f.name); } catch (err) { setStatus(err.message, true); }
});
$('map').addEventListener('change', (e) => { settings.map = e.target.value; saveSettings(); startMap(e.target.value, true).catch((err) => setStatus(err.message, true)); });
$('detail').value = settings.detail;
$('detail').addEventListener('change', async (e) => {
  settings.detail = e.target.value; saveSettings();
  await setView(db, viewWidth(), viewHeight(), settings.fov);
  renderer.setSize(viewWidth(), viewHeight());
});
$('skill').value = String(settings.skill);
$('skill').addEventListener('change', (e) => { settings.skill = Number(e.target.value); saveSettings(); });
$('sfxvol').value = settings.sfx;
$('sfxvol').addEventListener('input', () => { settings.sfx = Number($('sfxvol').value); saveSettings(); audio.unlock(); audio.setVolume(settings.sfx / 100); });

boot();
