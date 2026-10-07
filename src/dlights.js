// dlights.js – cl_dlights: the dynamic lights of a frame (CL_RelinkEntities, the temp entities, the
// player's own), for the painter's surfaces (Renderer.dlights, R_AddDynamicLights) and the models'
// light (R_LightPoint). Rockets and lava balls by their model's EF_ROCKET flag; explosions (350 units,
// shrinking for half a second); the player's muzzle flash and the quad's or the pentagram's glow; and,
// in QuakeC mode, the entities' own effects bits (the PSQL game uses effects 4 and 8 to mark fullbright
// things, not lights).

const EF_MUZZLEFLASH = 2, EF_BRIGHTLIGHT = 4, EF_DIMLIGHT = 8, EF_ROCKET = 1;

/**
 * ents: frame_ents rows; models: the model registry; explosions: [{ x, y, z, t0 }];
 * player: { x, y, z, yaw, muzzle (a flash this frame), glow (quad or pentagram) }; qc: QuakeC mode.
 */
export function frameDlights({ ents, models, explosions = [], player = null, qc = false, time, rnd = Math.random }) {
  const out = [];
  const jitter = () => Math.floor(rnd() * 32);
  for (const e of ents) {
    const [, mid, , , x, y, z, , yaw, , effects] = e;
    const m = models.get(mid);
    if (m?.mdl && (m.mdl.flags & EF_ROCKET)) out.push({ x, y, z, radius: 200, minlight: 0 });
    if (!qc || !effects) continue;
    if (effects & EF_MUZZLEFLASH) {
      const a = (yaw * Math.PI) / 180;
      out.push({ x: x + Math.cos(a) * 18, y: y + Math.sin(a) * 18, z: z + 16, radius: 200 + jitter(), minlight: 32 });
    }
    if (effects & EF_BRIGHTLIGHT) out.push({ x, y, z: z + 16, radius: 400 + jitter(), minlight: 0 });
    if (effects & EF_DIMLIGHT) out.push({ x, y, z, radius: 200 + jitter(), minlight: 0 });
  }
  for (const x of explosions) {
    const age = time - x.t0;
    if (age >= 0 && age < 0.5) out.push({ x: x.x, y: x.y, z: x.z, radius: 350 - 300 * age, minlight: 0 });
  }
  if (player?.muzzle) {
    const a = (player.yaw * Math.PI) / 180;
    out.push({ x: player.x + Math.cos(a) * 18, y: player.y + Math.sin(a) * 18, z: player.z + 16, radius: 200 + jitter(), minlight: 32 });
  }
  if (player?.glow) out.push({ x: player.x, y: player.y, z: player.z, radius: 200 + jitter(), minlight: 0 });
  return out;
}

/** R_LightPoint's dynamic part: what the lights add at a point. */
export function dlightAt(dlights, x, y, z) {
  let add = 0;
  for (const d of dlights) {
    const v = d.radius - Math.hypot(x - d.x, y - d.y, z - d.z);
    if (v > 0) add += v;
  }
  return add;
}
