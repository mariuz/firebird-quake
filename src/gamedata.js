// gamedata.js – the data tables of progs: light styles (world.qc) and the
// per-monster numbers from the monsters' .qc files, loaded into
// LIGHTSTYLES and MONSTER_TYPES by loader.js.

// lightstyle(n, pattern): 'a' is dark, 'm' normal, 'z' double bright, 10 Hz.
export const LIGHTSTYLES = [
  'm',                                                      // 0 normal
  'mmnmmommommnonmmonqnmmo',                                // 1 flicker
  'abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba',    // 2 slow strong pulse
  'mmmmmaaaaammmmmaaaaaabcdefgabcdefg',                     // 3 candle
  'mamamamamama',                                           // 4 fast strobe
  'jklmnopqrstuvwxyzyxwvutsrqponmlkj',                      // 5 gentle pulse
  'nmonqnmomnmomomno',                                      // 6 flicker 2
  'mmmaaaabcdefgmmmmaaaammmaamm',                           // 7 candle 2
  'mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa',             // 8 candle 3
  'aaaaaaaazzzzzzzz',                                       // 9 slow strobe
  'mmamammmmammamamaaamammma',                              // 10 fluorescent flicker
  'abcdefghijklmnopqrrqponmlkjihgfedcba',                   // 11 slow pulse, not to black
];
// styles 32–62 are switchable lights: 'a' off, 'm' on (set by triggers)
for (let i = 12; i < 64; i++) LIGHTSTYLES.push('m');

// Speeds are units per 10 Hz AI frame (ai_run(n) in the .qc).
export const MONSTERS = [
  {
    name: 'army', model: 'progs/soldier.mdl', head_model: 'progs/h_guard.mdl', health: 30, hull: 1, maxz: 40,
    run_speed: 10, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'prowl_', run_anim: 'run', pain_anims: 'pain,painb,painc', death_anims: 'death,deathc',
    missile_anim: 'shoot', missile_frames: '4', missile_kind: 'shotgun', attack_chance: 0.3, pain_chance: 1,
    sight_snd: 'soldier/sight1.wav', idle_snd: 'soldier/idle.wav', pain_snd: 'soldier/pain1.wav', death_snd: 'soldier/death1.wav',
    attack_snd: 'soldier/sattck1.wav', gib_health: -35, drop_item: 'shells',
  },
  {
    name: 'dog', model: 'progs/dog.mdl', head_model: 'progs/h_dog.mdl', health: 25, hull: 2, maxz: 40,   // setsize '-32 -32 -24' '32 32 40'
    run_speed: 24, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain,painb', death_anims: 'death,deathb',
    melee_anim: 'attack', melee_frame: 3, melee_range: 100, melee_dmg: 8,          // dog_atta4 bites
    missile_anim: 'leap', missile_frames: '1', missile_kind: 'leap', attack_chance: 0.2, pain_chance: 1,
    sight_snd: 'dog/dsight.wav', idle_snd: 'dog/idle.wav', pain_snd: 'dog/dpain1.wav', death_snd: 'dog/ddeath.wav',
    attack_snd: 'dog/dattack1.wav', gib_health: -35,
  },
  {
    name: 'ogre', model: 'progs/ogre.mdl', head_model: 'progs/h_ogre.mdl', health: 200, hull: 2, maxz: 64,
    run_speed: 11, walk_speed: 4, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain,painb,painc,paind,paine', death_anims: 'death,bdeath',
    melee_anim: 'smash', melee_frame: 5, melee_frames: '6,7,8,9,10', melee_range: 100, melee_dmg: 12,   // ogre_smash6..11: the chainsaw
    missile_anim: 'shoot', missile_frames: '3', missile_seq: '61,62,62,63,64,65,66', missile_kind: 'grenade', attack_chance: 0.3, pain_chance: 1,   // ogre_nail1..7 ($shoot2 twice)
    sight_snd: 'ogre/ogwake.wav', idle_snd: 'ogre/ogidle.wav', pain_snd: 'ogre/ogpain1.wav', death_snd: 'ogre/ogdth.wav',
    attack_snd: 'weapons/grenade.wav', melee_snd: 'ogre/ogsawatk.wav', melee_start_snd: 'ogre/ogsawatk.wav', gib_health: -80, drop_item: 'rockets',
  },
  {
    name: 'knight', model: 'progs/knight.mdl', head_model: 'progs/h_knight.mdl', health: 75, hull: 1, maxz: 40,
    run_speed: 16, walk_speed: 3, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'runb', pain_anims: 'pain,painb', death_anims: 'death,deathb',
    melee_anim: 'attackb', melee_frame: 5, melee_frames: '6,7', melee_seq: '42,44,45,46,47,48,49,50,51,52', melee_range: 100, melee_dmg: 6,   // knight_atk6..8 swing (atk1 to atk2 skip $attackb2)
    missile_kind: null, attack_chance: 0, pain_chance: 1,
    sight_snd: 'knight/ksight.wav', idle_snd: 'knight/idle.wav', pain_snd: 'knight/khurt.wav', death_snd: 'knight/kdeath.wav',
    melee_snd: 'knight/sword1.wav', melee_start_snd: 'knight/sword1.wav', gib_health: -40,
  },
  {
    name: 'wizard', model: 'progs/wizard.mdl', head_model: 'progs/h_wizard.mdl', health: 80, hull: 1, maxz: 40, flags: 1,
    run_speed: 16, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'hover', walk_anim: 'fly', run_anim: 'fly', pain_anims: 'pain', death_anims: 'death',
    missile_anim: 'magatt', missile_frames: '', missile_seq: '29,30,31,32,33,34,33,32,31,30', missile_kind: 'wspike',   // the spikes come from Wiz_StartFast's two shooters attack_chance: 0.35, pain_chance: 1,
    sight_snd: 'wizard/wsight.wav', idle_snd: 'wizard/widle1.wav', pain_snd: 'wizard/wpain.wav', death_snd: 'wizard/wdeath.wav',
    attack_snd: 'wizard/wattack.wav', missile_start_snd: 'wizard/wattack.wav', gib_health: -40,
  },
  {
    name: 'demon1', model: 'progs/demon.mdl', head_model: 'progs/h_demon.mdl', health: 300, hull: 2, maxz: 64,
    run_speed: 20, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain', death_anims: 'death',
    melee_anim: 'attacka', melee_frame: 4, melee_frames: '10', melee_range: 100, melee_dmg: 10,   // demon1_atta5 and atta11 claw
    missile_anim: 'leap', missile_frames: '3', missile_kind: 'leap', attack_chance: 0.3, pain_chance: 1,   // demon1_jump4 leaps
    sight_snd: 'demon/sight2.wav', idle_snd: 'demon/idle1.wav', pain_snd: 'demon/dpain1.wav', death_snd: 'demon/ddeath.wav',
    attack_snd: 'demon/djump.wav', melee_snd: 'demon/dhit2.wav', leap_dmg: 10, leap_up: 250, leap_speed: 600, gib_health: -80,
  },
  {
    name: 'shambler', model: 'progs/shambler.mdl', head_model: 'progs/h_shams.mdl', health: 600, hull: 2, maxz: 64,
    run_speed: 20, walk_speed: 10, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain', death_anims: 'death',
    melee_anim: 'smash', melee_frame: 9, melee_range: 100, melee_dmg: 40,
    missile_anim: 'magic', missile_frames: '5,6,7', missile_frames_nm: '8', missile_seq: '65,66,67,68,69,70,73,74,75,76',   // sham_magic6, 9, 10 (11 on nightmare); magic6 goes on to magic9
    missile_kind: 'lightning', attack_chance: 0.4, pain_chance: 0.5,
    sight_snd: 'shambler/ssight.wav', idle_snd: 'shambler/sidle.wav', pain_snd: 'shambler/shurt2.wav', death_snd: 'shambler/sdeath.wav',
    attack_snd: 'shambler/sattck1.wav', missile_start_snd: 'shambler/sattck1.wav', melee_snd: 'shambler/smack.wav', melee_start_snd: 'shambler/melee1.wav', gib_health: -60,
  },
  {
    name: 'zombie', model: 'progs/zombie.mdl', head_model: 'progs/h_zombie.mdl', health: 60, hull: 1, maxz: 40,
    run_speed: 4, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'paina,painb,painc,paind', death_anims: 'paine',
    missile_anim: 'atta', missile_frames: '11,12,13', missile_kind: 'gib', attack_chance: 0.4, pain_chance: 1,
    sight_snd: 'zombie/z_idle.wav', idle_snd: 'zombie/z_idle.wav', pain_snd: 'zombie/z_pain.wav', death_snd: 'zombie/z_gib.wav',
    attack_snd: 'zombie/z_shot1.wav', gib_snd: 'zombie/z_gib.wav', gib_health: 1,   // 1: a zombie has no death but the gib; it throws from atta, attb or attc, on the last frame
  },
  {
    name: 'boss', model: 'progs/boss.mdl', health: 3, hull: 2, maxz: 256,
    run_speed: 0, walk_speed: 0, yaw_speed: 20,
    stand_anim: 'rise', walk_anim: 'walk', run_anim: 'walk', pain_anims: 'shocka', death_anims: 'death',
    missile_anim: 'attack', missile_frames: '9,20', missile_kind: 'lavaball', attack_chance: 1, pain_chance: 1,
    sight_snd: 'boss1/sight1.wav', pain_snd: 'boss1/pain.wav', death_snd: 'boss1/death.wav', attack_snd: 'boss1/throw.wav',
    gib_health: -1000,
  },
  // ── the registered episodes (pak1.pak) ──
  {
    name: 'enforcer', model: 'progs/enforcer.mdl', head_model: 'progs/h_mega.mdl', health: 80, hull: 1, maxz: 40,
    run_speed: 18, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'paina,painb,painc,paind', death_anims: 'death,fdeath',
    missile_anim: 'attack', missile_frames: '5,9', missile_seq: '31,32,33,34,35,36,37,38,35,36,37,38,39,40', missile_kind: 'laser',   // enf_atk6 and atk10 fire attack_chance: 0.3, pain_chance: 1,
    sight_snd: 'enforcer/sight1.wav', idle_snd: 'enforcer/idle1.wav', pain_snd: 'enforcer/pain1.wav', death_snd: 'enforcer/death1.wav',
    attack_snd: 'enforcer/enfire.wav', gib_health: -35, drop_item: 'cells',
  },
  {
    name: 'hell_knight', model: 'progs/hknight.mdl', head_model: 'progs/h_hellkn.mdl', health: 250, hull: 1, maxz: 40,
    run_speed: 20, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain', death_anims: 'death,deathb',
    melee_anim: 'slice', melee_frame: 4, melee_frames: '5,6,7,8', melee_range: 100, melee_dmg: 15,   // hknight_slice5..9
    missile_anim: 'magicc', missile_frames: '5,6,7,8,9,10', missile_kind: 'kspike', attack_chance: 0.3, pain_chance: 1,   // hknight_magicc6..11
    sight_snd: 'hknight/sight1.wav', idle_snd: 'hknight/idle.wav', pain_snd: 'hknight/pain1.wav', death_snd: 'hknight/death1.wav',
    attack_snd: 'hknight/attack1.wav', melee_snd: 'hknight/slash1.wav', gib_health: -40,
  },
  {
    name: 'shalrath', model: 'progs/shalrath.mdl', head_model: 'progs/h_shal.mdl', health: 400, hull: 2, maxz: 64,
    run_speed: 6, walk_speed: 6, yaw_speed: 20,
    stand_anim: 'attack', walk_anim: 'walk', run_anim: 'walk', pain_anims: 'pain', death_anims: 'death',
    missile_anim: 'attack', missile_frames: '8', missile_kind: 'voreball', attack_chance: 0.4, pain_chance: 1,
    sight_snd: 'shalrath/sight.wav', idle_snd: 'shalrath/idle.wav', pain_snd: 'shalrath/pain.wav', death_snd: 'shalrath/death.wav',
    attack_snd: 'shalrath/attack.wav', gib_health: -90,
  },
  {
    name: 'tarbaby', model: 'progs/tarbaby.mdl', health: 80, hull: 1, maxz: 40,
    run_speed: 24, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'walk', walk_anim: 'walk', run_anim: 'run', pain_anims: 'fly', death_anims: 'exp',
    missile_anim: 'jump', missile_frames: '4', missile_kind: 'leap', attack_chance: 0.6, pain_chance: 0,
    sight_snd: 'blob/sight1.wav', death_snd: 'blob/death1.wav', attack_snd: 'blob/land1.wav', leap_snd: 'blob/hit1.wav', leap_min: 0, leap_speed: 600, gib_health: -1000,
  },
  {
    name: 'fish', model: 'progs/fish.mdl', health: 25, hull: 1, maxz: 24, flags: 2,
    run_speed: 12, walk_speed: 8, yaw_speed: 10,
    stand_anim: 'swim', walk_anim: 'swim', run_anim: 'swim', pain_anims: 'pain', death_anims: 'death',
    melee_anim: 'attack', melee_frame: 2, melee_frames: '8,14', melee_range: 60, melee_dmg: 4,   // f_attack3, 9 and 15 bite
    missile_kind: null, attack_chance: 0, pain_chance: 1,
    sight_snd: null, idle_snd: 'fish/idle.wav', pain_snd: null, death_snd: 'fish/death.wav', melee_snd: 'fish/bite.wav', gib_health: -1000,
  },
  {
    name: 'oldone', model: 'progs/oldone.mdl', health: 40000, hull: 2, maxz: 256,
    run_speed: 0, walk_speed: 0, yaw_speed: 0,
    stand_anim: 'old', walk_anim: 'old', run_anim: 'old', pain_anims: 'shake', death_anims: 'shake',
    missile_kind: null, attack_chance: 0, pain_chance: 0,
    sight_snd: null, idle_snd: 'boss2/idle.wav', pain_snd: 'boss2/pop2.wav', death_snd: 'boss2/death.wav', gib_health: -100000,
  },
];

// How far each frame of a monster's walk, run and attacks moves it: the constant id's frame function hands ai_walk,
// ai_run or ai_charge (army_run1 = [$run1, army_run2] { ai_run(11); }, dog_atta1 { ai_charge(10); }), read out of id's
// progs.dat 1.06: model → { frame: distance }. The PSQL game steps by the distance of the frame a think enters, as the
// frame function does (FRAME_MOVES → frame_moves); an attack frame without an entry only faces the enemy (ai_face).
// (ogre_smash12 calls ai_charge() with no distance at all, so whatever an earlier call left in the parameter: none here.)
export const FRAME_MOVES = {
  'progs/ogre.mdl': { 9: 3, 10: 2, 11: 2, 12: 2, 13: 2, 14: 5, 15: 3, 16: 2, 17: 3, 18: 1, 19: 2, 20: 3, 21: 3, 22: 3, 23: 3, 24: 4, 25: 9, 26: 12, 27: 8, 28: 22, 29: 16, 30: 4, 31: 13, 32: 24, 33: 11, 34: 1, 35: 4, 36: 13, 37: 9, 44: 3, 45: 8, 46: 9, 47: 6, 48: 0, 49: 0, 50: 1, 51: 4, 52: 4, 53: 4, 54: 10, 55: 13, 57: 2, 59: 4, 60: 12 },
  'progs/demon.mdl': { 13: 8, 14: 6, 15: 6, 16: 7, 17: 4, 18: 6, 19: 10, 20: 10, 21: 20, 22: 15, 23: 36, 24: 20, 25: 15, 26: 36, 54: 4, 55: 0, 56: 0, 57: 1, 58: 2, 59: 1, 60: 6, 61: 8, 62: 4, 63: 2, 65: 5, 66: 8, 67: 4, 68: 4 },
  'progs/shambler.mdl': { 17: 10, 18: 9, 19: 9, 20: 5, 21: 6, 22: 12, 23: 8, 24: 3, 25: 13, 26: 9, 27: 7, 28: 7, 29: 20, 30: 24, 31: 20, 32: 20, 33: 24, 34: 20, 35: 2, 36: 6, 37: 6, 38: 5, 39: 4, 40: 1, 41: 0, 42: 0, 43: 0, 44: 0, 45: 5, 46: 4, 47: 1, 48: 8, 49: 14, 50: 7, 51: 3, 52: 6, 53: 6, 54: 3, 55: 1, 56: 5, 57: 3, 58: 7, 59: 3, 60: 7, 61: 9, 62: 5, 63: 4, 64: 8 },
  'progs/knight.mdl': { 9: 16, 10: 20, 11: 13, 12: 7, 13: 16, 14: 20, 15: 14, 16: 6, 17: 20, 27: 10, 42: 0, 44: 7, 45: 4, 46: 0, 47: 3, 48: 4, 49: 1, 50: 3, 51: 1, 52: 5, 53: 3, 54: 2, 55: 3, 56: 4, 57: 3, 58: 3, 59: 3, 60: 4, 61: 3, 62: 3, 63: 2, 64: 3, 65: 4, 66: 3 },
  'progs/soldier.mdl': { 73: 11, 74: 15, 75: 10, 76: 10, 77: 8, 78: 15, 79: 10, 80: 8, 90: 1, 91: 1, 92: 1, 93: 1, 94: 2, 95: 3, 96: 4, 97: 4, 98: 2, 99: 2, 100: 2, 101: 1, 102: 0, 103: 1, 104: 1, 105: 1, 106: 3, 107: 3, 108: 3, 109: 3, 110: 2, 111: 1, 112: 1, 113: 1 },
  'progs/wizard.mdl': { 0: 8, 1: 8, 2: 8, 3: 8, 4: 8, 5: 8, 6: 8, 7: 8, 15: 16, 16: 16, 17: 16, 18: 16, 19: 16, 20: 16, 21: 16, 22: 16, 23: 16, 24: 16, 25: 16, 26: 16, 27: 16, 28: 16 },
  'progs/dog.mdl': { 0: 10, 1: 10, 2: 10, 4: 10, 5: 10, 6: 10, 7: 10, 48: 16, 49: 32, 50: 32, 51: 20, 52: 64, 53: 32, 54: 16, 55: 32, 56: 32, 57: 20, 58: 64, 59: 32, 78: 8, 79: 8, 80: 8, 81: 8, 82: 8, 83: 8, 84: 8, 85: 8 },
  'progs/zombie.mdl': { 15: 0, 16: 2, 17: 3, 18: 2, 19: 1, 20: 0, 21: 0, 22: 0, 23: 0, 24: 0, 25: 2, 26: 2, 27: 1, 28: 0, 29: 0, 30: 0, 31: 0, 32: 0, 33: 0, 34: 1, 35: 1, 36: 0, 37: 1, 38: 2, 39: 3, 40: 4, 41: 4, 42: 2, 43: 0, 44: 0, 45: 0, 46: 2, 47: 4, 48: 6, 49: 7, 50: 3, 51: 8 },
  'progs/tarbaby.mdl': { 10: 2, 11: 2, 12: 2, 13: 2, 14: 2, 15: 2, 16: 2, 17: 2, 18: 2, 19: 2, 20: 2, 21: 2, 22: 2, 23: 2, 24: 2, 35: 2, 36: 2, 37: 2, 38: 2, 39: 2, 40: 2, 41: 2, 42: 2, 43: 2, 44: 2, 45: 2, 46: 2, 47: 2, 48: 2, 49: 2 },
  'progs/hknight.mdl': { 9: 2, 10: 5, 11: 5, 12: 4, 13: 4, 14: 2, 15: 2, 16: 3, 17: 3, 18: 4, 19: 3, 20: 4, 21: 6, 22: 2, 23: 2, 24: 4, 25: 3, 26: 3, 27: 3, 28: 2, 29: 20, 30: 25, 31: 18, 32: 16, 33: 14, 34: 25, 35: 21, 36: 13, 112: 9, 113: 6, 114: 13, 115: 4, 116: 7, 117: 15, 118: 8, 119: 2, 121: 3, 122: 1, 123: 13, 124: 9, 125: 11, 126: 10, 127: 7, 128: 12, 129: 2, 130: 3, 131: 0, 132: 0, 133: 2, 134: 0, 135: 0, 139: 1, 140: 4, 141: 5, 142: 3, 143: 2, 144: 2, 145: 0, 146: 0, 147: 0, 148: 1, 149: 1, 150: 3, 151: 4, 152: 6, 153: 7, 154: 3 },
  'progs/fish.mdl': { 0: 10, 1: 10, 3: 10, 4: 10, 5: 10, 6: 10, 7: 10, 9: 10, 10: 10, 11: 10, 12: 10, 13: 10, 15: 10, 16: 10, 17: 10, 39: 12, 40: 8, 41: 12, 42: 8, 43: 12, 44: 8, 45: 12, 46: 8, 47: 12, 48: 8, 49: 12, 50: 8, 51: 12, 52: 8, 53: 12, 54: 8, 55: 12, 56: 8 },
  'progs/shalrath.mdl': { 23: 5, 24: 6, 25: 4, 26: 0, 27: 0, 28: 0, 29: 0, 30: 5, 31: 6, 32: 5, 33: 0, 34: 4 },
  'progs/enforcer.mdl': { 7: 2, 8: 4, 9: 4, 10: 3, 11: 1, 12: 2, 13: 2, 14: 1, 15: 2, 16: 4, 17: 4, 18: 1, 19: 2, 20: 3, 21: 4, 22: 2, 23: 18, 24: 14, 25: 7, 26: 12, 27: 14, 28: 14, 29: 7, 30: 11 },
};
