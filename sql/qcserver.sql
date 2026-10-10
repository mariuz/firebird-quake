-- qcserver.sql – the QuakeC half of the server: the map's entities spawned by their QuakeC functions
-- (ED_LoadFromFile), a server frame's StartFrame and thinks, and the client's connection and thinks.

SET TERM ^ ;

-- ── the map's entities, spawned by their QuakeC functions (ED_LoadFromFile) ─

CREATE OR ALTER PROCEDURE qc_set_str (ent INTEGER, fofs INTEGER, s VARCHAR(2048) CHARACTER SET ASCII)
AS
BEGIN
  IF (s IS NULL OR s = '' OR fofs IS NULL) THEN EXIT;
  EXECUTE PROCEDURE qc_sf(ent, fofs, qc_newstr(s));
END^

CREATE OR ALTER PROCEDURE qc_set_num (ent INTEGER, fofs INTEGER, v DOUBLE PRECISION)
AS
BEGIN
  IF (v IS NULL OR fofs IS NULL) THEN EXIT;
  EXECUTE PROCEDURE qc_sf(ent, fofs, v);
END^

-- Every map_ents row (less those the skill or deathmatch flags drop) becomes an edict with its keys
-- in the fields the progs declare, then its classname's function runs with self set. worldspawn is
-- edict 0. A spawn function that raises loses its edict and leaves a row in qc_log.
CREATE OR ALTER PROCEDURE qc_spawn_map (skill SMALLINT, t DOUBLE PRECISION)
RETURNS (spawned INTEGER, failed INTEGER, skipped INTEGER)
AS
DECLARE mid INTEGER; DECLARE cls VARCHAR(40); DECLARE sf INTEGER; DECLARE e INTEGER; DECLARE f INTEGER; DECLARE skillbit INTEGER;
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER;
DECLARE f_cls INTEGER; DECLARE f_tn INTEGER; DECLARE f_tg INTEGER; DECLARE f_kt INTEGER; DECLARE f_model INTEGER; DECLARE f_org INTEGER; DECLARE f_ang INTEGER;
DECLARE f_sf INTEGER; DECLARE f_msg INTEGER; DECLARE f_wait INTEGER; DECLARE f_delay INTEGER; DECLARE f_speed INTEGER; DECLARE f_lip INTEGER; DECLARE f_health INTEGER;
DECLARE f_light INTEGER; DECLARE f_style INTEGER; DECLARE f_sounds INTEGER; DECLARE f_dmg INTEGER; DECLARE f_height INTEGER; DECLARE f_count INTEGER; DECLARE f_map INTEGER; DECLARE f_noise INTEGER; DECLARE f_wt INTEGER;
DECLARE tn VARCHAR(40); DECLARE tg VARCHAR(40); DECLARE kt VARCHAR(40); DECLARE mdl VARCHAR(40); DECLARE msg VARCHAR(200); DECLARE mp VARCHAR(32); DECLARE nz VARCHAR(64);
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE ang DOUBLE PRECISION; DECLARE mp_ DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mr DOUBLE PRECISION;
DECLARE wt DOUBLE PRECISION; DECLARE dl DOUBLE PRECISION; DECLARE sp DOUBLE PRECISION; DECLARE lp DOUBLE PRECISION; DECLARE hl INTEGER; DECLARE li INTEGER; DECLARE st INTEGER; DECLARE so INTEGER; DECLARE dm DOUBLE PRECISION; DECLARE hg DOUBLE PRECISION; DECLARE cn INTEGER; DECLARE wtype INTEGER;
DECLARE dmatch SMALLINT;
DECLARE kk VARCHAR(64); DECLARE kv VARCHAR(2048) CHARACTER SET ASCII; DECLARE ktp SMALLINT; DECLARE kofs INTEGER; DECLARE kp1 INTEGER; DECLARE kp2 INTEGER;
BEGIN
  spawned = 0; failed = 0; skipped = 0;
  skillbit = CASE skill WHEN 0 THEN 256 WHEN 1 THEN 512 ELSE 1024 END;
  dmatch = COALESCE((SELECT g.deathmatch FROM game g WHERE g.id = 1), 0);
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  f_cls = qc_fdef('classname'); f_tn = qc_fdef('targetname'); f_tg = qc_fdef('target'); f_kt = qc_fdef('killtarget'); f_model = qc_fdef('model');
  f_org = qc_fdef('origin'); f_ang = qc_fdef('angles'); f_sf = qc_fdef('spawnflags'); f_msg = qc_fdef('message'); f_wait = qc_fdef('wait'); f_delay = qc_fdef('delay');
  f_speed = qc_fdef('speed'); f_lip = qc_fdef('lip'); f_health = qc_fdef('health'); f_light = qc_fdef('light_lev'); f_style = qc_fdef('style'); f_sounds = qc_fdef('sounds');
  f_dmg = qc_fdef('dmg'); f_height = qc_fdef('height'); f_count = qc_fdef('count'); f_map = qc_fdef('map'); f_noise = qc_fdef('noise'); f_wt = qc_fdef('worldtype');
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_other, 0);
  FOR SELECT m.id, m.classname, m.spawnflags, m.targetname, m.target, m.killtarget, m.model, m.ox, m.oy, m.oz, m.angle, m.mpitch, m.myaw, m.mroll,
             m.message, m.wait_, m.delay, m.speed, m.lip, m.health, m.light, m.style, m.sounds, m.dmg, m.height, m.count_, m.map, m.noise, m.worldtype
      FROM map_ents m ORDER BY IIF(m.classname = 'worldspawn', 0, 1), m.id
      INTO mid, cls, sf, tn, tg, kt, mdl, ox, oy, oz, ang, mp_, my, mr, msg, wt, dl, sp, lp, hl, li, st, so, dm, hg, cn, mp, nz, wtype DO
  BEGIN
    -- ED_LoadFromFile: in deathmatch only NOT_DEATHMATCH (2048) drops an entity, else the skill's bit
    IF (cls <> 'worldspawn' AND BIN_AND(sf, IIF(:dmatch <> 0, 2048, skillbit)) <> 0) THEN BEGIN skipped = skipped + 1; CONTINUE; END
    f = qc_fn(cls);
    IF (f IS NULL) THEN
    BEGIN
      EXECUTE PROCEDURE qc_print('dprint', 'No spawn function for: ' || cls);
      skipped = skipped + 1;
      CONTINUE;
    END
    e = IIF(cls = 'worldspawn', 0, qc_spawn());
    EXECUTE PROCEDURE qc_set_str(e, f_cls, cls);
    EXECUTE PROCEDURE qc_set_str(e, f_tn, tn); EXECUTE PROCEDURE qc_set_str(e, f_tg, tg); EXECUTE PROCEDURE qc_set_str(e, f_kt, kt);
    EXECUTE PROCEDURE qc_set_str(e, f_model, mdl); EXECUTE PROCEDURE qc_set_str(e, f_msg, msg); EXECUTE PROCEDURE qc_set_str(e, f_map, mp); EXECUTE PROCEDURE qc_set_str(e, f_noise, nz);
    EXECUTE PROCEDURE qc_set_num(e, f_org, ox); EXECUTE PROCEDURE qc_set_num(e, f_org + 1, oy); EXECUTE PROCEDURE qc_set_num(e, f_org + 2, oz);
    IF (ang IS NOT NULL) THEN EXECUTE PROCEDURE qc_set_num(e, f_ang + 1, ang);               -- "angle" is angles '0 angle 0'
    IF (mp_ IS NOT NULL) THEN BEGIN EXECUTE PROCEDURE qc_set_num(e, f_ang, mp_); EXECUTE PROCEDURE qc_set_num(e, f_ang + 1, my); EXECUTE PROCEDURE qc_set_num(e, f_ang + 2, mr); END
    EXECUTE PROCEDURE qc_set_num(e, f_sf, sf);
    EXECUTE PROCEDURE qc_set_num(e, f_wait, wt); EXECUTE PROCEDURE qc_set_num(e, f_delay, dl); EXECUTE PROCEDURE qc_set_num(e, f_speed, sp); EXECUTE PROCEDURE qc_set_num(e, f_lip, lp);
    EXECUTE PROCEDURE qc_set_num(e, f_health, hl); EXECUTE PROCEDURE qc_set_num(e, f_light, li); EXECUTE PROCEDURE qc_set_num(e, f_style, st); EXECUTE PROCEDURE qc_set_num(e, f_sounds, so);
    EXECUTE PROCEDURE qc_set_num(e, f_dmg, dm); EXECUTE PROCEDURE qc_set_num(e, f_height, hg); EXECUTE PROCEDURE qc_set_num(e, f_count, cn); EXECUTE PROCEDURE qc_set_num(e, f_wt, wtype);
    -- ED_ParseEpair for every other key that names a field: a string, a float, a vector, a function
    -- (keys starting with _ are the compiler's, and an entity field cannot be written in a map)
    FOR SELECT k.k, k.v, d.type_, d.ofs FROM map_keys k JOIN qc_defs d ON d.kind = 1 AND d.name = k.k
         WHERE k.ent = :mid AND k.k NOT STARTING WITH '_' AND k.k NOT IN ('classname', 'targetname', 'target', 'killtarget', 'model', 'message', 'map',
               'noise', 'origin', 'angle', 'angles', 'mangle', 'spawnflags', 'wait', 'delay', 'speed', 'lip', 'health', 'light', 'style', 'sounds', 'dmg',
               'height', 'count', 'worldtype')
          INTO kk, kv, ktp, kofs DO
    BEGIN
      IF (ktp = 1) THEN EXECUTE PROCEDURE qc_set_str(e, kofs, kv);
      ELSE IF (ktp = 2) THEN EXECUTE PROCEDURE qc_set_num(e, kofs, CAST(TRIM(kv) AS DOUBLE PRECISION));
      ELSE IF (ktp = 3) THEN
      BEGIN
        kv = TRIM(kv) || ' 0 0'; kp1 = POSITION(' ', kv); kp2 = POSITION(' ', kv, kp1 + 1);
        EXECUTE PROCEDURE qc_set_num(e, kofs, CAST(SUBSTRING(kv FROM 1 FOR kp1 - 1) AS DOUBLE PRECISION));
        EXECUTE PROCEDURE qc_set_num(e, kofs + 1, CAST(SUBSTRING(kv FROM kp1 + 1 FOR kp2 - kp1 - 1) AS DOUBLE PRECISION));
        EXECUTE PROCEDURE qc_set_num(e, kofs + 2, CAST(SUBSTRING(kv FROM kp2 + 1 FOR POSITION(' ', kv || ' ', kp2 + 1) - kp2 - 1) AS DOUBLE PRECISION));
      END
      ELSE IF (ktp = 6) THEN EXECUTE PROCEDURE qc_set_num(e, kofs, COALESCE(qc_fn(TRIM(kv)), 0));
    WHEN ANY DO
      EXECUTE PROCEDURE qc_print('dprint', 'Can''t parse ' || kk || ' "' || SUBSTRING(kv FROM 1 FOR 60) || '" of map entity ' || mid);
    END
    EXECUTE PROCEDURE qc_sg(g_self, e);
    BEGIN
      EXECUTE PROCEDURE qc_call(f);
      spawned = spawned + 1;
    WHEN ANY DO
    BEGIN
      failed = failed + 1;
      UPDATE qc_vm v SET v.depth = 0 WHERE v.id = 1;
      DELETE FROM qc_localstack;
      EXECUTE PROCEDURE qc_print('error', 'spawn of ' || cls || ' (map entity ' || mid || ') failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
      IF (e > 0) THEN EXECUTE PROCEDURE qc_free(e);
    END
    END
  END
  SUSPEND;
END^

-- ── a server frame (SV_Physics, the QuakeC half): StartFrame, then every think that is due ──
CREATE OR ALTER PROCEDURE qc_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION)
RETURNS (thought INTEGER, failed INTEGER)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE g_ft INTEGER; DECLARE f_nt INTEGER; DECLARE f_think INTEGER;
DECLARE e INTEGER; DECLARE nt DOUBLE PRECISION; DECLARE f INTEGER; DECLARE last INTEGER;
BEGIN
  thought = 0; failed = 0;
  SELECT v.g_self, v.g_other, v.g_time, v.g_frametime, v.f_nextthink, v.f_think FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, g_ft, f_nt, f_think;
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_ft, dt);
  EXECUTE PROCEDURE qc_sg(g_self, 0); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('StartFrame');
  IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  -- the thinks due in this frame, in edict order; a think may spawn or free others, so walk by id
  last = -1;
  WHILE (1 = 1) DO
  BEGIN
    e = NULL;
    SELECT FIRST 1 d.id FROM qc_edicts d JOIN qc_fields n ON n.ent = d.id AND n.ofs = :f_nt
      WHERE d.free = 0 AND d.id > :last AND n.v > 0 AND n.v <= :t + 0.0005 ORDER BY d.id INTO e;
    IF (e IS NULL) THEN LEAVE;
    last = e;
    nt = qc_f(e, f_nt);
    f = CAST(qc_f(e, f_think) AS INTEGER);
    EXECUTE PROCEDURE qc_sf(e, f_nt, 0);
    IF (f = 0) THEN CONTINUE;
    EXECUTE PROCEDURE qc_sg(g_time, nt);            -- the think runs at its own time, as SV_RunThink does
    EXECUTE PROCEDURE qc_sg(g_self, e); EXECUTE PROCEDURE qc_sg(g_other, 0);
    BEGIN
      EXECUTE PROCEDURE qc_call(f);
      thought = thought + 1;
    WHEN ANY DO
    BEGIN
      failed = failed + 1;
      UPDATE qc_vm v SET v.depth = 0 WHERE v.id = 1;
      DELETE FROM qc_localstack;
      EXECUTE PROCEDURE qc_print('error', 'think of edict ' || e || ' (' || COALESCE((SELECT q.name FROM qc_functions q WHERE q.id = :f), '?') || ') failed: ' || SUBSTRING(RDB$ERROR(MESSAGE) FROM 1 FOR 400));
    END
    END
  END
  EXECUTE PROCEDURE qc_sg(g_time, t);
  SUSPEND;
END^


-- ── the client (sv_main.c, sv_user.c: the QuakeC half) ───────────────────

-- a touch delivered: self = e, other = o, e.touch()
CREATE OR ALTER PROCEDURE qc_touch (e INTEGER, o INTEGER)
AS
DECLARE f INTEGER; DECLARE g_self INTEGER; DECLARE g_other INTEGER;
BEGIN
  f = CAST(qc_f(e, qc_fdef('touch')) AS INTEGER);
  IF (f = 0) THEN EXIT;
  SELECT v.g_self, v.g_other FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other;
  EXECUTE PROCEDURE qc_sg(g_self, e); EXECUTE PROCEDURE qc_sg(g_other, o);
  EXECUTE PROCEDURE qc_call(f);
END^

-- a client in edict c (1 is the page's player, 2 and up the bots, sql/bots.sql): SetNewParms for a new game
-- (carry = 0; otherwise the parms carried over are in the globals already), ClientConnect, PutClientInServer
CREATE OR ALTER PROCEDURE qc_client_join_n (c INTEGER, t DOUBLE PRECISION, carry SMALLINT, name VARCHAR(32))
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE f INTEGER;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time;
  EXECUTE PROCEDURE qc_sg(g_time, t);
  EXECUTE PROCEDURE qc_sg(g_other, 0);
  UPDATE OR INSERT INTO qc_edicts (id, free) VALUES (:c, 0) MATCHING (id);
  DELETE FROM qc_fields x WHERE x.ent = :c;
  IF (qc_on() = 1) THEN
  BEGIN
    DELETE FROM ents x WHERE x.id = :c;
    INSERT INTO ents (id, classname) VALUES (:c, 'player');
  END
  -- Host_Spawn_f: the edict's colormap is its client number, its team its colours' (0, so 1), its netname
  -- the client's name (mods find a client's slot by colormap: FrikBot's rankings)
  EXECUTE PROCEDURE qc_set_str(c, qc_fdef('netname'), name);
  EXECUTE PROCEDURE qc_sf(c, qc_fdef('colormap'), c);
  EXECUTE PROCEDURE qc_sf(c, qc_fdef('team'), 1);
  EXECUTE PROCEDURE qc_sg(g_self, c);
  IF (carry = 0) THEN
  BEGIN
    f = qc_fn('SetNewParms'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  END
  EXECUTE PROCEDURE qc_sg(g_self, c);
  f = qc_fn('ClientConnect'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, c);
  f = qc_fn('PutClientInServer'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

CREATE OR ALTER PROCEDURE qc_client_join (t DOUBLE PRECISION, carry SMALLINT)
AS
BEGIN
  EXECUTE PROCEDURE qc_client_join_n(1, t, carry, 'player');
END^

CREATE OR ALTER PROCEDURE qc_client_connect (t DOUBLE PRECISION)
AS
BEGIN
  EXECUTE PROCEDURE qc_client_join(t, 0);
END^

-- the client's frame: the input into the fields, PlayerPreThink, (the engine's movement goes here), PlayerPostThink
CREATE OR ALTER PROCEDURE qc_player_frame (t DOUBLE PRECISION, dt DOUBLE PRECISION, pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, impulse SMALLINT)
AS
DECLARE g_self INTEGER; DECLARE g_other INTEGER; DECLARE g_time INTEGER; DECLARE g_ft INTEGER; DECLARE f INTEGER; DECLARE va INTEGER;
BEGIN
  SELECT v.g_self, v.g_other, v.g_time, v.g_frametime FROM qc_vm v WHERE v.id = 1 INTO g_self, g_other, g_time, g_ft;
  EXECUTE PROCEDURE qc_sg(g_time, t); EXECUTE PROCEDURE qc_sg(g_ft, dt);
  EXECUTE PROCEDURE qc_sf(1, qc_fdef('button0'), fire);
  EXECUTE PROCEDURE qc_sf(1, qc_fdef('button2'), jump);
  IF (impulse <> 0) THEN EXECUTE PROCEDURE qc_sf(1, qc_fdef('impulse'), impulse);
  va = qc_fdef('v_angle');
  EXECUTE PROCEDURE qc_sf(1, va, pitch); EXECUTE PROCEDURE qc_sf(1, va + 1, yaw); EXECUTE PROCEDURE qc_sf(1, va + 2, 0);
  EXECUTE PROCEDURE qc_sg(g_self, 1); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPreThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
  EXECUTE PROCEDURE qc_sg(g_self, 1); EXECUTE PROCEDURE qc_sg(g_other, 0);
  f = qc_fn('PlayerPostThink'); IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
END^

SET TERM ; ^
