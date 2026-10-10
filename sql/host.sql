-- host.sql – the console's game commands (host_cmd.c): god, notarget, noclip, give, kill, in both logics.
-- The flags and the movetype are the player edict's ents columns either way (QuakeC mode routes the
-- engine's fields there); the inventory is the player table's in the PSQL game and the client's QuakeC
-- fields in QuakeC mode; kill is ClientKill in QuakeC mode and a death past god mode in the PSQL game.

SET TERM ^ ;

CREATE OR ALTER PROCEDURE host_cmd (cmd VARCHAR(32), arg1 VARCHAR(64), arg2 VARCHAR(64))
RETURNS (msg VARCHAR(200))
AS
DECLARE pe INTEGER; DECLARE qc SMALLINT; DECLARE fl INTEGER; DECLARE mt SMALLINT; DECLARE hp DOUBLE PRECISION;
DECLARE n INTEGER; DECLARE c VARCHAR(1); DECLARE f INTEGER; DECLARE w INTEGER;
BEGIN
  msg = NULL;
  pe = player_ent();
  qc = qc_on();
  SELECT e.flags, e.movetype FROM ents e WHERE e.id = :pe INTO fl, mt;
  IF (fl IS NULL) THEN BEGIN msg = 'no player in the game'; SUSPEND; EXIT; END
  hp = IIF(qc = 1, qc_f(pe, qc_fdef('health')), (SELECT e.health FROM ents e WHERE e.id = :pe));
  IF (cmd = 'god') THEN                                -- Host_God_f: FL_GODMODE
  BEGIN
    UPDATE ents e SET e.flags = BIN_XOR(e.flags, 64) WHERE e.id = :pe;
    msg = TRIM(IIF(BIN_AND(fl, 64) = 0, 'godmode ON', 'godmode OFF'));   -- TRIM: IIF pads to the longer literal
  END
  ELSE IF (cmd = 'notarget') THEN                      -- Host_Notarget_f: FL_NOTARGET
  BEGIN
    UPDATE ents e SET e.flags = BIN_XOR(e.flags, 128) WHERE e.id = :pe;
    msg = TRIM(IIF(BIN_AND(fl, 128) = 0, 'notarget ON', 'notarget OFF'));
  END
  ELSE IF (cmd = 'noclip') THEN                        -- Host_Noclip_f: MOVETYPE_NOCLIP, back to MOVETYPE_WALK
  BEGIN
    UPDATE ents e SET e.movetype = IIF(:mt = 8, 3, 8), e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :pe;
    msg = TRIM(IIF(mt = 8, 'noclip OFF', 'noclip ON'));
  END
  ELSE IF (cmd = 'give') THEN                          -- Host_Give_f: a weapon 2..8, or s n r c h and an amount
  BEGIN
    c = LOWER(SUBSTRING(COALESCE(arg1, '') FROM 1 FOR 1));
    n = COALESCE(CAST(NULLIF(TRIM(arg2), '') AS INTEGER), 0);
    IF (c BETWEEN '2' AND '8') THEN
    BEGIN
      w = BIN_SHL(1, CAST(c AS INTEGER) - 2);         -- IT_SHOTGUN << (n - 2)
      IF (qc = 1) THEN
      BEGIN
        f = qc_fdef('items');
        EXECUTE PROCEDURE qc_sf(pe, f, BIN_OR(CAST(qc_f(pe, f) AS INTEGER), w));
      END
      ELSE UPDATE player p SET p.items = BIN_OR(p.items, :w) WHERE p.id = 1;
    END
    ELSE IF (c IN ('s', 'n', 'r', 'c')) THEN
    BEGIN
      IF (qc = 1) THEN
        EXECUTE PROCEDURE qc_sf(pe, qc_fdef(CASE c WHEN 's' THEN 'ammo_shells' WHEN 'n' THEN 'ammo_nails' WHEN 'r' THEN 'ammo_rockets' ELSE 'ammo_cells' END), n);
      ELSE UPDATE player p SET p.shells = IIF(:c = 's', :n, p.shells), p.nails = IIF(:c = 'n', :n, p.nails),
                               p.rockets = IIF(:c = 'r', :n, p.rockets), p.cells = IIF(:c = 'c', :n, p.cells) WHERE p.id = 1;
    END
    ELSE IF (c = 'h') THEN
    BEGIN
      IF (qc = 1) THEN EXECUTE PROCEDURE qc_sf(pe, qc_fdef('health'), n);
      ELSE UPDATE ents e SET e.health = :n WHERE e.id = :pe;
    END
    ELSE msg = 'give <2..8 | s n r c h> <amount>';
  END
  ELSE IF (cmd = 'kill') THEN                          -- Host_Kill_f: ClientKill, not when dead already
  BEGIN
    IF (hp <= 0) THEN msg = 'Can''t suicide -- already dead!';
    ELSE IF (qc = 1) THEN
    BEGIN
      EXECUTE PROCEDURE qc_sg((SELECT v.g_time FROM qc_vm v WHERE v.id = 1), (SELECT v.sv_time FROM qc_vm v WHERE v.id = 1));
      EXECUTE PROCEDURE qc_sg((SELECT v.g_self FROM qc_vm v WHERE v.id = 1), pe);
      f = qc_fn('ClientKill');
      IF (f IS NOT NULL) THEN EXECUTE PROCEDURE qc_call(f);
    END
    ELSE
    BEGIN
      -- the PSQL game has no ClientKill: the damage that kills, with god mode set aside for it
      UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(64)) WHERE e.id = :pe;
      EXECUTE PROCEDURE t_damage(pe, pe, pe, 50000);
      UPDATE ents e SET e.flags = BIN_OR(e.flags, BIN_AND(:fl, 64)) WHERE e.id = :pe;
    END
  END
  ELSE msg = 'unknown command "' || cmd || '"';
  SUSPEND;
END^

SET TERM ; ^
