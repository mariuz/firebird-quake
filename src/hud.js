// hud.js – sbar.c: the status bar from gfx.wad, drawn into the 8-bit frame.

const IT = { SHOTGUN: 1, SUPER_SHOTGUN: 2, NAILGUN: 4, SUPER_NAILGUN: 8, GRENADE_LAUNCHER: 16, ROCKET_LAUNCHER: 32, LIGHTNING: 64,
  SHELLS: 256, NAILS: 512, ROCKETS: 1024, CELLS: 2048, AXE: 4096, ARMOR1: 8192, ARMOR2: 16384, ARMOR3: 32768, SUPERHEALTH: 65536,
  KEY1: 131072, KEY2: 262144, INVISIBILITY: 524288, INVULNERABILITY: 1048576, SUIT: 2097152, QUAD: 4194304 };

export class Hud {
  // wad: gfx.wad; lmp(name): a picture of its own in the pak (gfx/complete.lmp …), or null
  constructor(wad, lmp = () => null) {
    this.pic = (n) => wad.pic(n);
    this.complete = lmp('gfx/complete.lmp');
    this.inter = lmp('gfx/inter.lmp');
    this.finale = lmp('gfx/finale.lmp');
    this.colon = wad.pic('NUM_COLON');
    this.slash = wad.pic('NUM_SLASH');
    this.conchars = wad.pic('CONCHARS');
    this.nums = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((i) => wad.pic(`NUM_${i}`));
    this.anums = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((i) => wad.pic(`ANUM_${i}`));
    this.numMinus = wad.pic('NUM_MINUS');
    this.sbar = wad.pic('SBAR');
    this.ibar = wad.pic('IBAR');
    this.weapons = ['SHOTGUN', 'SSHOTGUN', 'NAILGUN', 'SNAILGUN', 'RLAUNCH', 'SRLAUNCH', 'LIGHTNG'].map((n) => ({
      off: wad.pic(`INV_${n}`), on: wad.pic(`INV2_${n}`), flash: [1, 2, 3, 4, 5].map((k) => wad.pic(`INVA${k}_${n}`)),
    }));
    this.ammo = ['SHELLS', 'NAILS', 'ROCKET', 'CELLS'].map((n) => wad.pic(`SB_${n}`));
    this.armor = [1, 2, 3].map((n) => wad.pic(`SB_ARMOR${n}`));
    this.items = ['KEY1', 'KEY2', 'INVIS', 'INVULN', 'SUIT', 'QUAD'].map((n) => wad.pic(`SB_${n}`));
    this.faces = [1, 2, 3, 4, 5].map((n) => ({ normal: wad.pic(`FACE${n}`), pain: wad.pic(`FACE_P${n}`) }));
    this.faceInvis = wad.pic('FACE_INVIS');
    this.faceInvul = wad.pic('FACE_INVUL2');
    this.faceQuad = wad.pic('FACE_QUAD');
    this.faceInvisInvul = wad.pic('FACE_INV2');
    this.sigils = [1, 2, 3, 4].map((n) => wad.pic(`SB_SIGIL${n}`));
    this.showInventory = false;   // Quake shows it only below viewsize 100
  }

  drawNum(r, x, y, num, digits, color) {
    let s = String(Math.max(-99, Math.min(999, Math.round(num))));
    if (s.length > digits) s = s.slice(s.length - digits);
    x += (digits - s.length) * 24;
    for (const ch of s) {
      const pic = ch === '-' ? this.numMinus : (color ? this.anums : this.nums)[Number(ch)];
      r.drawPic(pic, x, y);
      x += 24;
    }
  }

  drawInventory(r, hud, time, sbx, y, items) {
    r.drawPic(this.ibar, sbx, y - 24);
    for (let i = 0; i < 7; i++) {
      const bit = 1 << i;
      if (!(items & bit)) continue;
      const wp = this.weapons[i];
      r.drawPic(hud.WEAPON === bit ? wp.on : wp.off, sbx + i * 24, y - 16);
    }
    const counts = [hud.SHELLS, hud.NAILS, hud.ROCKETS, hud.CELLS];
    for (let i = 0; i < 4; i++) {
      const s = String(Math.min(999, Math.max(0, counts[i]))).padStart(3, ' ');
      for (let k = 0; k < 3; k++) if (s[k] !== ' ') r.drawChar(this.conchars, 18 + s.charCodeAt(k) - 48, sbx + (6 * i + 1) * 8 + k * 8, y - 24);
    }
    for (let i = 0; i < 6; i++) {
      const bit = [IT.KEY1, IT.KEY2, IT.INVISIBILITY, IT.INVULNERABILITY, IT.SUIT, IT.QUAD][i];
      if (items & bit) r.drawPic(this.items[i], sbx + 192 + i * 16, y - 16);
    }
    for (let i = 0; i < 4; i++) if (items & (1 << (28 + i))) r.drawPic(this.sigils[i], sbx + 320 - 32 + i * 8, y - 16);
  }

  /** hud: the QUAKE_TIC row. time: game time. */
  draw(r, hud, time) {
    const w = r.w, h = r.h;
    if (w < 320) {
      // low detail: no room for the pictures, just the numbers
      r.fillRect(0, h - 12, w, 12, 0);
      r.drawString(this.conchars, `${String(hud.ARMORVALUE).padStart(3)} ${String(hud.HEALTH).padStart(3)} ${String(hud.WEAPON & 3 ? hud.SHELLS : hud.WEAPON & 12 ? hud.NAILS : hud.WEAPON & 48 ? hud.ROCKETS : hud.WEAPON & 64 ? hud.CELLS : 0).padStart(3)}`, 4, h - 10);
      return;
    }
    const sbx = (w - 320) >> 1;
    const y = h - 24;
    const items = hud.ITEMS;
    if (this.showInventory) this.drawInventory(r, hud, time, sbx, y, items);
    // the status bar
    r.drawPic(this.sbar, sbx, y);
    if (items & IT.INVULNERABILITY) {
      this.drawNum(r, sbx + 24, y, 666, 3, 1);
      r.drawPic(this.pic('DISC'), sbx, y);
    } else {
      const a = hud.ARMORVALUE;
      this.drawNum(r, sbx + 24, y, a, 3, a <= 25 ? 1 : 0);
      if (items & IT.ARMOR3) r.drawPic(this.armor[2], sbx, y);
      else if (items & IT.ARMOR2) r.drawPic(this.armor[1], sbx, y);
      else if (items & IT.ARMOR1) r.drawPic(this.armor[0], sbx, y);
    }
    // the face
    const hp = hud.HEALTH;
    let face;
    if ((items & IT.INVISIBILITY) && (items & IT.INVULNERABILITY)) face = this.faceInvisInvul;
    else if (items & IT.QUAD) face = this.faceQuad;
    else if (items & IT.INVISIBILITY) face = this.faceInvis;
    else if (items & IT.INVULNERABILITY) face = this.faceInvul;
    else {
      const f = hp >= 100 ? 4 : Math.max(0, Math.floor(hp / 20));
      const pain = time - hud.DMG_TIME < 0.2;
      face = pain ? this.faces[4 - f].pain : this.faces[4 - f].normal;
    }
    r.drawPic(face, sbx + 112, y);
    this.drawNum(r, sbx + 136, y, hp, 3, hp <= 25 ? 1 : 0);
    // ammo
    const wpn = hud.WEAPON;
    let ai = -1, cnt = 0;
    if (wpn & (IT.SHOTGUN | IT.SUPER_SHOTGUN)) { ai = 0; cnt = hud.SHELLS; }
    else if (wpn & (IT.NAILGUN | IT.SUPER_NAILGUN)) { ai = 1; cnt = hud.NAILS; }
    else if (wpn & (IT.GRENADE_LAUNCHER | IT.ROCKET_LAUNCHER)) { ai = 2; cnt = hud.ROCKETS; }
    else if (wpn & IT.LIGHTNING) { ai = 3; cnt = hud.CELLS; }
    if (ai >= 0) {
      r.drawPic(this.ammo[ai], sbx + 224, y);
      this.drawNum(r, sbx + 248, y, cnt, 3, cnt <= 10 ? 1 : 0);
    }
  }

  // Sbar_IntermissionOverlay: the level's time, secrets and kills over the view (Quake's 320-wide layout)
  drawIntermission(r, hud) {
    const x = Math.max(0, (r.w - 320) >> 1);
    r.drawPic(this.complete, x + 64, 24);
    r.drawPic(this.inter, x, 56);
    const t = Math.max(0, Math.floor(hud.COMPLETED_TIME ?? 0));
    this.drawNum(r, x + 160, 64, Math.floor(t / 60), 3, 0);
    r.drawPic(this.colon, x + 234, 64);
    r.drawPic(this.nums[Math.floor((t % 60) / 10)], x + 246, 64);
    r.drawPic(this.nums[t % 10], x + 266, 64);
    this.drawNum(r, x + 160, 104, hud.FOUND_SECRETS, 3, 0);
    r.drawPic(this.slash, x + 232, 104);
    this.drawNum(r, x + 240, 104, hud.TOTAL_SECRETS, 3, 0);
    this.drawNum(r, x + 160, 144, hud.KILLED, 3, 0);
    r.drawPic(this.slash, x + 232, 144);
    this.drawNum(r, x + 240, 144, hud.TOTAL_MONSTERS, 3, 0);
  }

  // Sbar_FinaleOverlay and the finale's centre print: the picture, then the text typed out at eight
  // characters a second (scr_printspeed), each line centred
  drawFinale(r, text, elapsed) {
    if (this.finale) r.drawPic(this.finale, (r.w - this.finale.w) >> 1, 16);
    const lines = text.split('\n');
    let remaining = Math.floor(elapsed * 8);
    let y = lines.length <= 4 ? Math.floor(r.h * 0.35) : 48;
    for (const line of lines) {
      if (remaining <= 0) break;
      r.drawString(this.conchars, line.slice(0, remaining), (r.w - line.length * 8) >> 1, y);
      remaining -= line.length + 1;
      y += 8;
    }
  }

  drawCenter(r, msg, y) {
    const lines = msg.split('\n');
    for (const line of lines) {
      r.drawString(this.conchars, line, (r.w - line.length * 8) >> 1, y);
      y += 8;
    }
  }
}

export const VIEW_MODELS = { 4096: 'progs/v_axe.mdl', 1: 'progs/v_shot.mdl', 2: 'progs/v_shot2.mdl', 4: 'progs/v_nail.mdl',
  8: 'progs/v_nail2.mdl', 16: 'progs/v_rock.mdl', 32: 'progs/v_rock2.mdl', 64: 'progs/v_light.mdl' };
