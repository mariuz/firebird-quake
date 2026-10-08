// audio.js – snd_dma.c, more or less: the SOUND_EVENTS rows become Web
// Audio buffers, attenuated and panned from where they happened (Quake's
// spatialisation: volume falls off linearly with distance × attenuation,
// pan by the dot product with the right vector). Three kinds of ambience:
//   - entity ambients (ambient_drip, torches, …) loop at their map entity,
//   - leaf ambients: water and wind, from the BSP leaf the player is in
//     (S_UpdateAmbientSounds), faded in and out,
//   - music: Quake's soundtrack was CD audio, which the pak does not hold.
//     Tracks come from music/trackNN.ogg|mp3 next to the page or a folder
//     the player picks; failing that, a synthesised drone keeps the mood.

const AMBIENTS = {
  ambient_comp_hum: 'ambience/comp1.wav', ambient_drip: 'ambience/drip1.wav', ambient_drone: 'ambience/drone6.wav',
  ambient_swamp1: 'ambience/swamp1.wav', ambient_swamp2: 'ambience/swamp2.wav', ambient_suck_wind: 'ambience/suck1.wav',
  ambient_flouro_buzz: 'ambience/buzz1.wav', ambient_light_buzz: 'ambience/fl_hum1.wav', ambient_thunder: 'ambience/thunder1.wav',
  light_fluoro: 'ambience/fl_hum1.wav', light_fluorospark: 'ambience/buzz1.wav',
  light_torch_small_walltorch: 'ambience/fire1.wav', light_flame_large_yellow: 'ambience/fire1.wav',
  light_flame_small_yellow: 'ambience/fire1.wav', light_flame_small_white: 'ambience/fire1.wav',
};
const LEAF_AMBIENTS = ['ambience/water1.wav', 'ambience/wind2.wav'];   // AMBIENT_WATER, AMBIENT_SKY
const AMBIENT_FADE = 100;   // ambient_fade: units of volume (0..255) per second

export class QuakeAudio {
  constructor() {
    this.ctx = null;
    this.pak = null;
    this.buffers = new Map();
    this.volume = 0.7;
    this.musicVolume = 0.5;
    this.channels = new Map();   // `${ent}:${chan}` → source, to cut
    this.ambients = [];
    this.leafAmbients = [];      // [{ src, gain, level }] for water, sky
    this.listener = { x: 0, y: 0, z: 0, yaw: 0 };
    this.musicMode = 'tracks';   // 'off' | 'tracks' | 'synth'
    this.musicFiles = new Map(); // 'track06' → File, from a picked folder
    this.music = null;           // { track, src, gain } or synth nodes
    this.track = 0;
  }

  setPak(pak) { this.pak = pak; this.buffers.clear(); }
  setVolume(v) { this.volume = v; if (this.master) this.master.gain.value = v; }
  setMusicVolume(v) { this.musicVolume = v; if (this.musicGain) this.musicGain.gain.value = v; }

  unlock() {
    if (!this.ctx) {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this.master = this.ctx.createGain();
      this.master.gain.value = this.volume;
      this.master.connect(this.ctx.destination);
      this.musicGain = this.ctx.createGain();
      this.musicGain.gain.value = this.musicVolume;
      this.musicGain.connect(this.ctx.destination);
      this.startAmbients();
      this.startLeafAmbients();
      if (this.track) this.playMusic(this.track);
    }
    if (this.ctx.state === 'suspended') this.ctx.resume();
  }

  suspend(hidden) {
    if (!this.ctx) return;
    if (hidden) this.ctx.suspend(); else this.ctx.resume();
  }

  async buffer(name) {
    if (this.buffers.has(name)) return this.buffers.get(name);
    const p = (async () => {
      if (!this.pak || !this.pak.has('sound/' + name)) return null;
      try {
        return await this.ctx.decodeAudioData(this.pak.buffer('sound/' + name));
      } catch { return null; }
    })();
    this.buffers.set(name, p);
    return p;
  }

  /** Volume and pan of a sound at (x, y, z) for the listener. */
  spatialize(x, y, z, attn) {
    const l = this.listener;
    if (x == null) return { gain: 1, pan: 0 };
    const dx = x - l.x, dy = y - l.y, dz = z - l.z;
    const dist = Math.hypot(dx, dy, dz) * attn * 0.001;
    const gain = Math.max(0, 1 - dist);
    const yaw = (l.yaw * Math.PI) / 180;
    const rx = Math.sin(yaw), ry = -Math.cos(yaw);
    const d = Math.hypot(dx, dy) || 1;
    const pan = ((dx * rx + dy * ry) / d) * 0.8;
    return { gain, pan };
  }

  // a sound with no place (the menu's)
  async playLocal(name) {
    if (!this.ctx) return;
    const buf = await this.buffer(name);
    if (!buf) return;
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(this.master);
    src.start();
  }

  async playEvents(rows, listener) {
    this.listener = listener;
    if (!this.ctx) return;
    for (const [, , ent, chan, name, vol, attn, x, y, z] of rows) {
      const buf = await this.buffer(name);
      if (!buf) continue;
      const { gain, pan } = this.spatialize(x, y, z, attn);
      if (gain <= 0) continue;
      const key = `${ent}:${chan}`;
      if (ent != null && chan !== 0) {
        const old = this.channels.get(key);
        if (old) { try { old.stop(); } catch { /* ended */ } }
      }
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      const g = this.ctx.createGain();
      g.gain.value = gain * vol;
      const p = this.ctx.createStereoPanner ? this.ctx.createStereoPanner() : null;
      if (p) { p.pan.value = pan; src.connect(g).connect(p).connect(this.master); } else src.connect(g).connect(this.master);
      src.start();
      if (ent != null && chan !== 0) this.channels.set(key, src);
    }
  }

  // ── entity ambients ────────────────────────────────────────────────────
  /** The map's ambient sound emitters (from the entity lump). */
  setAmbients(entities) {
    this.stopAmbients();
    this.ambientDefs = entities
      .filter((e) => AMBIENTS[e.classname])
      .map((e) => {
        const o = (e.origin ?? '0 0 0').split(/\s+/).map(Number);
        return { name: AMBIENTS[e.classname], x: o[0], y: o[1], z: o[2] };
      });
    if (this.ctx) this.startAmbients();
  }

  loop(buf, dest) {
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.loop = true;
    const g = this.ctx.createGain();
    g.gain.value = 0;
    const p = this.ctx.createStereoPanner ? this.ctx.createStereoPanner() : null;
    if (p) src.connect(g).connect(p).connect(dest); else src.connect(g).connect(dest);
    src.start(0, Math.random() * buf.duration);   // not all in phase
    return { src, gain: g, pan: p };
  }

  async startAmbients() {
    if (!this.ambientDefs || !this.ctx) return;
    for (const a of this.ambientDefs) {
      const buf = await this.buffer(a.name);
      if (!buf || a.src) continue;
      Object.assign(a, this.loop(buf, this.master));
      this.ambients.push(a);
    }
  }

  stopAmbients() {
    for (const a of this.ambients) { try { a.src.stop(); } catch { /* ended */ } a.src = null; }
    this.ambients = [];
  }

  // ── leaf ambients (S_UpdateAmbientSounds) ──────────────────────────────
  async startLeafAmbients() {
    if (!this.ctx || this.leafAmbients.length) return;
    for (const name of LEAF_AMBIENTS) {
      const buf = await this.buffer(name);
      if (!buf) { this.leafAmbients.push(null); continue; }
      this.leafAmbients.push({ ...this.loop(buf, this.master), level: 0 });
    }
  }

  /**
   * Called every frame with the listener and the ambient levels (0..255) of
   * the leaf the player is in. Fades at ambient_fade per second, like Quake.
   */
  update(listener, levels, dt) {
    this.listener = listener;
    for (const a of this.ambients) {
      const { gain, pan } = this.spatialize(a.x, a.y, a.z, 2);
      a.gain.gain.value = gain * 0.6;
      if (a.pan) a.pan.pan.value = pan;
    }
    for (let i = 0; i < this.leafAmbients.length; i++) {
      const la = this.leafAmbients[i];
      if (!la) continue;
      const target = levels[i] ?? 0;
      const step = AMBIENT_FADE * dt;
      if (la.level < target) la.level = Math.min(target, la.level + step);
      else if (la.level > target) la.level = Math.max(target, la.level - step);
      la.gain.gain.value = (la.level / 255) * 0.3;   // ambient_level 0.3
    }
  }

  // ── music ──────────────────────────────────────────────────────────────
  setMusicMode(mode) {
    this.musicMode = mode;
    this.stopMusic();
    if (this.track && this.ctx) this.playMusic(this.track);
  }

  /** A folder of trackNN.ogg/mp3 files the player picked. */
  setMusicFiles(files) {
    this.musicFiles.clear();
    for (const f of files) {
      const m = /track(\d+)\.(ogg|mp3|wav|m4a|flac)$/i.exec(f.name);
      if (m) this.musicFiles.set(`track${m[1].padStart(2, '0')}`, f);
    }
    if (this.track && this.ctx) { this.stopMusic(); this.playMusic(this.track); }
  }

  /** Start the CD track of the map (worldspawn "sounds"). */
  async playMusic(track) {
    this.track = track;
    if (!this.ctx || this.musicMode === 'off' || !track) { this.stopMusic(); return; }
    if (this.music && this.music.track === track) return;
    this.stopMusic();
    const name = `track${String(track).padStart(2, '0')}`;
    const token = { track };
    this.music = token;
    let buf = null;
    if (this.musicMode === 'tracks') {
      const file = this.musicFiles.get(name);
      const sources = file ? [file] : ['ogg', 'mp3'].map((ext) => new URL(`./music/${name}.${ext}`, location.href));
      for (const srcUrl of sources) {
        try {
          const data = srcUrl instanceof File ? await srcUrl.arrayBuffer() : await fetch(srcUrl).then((r) => (r.ok ? r.arrayBuffer() : null));
          if (!data) continue;
          buf = await this.ctx.decodeAudioData(data);
          break;
        } catch { /* try the next */ }
      }
    }
    if (this.music !== token) return;   // superseded while loading
    if (buf) {
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.loop = true;
      src.connect(this.musicGain);
      src.start();
      token.src = src;
      token.kind = 'track';
    } else if (this.musicMode !== 'off') {
      token.kind = 'synth';
      token.stop = this.startDrone(track);
    }
  }

  stopMusic() {
    if (!this.music) return;
    try { this.music.src?.stop(); } catch { /* ended */ }
    this.music.stop?.();
    this.music = null;
  }

  /**
   * A generated dark-ambient drone when no track file is available: two
   * detuned low oscillators under a slow filter sweep, a sub tone, and sparse
   * noise swells. The map's track number seeds the key.
   */
  startDrone(track) {
    const ctx = this.ctx;
    const out = ctx.createGain();
    out.gain.value = 0;
    out.connect(this.musicGain);
    out.gain.linearRampToValueAtTime(0.35, ctx.currentTime + 4);
    const root = 36 + ((track * 5) % 7);     // a low note, different per map
    const hz = (n) => 440 * Math.pow(2, (n - 69) / 12);
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = 220;
    filter.Q.value = 2;
    filter.connect(out);
    const lfo = ctx.createOscillator();
    lfo.frequency.value = 0.05;
    const lfoGain = ctx.createGain();
    lfoGain.gain.value = 140;
    lfo.connect(lfoGain).connect(filter.frequency);
    lfo.start();
    const nodes = [lfo];
    for (const [n, type, detune, g] of [[root, 'sawtooth', -6, 0.5], [root, 'sawtooth', 7, 0.5], [root + 7, 'triangle', 3, 0.25], [root - 12, 'sine', 0, 0.7]]) {
      const o = ctx.createOscillator();
      o.type = type;
      o.frequency.value = hz(n);
      o.detune.value = detune;
      const og = ctx.createGain();
      og.gain.value = g;
      o.connect(og).connect(filter);
      o.start();
      nodes.push(o);
    }
    // sparse noise swells: a wind under the drone
    const noiseBuf = ctx.createBuffer(1, ctx.sampleRate * 4, ctx.sampleRate);
    const d = noiseBuf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * 0.3;
    const noise = ctx.createBufferSource();
    noise.buffer = noiseBuf;
    noise.loop = true;
    const nf = ctx.createBiquadFilter();
    nf.type = 'bandpass';
    nf.frequency.value = 400;
    nf.Q.value = 0.7;
    const ng = ctx.createGain();
    ng.gain.value = 0;
    noise.connect(nf).connect(ng).connect(out);
    noise.start();
    nodes.push(noise);
    let alive = true;
    const swell = () => {
      if (!alive) return;
      const t = ctx.currentTime;
      ng.gain.cancelScheduledValues(t);
      ng.gain.setValueAtTime(ng.gain.value, t);
      ng.gain.linearRampToValueAtTime(0.12 + Math.random() * 0.1, t + 6 + Math.random() * 6);
      ng.gain.linearRampToValueAtTime(0.02, t + 16 + Math.random() * 8);
      nf.frequency.linearRampToValueAtTime(250 + Math.random() * 500, t + 12);
      setTimeout(swell, 20000 + Math.random() * 10000);
    };
    swell();
    return () => {
      alive = false;
      out.gain.cancelScheduledValues(ctx.currentTime);
      out.gain.setValueAtTime(out.gain.value, ctx.currentTime);
      out.gain.linearRampToValueAtTime(0, ctx.currentTime + 1.5);
      setTimeout(() => { for (const n of nodes) { try { n.stop(); } catch { /* ended */ } } out.disconnect(); }, 1600);
    };
  }
}
