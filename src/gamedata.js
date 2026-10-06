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
    name: 'dog', model: 'progs/dog.mdl', head_model: 'progs/h_dog.mdl', health: 25, hull: 1, maxz: 40,
    run_speed: 24, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain,painb', death_anims: 'death,deathb',
    melee_anim: 'attack', melee_frame: 4, melee_range: 100, melee_dmg: 8,
    missile_anim: 'leap', missile_frames: '1', missile_kind: 'leap', attack_chance: 0.2, pain_chance: 1,
    sight_snd: 'dog/dsight.wav', idle_snd: 'dog/idle.wav', pain_snd: 'dog/dpain1.wav', death_snd: 'dog/ddeath.wav',
    attack_snd: 'dog/dattack1.wav', gib_health: -35,
  },
  {
    name: 'ogre', model: 'progs/ogre.mdl', head_model: 'progs/h_ogre.mdl', health: 200, hull: 2, maxz: 64,
    run_speed: 11, walk_speed: 4, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain,painb,painc,paind,paine', death_anims: 'death,bdeath',
    melee_anim: 'smash', melee_frame: 7, melee_range: 100, melee_dmg: 12,
    missile_anim: 'shoot', missile_frames: '3', missile_kind: 'grenade', attack_chance: 0.3, pain_chance: 1,
    sight_snd: 'ogre/ogwake.wav', idle_snd: 'ogre/ogidle.wav', pain_snd: 'ogre/ogpain1.wav', death_snd: 'ogre/ogdth.wav',
    attack_snd: 'weapons/grenade.wav', melee_snd: 'ogre/ogsawatk.wav', gib_health: -80, drop_item: 'rockets',
  },
  {
    name: 'knight', model: 'progs/knight.mdl', head_model: 'progs/h_knight.mdl', health: 75, hull: 1, maxz: 40,
    run_speed: 16, walk_speed: 3, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'runb', pain_anims: 'pain,painb', death_anims: 'death,deathb',
    melee_anim: 'attackb', melee_frame: 6, melee_range: 100, melee_dmg: 6,
    missile_kind: null, attack_chance: 0, pain_chance: 1,
    sight_snd: 'knight/ksight.wav', idle_snd: 'knight/idle.wav', pain_snd: 'knight/khurt.wav', death_snd: 'knight/kdeath.wav',
    melee_snd: 'knight/sword1.wav', gib_health: -40,
  },
  {
    name: 'wizard', model: 'progs/wizard.mdl', head_model: 'progs/h_wizard.mdl', health: 80, hull: 1, maxz: 40, flags: 1,
    run_speed: 16, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'hover', walk_anim: 'fly', run_anim: 'fly', pain_anims: 'pain', death_anims: 'death',
    missile_anim: 'magatt', missile_frames: '3,6', missile_kind: 'wspike', attack_chance: 0.35, pain_chance: 1,
    sight_snd: 'wizard/wsight.wav', idle_snd: 'wizard/widle1.wav', pain_snd: 'wizard/wpain.wav', death_snd: 'wizard/wdeath.wav',
    attack_snd: 'wizard/wattack.wav', gib_health: -40,
  },
  {
    name: 'demon1', model: 'progs/demon.mdl', head_model: 'progs/h_demon.mdl', health: 300, hull: 2, maxz: 64,
    run_speed: 20, walk_speed: 8, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain', death_anims: 'death',
    melee_anim: 'attacka', melee_frame: 5, melee_range: 100, melee_dmg: 10,
    missile_anim: 'leap', missile_frames: '4', missile_kind: 'leap', attack_chance: 0.3, pain_chance: 1,
    sight_snd: 'demon/sight2.wav', idle_snd: 'demon/idle1.wav', pain_snd: 'demon/dpain1.wav', death_snd: 'demon/ddeath.wav',
    attack_snd: 'demon/djump.wav', melee_snd: 'demon/dhit2.wav', gib_health: -80,
  },
  {
    name: 'shambler', model: 'progs/shambler.mdl', head_model: 'progs/h_shams.mdl', health: 600, hull: 2, maxz: 64,
    run_speed: 20, walk_speed: 10, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'pain', death_anims: 'death',
    melee_anim: 'smash', melee_frame: 9, melee_range: 100, melee_dmg: 40,
    missile_anim: 'magic', missile_frames: '7,8,9', missile_kind: 'lightning', attack_chance: 0.4, pain_chance: 0.5,
    sight_snd: 'shambler/ssight.wav', idle_snd: 'shambler/sidle.wav', pain_snd: 'shambler/shurt2.wav', death_snd: 'shambler/sdeath.wav',
    attack_snd: 'shambler/sattck1.wav', melee_snd: 'shambler/smack.wav', gib_health: -60,
  },
  {
    name: 'zombie', model: 'progs/zombie.mdl', head_model: 'progs/h_zombie.mdl', health: 60, hull: 1, maxz: 40,
    run_speed: 4, walk_speed: 2, yaw_speed: 20,
    stand_anim: 'stand', walk_anim: 'walk', run_anim: 'run', pain_anims: 'paina,painb,painc,paind', death_anims: 'paine',
    missile_anim: 'atta', missile_frames: '12', missile_kind: 'gib', attack_chance: 0.4, pain_chance: 1,
    sight_snd: 'zombie/z_idle.wav', idle_snd: 'zombie/z_idle.wav', pain_snd: 'zombie/z_pain.wav', death_snd: 'zombie/z_gib.wav',
    attack_snd: 'zombie/z_shot1.wav', gib_health: 0,
  },
  {
    name: 'boss', model: 'progs/boss.mdl', health: 3, hull: 2, maxz: 256,
    run_speed: 0, walk_speed: 0, yaw_speed: 20,
    stand_anim: 'rise', walk_anim: 'walk', run_anim: 'walk', pain_anims: 'shocka', death_anims: 'death',
    missile_anim: 'attack', missile_frames: '9,20', missile_kind: 'lavaball', attack_chance: 1, pain_chance: 1,
    sight_snd: 'boss1/sight1.wav', pain_snd: 'boss1/pain.wav', death_snd: 'boss1/death.wav', attack_snd: 'boss1/throw.wav',
    gib_health: -1000,
  },
];
