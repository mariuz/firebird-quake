-- spawn.sql – the map's entities: spawn_map_ents runs QuakeC's spawn function for every
-- classname this game knows, and the thinks of the things it spawns (trains, fireballs, shooters).

SET TERM ^ ;

-- ── map setup ───────────────────────────────────────────────────────────
-- spawn_map_ents: QuakeC's spawn functions for every classname we know
CREATE OR ALTER PROCEDURE spawn_map_ents (skill SMALLINT)
AS
DECLARE mid INTEGER; DECLARE cls VARCHAR(40); DECLARE tn VARCHAR(40); DECLARE tg VARCHAR(40); DECLARE kt VARCHAR(40); DECLARE mdl VARCHAR(40);
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE ang DOUBLE PRECISION;
DECLARE mp DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mr DOUBLE PRECISION;
DECLARE sf INTEGER; DECLARE msg VARCHAR(200); DECLARE wt DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE spd DOUBLE PRECISION;
DECLARE lip DOUBLE PRECISION; DECLARE hp INTEGER; DECLARE lt INTEGER; DECLARE sty INTEGER; DECLARE snds INTEGER; DECLARE dmg DOUBLE PRECISION;
DECLARE hgt DOUBLE PRECISION; DECLARE cnt INTEGER; DECLARE map_ VARCHAR(32); DECLARE noise VARCHAR(64); DECLARE wtype INTEGER;
DECLARE eid INTEGER; DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION;
DECLARE sx DOUBLE PRECISION; DECLARE sy DOUBLE PRECISION; DECLARE sz DOUBLE PRECISION; DECLARE dist DOUBLE PRECISION;
DECLARE n1 VARCHAR(64); DECLARE n2 VARCHAR(64); DECLARE n3 VARCHAR(64);
DECLARE mname VARCHAR(16); DECLARE mmodel VARCHAR(40); DECLARE mhp INTEGER; DECLARE mhull SMALLINT; DECLARE mmaxz DOUBLE PRECISION; DECLARE mflags INTEGER;
DECLARE mys DOUBLE PRECISION; DECLARE stand VARCHAR(16);
DECLARE skillbit INTEGER;
DECLARE items INTEGER;
BEGIN
  skillbit = CASE skill WHEN 0 THEN 256 WHEN 1 THEN 512 ELSE 1024 END;
  FOR SELECT m.id, m.classname, m.targetname, m.target, m.killtarget, m.model, m.ox, m.oy, m.oz, m.angle, m.mpitch, m.myaw, m.mroll,
             m.spawnflags, m.message, m.wait_, m.delay, m.speed, m.lip, m.health, m.light, m.style, m.sounds, m.dmg, m.height, m.count_, m.map, m.noise, m.worldtype
        FROM map_ents m ORDER BY m.id
        INTO mid, cls, tn, tg, kt, mdl, ox, oy, oz, ang, mp, my, mr, sf, msg, wt, dl, spd, lip, hp, lt, sty, snds, dmg, hgt, cnt, map_, noise, wtype
  DO
  BEGIN
    IF (BIN_AND(sf, skillbit) <> 0) THEN CONTINUE;                 -- not on this skill
    IF (cls = 'worldspawn') THEN
    BEGIN
      UPDATE game g SET g.world_type = COALESCE(:wtype, 0), g.level_msg = :msg WHERE g.id = 1;
      CONTINUE;
    END
    IF (cls IN ('light', 'info_intermission', 'info_player_deathmatch', 'info_player_coop', 'light_fluoro', 'light_fluorospark', 'air_bubbles',
                'ambient_comp_hum', 'ambient_drip', 'ambient_drone', 'ambient_swamp1', 'ambient_swamp2', 'trigger_onlyregistered')) THEN
    BEGIN
      IF (cls = 'light' AND tn IS NOT NULL AND tn <> '' AND sty IS NOT NULL) THEN
      BEGIN
        EXECUTE PROCEDURE spawn_ent(cls, ox, oy, oz) RETURNING_VALUES eid;
        UPDATE ents e SET e.targetname = :tn, e.style = :sty WHERE e.id = :eid;
        UPDATE OR INSERT INTO lightstyles (style, pattern) VALUES (:sty, IIF(BIN_AND(:sf, 1) <> 0, 'a', 'm')) MATCHING (style);
      END
      IF (cls = 'trigger_onlyregistered' AND mdl IS NOT NULL) THEN
      BEGIN
        SELECT g.registered FROM game g WHERE g.id = 1 INTO wtype;
        IF (wtype = 1) THEN
        BEGIN
          -- registered: an ordinary trigger_multiple
          EXECUTE PROCEDURE spawn_ent('trigger_multiple', ox, oy, oz) RETURNING_VALUES eid;
          EXECUTE PROCEDURE set_model(eid, mdl);
          UPDATE ents e SET e.model_id = NULL, e.solid = 1, e.target = :tg, e.killtarget = :kt, e.message = :msg, e.spawnflags = :sf,
                 e.wait_ = IIF(COALESCE(:wt, 0) = 0, 2, :wt), e.targetname = :tn WHERE e.id = :eid;
        END
        ELSE
        BEGIN
          -- the shareware version: show the message, never fire
          EXECUTE PROCEDURE spawn_ent('trigger_message', ox, oy, oz) RETURNING_VALUES eid;
          EXECUTE PROCEDURE set_model(eid, mdl);
          UPDATE ents e SET e.model_id = NULL, e.solid = 1, e.message = COALESCE(:msg, 'This item is only available in the registered version'), e.wait_ = 2 WHERE e.id = :eid;
        END
      END
      CONTINUE;
    END

    EXECUTE PROCEDURE spawn_ent(cls, ox, oy, oz) RETURNING_VALUES eid;
    UPDATE ents e SET e.targetname = :tn, e.target = :tg, e.killtarget = :kt, e.spawnflags = :sf, e.message = :msg,
           e.wait_ = COALESCE(:wt, 0), e.delay = COALESCE(:dl, 0), e.speed = COALESCE(:spd, 0), e.lip = COALESCE(:lip, 0),
           e.health = COALESCE(:hp, 0), e.max_health = COALESCE(:hp, 0), e.style = COALESCE(:sty, 0), e.sounds = COALESCE(:snds, 0),
           e.dmg = COALESCE(:dmg, 0), e.height = COALESCE(:hgt, 0), e.count_ = COALESCE(:cnt, 0), e.map = :map_,
           e.yaw = COALESCE(:ang, 0), e.spawn_x = :ox, e.spawn_y = :oy, e.spawn_z = :oz
     WHERE e.id = :eid;
    IF (mdl IS NOT NULL AND mdl STARTING WITH '*') THEN EXECUTE PROCEDURE set_model(eid, mdl);
    SELECT e.maxx - e.minx, e.maxy - e.miny, e.maxz - e.minz FROM ents e WHERE e.id = :eid INTO sx, sy, sz;

    -- ── player ──
    IF (cls = 'info_player_start') THEN
    BEGIN
      UPDATE ents e SET e.classname = 'player', e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 32,
             e.solid = 3, e.movetype = 3, e.health = 100, e.max_health = 100, e.takedamage = 2, e.flags = 8, e.anim = 'stand',
             e.z = e.z + 1 WHERE e.id = :eid;                       -- PutClientInServer: spot.origin + '0 0 1'
      EXECUTE PROCEDURE set_model(eid, 'progs/player.mdl');
      UPDATE player p SET p.ent_id = :eid WHERE p.id = 1;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'info_player_start2') THEN
    BEGIN
      IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.classname = 'player')) THEN
      BEGIN
        UPDATE ents e SET e.classname = 'player', e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 32,
               e.solid = 3, e.movetype = 3, e.health = 100, e.max_health = 100, e.takedamage = 2, e.flags = 8, e.z = e.z + 1 WHERE e.id = :eid;
        EXECUTE PROCEDURE set_model(eid, 'progs/player.mdl');
        UPDATE player p SET p.ent_id = :eid WHERE p.id = 1;
      END
      ELSE DELETE FROM ents e WHERE e.id = :eid;
    END
    -- ── doors ──
    ELSE IF (cls = 'func_door') THEN
    BEGIN
      IF (snds = 0 OR snds IS NULL) THEN BEGIN n1 = 'misc/null.wav'; n2 = 'misc/null.wav'; END
      ELSE IF (snds = 1) THEN BEGIN n1 = 'doors/drclos4.wav'; n2 = 'doors/doormv1.wav'; END
      ELSE IF (snds = 2) THEN BEGIN n1 = 'doors/hydro2.wav'; n2 = 'doors/hydro1.wav'; END
      ELSE IF (snds = 3) THEN BEGIN n1 = 'doors/stndr2.wav'; n2 = 'doors/stndr1.wav'; END
      ELSE BEGIN n1 = 'doors/ddoor2.wav'; n2 = 'doors/ddoor1.wav'; END
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      IF (spd IS NULL OR spd = 0) THEN spd = 100;
      IF (wt IS NULL) THEN wt = 3;
      IF (lip IS NULL) THEN lip = 8;
      IF (dmg IS NULL OR dmg = 0) THEN dmg = 2;
      dist = ABS(dx * sx + dy * sy + dz * sz) - lip;
      items = IIF(BIN_AND(sf, 16) <> 0, 131072, 0) + IIF(BIN_AND(sf, 8) <> 0, 262144, 0);
      SELECT g.world_type FROM game g WHERE g.id = 1 INTO wtype;
      n3 = CASE wtype WHEN 2 THEN 'doors/basetry.wav' WHEN 1 THEN 'doors/runetry.wav' ELSE 'doors/medtry.wav' END;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.wait_ = :wt, e.lip = :lip, e.dmg = :dmg,
             e.noise1 = :n1, e.noise2 = :n2, e.noise3 = :n3, e.items = :items, e.takedamage = IIF(:hp > 0, 1, 0),
             e.p1x = 0, e.p1y = 0, e.p1z = 0, e.p2x = :dx * :dist, e.p2y = :dy * :dist, e.p2z = :dz * :dist, e.mv_state = 1 WHERE e.id = :eid;
      IF (BIN_AND(sf, 1) <> 0) THEN     -- DOOR_START_OPEN
        UPDATE ents e SET e.x = e.p2x, e.y = e.p2y, e.z = e.p2z, e.p2x = e.p1x, e.p2y = e.p1y, e.p2z = e.p1z,
               e.p1x = e.x, e.p1y = e.y, e.p1z = e.z WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'func_door_secret') THEN
    BEGIN
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.ideal_yaw = COALESCE(:ang, 0), e.yaw = 0, e.mv_state = 1, e.speed = 50,
             e.takedamage = IIF(BIN_AND(:sf, 8) = 0 AND (:tn IS NULL OR :tn = '' OR BIN_AND(:sf, 16) <> 0), 1, 0),
             e.health = 10000, e.max_health = IIF(BIN_AND(:sf, 8) = 0 AND (:tn IS NULL OR :tn = '' OR BIN_AND(:sf, 16) <> 0), 10000, 0) WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── plats ──
    ELSE IF (cls = 'func_plat') THEN
    BEGIN
      IF (snds IS NULL OR snds = 0) THEN snds = 2;
      n1 = TRIM(IIF(snds = 1, 'plats/plat1.wav', 'plats/medplat1.wav'));
      n2 = TRIM(IIF(snds = 1, 'plats/plat2.wav', 'plats/medplat2.wav'));
      IF (spd IS NULL OR spd = 0) THEN spd = 150;
      IF (hgt IS NULL OR hgt = 0) THEN hgt = sz - 8;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.noise1 = :n1, e.noise2 = :n2, e.height = :hgt,
             e.p1x = e.x, e.p1y = e.y, e.p1z = e.z, e.p2x = e.x, e.p2y = e.y, e.p2z = e.z - :hgt, e.dmg = 1 WHERE e.id = :eid;
      -- starts at the bottom unless it is triggered
      IF (tn IS NULL OR tn = '') THEN
        UPDATE ents e SET e.z = e.p2z, e.mv_state = 1 WHERE e.id = :eid;
      ELSE
        UPDATE ents e SET e.mv_state = 0 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── buttons ──
    ELSE IF (cls = 'func_button') THEN
    BEGIN
      n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'buttons/switch21.wav' WHEN 2 THEN 'buttons/switch02.wav' WHEN 3 THEN 'buttons/switch04.wav' ELSE 'buttons/airbut1.wav' END;
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      IF (spd IS NULL OR spd = 0) THEN spd = 40;
      IF (wt IS NULL OR wt = 0) THEN wt = 1;
      IF (lip IS NULL OR lip = 0) THEN lip = 4;
      dist = ABS(dx * sx + dy * sy + dz * sz) - lip;
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.wait_ = :wt, e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0),
             e.p1x = e.x, e.p1y = e.y, e.p1z = e.z, e.p2x = e.x + :dx * :dist, e.p2y = e.y + :dy * :dist, e.p2z = e.z + :dz * :dist, e.mv_state = 1 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    -- ── trains ──
    ELSE IF (cls = 'func_train') THEN
    BEGIN
      IF (spd IS NULL OR spd = 0) THEN spd = 100;
      n1 = TRIM(IIF(COALESCE(snds, 1) = 1, 'plats/train2.wav', 'misc/null.wav'));
      n2 = TRIM(IIF(COALESCE(snds, 1) = 1, 'plats/train1.wav', 'misc/null.wav'));
      UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0, e.speed = :spd, e.noise1 = :n1, e.noise2 = :n2, e.dmg = IIF(COALESCE(:dmg, 0) = 0, 2, :dmg),
             e.mv_state = IIF(:tn IS NULL OR :tn = '', 2, 1), e.think = 'train_find', e.nextthink = 0.1e0 WHERE e.id = :eid;
    END
    ELSE IF (cls = 'path_corner') THEN BEGIN END
    ELSE IF (cls IN ('func_wall', 'func_episodegate', 'func_bossgate')) THEN
    BEGIN
      -- an episode gate stands only once its rune is held; the boss gate until all four are
      SELECT g.serverflags FROM game g WHERE g.id = 1 INTO wtype;
      IF (cls = 'func_episodegate' AND BIN_AND(wtype, sf) = 0) THEN DELETE FROM ents e WHERE e.id = :eid;
      ELSE IF (cls = 'func_bossgate' AND BIN_AND(wtype, 15) = 15) THEN DELETE FROM ents e WHERE e.id = :eid;
      ELSE UPDATE ents e SET e.solid = 4, e.movetype = 7, e.yaw = 0 WHERE e.id = :eid;
    END
    ELSE IF (cls = 'func_illusionary') THEN
      UPDATE ents e SET e.solid = 0, e.movetype = 0, e.yaw = 0 WHERE e.id = :eid;
    -- ── triggers ──
    ELSE IF (cls IN ('trigger_multiple', 'trigger_once', 'trigger_secret', 'trigger_counter', 'trigger_teleport', 'trigger_changelevel',
                     'trigger_push', 'trigger_hurt', 'trigger_monsterjump', 'trigger_relay', 'trigger_setskill')) THEN
    BEGIN
      UPDATE ents e SET e.model_id = NULL, e.solid = IIF(:mdl IS NULL, 0, 1), e.movetype = 0, e.yaw = 0 WHERE e.id = :eid;
      IF (cls = 'trigger_multiple') THEN
      BEGIN
        n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' WHEN 3 THEN 'misc/trigger1.wav' ELSE NULL END;
        UPDATE ents e SET e.wait_ = IIF(COALESCE(:wt, 0) = 0, 0.2e0, :wt), e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0),
               e.solid = IIF(:hp > 0, 2, e.solid) WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_once') THEN
      BEGIN
        n1 = CASE COALESCE(snds, 0) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' WHEN 3 THEN 'misc/trigger1.wav' ELSE NULL END;
        UPDATE ents e SET e.wait_ = -1, e.noise1 = :n1, e.takedamage = IIF(:hp > 0, 1, 0), e.solid = IIF(:hp > 0, 2, e.solid) WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_secret') THEN
      BEGIN
        UPDATE game g SET g.total_secrets = g.total_secrets + 1 WHERE g.id = 1;
        n1 = CASE COALESCE(snds, 1) WHEN 1 THEN 'misc/secret.wav' WHEN 2 THEN 'misc/talk.wav' ELSE 'misc/secret.wav' END;
        UPDATE ents e SET e.wait_ = -1, e.noise1 = :n1, e.message = COALESCE(:msg, 'You found a secret area!') WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_counter') THEN
        UPDATE ents e SET e.wait_ = -1, e.count_ = IIF(COALESCE(:cnt, 0) = 0, 2, :cnt) WHERE e.id = :eid;
      ELSE IF (cls = 'trigger_push') THEN
      BEGIN
        EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
        UPDATE ents e SET e.speed = IIF(COALESCE(:spd, 0) = 0, 1000, :spd), e.p1x = :dx, e.p1y = :dy, e.p1z = :dz WHERE e.id = :eid;
      END
      ELSE IF (cls = 'trigger_hurt') THEN
        -- hurt_touch's dmg: 5 when missing or 0; a fraction (LibreQuake's 0.1) rounds to nothing on integer health
        UPDATE ents e SET e.dmg = IIF(COALESCE(:dmg, 0) = 0, 5, FLOOR(:dmg)) WHERE e.id = :eid;
      ELSE IF (cls = 'trigger_monsterjump') THEN
        UPDATE ents e SET e.speed = IIF(COALESCE(:spd, 0) = 0, 200, :spd), e.height = IIF(COALESCE(:hgt, 0) = 0, 200, :hgt) WHERE e.id = :eid;
    END
    ELSE IF (cls IN ('info_teleport_destination', 'info_null', 'info_notnull')) THEN
      UPDATE ents e SET e.solid = 0, e.yaw = COALESCE(:ang, 0) WHERE e.id = :eid;
    -- ── items ──
    ELSE IF (cls LIKE 'item_%' OR cls LIKE 'weapon_%') THEN
    BEGIN
      mdl = CASE cls
        WHEN 'item_health' THEN TRIM(IIF(BIN_AND(sf, 2) <> 0, 'maps/b_bh100.bsp', IIF(BIN_AND(sf, 1) <> 0, 'maps/b_bh10.bsp', 'maps/b_bh25.bsp')))
        WHEN 'item_armor1' THEN 'progs/armor.mdl' WHEN 'item_armor2' THEN 'progs/armor.mdl' WHEN 'item_armorInv' THEN 'progs/armor.mdl'
        WHEN 'item_shells' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_shell1.bsp', 'maps/b_shell0.bsp')
        WHEN 'item_spikes' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_nail1.bsp', 'maps/b_nail0.bsp')
        WHEN 'item_rockets' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_rock1.bsp', 'maps/b_rock0.bsp')
        WHEN 'item_cells' THEN IIF(BIN_AND(sf, 1) <> 0, 'maps/b_batt1.bsp', 'maps/b_batt0.bsp')
        WHEN 'item_key1' THEN NULL WHEN 'item_key2' THEN NULL
        WHEN 'item_sigil' THEN 'progs/end1.mdl'
        WHEN 'item_artifact_invulnerability' THEN 'progs/invulner.mdl' WHEN 'item_artifact_invisibility' THEN 'progs/invisibl.mdl'
        WHEN 'item_artifact_super_damage' THEN 'progs/quaddama.mdl' WHEN 'item_artifact_envirosuit' THEN 'progs/suit.mdl'
        WHEN 'weapon_supershotgun' THEN 'progs/g_shot.mdl' WHEN 'weapon_nailgun' THEN 'progs/g_nail.mdl' WHEN 'weapon_supernailgun' THEN 'progs/g_nail2.mdl'
        WHEN 'weapon_grenadelauncher' THEN 'progs/g_rock.mdl' WHEN 'weapon_rocketlauncher' THEN 'progs/g_rock2.mdl' WHEN 'weapon_lightning' THEN 'progs/g_light.mdl'
        ELSE NULL END;
      IF (cls IN ('item_key1', 'item_key2')) THEN
      BEGIN
        SELECT g.world_type FROM game g WHERE g.id = 1 INTO wtype;
        mdl = CASE wtype WHEN 2 THEN IIF(cls = 'item_key1', 'progs/b_s_key.mdl', 'progs/b_g_key.mdl')
                         WHEN 1 THEN IIF(cls = 'item_key1', 'progs/m_s_key.mdl', 'progs/m_g_key.mdl')
                         ELSE IIF(cls = 'item_key1', 'progs/w_s_key.mdl', 'progs/w_g_key.mdl') END;
        IF (model_by_name(mdl) IS NULL) THEN mdl = IIF(cls = 'item_key1', 'progs/w_s_key.mdl', 'progs/w_g_key.mdl');
      END
      EXECUTE PROCEDURE set_model(eid, mdl);
      UPDATE ents e SET e.solid = 1, e.movetype = 6, e.flags = 256, e.yaw = 0,
             e.skin = CASE :cls WHEN 'item_armor2' THEN 1 WHEN 'item_armorInv' THEN 2 ELSE 0 END WHERE e.id = :eid;
      IF (mdl IS NULL OR mdl NOT STARTING WITH 'maps/') THEN
        UPDATE ents e SET e.minx = -16, e.miny = -16, e.minz = 0, e.maxx = 16, e.maxy = 16, e.maxz = 56 WHERE e.id = :eid;
      ELSE
        UPDATE ents e SET e.minx = 0, e.miny = 0, e.minz = 0, e.maxx = 32, e.maxy = 32, e.maxz = IIF(:cls = 'item_health', 32, 56) WHERE e.id = :eid;
      -- items start 6 units above the floor and drop
      UPDATE ents e SET e.z = e.z + 6 WHERE e.id = :eid;
      EXECUTE PROCEDURE drop_to_floor(eid);
    END
    -- ── monsters ──
    ELSE IF (cls LIKE 'monster_%') THEN
    BEGIN
      mname = SUBSTRING(cls FROM 9);
      SELECT t.model, t.health, t.hull, t.maxz, t.flags, t.yaw_speed, t.stand_anim FROM monster_types t WHERE t.name = :mname
        INTO mmodel, mhp, mhull, mmaxz, mflags, mys, stand;
      IF (mmodel IS NULL) THEN BEGIN DELETE FROM ents e WHERE e.id = :eid; CONTINUE; END
      EXECUTE PROCEDURE set_model(eid, mmodel);
      UPDATE ents e SET e.mtype = :mname, e.health = :mhp, e.max_health = :mhp, e.solid = 3, e.takedamage = 2,
             e.movetype = IIF(BIN_AND(:mflags, 3) <> 0, 5, 4), e.flags = BIN_OR(32, :mflags), e.yaw_speed = :mys,
             e.minx = IIF(:mhull = 2, -32, -16), e.miny = IIF(:mhull = 2, -32, -16), e.minz = -24,
             e.maxx = IIF(:mhull = 2, 32, 16), e.maxy = IIF(:mhull = 2, 32, 16), e.maxz = :mmaxz,
             e.st = 'stand', e.anim = :stand, e.anim_frame = FLOOR(rnd() * 4), e.ideal_yaw = e.yaw,
             e.think = 'monster_think', e.nextthink = 0.1e0 + rnd() * 0.5e0 WHERE e.id = :eid;
      IF (mname = 'fish') THEN
        UPDATE ents e SET e.minx = -16, e.miny = -16, e.minz = -24, e.maxx = 16, e.maxy = 16, e.maxz = 24 WHERE e.id = :eid;
      IF (mname = 'oldone') THEN
        UPDATE ents e SET e.minx = -160, e.miny = -128, e.minz = -24, e.maxx = 160, e.maxy = 128, e.maxz = 256, e.takedamage = 0, e.movetype = 0 WHERE e.id = :eid;
      IF (mname = 'zombie' AND BIN_AND(sf, 1) <> 0) THEN       -- SPAWN_CRUCIFIED
        UPDATE ents e SET e.solid = 0, e.takedamage = 0, e.movetype = 0, e.anim = 'cruc_', e.flags = 0, e.st = 'cruc' WHERE e.id = :eid;
      ELSE
      BEGIN
        UPDATE game g SET g.total_monsters = g.total_monsters + 1 WHERE g.id = 1;
        IF (mname = 'boss') THEN
          UPDATE ents e SET e.model_id = NULL, e.solid = 0, e.takedamage = 0, e.movetype = 0, e.st = 'asleep', e.nextthink = NULL,
                 e.minx = -128, e.miny = -128, e.minz = -24, e.maxx = 128, e.maxy = 128, e.maxz = 256 WHERE e.id = :eid;
        ELSE IF (BIN_AND(mflags, 3) = 0) THEN EXECUTE PROCEDURE drop_to_floor(eid);
        ELSE EXECUTE PROCEDURE link_ent(eid);
        IF (tg IS NOT NULL AND tg <> '' AND mname <> 'boss') THEN
          UPDATE ents e SET e.st = 'walk', e.anim = NULL WHERE e.id = :eid;
      END
    END
    -- ── decorations and traps ──
    ELSE IF (cls = 'light_torch_small_walltorch') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/flame.mdl');
      UPDATE ents e SET e.solid = 0, e.effects = 8 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls IN ('light_flame_large_yellow', 'light_flame_small_yellow', 'light_flame_small_white')) THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/flame2.mdl');
      UPDATE ents e SET e.solid = 0, e.frame = IIF(:cls = 'light_flame_large_yellow', 0, 1), e.effects = 8 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'light_globe') THEN                           -- the s_light sprite, made static
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/s_light.spr');
      UPDATE ents e SET e.solid = 0, e.effects = 8 WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
    END
    ELSE IF (cls = 'misc_explobox' OR cls = 'misc_explobox2') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, IIF(cls = 'misc_explobox', 'maps/b_explob.bsp', 'maps/b_exbox2.bsp'));
      UPDATE ents e SET e.solid = 2, e.movetype = 0, e.health = 20, e.takedamage = 2, e.yaw = 0,
             e.minx = 0, e.miny = 0, e.minz = 0, e.maxx = 32, e.maxy = 32, e.maxz = IIF(:cls = 'misc_explobox', 64, 32) WHERE e.id = :eid;
      EXECUTE PROCEDURE drop_to_floor(eid);
    END
    ELSE IF (cls = 'misc_fireball') THEN
      -- misc.qc's "if (!self.speed) self.speed == 1000;" compares instead of assigning: without a speed key a
      -- fireball rises only random() * 200
      UPDATE ents e SET e.solid = 0, e.speed = COALESCE(:spd, 0), e.think = 'fireball_think', e.nextthink = rnd() * 5 WHERE e.id = :eid;
    ELSE IF (cls = 'trap_spikeshooter' OR cls = 'trap_shooter') THEN
    BEGIN
      EXECUTE PROCEDURE movedir(COALESCE(ang, 0)) RETURNING_VALUES dx, dy, dz;
      UPDATE ents e SET e.solid = 0, e.p1x = :dx, e.p1y = :dy, e.p1z = :dz, e.wait_ = IIF(COALESCE(:wt, 0) = 0, 1, :wt) WHERE e.id = :eid;
      IF (cls = 'trap_shooter') THEN UPDATE ents e SET e.think = 'shooter_think', e.nextthink = e.wait_ WHERE e.id = :eid;
    END
    ELSE IF (cls = 'event_lightning') THEN UPDATE ents e SET e.solid = 0 WHERE e.id = :eid;
    ELSE IF (cls = 'misc_teleporttrain') THEN
    BEGIN
      EXECUTE PROCEDURE set_model(eid, 'progs/teleport.mdl');
      UPDATE ents e SET e.classname = 'trigger_teleport', e.solid = 1, e.movetype = 0, e.avel_yaw = 100, e.effects = 8,
             e.minx = -16, e.miny = -16, e.minz = -16, e.maxx = 16, e.maxy = 16, e.maxz = 16, e.target = :tg, e.targetname = :tn,
             e.speed = IIF(COALESCE(:spd, 0) = 0, 100, :spd), e.mv_state = 2, e.think = 'teleporttrain_next', e.nextthink = 0.1e0 WHERE e.id = :eid;
    END
    ELSE
      UPDATE ents e SET e.solid = 0 WHERE e.id = :eid;
  END

  -- LinkDoors: doors whose boxes touch open together (unless DOOR_DONT_LINK)
  FOR SELECT e.id FROM ents e WHERE e.classname = 'func_door' AND BIN_AND(e.spawnflags, 4) = 0 ORDER BY e.id INTO eid DO
  BEGIN
    SELECT MIN(COALESCE(o.linked_id, o.id)) FROM ents o
     WHERE o.classname = 'func_door' AND BIN_AND(o.spawnflags, 4) = 0 AND o.id < :eid
       AND EXISTS (SELECT 1 FROM ents s WHERE s.id = :eid
                   AND s.x + s.minx <= o.x + o.maxx AND s.x + s.maxx >= o.x + o.minx
                   AND s.y + s.miny <= o.y + o.maxy AND s.y + s.maxy >= o.y + o.miny
                   AND s.z + s.minz <= o.z + o.maxz AND s.z + s.maxz >= o.z + o.minz)
      INTO mid;
    IF (mid IS NOT NULL) THEN
    BEGIN
      UPDATE ents e SET e.linked_id = :mid WHERE e.id = :eid;
      -- the master carries the group's key, message and targetname
      UPDATE ents m SET m.items = BIN_OR(m.items, (SELECT e.items FROM ents e WHERE e.id = :eid)),
             m.message = COALESCE(m.message, (SELECT e.message FROM ents e WHERE e.id = :eid)),
             m.targetname = COALESCE(m.targetname, (SELECT e.targetname FROM ents e WHERE e.id = :eid)),
             m.max_health = MAXVALUE(m.max_health, (SELECT e.max_health FROM ents e WHERE e.id = :eid))
       WHERE m.id = :mid;
    END
  END
END^

CREATE OR ALTER PROCEDURE train_find (eid INTEGER)
AS
DECLARE tgt VARCHAR(40); DECLARE cx DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE cz DOUBLE PRECISION; DECLARE st SMALLINT;
BEGIN
  SELECT e.target, e.mv_state FROM ents e WHERE e.id = :eid INTO tgt, st;
  SELECT FIRST 1 e.x, e.y, e.z FROM ents e WHERE e.targetname = :tgt AND e.classname = 'path_corner' INTO cx, cy, cz;
  IF (cx IS NOT NULL) THEN
    UPDATE ents e SET e.x = :cx - e.minx, e.y = :cy - e.miny, e.z = :cz - e.minz, e.think = NULL, e.nextthink = NULL WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
  IF (st = 2) THEN EXECUTE PROCEDURE train_next(eid);
END^

CREATE OR ALTER PROCEDURE fireball_think (eid INTEGER)
AS
DECLARE f INTEGER; DECLARE spd DOUBLE PRECISION;
BEGIN
  SELECT e.speed FROM ents e WHERE e.id = :eid INTO spd;
  EXECUTE PROCEDURE spawn_ent('fireball', (SELECT e.x FROM ents e WHERE e.id = :eid), (SELECT e.y FROM ents e WHERE e.id = :eid), (SELECT e.z FROM ents e WHERE e.id = :eid))
    RETURNING_VALUES f;
  EXECUTE PROCEDURE set_model(f, 'progs/lavaball.mdl');
  UPDATE ents e SET e.solid = 1, e.movetype = 6, e.vx = rnd() * 100 - 50, e.vy = rnd() * 100 - 50, e.vz = :spd + rnd() * 200,
         e.avel_yaw = 200, e.think = 'remove', e.nextthink = now_() + 5, e.effects = 4 WHERE e.id = :f;
  UPDATE ents e SET e.nextthink = now_() + rnd() * 5 + 3 WHERE e.id = :eid;
END^

CREATE OR ALTER PROCEDURE spikeshooter_fire (eid INTEGER)
AS
DECLARE x DOUBLE PRECISION; DECLARE y DOUBLE PRECISION; DECLARE z DOUBLE PRECISION;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION; DECLARE sf INTEGER;
BEGIN
  SELECT e.x, e.y, e.z, e.p1x, e.p1y, e.p1z, e.spawnflags FROM ents e WHERE e.id = :eid INTO x, y, z, dx, dy, dz, sf;
  EXECUTE PROCEDURE snd(eid, 0, 'weapons/spike2.wav', 1, 1);
  EXECUTE PROCEDURE launch_spike(eid, x, y, z, dx, dy, dz, 500, IIF(BIN_AND(sf, 2) <> 0, 'superspike', 'spike'));
END^

CREATE OR ALTER PROCEDURE shooter_think (eid INTEGER)
AS
BEGIN
  EXECUTE PROCEDURE spikeshooter_fire(eid);
  UPDATE ents e SET e.nextthink = now_() + e.wait_ WHERE e.id = :eid;
END^

SET TERM ; ^
