// console.js – console.c and cmd.c: Quake's console, drawn in the frame over gfx/conback.lmp with the
// console font. ` (toggleconsole) brings it down over the top half; what is typed runs as commands,
// several on a line separated by ;, arguments split at spaces with "quotes" keeping one; ↑ and ↓ walk
// the lines typed before, Tab completes a command's name, PageUp and PageDown scroll back. The commands
// are the page's (src/main.js hands them in): most become the SQL they stand for.
//
//   const con = new Console({ commands: { god: { help, run(args, con) } … }, conchars, conback });
//   con.toggle(); con.key(code, key); con.draw(renderer, seconds);

const MAX_LINES = 256;
const HISTORY = 32;

/** Cmd_TokenizeString: words split at spaces, "a quoted phrase" one word. */
export function tokenize(line) {
  const out = [];
  const re = /"([^"]*)"|(\S+)/g;
  let m;
  while ((m = re.exec(line))) out.push(m[1] ?? m[2]);
  return out;
}

/** Cbuf_AddText's split: commands on one line separated by ; outside quotes. */
export function splitCommands(line) {
  const out = [];
  let cur = '', quoted = false;
  for (const ch of line) {
    if (ch === '"') quoted = !quoted;
    if (ch === ';' && !quoted) { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

export class Console {
  constructor({ commands, conchars = null, conback = null, title = 'Firebird Quake' }) {
    this.commands = commands;
    this.conchars = conchars;
    this.conback = conback;
    this.title = title;
    this.lines = [];
    this.input = '';
    this.history = [];
    this.histPos = 0;
    this.scroll = 0;
    this.active = false;
  }

  toggle(open = !this.active) { this.active = open; this.scroll = 0; }

  /** Con_Printf: text, broken into lines (a trailing newline ends the line). */
  print(text) {
    for (const line of String(text).replace(/\n$/, '').split('\n')) this.lines.push(line);
    if (this.lines.length > MAX_LINES) this.lines.splice(0, this.lines.length - MAX_LINES);
  }

  /** Run a line: each of its commands in turn (an async command finishes before the next starts). */
  async execute(line, echo = true) {
    if (echo) this.print(`]${line}`);
    for (const part of splitCommands(line)) {
      const [name, ...args] = tokenize(part);
      const cmd = this.commands[name?.toLowerCase()];
      if (!cmd) { this.print(`Unknown command "${name}"`); continue; }
      try {
        const out = await cmd.run(args, this, part.slice(name.length).trim());   // (the line as typed, for sql)
        if (out != null && out !== '') this.print(out);
      } catch (err) {
        this.print(`${name}: ${err.message.split('\n')[0]}`);
      }
    }
  }

  /** A key while the console is down (KeyboardEvent.code and .key); returns true when it used it. */
  key(code, key) {
    if (!this.active) return false;
    if (code === 'Backquote' || code === 'Escape') { this.toggle(false); return true; }
    if (code === 'Enter' || code === 'NumpadEnter') {
      const line = this.input.trim();
      this.input = '';
      this.scroll = 0;
      if (line) {
        this.history = [...this.history.filter((h) => h !== line), line].slice(-HISTORY);
        this.execute(line);
      }
      this.histPos = this.history.length;
      return true;
    }
    if (code === 'Backspace') { this.input = this.input.slice(0, -1); return true; }
    if (code === 'ArrowUp' || code === 'ArrowDown') {
      this.histPos = Math.max(0, Math.min(this.history.length, this.histPos + (code === 'ArrowUp' ? -1 : 1)));
      this.input = this.history[this.histPos] ?? '';
      return true;
    }
    if (code === 'PageUp' || code === 'PageDown') {
      this.scroll = Math.max(0, Math.min(this.lines.length - 1, this.scroll + (code === 'PageUp' ? 4 : -4)));
      return true;
    }
    if (code === 'Tab') {
      // Con_CompleteCommandLine: the commands the word starts; one fills it in, several are listed
      const word = this.input.trimStart().toLowerCase();
      if (!word || word.includes(' ')) return true;
      const names = Object.keys(this.commands).filter((n) => n.startsWith(word)).sort();
      if (names.length === 1) this.input = `${names[0]} `;
      else if (names.length > 1) {
        this.print(names.join('  '));
        let common = names[0];
        for (const n of names) while (!n.startsWith(common)) common = common.slice(0, -1);
        this.input = common;
      }
      return true;
    }
    if (key && key.length === 1 && key.charCodeAt(0) >= 32 && key.charCodeAt(0) < 127 && this.input.length < 120) this.input += key;
    return true;
  }

  /** Con_DrawConsole: the top half of the frame, the newest lines above the input line. */
  draw(r, seconds) {
    if (!this.active) return;
    const lines = Math.floor(r.h / 2);
    if (this.conback) r.drawConback(this.conback, lines);
    else r.fillRect(0, 0, r.w, lines, 0);
    if (!this.conchars) return;
    const cols = Math.floor(r.w / 8) - 2;
    // the version in the corner, as Quake writes it into the background
    r.drawString(this.conchars, this.title, r.w - this.title.length * 8 - 8, lines - 18, true);
    const rows = Math.floor((lines - 22) / 8);
    const wrapped = [];
    for (const l of this.lines) for (let i = 0; i < Math.max(1, l.length); i += cols) wrapped.push(l.slice(i, i + cols));
    const end = wrapped.length - Math.min(this.scroll, Math.max(0, wrapped.length - 1));
    const shown = wrapped.slice(Math.max(0, end - rows), end);
    shown.forEach((l, i) => r.drawString(this.conchars, l, 8, lines - 22 - (shown.length - i) * 8 + 4));
    if (this.scroll) r.drawString(this.conchars, '^ '.repeat(Math.floor(cols / 2)), 8, lines - 22 + 4, true);
    // the input line, the cursor blinking at 4 Hz (Quake's char 10/11)
    const text = `]${this.input}`;
    const visible = text.slice(Math.max(0, text.length - cols));
    r.drawString(this.conchars, visible, 8, lines - 14);
    r.drawChar(this.conchars, Math.floor(seconds * 4) & 1 ? 11 : 10, 8 + visible.length * 8, lines - 14);
  }
}
