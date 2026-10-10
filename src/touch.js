// touch.js – the controls on a phone or a tablet, over the view: a stick that appears where the left thumb
// lands (forward, back and sideways, as far as it is pushed), the right side of the view to look by dragging
// (a quick tap there fires once), and buttons: fire and jump held while touched, change weapon, the menu.
// While the menu is up, a pad of arrows, OK and back drives it as the keys do. The logic is here and
// testable without a page (scripts/touch-test.mjs); attachTouch() puts it on the page's elements.

export const STICK_RADIUS = 56;       // CSS pixels from the stick's centre to full speed
export const DEAD_ZONE = 0.12;        // a fraction of the radius that does not move
export const TAP_MS = 250, TAP_PX = 10;

export class TouchControls {
  constructor({ sensitivity = 0.4 } = {}) {
    this.sensitivity = sensitivity;   // degrees of turn per CSS pixel dragged
    this.stick = null;                // { id, x0, y0, x, y }: the moving thumb
    this.look = null;                 // { id, x, y, x0, y0, t }: the looking thumb
    this.held = new Map();            // touch id → the + button it holds (+attack, +jump)
    this.yaw = 0; this.pitch = 0;     // turned since the last read
    this.taps = 0;                    // quick taps on the look side since the last read: a shot each
    this.pressed = new Set();         // + buttons touched since the last read, so a touch shorter than a tic counts
  }

  /** A touch went down on the view at (x, y), the view w wide: the left half moves, the right half looks. */
  start(id, x, y, w) {
    if (x < w / 2) { if (!this.stick) this.stick = { id, x0: x, y0: y, x, y }; }
    else if (!this.look) this.look = { id, x, y, x0: x, y0: y, t: performance.now() };
  }
  move(id, x, y) {
    if (this.stick?.id === id) { this.stick.x = x; this.stick.y = y; }
    if (this.look?.id === id) {
      this.yaw -= (x - this.look.x) * this.sensitivity;
      this.pitch += (y - this.look.y) * this.sensitivity;
      this.look.x = x; this.look.y = y;
    }
  }
  end(id) {
    if (this.stick?.id === id) this.stick = null;
    if (this.look?.id === id) {
      const l = this.look;
      if (performance.now() - l.t < TAP_MS && Math.abs(l.x - l.x0) < TAP_PX && Math.abs(l.y - l.y0) < TAP_PX) this.taps++;
      this.look = null;
    }
    this.held.delete(id);
  }
  /** A button touched (id) and held until end(id): fire, jump. */
  hold(id, button) { this.held.set(id, button); this.pressed.add(button); }
  down(button) { for (const b of this.held.values()) if (b === button) return true; return false; }
  release() { this.stick = null; this.look = null; this.held.clear(); this.pressed.clear(); }

  /** The stick's push: forward (+1 up) and sideways (+1 right), each -1..1, nothing inside the dead zone. */
  axes() {
    const s = this.stick;
    if (!s) return { fwd: 0, side: 0, knob: null };
    let dx = s.x - s.x0, dy = s.y - s.y0;
    const len = Math.hypot(dx, dy);
    if (len > STICK_RADIUS) { dx *= STICK_RADIUS / len; dy *= STICK_RADIUS / len; }
    const k = len < DEAD_ZONE * STICK_RADIUS ? 0 : 1;
    return { fwd: k * -dy / STICK_RADIUS, side: k * dx / STICK_RADIUS, knob: { x0: s.x0, y0: s.y0, dx, dy } };
  }
  /** The turn, the taps and the + buttons down or touched since the last read, cleared. */
  take() {
    const buttons = new Set([...this.pressed, ...this.held.values()]);
    const r = { yaw: this.yaw, pitch: this.pitch, taps: this.taps, buttons };
    this.yaw = 0; this.pitch = 0; this.taps = 0; this.pressed.clear();
    return r;
  }
}

// the buttons over the view: [label, what it does (a + button held, a command run once, the menu, full screen)]
export const BUTTONS = [['fire', '+attack'], ['jump', '+jump'], ['weapon', 'impulse 10'], ['menu', 'menu'], ['full', 'fullscreen']];
export const MENU_PAD = [['↑', 'ArrowUp'], ['↓', 'ArrowDown'], ['←', 'ArrowLeft'], ['→', 'ArrowRight'], ['OK', 'Enter'], ['back', 'Escape']];

// the view alone on the screen, turned sideways where the phone allows it; again to leave
function fullscreen(wrap) {
  if (document.fullscreenElement) { document.exitFullscreen?.().catch(() => {}); return; }
  const go = wrap.requestFullscreen ?? wrap.webkitRequestFullscreen;
  Promise.resolve(go?.call(wrap, { navigationUI: 'hide' })).then(() => screen.orientation?.lock?.('landscape')).catch(() => {});
}

/**
 * Puts the controls on the page: `wrap` holds the canvas and gets the overlay, shown from the first touch.
 * run(cmd) runs a command ("impulse 10"), menuKey(code) drives the menu, openMenu() brings it up,
 * menuActive() says whether it is up.
 */
export function attachTouch(wrap, canvas, ctl, { run, menuKey, openMenu, menuActive }) {
  const pad = document.createElement('div');
  pad.className = 'touch-pad';
  pad.innerHTML = '<div class="touch-stick"><div class="touch-knob"></div></div>'
    + `<div class="touch-buttons">${BUTTONS.map(([l, c]) => `<button type="button" data-cmd="${c}" class="touch-${l}">${l}</button>`).join('')}</div>`
    + `<div class="touch-menupad">${MENU_PAD.map(([l, k]) => `<button type="button" data-key="${k}">${l}</button>`).join('')}</div>`;
  wrap.append(pad);
  const stickEl = pad.querySelector('.touch-stick'), knobEl = pad.querySelector('.touch-knob');
  // shown from the first touch, and from then on drawn every display frame
  window.addEventListener('touchstart', () => {
    wrap.classList.add('touch');
    const loop = () => { update(); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }, { once: true, passive: true });

  canvas.addEventListener('touchstart', (e) => {
    const r = canvas.getBoundingClientRect();
    for (const t of e.changedTouches) ctl.start(t.identifier, t.clientX - r.left, t.clientY - r.top, r.width);
    e.preventDefault();
  }, { passive: false });
  canvas.addEventListener('touchmove', (e) => {
    const r = canvas.getBoundingClientRect();
    for (const t of e.changedTouches) ctl.move(t.identifier, t.clientX - r.left, t.clientY - r.top);
    e.preventDefault();
  }, { passive: false });
  const end = (e) => { for (const t of e.changedTouches) ctl.end(t.identifier); };
  canvas.addEventListener('touchend', end);
  canvas.addEventListener('touchcancel', end);

  for (const b of pad.querySelectorAll('[data-cmd]')) {
    const cmd = b.dataset.cmd;
    b.addEventListener('touchstart', (e) => {
      e.preventDefault();
      for (const t of e.changedTouches) {
        if (cmd.startsWith('+')) ctl.hold(t.identifier, cmd);
        else if (cmd === 'menu') openMenu();
        else if (cmd === 'fullscreen') fullscreen(wrap);
        else run(cmd);
      }
      b.classList.add('down');
    }, { passive: false });
    const up = (e) => { for (const t of e.changedTouches) ctl.end(t.identifier); b.classList.remove('down'); };
    b.addEventListener('touchend', up);
    b.addEventListener('touchcancel', up);
  }
  for (const b of pad.querySelectorAll('[data-key]')) {
    b.addEventListener('touchstart', (e) => { e.preventDefault(); menuKey(b.dataset.key); }, { passive: false });
  }

  // each frame: the stick drawn where the thumb is, the menu's pad in place of the game's buttons
  function update() {
    const a = ctl.axes();
    stickEl.hidden = !a.knob;
    if (a.knob) {
      stickEl.style.left = `${a.knob.x0}px`; stickEl.style.top = `${a.knob.y0}px`;
      knobEl.style.transform = `translate(${a.knob.dx}px, ${a.knob.dy}px)`;
    }
    pad.classList.toggle('menu-up', !!menuActive());
  }
}
