// menu.js – menu.c: Quake's menu, drawn into the 8-bit frame over the dimmed game. Escape brings it up
// (and the game pauses, as single player Quake does); the arrows move, Enter chooses, Escape goes back,
// left and right change an option. The pictures are Quake's own (gfx/qplaque.lmp, gfx/ttl_main.lmp,
// gfx/mainmenu.lmp, the spinning gfx/menudotN.lmp cursor…), the text the alternate font of M_Print.
//
//   const menu = new Menu({ lmp, conchars, play, actions });
//   menu.open(); menu.key('ArrowDown'); menu.draw(renderer, seconds);

const MAIN_ITEMS = 5;            // Single Player, Multiplayer, Options, Help, Quit (mainmenu.lmp)
const SINGLE_ITEMS = 3;          // New Game, Load, Save (sp_menu.lmp)
const SAVE_SLOTS = 12;           // MAX_SAVEGAMES
const SLIDER_RANGE = 10;

export class Menu {
  /**
   * lmp(name): a picture of the pak (or null); conchars: the console font; play(sound): a menu sound;
   * actions: { newGame(), quit(), multiplayer(), saves() → [12 slot names or null], load(slot), save(slot),
   *            options: [{ label, get(), change(dir), kind: 'slider' | 'check' | 'value' | 'action' | 'keys' }],
   *            keys: { list: [[command, label]], keysFor(command), bind(key, command), clear(command), keyName(code) } }
   */
  constructor({ lmp, conchars, play = () => {}, actions }) {
    this.lmp = lmp;
    this.pics = new Map();
    this.conchars = conchars;
    this.play = play;
    this.actions = actions;
    this.state = null;
    this.cursor = { main: 0, single: 0, options: 0, load: 0, save: 0, keys: 0 };
    this.binding = false;        // Customize controls: waiting for the key to bind
    this.helpPage = 0;
    this.slots = [];
    this.message = null;         // a line under the menu for a moment (a slot saved, a feature missing)
  }

  pic(name) {
    if (!this.pics.has(name)) this.pics.set(name, this.lmp(name));
    return this.pics.get(name);
  }

  get active() { return this.state !== null; }
  open() { this.state = 'main'; this.message = null; this.play('misc/menu2.wav'); }
  close() { this.state = null; this.play('misc/menu3.wav'); }

  /** A key (KeyboardEvent.code) while the menu is up; returns true when the menu used it. */
  key(code) {
    const s = this.state;
    if (!s) return false;
    const up = code === 'ArrowUp', down = code === 'ArrowDown', enter = code === 'Enter' || code === 'NumpadEnter' || code === 'Space';
    const back = code === 'Escape' || code === 'Backspace';
    const move = (k, n) => { this.cursor[k] = (this.cursor[k] + (down ? 1 : -1) + n) % n; this.play('misc/menu1.wav'); };
    if (s === 'main') {
      if (back) { this.close(); return true; }
      if (up || down) move('main', MAIN_ITEMS);
      else if (enter) {
        this.play('misc/menu2.wav');
        this.message = null;
        switch (this.cursor.main) {
          case 0: this.state = 'single'; break;
          case 1: this.state = null; this.actions.multiplayer?.(); break;   // a deathmatch with bots (sql/bots.sql)
          case 2: this.state = 'options'; break;
          case 3: this.state = 'help'; this.helpPage = 0; break;
          default: this.state = 'quit'; break;
        }
      }
      return true;
    }
    if (s === 'single') {
      if (back) { this.state = 'main'; this.play('misc/menu1.wav'); return true; }
      if (up || down) move('single', SINGLE_ITEMS);
      else if (enter) {
        this.play('misc/menu2.wav');
        if (this.cursor.single === 0) { this.state = null; this.actions.newGame(); }
        else if (!this.actions.saves) this.message = 'no saving or loading yet';
        else {
          this.state = this.cursor.single === 1 ? 'load' : 'save';
          this.slots = this.actions.saves();
        }
      }
      return true;
    }
    if (s === 'load' || s === 'save') {
      if (back) { this.state = 'single'; this.play('misc/menu1.wav'); return true; }
      if (up || down) move(s, SAVE_SLOTS);
      else if (enter) {
        const slot = this.cursor[s];
        if (s === 'load' && !this.slots[slot]) { this.play('misc/menu3.wav'); return true; }
        this.play('misc/menu2.wav');
        this.state = null;
        if (s === 'load') this.actions.load?.(slot); else this.actions.save?.(slot);
      }
      return true;
    }
    if (s === 'options') {
      const items = this.actions.options;
      if (back) { this.state = 'main'; this.play('misc/menu1.wav'); return true; }
      if (up || down) { move('options', items.length); return true; }
      const it = items[this.cursor.options];
      const left = code === 'ArrowLeft', right = code === 'ArrowRight';
      if (it.kind === 'keys') { if (enter) { this.state = 'keys'; this.play('misc/menu2.wav'); } return true; }
      if (left || right || enter) {
        if (it.kind === 'action' && !enter) return true;
        it.change(left ? -1 : 1);
        this.play('misc/menu3.wav');
      }
      return true;
    }
    if (s === 'keys') {
      // M_Keys_Key: Enter waits for a key and binds it (a third key replaces the two), Backspace clears
      const k = this.actions.keys;
      const [cmd] = k.list[this.cursor.keys];
      if (this.binding) {
        this.binding = false;
        if (code === 'Escape') { this.play('misc/menu1.wav'); return true; }
        const name = k.keyName(code);
        if (!name || name === '`') return true;
        if (k.keysFor(cmd).length >= 2) k.clear(cmd);
        k.bind(name, cmd);
        this.play('misc/menu1.wav');
        return true;
      }
      if (code === 'Escape') { this.state = 'options'; this.play('misc/menu1.wav'); return true; }
      if (up || down) { move('keys', k.list.length); return true; }
      if (code === 'Enter' || code === 'NumpadEnter') { this.binding = true; this.play('misc/menu2.wav'); return true; }
      if (code === 'Backspace' || code === 'Delete') { k.clear(cmd); this.play('misc/menu2.wav'); }
      return true;
    }
    if (s === 'help') {
      if (back) { this.state = 'main'; this.play('misc/menu1.wav'); return true; }
      if (code === 'ArrowLeft' || code === 'ArrowUp') { this.helpPage = (this.helpPage + 5) % 6; this.play('misc/menu1.wav'); }
      else if (code === 'ArrowRight' || code === 'ArrowDown' || enter) { this.helpPage = (this.helpPage + 1) % 6; this.play('misc/menu1.wav'); }
      return true;
    }
    if (s === 'quit') {
      if (code === 'KeyY' || enter) { this.state = null; this.actions.quit(); }
      else if (code === 'KeyN' || back) { this.state = 'main'; this.play('misc/menu1.wav'); }
      return true;
    }
    return true;
  }

  // ── drawing (M_Draw): Quake's 320-wide layout, centred ──────────────────
  draw(r, seconds) {
    const x0 = Math.max(0, (r.w - 320) >> 1);
    const P = (name, x, y) => { const p = this.pic(name); if (p) r.drawPic(p, x0 + x, y); return p; };
    const centred = (name, y) => { const p = this.pic(name); if (p) r.drawPic(p, x0 + ((320 - p.w) >> 1), y); };
    const print = (x, y, text, alt = true) => r.drawString(this.conchars, text, x0 + x, y, alt);
    const ch = (x, y, c) => r.drawChar(this.conchars, c, x0 + x, y);
    const dot = `gfx/menudot${(Math.floor(seconds * 10) % 6) + 1}.lmp`;
    switch (this.state) {
      case 'main':
        P('gfx/qplaque.lmp', 16, 4); centred('gfx/ttl_main.lmp', 4);
        P('gfx/mainmenu.lmp', 72, 32); P(dot, 54, 32 + this.cursor.main * 20);
        break;
      case 'single':
        P('gfx/qplaque.lmp', 16, 4); centred('gfx/ttl_sgl.lmp', 4);
        P('gfx/sp_menu.lmp', 72, 32); P(dot, 54, 32 + this.cursor.single * 20);
        break;
      case 'load': case 'save': {
        centred(this.state === 'load' ? 'gfx/p_load.lmp' : 'gfx/p_save.lmp', 4);
        for (let i = 0; i < SAVE_SLOTS; i++) print(16, 32 + 8 * i, (this.slots[i] ?? '--- UNUSED SLOT ---').slice(0, 39), false);
        ch(8, 32 + this.cursor[this.state] * 8, 12 + (Math.floor(seconds * 4) & 1));
        break;
      }
      case 'options': {
        P('gfx/qplaque.lmp', 16, 4); centred('gfx/p_option.lmp', 4);
        this.actions.options.forEach((it, i) => {
          const y = 32 + i * 8;
          print(16, y, it.label.padStart(22));
          if (it.kind === 'slider') {
            const v = Math.max(0, Math.min(1, it.get()));
            ch(220, y, 128);
            for (let k = 0; k < SLIDER_RANGE; k++) ch(228 + k * 8, y, 129);
            ch(228 + SLIDER_RANGE * 8, y, 130);
            ch(228 + Math.round((SLIDER_RANGE - 1) * 8 * v), y, 131);
          } else if (it.kind === 'check') print(220, y, it.get() ? 'on' : 'off', false);
          else if (it.kind === 'value') print(220, y, String(it.get()), false);
        });
        ch(200, 32 + this.cursor.options * 8, 12 + (Math.floor(seconds * 4) & 1));
        break;
      }
      case 'keys': {
        // M_Keys_Draw: each button and its two keys, the cursor (=, blinking, while waiting for a key)
        centred('gfx/ttl_cstm.lmp', 4);
        const k = this.actions.keys;
        print(12, 32, this.binding ? 'Press a key or button for this action' : 'Enter to change, backspace to clear', false);
        k.list.forEach(([cmd, label], i) => {
          const y = 48 + 8 * i;
          print(16, y, label, false);
          const keys = k.keysFor(cmd);
          print(140, y, keys.length ? keys.slice(0, 2).join(' or ') : '???');
        });
        ch(130, 48 + this.cursor.keys * 8, this.binding ? 61 : 12 + (Math.floor(seconds * 4) & 1));
        break;
      }
      case 'help': P(`gfx/help${this.helpPage}.lmp`, 0, 0); break;
      case 'quit': {
        // M_Quit_Draw's box: the question, Y or N
        const lines = ['Leave this game?', '', 'Y: a new game from the start map', 'N: back to the menu'];
        const w = 36, top = 72;
        this.box(r, x0 + 160 - (w * 8) / 2 - 8, top - 8, w, lines.length);
        lines.forEach((l, i) => print(160 - (l.length * 4), top + i * 8, l, i === 0));
        break;
      }
      default: break;
    }
    if (this.message) print(160 - this.message.length * 4, 190, this.message, false);
  }

  // M_DrawTextBox: the box of gfx/box_*.lmp around w×lines characters
  box(r, x, y, w, lines) {
    const P = (n, px, py) => { const p = this.pic(n); if (p) r.drawPic(p, px, py); };
    P('gfx/box_tl.lmp', x, y);
    for (let i = 0; i < lines; i++) P('gfx/box_ml.lmp', x, y + 8 + i * 8);
    P('gfx/box_bl.lmp', x, y + 8 + lines * 8);
    let cx = x + 8;
    for (let k = 0; k < w; k += 2) {
      P('gfx/box_tm.lmp', cx, y);
      for (let i = 0; i < lines; i++) P(i & 1 ? 'gfx/box_mm2.lmp' : 'gfx/box_mm.lmp', cx, y + 8 + i * 8);
      P('gfx/box_bm.lmp', cx, y + 8 + lines * 8);
      cx += 16;
    }
    P('gfx/box_tr.lmp', cx, y);
    for (let i = 0; i < lines; i++) P('gfx/box_mr.lmp', cx, y + 8 + i * 8);
    P('gfx/box_br.lmp', cx, y + 8 + lines * 8);
  }
}
