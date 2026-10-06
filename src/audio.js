// audio.js – snd_dma.c, more or less: the SOUND_EVENTS rows become Web
// Audio buffers, attenuated and panned from where they happened (Quake's
// spatialisation: volume falls off linearly with distance × attenuation,
// pan by the dot product with the right vector). Ambient sounds loop at
// their map entity.

const AMBIENTS = {
  ambient_comp_hum: 'ambience/comp1.wav', ambient_drip: 'ambience/drip1.wav', ambient_drone: 'ambience/drone6.wav',
  ambient_swamp1: 'ambience/swamp1.wav', ambient_swamp2: 'ambience/swamp2.wav', air_bubbles: null,
  light_torch_small_walltorch: 'ambience/fire1.wav', light_flame_large_yellow: 'ambience/fire1.wav',
  light_flame_small_yellow: 'ambience/fire1.wav', light_flame_small_white: 'ambience/fire1.wav',
};

export class QuakeAudio {
  constructor() {
    this.ctx = null;
    this.pak = null;
    this.buffers = new Map();
    this.volume = 0.7;
    this.channels = new Map();   // `${ent}:${chan}` → source, to cut
    this.ambients = [];
    this.listener = { x: 0, y: 0, z: 0, yaw: 0 };
  }

  setPak(pak) { this.pak = pak; this.buffers.clear(); }
  setVolume(v) { this.volume = v; if (this.master) this.master.gain.value = v; }

  unlock() {
    if (!this.ctx) {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this.master = this.ctx.createGain();
      this.master.gain.value = this.volume;
      this.master.connect(this.ctx.destination);
      this.startAmbients();
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

  async startAmbients() {
    if (!this.ambientDefs || !this.ctx) return;
    for (const a of this.ambientDefs) {
      const buf = await this.buffer(a.name);
      if (!buf || a.src) continue;
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.loop = true;
      const g = this.ctx.createGain();
      g.gain.value = 0;
      const p = this.ctx.createStereoPanner ? this.ctx.createStereoPanner() : null;
      if (p) src.connect(g).connect(p).connect(this.master); else src.connect(g).connect(this.master);
      src.start();
      a.src = src; a.gain = g; a.pan = p;
      this.ambients.push(a);
    }
  }

  /** Called every frame: fade ambients by distance. */
  updateAmbients(listener) {
    this.listener = listener;
    for (const a of this.ambients) {
      const { gain, pan } = this.spatialize(a.x, a.y, a.z, 2);
      a.gain.gain.value = gain * 0.6;
      if (a.pan) a.pan.pan.value = pan;
    }
  }

  stopAmbients() {
    for (const a of this.ambients) { try { a.src.stop(); } catch { /* ended */ } a.src = null; }
    this.ambients = [];
  }
}
