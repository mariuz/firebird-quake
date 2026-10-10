// binds.js – keys.c: every key is bound to a console command. A command starting with + is a button held
// while its key is down (+forward, +attack…: in_button.c's kbuttons, two keys each in Quake, any number
// here); anything else runs once when the key goes down ("impulse 7", "god", "save quick"). The page reads
// the buttons into each tic's input. Keys have Quake's names (w, uparrow, ctrl, mouse1, mwheelup, f6…),
// so `bind ctrl +attack` covers both control keys, as in Quake.

// KeyboardEvent.code → Quake's key name (Key_KeynumToString's names)
const NAMED = {
  Space: 'space', Enter: 'enter', NumpadEnter: 'enter', Tab: 'tab', Backspace: 'backspace', Escape: 'escape', Pause: 'pause',
  ArrowUp: 'uparrow', ArrowDown: 'downarrow', ArrowLeft: 'leftarrow', ArrowRight: 'rightarrow',
  ControlLeft: 'ctrl', ControlRight: 'ctrl', ShiftLeft: 'shift', ShiftRight: 'shift', AltLeft: 'alt', AltRight: 'alt',
  PageUp: 'pgup', PageDown: 'pgdn', Home: 'home', End: 'end', Insert: 'ins', Delete: 'del',
  Comma: ',', Period: '.', Slash: '/', Semicolon: 'semicolon', Quote: "'", Minus: '-', Equal: '=',
  BracketLeft: '[', BracketRight: ']', Backslash: '\\', Backquote: '`',
};
export function keyName(code) {
  if (NAMED[code]) return NAMED[code];
  let m = /^Key([A-Z])$/.exec(code);
  if (m) return m[1].toLowerCase();
  m = /^(?:Digit|Numpad)(\d)$/.exec(code);
  if (m) return m[1];
  m = /^F(\d{1,2})$/.exec(code);
  if (m) return `f${m[1]}`;
  return null;
}
export const MOUSE_NAMES = { 0: 'mouse1', 1: 'mouse3', 2: 'mouse2' };

// the page's keys as they were before bindings, which are Quake's default.cfg where it has one
export const DEFAULT_BINDS = {
  w: '+forward', uparrow: '+forward', s: '+back', downarrow: '+back', a: '+moveleft', ',': '+moveleft',
  d: '+moveright', '.': '+moveright', leftarrow: '+left', rightarrow: '+right', pgup: '+lookup', pgdn: '+lookdown',
  ctrl: '+attack', f: '+attack', mouse1: '+attack', space: '+jump', e: '+jump', mouse2: '+forward', shift: '+speed',
  1: 'impulse 1', 2: 'impulse 2', 3: 'impulse 3', 4: 'impulse 4', 5: 'impulse 5', 6: 'impulse 6', 7: 'impulse 7', 8: 'impulse 8', 9: 'impulse 9',
  '/': 'impulse 10', mwheelup: 'impulse 10', mwheeldown: 'impulse 10',
  p: 'pause', pause: 'pause', f6: 'save quick', f9: 'load quick', '`': 'toggleconsole',
};

// the buttons, in the order the menu's Customize controls lists them (M_Keys' bindnames)
export const BUTTONS = [
  ['+attack', 'attack'], ['impulse 10', 'change weapon'], ['+jump', 'jump / swim up'], ['+forward', 'walk forward'],
  ['+back', 'backpedal'], ['+left', 'turn left'], ['+right', 'turn right'], ['+speed', 'run'],
  ['+moveleft', 'step left'], ['+moveright', 'step right'], ['+lookup', 'look up'], ['+lookdown', 'look down'],
  ['toggleconsole', 'console'],
];

export class Bindings {
  constructor(saved = null) {
    this.map = new Map(Object.entries(saved ?? DEFAULT_BINDS));
    this.held = new Map();         // button (+forward) → the keys holding it down
  }
  get(key) { return this.map.get(key) ?? null; }
  set(key, cmd) { if (cmd) this.map.set(key, cmd); else this.map.delete(key); }
  unbindAll() { this.map.clear(); this.held.clear(); }
  reset() { this.map = new Map(Object.entries(DEFAULT_BINDS)); this.held.clear(); }
  keysFor(cmd) { return [...this.map].filter(([, c]) => c === cmd).map(([k]) => k); }
  toJSON() { return Object.fromEntries(this.map); }

  /**
   * A key went down (true) or up (false). Returns the command to run once, or null: a + command holds its
   * button instead, and its release lets go (in Quake the release runs the - command).
   */
  key(name, down) {
    const cmd = name ? this.get(name) : null;
    if (!cmd) return null;
    if (cmd.startsWith('+')) {
      const keys = this.held.get(cmd) ?? new Set();
      if (down) keys.add(name); else keys.delete(name);
      if (keys.size) this.held.set(cmd, keys); else this.held.delete(cmd);
      return null;
    }
    return down ? cmd : null;
  }
  down(button) { return this.held.has(button); }
  release() { this.held.clear(); }
}
