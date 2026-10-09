-- items.sql – items.qc: W_BestWeapon and every pickup's touch.

SET TERM ^ ;

-- ── items (items.qc) ─────────────────────────────────────────────────────
-- W_BestWeapon
CREATE OR ALTER FUNCTION best_weapon () RETURNS INTEGER
AS
DECLARE it INTEGER; DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE wl SMALLINT;
BEGIN
  SELECT p.items, p.shells, p.nails, p.rockets, p.cells, COALESCE(e.waterlevel, 0) FROM player p LEFT JOIN ents e ON e.id = p.ent_id WHERE p.id = 1
    INTO it, sh, na, ro, ce, wl;
  IF (BIN_AND(it, 64) <> 0 AND ce >= 1 AND wl <= 1) THEN RETURN 64;
  IF (BIN_AND(it, 8) <> 0 AND na >= 2) THEN RETURN 8;
  IF (BIN_AND(it, 2) <> 0 AND sh >= 2) THEN RETURN 2;
  IF (BIN_AND(it, 4) <> 0 AND na >= 1) THEN RETURN 4;
  IF (BIN_AND(it, 1) <> 0 AND sh >= 1) THEN RETURN 1;
  RETURN 4096;
END^

CREATE OR ALTER PROCEDURE bound_ammo
AS
BEGIN
  UPDATE player p SET p.shells = MINVALUE(p.shells, 100), p.nails = MINVALUE(p.nails, 200), p.rockets = MINVALUE(p.rockets, 100), p.cells = MINVALUE(p.cells, 100) WHERE p.id = 1;
END^

CREATE OR ALTER PROCEDURE item_touch (item INTEGER, other INTEGER)
AS
DECLARE cls VARCHAR(40); DECLARE sf INTEGER; DECLARE items INTEGER; DECLARE hp INTEGER; DECLARE mhp INTEGER;
DECLARE snd_ VARCHAR(64); DECLARE msg VARCHAR(200); DECLARE pitems INTEGER; DECLARE newit INTEGER = 0;
DECLARE sh INTEGER; DECLARE na INTEGER; DECLARE ro INTEGER; DECLARE ce INTEGER; DECLARE av INTEGER; DECLARE atype DOUBLE PRECISION;
DECLARE big SMALLINT; DECLARE w INTEGER; DECLARE t DOUBLE PRECISION; DECLARE wt SMALLINT;
BEGIN
  IF (other <> player_ent()) THEN EXIT;
  SELECT e.classname, e.spawnflags, e.ammo_shells, e.ammo_nails, e.ammo_rockets, e.ammo_cells FROM ents e WHERE e.id = :item
    INTO cls, sf, sh, na, ro, ce;
  SELECT e.health FROM ents e WHERE e.id = :other INTO hp;
  IF (hp <= 0) THEN EXIT;
  SELECT p.items, p.armorvalue, p.armortype FROM player p WHERE p.id = 1 INTO pitems, av, atype;
  t = now_();
  big = IIF(BIN_AND(sf, 1) <> 0, 1, 0);
  SELECT g.world_type FROM game g WHERE g.id = 1 INTO wt;
  snd_ = 'weapons/lock4.wav';

  IF (cls = 'item_health') THEN
  BEGIN
    IF (BIN_AND(sf, 2) <> 0) THEN                               -- MEGAHEALTH
    BEGIN
      IF (hp >= 250) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 100, 250) WHERE e.id = :other;
      UPDATE player p SET p.items = BIN_OR(p.items, 65536), p.dmg_time = :t WHERE p.id = 1;
      snd_ = 'items/r_item2.wav'; msg = 'You receive 100 health';
    END
    ELSE IF (BIN_AND(sf, 1) <> 0) THEN                          -- rotten
    BEGIN
      IF (hp >= 100) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 15, 100) WHERE e.id = :other;
      snd_ = 'items/r_item1.wav'; msg = 'You receive 15 health';
    END
    ELSE
    BEGIN
      IF (hp >= 100) THEN EXIT;
      UPDATE ents e SET e.health = MINVALUE(e.health + 25, 100) WHERE e.id = :other;
      snd_ = 'items/health1.wav'; msg = 'You receive 25 health';
    END
  END
  ELSE IF (cls IN ('item_armor1', 'item_armor2', 'item_armorInv')) THEN
  BEGIN
    IF (cls = 'item_armor1') THEN BEGIN hp = 100; atype = 0.3e0; newit = 8192; END
    ELSE IF (cls = 'item_armor2') THEN BEGIN hp = 150; atype = 0.6e0; newit = 16384; END
    ELSE BEGIN hp = 200; atype = 0.8e0; newit = 32768; END
    SELECT p.armorvalue, p.armortype FROM player p WHERE p.id = 1 INTO av, t;
    IF (av * t >= hp * atype) THEN EXIT;
    UPDATE player p SET p.armorvalue = :hp, p.armortype = :atype, p.items = BIN_OR(BIN_AND(p.items, BIN_NOT(8192 + 16384 + 32768)), :newit) WHERE p.id = 1;
    snd_ = 'items/armor1.wav'; msg = 'You got armor';
  END
  ELSE IF (cls IN ('item_shells', 'item_spikes', 'item_rockets', 'item_cells')) THEN
  BEGIN
    IF (cls = 'item_shells') THEN
    BEGIN
      SELECT p.shells FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.shells = p.shells + IIF(:big = 1, 40, 20) WHERE p.id = 1; msg = 'You got the shells';
    END
    ELSE IF (cls = 'item_spikes') THEN
    BEGIN
      SELECT p.nails FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 200) THEN EXIT;
      UPDATE player p SET p.nails = p.nails + IIF(:big = 1, 50, 25) WHERE p.id = 1; msg = 'You got the nails';
    END
    ELSE IF (cls = 'item_rockets') THEN
    BEGIN
      SELECT p.rockets FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.rockets = p.rockets + IIF(:big = 1, 10, 5) WHERE p.id = 1; msg = 'You got the rockets';
    END
    ELSE
    BEGIN
      SELECT p.cells FROM player p WHERE p.id = 1 INTO av;
      IF (av >= 100) THEN EXIT;
      UPDATE player p SET p.cells = p.cells + IIF(:big = 1, 12, 6) WHERE p.id = 1; msg = 'You got the cells';
    END
    EXECUTE PROCEDURE bound_ammo;
    -- switch to a better weapon if the current one is empty
    SELECT p.weapon FROM player p WHERE p.id = 1 INTO w;
    IF (w = 4096 OR (w = 1 AND (SELECT p.shells FROM player p WHERE p.id = 1) = 0)) THEN
      UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1;
  END
  ELSE IF (cls LIKE 'weapon_%') THEN
  BEGIN
    IF (cls = 'weapon_supershotgun') THEN BEGIN newit = 2; msg = 'You got the Double-barrelled Shotgun'; UPDATE player p SET p.shells = p.shells + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_nailgun') THEN BEGIN newit = 4; msg = 'You got the nailgun'; UPDATE player p SET p.nails = p.nails + 30 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_supernailgun') THEN BEGIN newit = 8; msg = 'You got the Super Nailgun'; UPDATE player p SET p.nails = p.nails + 30 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_grenadelauncher') THEN BEGIN newit = 16; msg = 'You got the Grenade Launcher'; UPDATE player p SET p.rockets = p.rockets + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_rocketlauncher') THEN BEGIN newit = 32; msg = 'You got the Rocket Launcher'; UPDATE player p SET p.rockets = p.rockets + 5 WHERE p.id = 1; END
    ELSE IF (cls = 'weapon_lightning') THEN BEGIN newit = 64; msg = 'You got the Thunderbolt'; UPDATE player p SET p.cells = p.cells + 15 WHERE p.id = 1; END
    ELSE EXIT;
    EXECUTE PROCEDURE bound_ammo;
    UPDATE player p SET p.items = BIN_OR(p.items, :newit), p.weapon = :newit WHERE p.id = 1;
    snd_ = 'weapons/pkup.wav';
  END
  ELSE IF (cls = 'item_key1' OR cls = 'item_key2') THEN
  BEGIN
    newit = IIF(cls = 'item_key1', 131072, 262144);
    IF (BIN_AND(pitems, newit) <> 0) THEN EXIT;
    UPDATE player p SET p.items = BIN_OR(p.items, :newit) WHERE p.id = 1;
    msg = IIF(cls = 'item_key1', CASE wt WHEN 2 THEN 'You got the silver keycard' WHEN 1 THEN 'You got the silver runekey' ELSE 'You got the silver key' END,
                                 CASE wt WHEN 2 THEN 'You got the gold keycard' WHEN 1 THEN 'You got the gold runekey' ELSE 'You got the gold key' END);
    snd_ = CASE wt WHEN 2 THEN 'misc/medkey.wav' WHEN 1 THEN 'misc/runekey.wav' ELSE 'misc/medkey.wav' END;
  END
  ELSE IF (cls = 'item_sigil') THEN
  BEGIN
    UPDATE game g SET g.serverflags = BIN_OR(g.serverflags, BIN_SHR(:sf, 0)) WHERE g.id = 1;
    UPDATE player p SET p.items = BIN_OR(p.items, BIN_SHL(BIN_AND(:sf, 15), 28)) WHERE p.id = 1;
    msg = 'You got the rune!'; snd_ = 'misc/runekey.wav';
  END
  ELSE IF (cls = 'item_artifact_invulnerability') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 1048576), p.invincible_finished = :t + 30 WHERE p.id = 1;
    msg = 'Pentagram of Protection!'; snd_ = 'items/protect.wav';
  END
  ELSE IF (cls = 'item_artifact_invisibility') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 524288), p.invisible_finished = :t + 30 WHERE p.id = 1;
    msg = 'Ring of Shadows!'; snd_ = 'items/inv1.wav';
  END
  ELSE IF (cls = 'item_artifact_super_damage') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 4194304), p.super_damage_finished = :t + 30 WHERE p.id = 1;
    msg = 'Quad Damage!'; snd_ = 'items/damage.wav';
  END
  ELSE IF (cls = 'item_artifact_envirosuit') THEN
  BEGIN
    UPDATE player p SET p.items = BIN_OR(p.items, 2097152), p.radsuit_finished = :t + 30 WHERE p.id = 1;
    msg = 'Biosuit'; snd_ = 'items/suit.wav';
  END
  ELSE IF (cls = 'backpack') THEN
  BEGIN
    UPDATE player p SET p.shells = p.shells + :sh, p.nails = p.nails + :na, p.rockets = p.rockets + :ro, p.cells = p.cells + :ce WHERE p.id = 1;
    EXECUTE PROCEDURE bound_ammo;
    msg = 'You get ' || TRIM(IIF(sh > 0, sh || ' shells ', '') || IIF(na > 0, na || ' nails ', '') || IIF(ro > 0, ro || ' rockets ', '') || IIF(ce > 0, ce || ' cells', ''));
    SELECT p.weapon FROM player p WHERE p.id = 1 INTO w;
    IF (w = 4096) THEN UPDATE player p SET p.weapon = best_weapon() WHERE p.id = 1;
  END
  ELSE EXIT;

  EXECUTE PROCEDURE sprint(msg);
  EXECUTE PROCEDURE snd(other, 3, snd_, 1, 1);
  UPDATE player p SET p.bonus_time = :t WHERE p.id = 1;
  EXECUTE PROCEDURE use_targets(item, other);
  DELETE FROM ents e WHERE e.id = :item;
END^

SET TERM ; ^
