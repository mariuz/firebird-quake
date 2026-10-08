-- physics.sql – world.c and sv_phys.c inside Firebird.
--
-- Collision is Quake's: a trace is a recursive walk of a BSP hull
-- (SV_RecursiveHullCheck) that splits the segment at every plane it
-- crosses. PSQL has recursion, so RHC is a recursive procedure threading
-- the trace state through its parameters. Box entities (monsters, the
-- player) are hit with a Minkowski slab test, as SV_HullForBox + the same
-- hull walk would do.

SET TERM ^ ;

-- forward declarations (bodies in game.sql); signatures must not change
CREATE OR ALTER PROCEDURE impact (e1 INTEGER, e2 INTEGER) AS BEGIN END^

-- The game's RAND(): a linear congruential generator in rng.seed, [0, 1). Every random choice of the
-- simulation goes through it, so a seed and the tics' input replay a game exactly (sql/demo.sql).
CREATE OR ALTER FUNCTION rnd RETURNS DOUBLE PRECISION
AS
DECLARE s BIGINT;
BEGIN
  UPDATE rng r SET r.seed = MOD(r.seed * 1103515245 + 12345, 2147483648) WHERE r.id = 1 RETURNING r.seed INTO s;
  RETURN s / 2147483648e0;
END^

-- A recording demo's next call: quake_tic and qc_tic hand over their arguments first (sql/demo.sql)
CREATE OR ALTER PROCEDURE demo_note (tics INTEGER, fwd DOUBLE PRECISION, side DOUBLE PRECISION, yaw_d DOUBLE PRECISION,
  pitch_d DOUBLE PRECISION, fire SMALLINT, jump SMALLINT, run SMALLINT, imp SMALLINT)
AS
DECLARE n INTEGER;
BEGIN
  IF (EXISTS (SELECT 1 FROM demo d WHERE d.id = 1 AND d.recording = 1)) THEN
  BEGIN
    UPDATE demo d SET d.calls = d.calls + 1 WHERE d.id = 1 RETURNING d.calls INTO n;
    INSERT INTO demo_tics (n, tics, fwd, side, yaw_d, pitch_d, fire, jump, run, imp)
    VALUES (:n, :tics, :fwd, :side, :yaw_d, :pitch_d, :fire, :jump, :run, :imp);
  END
END^


-- ── point queries ─────────────────────────────────────────────────────────
-- SV_HullPointContents: descend from node until a leaf/contents.
CREATE OR ALTER FUNCTION hull_contents (hull SMALLINT, node INTEGER,
  px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION)
RETURNS INTEGER
AS
DECLARE n INTEGER;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE d DOUBLE PRECISION;
DECLARE c0 INTEGER; DECLARE c1 INTEGER;
BEGIN
  n = node;
  WHILE (n >= 0) DO
  BEGIN
    SELECT h.nx, h.ny, h.nz, h.dist, h.c0, h.c1 FROM hulls h WHERE h.hull = :hull AND h.node = :n INTO nx, ny, nz, d, c0, c1;
    IF (nx IS NULL) THEN RETURN -2;
    n = IIF(nx * px + ny * py + nz * pz - d >= 0, c0, c1);
    nx = NULL;
  END
  IF (hull = 0) THEN
  BEGIN
    SELECT l.contents FROM leaves l WHERE l.id = -:n - 1 INTO c0;
    RETURN COALESCE(c0, -2);
  END
  RETURN n;
END^

-- Mod_PointInLeaf for the world.
CREATE OR ALTER FUNCTION point_leaf (px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION)
RETURNS INTEGER
AS
DECLARE n INTEGER;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION; DECLARE d DOUBLE PRECISION;
DECLARE c0 INTEGER; DECLARE c1 INTEGER;
BEGIN
  SELECT m.hull0 FROM models m JOIN game g ON g.world_model = m.id WHERE g.id = 1 INTO n;
  WHILE (n >= 0) DO
  BEGIN
    SELECT h.nx, h.ny, h.nz, h.dist, h.c0, h.c1 FROM hulls h WHERE h.hull = 0 AND h.node = :n INTO nx, ny, nz, d, c0, c1;
    IF (nx IS NULL) THEN RETURN 0;
    n = IIF(nx * px + ny * py + nz * pz - d >= 0, c0, c1);
    nx = NULL;
  END
  RETURN -n - 1;
END^

-- SV_PointContents against the world.
CREATE OR ALTER FUNCTION point_contents (px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION)
RETURNS INTEGER
AS
DECLARE head INTEGER;
BEGIN
  SELECT m.hull0 FROM models m JOIN game g ON g.world_model = m.id WHERE g.id = 1 INTO head;
  RETURN hull_contents(0, head, px, py, pz);
END^

-- Is leaf `leaf` in the PVS string `pvs`? ('' = everything visible)
CREATE OR ALTER FUNCTION pvs_visible (pvs VARCHAR(2048) CHARACTER SET ASCII, leaf INTEGER)
RETURNS SMALLINT
AS
DECLARE j INTEGER;
DECLARE c CHAR(1) CHARACTER SET ASCII;
BEGIN
  IF (pvs IS NULL OR pvs = '' OR leaf <= 0) THEN RETURN 1;
  j = leaf - 1;
  c = SUBSTRING(pvs FROM BIN_SHR(j, 2) + 1 FOR 1);
  IF (c IS NULL OR c = '') THEN RETURN 0;
  RETURN IIF(BIN_AND(POSITION(c, '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(j, 3))) <> 0, 1, 0);
END^

-- ── the hull walk ─────────────────────────────────────────────────────────
-- SV_RecursiveHullCheck. Returns res = 1 to keep going, 0 when the trace is
-- finished (hit, or never left solid). State in: allsolid/startsolid/inopen/
-- inwater; state out: the same plus fraction, end point and the hit plane.
CREATE OR ALTER PROCEDURE rhc (
  hull SMALLINT, head INTEGER, node INTEGER,
  p1f DOUBLE PRECISION, p2f DOUBLE PRECISION,
  p1x DOUBLE PRECISION, p1y DOUBLE PRECISION, p1z DOUBLE PRECISION,
  p2x DOUBLE PRECISION, p2y DOUBLE PRECISION, p2z DOUBLE PRECISION,
  allsolid_in SMALLINT, startsolid_in SMALLINT, inopen_in SMALLINT, inwater_in SMALLINT)
RETURNS (
  res SMALLINT, fraction DOUBLE PRECISION,
  ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
  nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION, pdist DOUBLE PRECISION,
  allsolid SMALLINT, startsolid SMALLINT, inopen SMALLINT, inwater SMALLINT)
AS
DECLARE contents INTEGER;
DECLARE c0 INTEGER; DECLARE c1 INTEGER;
DECLARE plnx DOUBLE PRECISION; DECLARE plny DOUBLE PRECISION; DECLARE plnz DOUBLE PRECISION; DECLARE pld DOUBLE PRECISION;
DECLARE t1 DOUBLE PRECISION; DECLARE t2 DOUBLE PRECISION;
DECLARE frac DOUBLE PRECISION; DECLARE midf DOUBLE PRECISION;
DECLARE mx DOUBLE PRECISION; DECLARE my DOUBLE PRECISION; DECLARE mz DOUBLE PRECISION;
DECLARE side_ SMALLINT;
DECLARE near_ INTEGER; DECLARE far_ INTEGER;
BEGIN
  allsolid = allsolid_in; startsolid = startsolid_in; inopen = inopen_in; inwater = inwater_in;
  fraction = 1; ex = p2x; ey = p2y; ez = p2z; nx = 0; ny = 0; nz = 0; pdist = 0;

  IF (node < 0) THEN
  BEGIN
    IF (hull = 0) THEN
      SELECT l.contents FROM leaves l WHERE l.id = -:node - 1 INTO contents;
    ELSE contents = node;
    contents = COALESCE(contents, -2);
    IF (contents <> -2) THEN
    BEGIN
      allsolid = 0;
      IF (contents = -1) THEN inopen = 1; ELSE inwater = 1;
    END
    ELSE startsolid = 1;
    res = 1;
    SUSPEND;
    EXIT;
  END

  SELECT h.nx, h.ny, h.nz, h.dist, h.c0, h.c1 FROM hulls h WHERE h.hull = :hull AND h.node = :node
    INTO plnx, plny, plnz, pld, c0, c1;
  IF (plnx IS NULL) THEN
  BEGIN
    res = 1;
    SUSPEND;
    EXIT;
  END
  t1 = plnx * p1x + plny * p1y + plnz * p1z - pld;
  t2 = plnx * p2x + plny * p2y + plnz * p2z - pld;

  IF (t1 >= 0 AND t2 >= 0) THEN
  BEGIN
    EXECUTE PROCEDURE rhc(hull, head, c0, p1f, p2f, p1x, p1y, p1z, p2x, p2y, p2z, allsolid, startsolid, inopen, inwater)
      RETURNING_VALUES res, fraction, ex, ey, ez, nx, ny, nz, pdist, allsolid, startsolid, inopen, inwater;
    SUSPEND;
    EXIT;
  END
  IF (t1 < 0 AND t2 < 0) THEN
  BEGIN
    EXECUTE PROCEDURE rhc(hull, head, c1, p1f, p2f, p1x, p1y, p1z, p2x, p2y, p2z, allsolid, startsolid, inopen, inwater)
      RETURNING_VALUES res, fraction, ex, ey, ez, nx, ny, nz, pdist, allsolid, startsolid, inopen, inwater;
    SUSPEND;
    EXIT;
  END

  -- the segment crosses the plane: split it, 1/32 unit onto the near side
  IF (t1 < 0) THEN frac = (t1 + 0.03125e0) / (t1 - t2);
  ELSE frac = (t1 - 0.03125e0) / (t1 - t2);
  IF (frac < 0) THEN frac = 0;
  IF (frac > 1) THEN frac = 1;
  midf = p1f + (p2f - p1f) * frac;
  mx = p1x + frac * (p2x - p1x);
  my = p1y + frac * (p2y - p1y);
  mz = p1z + frac * (p2z - p1z);
  side_ = IIF(t1 < 0, 1, 0);
  near_ = IIF(side_ = 0, c0, c1);
  far_ = IIF(side_ = 0, c1, c0);

  -- the near side first
  EXECUTE PROCEDURE rhc(hull, head, near_, p1f, midf, p1x, p1y, p1z, mx, my, mz, allsolid, startsolid, inopen, inwater)
    RETURNING_VALUES res, fraction, ex, ey, ez, nx, ny, nz, pdist, allsolid, startsolid, inopen, inwater;
  IF (res = 0) THEN
  BEGIN
    SUSPEND;
    EXIT;
  END

  -- the far side, if it is not solid where we would enter it
  IF (hull_contents(hull, far_, mx, my, mz) <> -2) THEN
  BEGIN
    EXECUTE PROCEDURE rhc(hull, head, far_, midf, p2f, mx, my, mz, p2x, p2y, p2z, allsolid, startsolid, inopen, inwater)
      RETURNING_VALUES res, fraction, ex, ey, ez, nx, ny, nz, pdist, allsolid, startsolid, inopen, inwater;
    SUSPEND;
    EXIT;
  END

  IF (allsolid = 1) THEN
  BEGIN
    res = 0;                            -- never got out of the solid area
    SUSPEND;
    EXIT;
  END

  -- the other side of the node is solid: this is the impact point
  IF (side_ = 0) THEN
  BEGIN
    nx = plnx; ny = plny; nz = plnz; pdist = pld;
  END
  ELSE
  BEGIN
    nx = -plnx; ny = -plny; nz = -plnz; pdist = -pld;
  END
  WHILE (hull_contents(hull, head, mx, my, mz) = -2) DO
  BEGIN
    -- shouldn't really happen, but does occasionally
    frac = frac - 0.1e0;
    IF (frac < 0) THEN
    BEGIN
      fraction = midf; ex = mx; ey = my; ez = mz; res = 0;
      SUSPEND;
      EXIT;
    END
    midf = p1f + (p2f - p1f) * frac;
    mx = p1x + frac * (p2x - p1x);
    my = p1y + frac * (p2y - p1y);
    mz = p1z + frac * (p2z - p1z);
  END
  fraction = midf; ex = mx; ey = my; ez = mz; res = 0;
  SUSPEND;
END^

-- A trace against one hull whose model sits at offset (ox, oy, oz).
CREATE OR ALTER PROCEDURE trace_hull (
  hull SMALLINT, head INTEGER,
  ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION,
  x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION)
RETURNS (
  fraction DOUBLE PRECISION,
  ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
  nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION,
  allsolid SMALLINT, startsolid SMALLINT, inopen SMALLINT, inwater SMALLINT)
AS
DECLARE res SMALLINT; DECLARE pdist DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE rhc(hull, head, head, 0, 1, x1 - ox, y1 - oy, z1 - oz, x2 - ox, y2 - oy, z2 - oz, 1, 0, 0, 0)
    RETURNING_VALUES res, fraction, ex, ey, ez, nx, ny, nz, pdist, allsolid, startsolid, inopen, inwater;
  ex = ex + ox; ey = ey + oy; ez = ez + oz;
  IF (allsolid = 1) THEN
  BEGIN
    startsolid = 1; fraction = 0; ex = x1; ey = y1; ez = z1;
  END
  SUSPEND;
END^

-- A segment against a box (bmins..bmaxs, absolute). Slab test; the hit
-- normal is the axis of the entered face.
CREATE OR ALTER PROCEDURE trace_box (
  bminx DOUBLE PRECISION, bminy DOUBLE PRECISION, bminz DOUBLE PRECISION,
  bmaxx DOUBLE PRECISION, bmaxy DOUBLE PRECISION, bmaxz DOUBLE PRECISION,
  x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION)
RETURNS (
  fraction DOUBLE PRECISION,
  ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
  nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION,
  startsolid SMALLINT)
AS
DECLARE tmin DOUBLE PRECISION = 0; DECLARE tmax DOUBLE PRECISION = 1;
DECLARE dx DOUBLE PRECISION; DECLARE dy DOUBLE PRECISION; DECLARE dz DOUBLE PRECISION;
DECLARE ta DOUBLE PRECISION; DECLARE tb DOUBLE PRECISION; DECLARE t DOUBLE PRECISION;
DECLARE axis SMALLINT = 0; DECLARE sgn DOUBLE PRECISION = 0;
BEGIN
  fraction = 1; ex = x2; ey = y2; ez = z2; nx = 0; ny = 0; nz = 0; startsolid = 0;
  IF (x1 >= bminx AND x1 <= bmaxx AND y1 >= bminy AND y1 <= bmaxy AND z1 >= bminz AND z1 <= bmaxz) THEN
  BEGIN
    startsolid = 1; fraction = 0; ex = x1; ey = y1; ez = z1;
    SUSPEND;
    EXIT;
  END
  dx = x2 - x1; dy = y2 - y1; dz = z2 - z1;
  -- x slab
  IF (ABS(dx) < 1e-9) THEN
  BEGIN
    IF (x1 < bminx OR x1 > bmaxx) THEN BEGIN SUSPEND; EXIT; END
  END
  ELSE
  BEGIN
    ta = (bminx - x1) / dx; tb = (bmaxx - x1) / dx;
    IF (ta > tb) THEN BEGIN t = ta; ta = tb; tb = t; END
    IF (ta > tmin) THEN BEGIN tmin = ta; axis = 1; sgn = IIF(dx > 0, -1, 1); END
    IF (tb < tmax) THEN tmax = tb;
  END
  -- y slab
  IF (ABS(dy) < 1e-9) THEN
  BEGIN
    IF (y1 < bminy OR y1 > bmaxy) THEN BEGIN SUSPEND; EXIT; END
  END
  ELSE
  BEGIN
    ta = (bminy - y1) / dy; tb = (bmaxy - y1) / dy;
    IF (ta > tb) THEN BEGIN t = ta; ta = tb; tb = t; END
    IF (ta > tmin) THEN BEGIN tmin = ta; axis = 2; sgn = IIF(dy > 0, -1, 1); END
    IF (tb < tmax) THEN tmax = tb;
  END
  -- z slab
  IF (ABS(dz) < 1e-9) THEN
  BEGIN
    IF (z1 < bminz OR z1 > bmaxz) THEN BEGIN SUSPEND; EXIT; END
  END
  ELSE
  BEGIN
    ta = (bminz - z1) / dz; tb = (bmaxz - z1) / dz;
    IF (ta > tb) THEN BEGIN t = ta; ta = tb; tb = t; END
    IF (ta > tmin) THEN BEGIN tmin = ta; axis = 3; sgn = IIF(dz > 0, -1, 1); END
    IF (tb < tmax) THEN tmax = tb;
  END
  IF (tmin > tmax OR axis = 0 OR tmin >= 1) THEN BEGIN SUSPEND; EXIT; END
  -- back off 1/32 unit like the hull walk does
  fraction = MAXVALUE(0, tmin - 0.03125e0 / MAXVALUE(1e-3, SQRT(dx * dx + dy * dy + dz * dz)));
  ex = x1 + fraction * dx; ey = y1 + fraction * dy; ez = z1 + fraction * dz;
  IF (axis = 1) THEN nx = sgn; ELSE IF (axis = 2) THEN ny = sgn; ELSE nz = sgn;
  SUSPEND;
END^

-- SV_Move: trace an entity's box (its mins/maxs) from p1 to p2 through the
-- world, the brush models and the box entities. `nomonsters` = 1 clips only
-- against BSP models (hitscan weapons use 0; sight checks use 1).
-- `mover` may be NULL for a point trace with no owner.
CREATE OR ALTER PROCEDURE trace_move (
  mover INTEGER,
  mnx DOUBLE PRECISION, mny DOUBLE PRECISION, mnz DOUBLE PRECISION,
  mxx DOUBLE PRECISION, mxy DOUBLE PRECISION, mxz DOUBLE PRECISION,
  x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION,
  x2 DOUBLE PRECISION, y2 DOUBLE PRECISION, z2 DOUBLE PRECISION,
  nomonsters SMALLINT)
RETURNS (
  fraction DOUBLE PRECISION,
  ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
  nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION,
  allsolid SMALLINT, startsolid SMALLINT, inopen SMALLINT, inwater SMALLINT,
  hit_ent INTEGER)
AS
DECLARE hull SMALLINT; DECLARE head INTEGER;
DECLARE offx DOUBLE PRECISION; DECLARE offy DOUBLE PRECISION; DECLARE offz DOUBLE PRECISION;
DECLARE sizex DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION;
DECLARE tnx DOUBLE PRECISION; DECLARE tny DOUBLE PRECISION; DECLARE tnz DOUBLE PRECISION;
DECLARE tas SMALLINT; DECLARE tss SMALLINT; DECLARE tio SMALLINT; DECLARE tiw SMALLINT;
DECLARE eid INTEGER; DECLARE emid INTEGER; DECLARE esolid SMALLINT; DECLARE eowner INTEGER;
DECLARE eox DOUBLE PRECISION; DECLARE eoy DOUBLE PRECISION; DECLARE eoz DOUBLE PRECISION;
DECLARE eminx DOUBLE PRECISION; DECLARE eminy DOUBLE PRECISION; DECLARE eminz DOUBLE PRECISION;
DECLARE emaxx DOUBLE PRECISION; DECLARE emaxy DOUBLE PRECISION; DECLARE emaxz DOUBLE PRECISION;
DECLARE bminx DOUBLE PRECISION; DECLARE bminy DOUBLE PRECISION; DECLARE bminz DOUBLE PRECISION;
DECLARE bmaxx DOUBLE PRECISION; DECLARE bmaxy DOUBLE PRECISION; DECLARE bmaxz DOUBLE PRECISION;
DECLARE mower INTEGER;
DECLARE world_mid INTEGER;
DECLARE hminx DOUBLE PRECISION; DECLARE hminy DOUBLE PRECISION; DECLARE hminz DOUBLE PRECISION;
BEGIN
  -- SV_HullForEntity: the hull that matches the mover's size
  sizex = mxx - mnx;
  IF (sizex < 3) THEN
  BEGIN
    hull = 0; hminx = 0; hminy = 0; hminz = 0;
  END
  ELSE IF (sizex <= 32) THEN
  BEGIN
    hull = 1; hminx = -16; hminy = -16; hminz = -24;
  END
  ELSE
  BEGIN
    hull = 2; hminx = -32; hminy = -32; hminz = -24;
  END
  -- the hull's reference point is its mins corner: shift the segment
  offx = hminx - mnx; offy = hminy - mny; offz = hminz - mnz;

  -- the world
  SELECT g.world_model FROM game g WHERE g.id = 1 INTO world_mid;
  SELECT IIF(:hull = 0, m.hull0, IIF(:hull = 1, m.hull1, m.hull2)) FROM models m WHERE m.id = :world_mid INTO head;
  -- hulls 1 and 2 share the CLIPNODES rows (table hull 1) and differ by head node
  EXECUTE PROCEDURE trace_hull(IIF(hull = 0, 0, 1), head, offx, offy, offz, x1, y1, z1, x2, y2, z2)
    RETURNING_VALUES fraction, ex, ey, ez, nx, ny, nz, allsolid, startsolid, inopen, inwater;
  hit_ent = 0;
  IF (allsolid = 1) THEN
  BEGIN
    SUSPEND;
    EXIT;
  END

  SELECT e.owner_id FROM ents e WHERE e.id = :mover INTO mower;

  -- brush models (doors, plats, …) and box entities
  bminx = MINVALUE(x1, x2) + mnx - 1; bminy = MINVALUE(y1, y2) + mny - 1; bminz = MINVALUE(z1, z2) + mnz - 1;
  bmaxx = MAXVALUE(x1, x2) + mxx + 1; bmaxy = MAXVALUE(y1, y2) + mxy + 1; bmaxz = MAXVALUE(z1, z2) + mxz + 1;
  FOR SELECT e.id, e.model_id, e.solid, e.owner_id, e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz
        FROM ents e
       WHERE e.solid IN (2, 3, 4)
         AND (:mover IS NULL OR e.id <> :mover)
         AND e.x + e.maxx >= :bminx AND e.x + e.minx <= :bmaxx
         AND e.y + e.maxy >= :bminy AND e.y + e.miny <= :bmaxy
         AND e.z + e.maxz >= :bminz AND e.z + e.minz <= :bmaxz
        INTO eid, emid, esolid, eowner, eox, eoy, eoz, eminx, eminy, eminz, emaxx, emaxy, emaxz
  DO
  BEGIN
    IF (mover IS NOT NULL AND (eowner = mover OR mower = eid)) THEN CONTINUE;   -- don't clip against own missiles / owner
    IF (esolid = 4) THEN
    BEGIN
      SELECT IIF(:hull = 0, m.hull0, IIF(:hull = 1, m.hull1, m.hull2)) FROM models m WHERE m.id = :emid INTO head;
      IF (head IS NULL) THEN CONTINUE;
      EXECUTE PROCEDURE trace_hull(IIF(hull = 0, 0, 1), head, eox + offx, eoy + offy, eoz + offz, x1, y1, z1, x2, y2, z2)
        RETURNING_VALUES f, tx, ty, tz, tnx, tny, tnz, tas, tss, tio, tiw;
    END
    ELSE
    BEGIN
      IF (nomonsters = 1) THEN CONTINUE;
      -- Minkowski box: the entity's box grown by the mover's
      EXECUTE PROCEDURE trace_box(eox + eminx - mxx, eoy + eminy - mxy, eoz + eminz - mxz,
                                  eox + emaxx - mnx, eoy + emaxy - mny, eoz + emaxz - mnz,
                                  x1, y1, z1, x2, y2, z2)
        RETURNING_VALUES f, tx, ty, tz, tnx, tny, tnz, tss;
      tas = tss; tio = 0; tiw = 0;
    END
    IF (tas = 1 OR tss = 1 OR f < fraction) THEN
    BEGIN
      hit_ent = eid;
      IF (tas = 1) THEN allsolid = 1;
      IF (tss = 1) THEN startsolid = 1;
      IF (f < fraction) THEN
      BEGIN
        fraction = f; ex = tx; ey = ty; ez = tz; nx = tnx; ny = tny; nz = tnz;
      END
      IF (allsolid = 1) THEN
      BEGIN
        fraction = 0; ex = x1; ey = y1; ez = z1;
        SUSPEND;
        EXIT;
      END
    END
  END
  SUSPEND;
END^

-- SV_TestEntityPosition: is the entity's box inside something solid?
CREATE OR ALTER FUNCTION test_position (eid INTEGER, px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION)
RETURNS SMALLINT
AS
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE tx DOUBLE PRECISION; DECLARE ty DOUBLE PRECISION; DECLARE tz DOUBLE PRECISION;
DECLARE tnx DOUBLE PRECISION; DECLARE tny DOUBLE PRECISION; DECLARE tnz DOUBLE PRECISION;
DECLARE tas SMALLINT; DECLARE tss SMALLINT; DECLARE tio SMALLINT; DECLARE tiw SMALLINT; DECLARE hit INTEGER;
BEGIN
  SELECT e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz FROM ents e WHERE e.id = :eid INTO mnx, mny, mnz, mxx, mxy, mxz;
  EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, px, py, pz, px, py, pz, 0)
    RETURNING_VALUES f, tx, ty, tz, tnx, tny, tnz, tas, tss, tio, tiw, hit;
  RETURN tss;
END^

-- SV_FindTouchedLeafs: the leaves a box touches, by one walk down the BSP tree that goes to both
-- sides of every plane the box straddles (BoxOnPlaneSide), as one recursive query. A point inside the
-- box rides along: at_point marks the leaf it is in (SV_PointInLeaf, without a second walk). Leaf 0 is
-- the solid leaf.
CREATE OR ALTER PROCEDURE box_leafs (px DOUBLE PRECISION, py DOUBLE PRECISION, pz DOUBLE PRECISION,
  x0 DOUBLE PRECISION, y0 DOUBLE PRECISION, z0 DOUBLE PRECISION, x1 DOUBLE PRECISION, y1 DOUBLE PRECISION, z1 DOUBLE PRECISION)
RETURNS (leaf INTEGER, at_point SMALLINT)
AS
BEGIN
  FOR WITH RECURSIVE w (node, onpath) AS (
    SELECT m.hull0, 1 FROM models m JOIN game g ON g.world_model = m.id WHERE g.id = 1
    UNION ALL
    SELECT h.c0, IIF(w.onpath = 1 AND h.nx * :px + h.ny * :py + h.nz * :pz - h.dist >= 0, 1, 0)       -- the front: the box's farthest corner along the normal
      FROM w JOIN hulls h ON h.hull = 0 AND h.node = w.node
     WHERE w.node >= 0 AND h.nx * IIF(h.nx >= 0, :x1, :x0) + h.ny * IIF(h.ny >= 0, :y1, :y0) + h.nz * IIF(h.nz >= 0, :z1, :z0) - h.dist >= 0
    UNION ALL
    SELECT h.c1, IIF(w.onpath = 1 AND h.nx * :px + h.ny * :py + h.nz * :pz - h.dist < 0, 1, 0)        -- the back: its nearest corner
      FROM w JOIN hulls h ON h.hull = 0 AND h.node = w.node
     WHERE w.node >= 0 AND h.nx * IIF(h.nx >= 0, :x0, :x1) + h.ny * IIF(h.ny >= 0, :y0, :y1) + h.nz * IIF(h.nz >= 0, :z0, :z1) - h.dist < 0)
  SELECT -w.node - 1, w.onpath FROM w WHERE w.node < 0 ORDER BY 2 DESC, 1 INTO leaf, at_point DO SUSPEND;
END^

-- SV_LinkEdict: remember the leaf of the origin and the leaves the box (absmin..absmax: one unit
-- bigger, fifteen sideways for items) touches, for the PVS test when drawing.
CREATE OR ALTER PROCEDURE link_ent (eid INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE lf INTEGER; DECLARE l2 INTEGER; DECLARE ap SMALLINT; DECLARE grow DOUBLE PRECISION;
DECLARE lst VARCHAR(200) CHARACTER SET ASCII;
BEGIN
  SELECT e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz, IIF(BIN_AND(e.flags, 256) <> 0, 15, 1) FROM ents e WHERE e.id = :eid
    INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz, grow;
  -- the origin's leaf comes first (one outside its box, such as a door's at 0 0 0, has a walk of its own)
  lst = ',';
  FOR SELECT b.leaf, b.at_point FROM box_leafs(:px, :py, :pz, :px + :mnx - :grow, :py + :mny - :grow, :pz + :mnz - 1,
                                               :px + :mxx + :grow, :py + :mxy + :grow, :pz + :mxz + 1) b INTO l2, ap DO
  BEGIN
    IF (ap = 1 AND lf IS NULL) THEN BEGIN lf = l2; lst = ',' || lf || ','; END
    ELSE IF (l2 > 0 AND POSITION(',' || l2 || ',', lst) = 0 AND CHAR_LENGTH(lst) < 180) THEN lst = lst || l2 || ',';
  END
  IF (lf IS NULL) THEN BEGIN lf = point_leaf(px, py, pz); lst = ',' || lf || lst; END
  UPDATE ents e SET e.leaf = :lf, e.leafs = :lst WHERE e.id = :eid;
END^

-- SV_CheckWater: water level 0 none, 1 feet, 2 waist, 3 eyes.
CREATE OR ALTER PROCEDURE check_water (eid INTEGER) RETURNS (waterlevel SMALLINT, watertype INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnz DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION; DECLARE vo DOUBLE PRECISION;
DECLARE c INTEGER;
BEGIN
  SELECT e.x, e.y, e.z, e.minz, e.maxz, IIF(e.classname = 'player', 22, (e.minz + e.maxz) / 2)
    FROM ents e WHERE e.id = :eid INTO px, py, pz, mnz, mxz, vo;
  waterlevel = 0; watertype = -1;
  c = point_contents(px, py, pz + mnz + 1);
  IF (c <= -3) THEN
  BEGIN
    watertype = c; waterlevel = 1;
    c = point_contents(px, py, pz + (mnz + mxz) / 2);
    IF (c <= -3) THEN
    BEGIN
      waterlevel = 2;
      c = point_contents(px, py, pz + vo);
      IF (c <= -3) THEN waterlevel = 3;
    END
  END
  UPDATE ents e SET e.waterlevel = :waterlevel, e.watertype = :watertype WHERE e.id = :eid;
  SUSPEND;
END^

-- ClipVelocity: slide along the plane. Returns blocked bits (1 floor, 2 step).
CREATE OR ALTER PROCEDURE clip_velocity (
  ix DOUBLE PRECISION, iy DOUBLE PRECISION, iz DOUBLE PRECISION,
  nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION, overbounce DOUBLE PRECISION)
RETURNS (ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION, blocked SMALLINT)
AS
DECLARE backoff DOUBLE PRECISION;
BEGIN
  blocked = 0;
  IF (nz > 0) THEN blocked = BIN_OR(blocked, 1);
  IF (nz = 0) THEN blocked = BIN_OR(blocked, 2);
  backoff = (ix * nx + iy * ny + iz * nz) * overbounce;
  ox = ix - nx * backoff; oy = iy - ny * backoff; oz = iz - nz * backoff;
  IF (ox > -0.1e0 AND ox < 0.1e0) THEN ox = 0;
  IF (oy > -0.1e0 AND oy < 0.1e0) THEN oy = 0;
  IF (oz > -0.1e0 AND oz < 0.1e0) THEN oz = 0;
  SUSPEND;
END^

SET TERM ; ^

-- the clip planes SV_FlyMove accumulates (PSQL has no arrays)
CREATE GLOBAL TEMPORARY TABLE clip_planes (
  k INTEGER NOT NULL,
  nx DOUBLE PRECISION NOT NULL, ny DOUBLE PRECISION NOT NULL, nz DOUBLE PRECISION NOT NULL
) ON COMMIT DELETE ROWS;

SET TERM ^ ;

-- SV_FlyMove: slide the entity along the world for `dt` seconds, bumping up
-- to four times. Returns blocked bits (1 floor, 2 wall) and the entity hit.
CREATE OR ALTER PROCEDURE fly_move (eid INTEGER, dt DOUBLE PRECISION)
RETURNS (blocked SMALLINT, hit_ent INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE ovx DOUBLE PRECISION; DECLARE ovy DOUBLE PRECISION; DECLARE ovz DOUBLE PRECISION;   -- original_velocity
DECLARE pvx DOUBLE PRECISION; DECLARE pvy DOUBLE PRECISION; DECLARE pvz DOUBLE PRECISION;   -- primal_velocity
DECLARE nvx DOUBLE PRECISION; DECLARE nvy DOUBLE PRECISION; DECLARE nvz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE flags INTEGER;
DECLARE time_left DOUBLE PRECISION;
DECLARE bump INTEGER = 0;
DECLARE numplanes INTEGER = 0;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE allsolid SMALLINT; DECLARE startsolid SMALLINT; DECLARE inopen SMALLINT; DECLARE inwater SMALLINT;
DECLARE hit INTEGER; DECLARE hsolid SMALLINT;
DECLARE i INTEGER; DECLARE j INTEGER; DECLARE ok SMALLINT; DECLARE cb SMALLINT;
DECLARE qx DOUBLE PRECISION; DECLARE qy DOUBLE PRECISION; DECLARE qz DOUBLE PRECISION;
DECLARE ax DOUBLE PRECISION; DECLARE ay DOUBLE PRECISION; DECLARE az DOUBLE PRECISION;
DECLARE bx DOUBLE PRECISION; DECLARE by_ DOUBLE PRECISION; DECLARE bz DOUBLE PRECISION;
DECLARE d DOUBLE PRECISION;
BEGIN
  blocked = 0; hit_ent = 0;
  SELECT e.x, e.y, e.z, e.vx, e.vy, e.vz, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz, e.flags
    FROM ents e WHERE e.id = :eid INTO px, py, pz, vx, vy, vz, mnx, mny, mnz, mxx, mxy, mxz, flags;
  ovx = vx; ovy = vy; ovz = vz; pvx = vx; pvy = vy; pvz = vz;
  time_left = dt;
  DELETE FROM clip_planes;

  WHILE (bump < 4) DO
  BEGIN
    IF (vx = 0 AND vy = 0 AND vz = 0) THEN LEAVE;
    EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, px, py, pz,
                                 px + time_left * vx, py + time_left * vy, pz + time_left * vz, 0)
      RETURNING_VALUES f, ex, ey, ez, nx, ny, nz, allsolid, startsolid, inopen, inwater, hit;
    IF (allsolid = 1) THEN
    BEGIN
      vx = 0; vy = 0; vz = 0; blocked = 3;
      LEAVE;
    END
    IF (f > 0) THEN
    BEGIN
      px = ex; py = ey; pz = ez;
      ovx = vx; ovy = vy; ovz = vz;
      numplanes = 0;
      DELETE FROM clip_planes;
    END
    IF (f = 1) THEN LEAVE;

    hit_ent = hit;
    IF (nz > 0.7e0) THEN
    BEGIN
      blocked = BIN_OR(blocked, 1);
      SELECT e.solid FROM ents e WHERE e.id = :hit INTO hsolid;
      IF (hit = 0 OR hsolid = 4) THEN flags = BIN_OR(flags, 512);   -- FL_ONGROUND
    END
    IF (nz = 0) THEN blocked = BIN_OR(blocked, 2);
    -- SV_Impact: touch
    UPDATE ents e SET e.x = :px, e.y = :py, e.z = :pz, e.vx = :vx, e.vy = :vy, e.vz = :vz, e.flags = :flags WHERE e.id = :eid;
    EXECUTE PROCEDURE impact(eid, hit);
    IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid)) THEN EXIT;   -- removed by its touch
    SELECT e.x, e.y, e.z, e.vx, e.vy, e.vz, e.flags FROM ents e WHERE e.id = :eid INTO px, py, pz, vx, vy, vz, flags;

    time_left = time_left - time_left * f;
    IF (numplanes >= 5) THEN
    BEGIN
      vx = 0; vy = 0; vz = 0; blocked = 3;
      LEAVE;
    END
    INSERT INTO clip_planes (k, nx, ny, nz) VALUES (:numplanes, :nx, :ny, :nz);
    numplanes = numplanes + 1;

    -- modify original_velocity so it parallels all of the clip planes
    i = 0; ok = 0;
    WHILE (i < numplanes) DO
    BEGIN
      SELECT c.nx, c.ny, c.nz FROM clip_planes c WHERE c.k = :i INTO ax, ay, az;
      EXECUTE PROCEDURE clip_velocity(ovx, ovy, ovz, ax, ay, az, 1) RETURNING_VALUES nvx, nvy, nvz, cb;
      j = 0; ok = 1;
      WHILE (j < numplanes) DO
      BEGIN
        IF (j <> i) THEN
        BEGIN
          SELECT c.nx, c.ny, c.nz FROM clip_planes c WHERE c.k = :j INTO bx, by_, bz;
          IF (nvx * bx + nvy * by_ + nvz * bz < 0) THEN
          BEGIN
            ok = 0;
            LEAVE;
          END
        END
        j = j + 1;
      END
      IF (ok = 1) THEN LEAVE;
      i = i + 1;
    END
    IF (ok = 1) THEN
    BEGIN
      vx = nvx; vy = nvy; vz = nvz;
    END
    ELSE
    BEGIN
      IF (numplanes <> 2) THEN
      BEGIN
        vx = 0; vy = 0; vz = 0;
        LEAVE;
      END
      -- go along the crease
      SELECT c.nx, c.ny, c.nz FROM clip_planes c WHERE c.k = 0 INTO ax, ay, az;
      SELECT c.nx, c.ny, c.nz FROM clip_planes c WHERE c.k = 1 INTO bx, by_, bz;
      qx = ay * bz - az * by_; qy = az * bx - ax * bz; qz = ax * by_ - ay * bx;
      d = qx * vx + qy * vy + qz * vz;
      vx = qx * d; vy = qy * d; vz = qz * d;
    END
    -- if original velocity is against the original velocity, stop dead
    IF (vx * pvx + vy * pvy + vz * pvz <= 0) THEN
    BEGIN
      vx = 0; vy = 0; vz = 0;
      LEAVE;
    END
    bump = bump + 1;
  END
  UPDATE ents e SET e.x = :px, e.y = :py, e.z = :pz, e.vx = :vx, e.vy = :vy, e.vz = :vz, e.flags = :flags WHERE e.id = :eid;
  SUSPEND;
END^

-- SV_PushEntity: move by a vector, stopping at the first thing hit.
CREATE OR ALTER PROCEDURE push_entity (eid INTEGER, dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION)
RETURNS (fraction DOUBLE PRECISION, nx DOUBLE PRECISION, ny DOUBLE PRECISION, nz DOUBLE PRECISION,
         allsolid SMALLINT, startsolid SMALLINT, hit_ent INTEGER)
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE inopen SMALLINT; DECLARE inwater SMALLINT; DECLARE mt SMALLINT;
BEGIN
  SELECT e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz, e.movetype
    FROM ents e WHERE e.id = :eid INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz, mt;
  EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, px, py, pz, px + dx, py + dy, pz + dz, 0)
    RETURNING_VALUES fraction, ex, ey, ez, nx, ny, nz, allsolid, startsolid, inopen, inwater, hit_ent;
  UPDATE ents e SET e.x = :ex, e.y = :ey, e.z = :ez WHERE e.id = :eid;
  IF (fraction < 1) THEN EXECUTE PROCEDURE impact(eid, hit_ent);
  SUSPEND;
END^

-- SV_WalkMove for the player: fly, and if a wall stopped us try again from
-- one step (18 units) up, keeping that only if it lands on ground.
CREATE OR ALTER PROCEDURE walk_move (eid INTEGER, dt DOUBLE PRECISION)
AS
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION;
DECLARE ovx DOUBLE PRECISION; DECLARE ovy DOUBLE PRECISION; DECLARE ovz DOUBLE PRECISION;
DECLARE nsx DOUBLE PRECISION; DECLARE nsy DOUBLE PRECISION; DECLARE nsz DOUBLE PRECISION;
DECLARE nsvx DOUBLE PRECISION; DECLARE nsvy DOUBLE PRECISION; DECLARE nsvz DOUBLE PRECISION;
DECLARE clip SMALLINT; DECLARE hit INTEGER;
DECLARE oldonground SMALLINT; DECLARE flags INTEGER; DECLARE wl SMALLINT;
DECLARE f DOUBLE PRECISION; DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT;
BEGIN
  SELECT e.x, e.y, e.z, e.vx, e.vy, e.vz, e.flags, e.waterlevel FROM ents e WHERE e.id = :eid
    INTO ox, oy, oz, ovx, ovy, ovz, flags, wl;
  oldonground = IIF(BIN_AND(flags, 512) <> 0, 1, 0);
  UPDATE ents e SET e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :eid;
  EXECUTE PROCEDURE fly_move(eid, dt) RETURNING_VALUES clip, hit;
  IF (BIN_AND(clip, 2) = 0) THEN EXIT;                   -- move looks good
  IF (oldonground = 0 AND wl = 0) THEN EXIT;             -- don't stair up while jumping
  IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid)) THEN EXIT;

  SELECT e.x, e.y, e.z, e.vx, e.vy, e.vz FROM ents e WHERE e.id = :eid INTO nsx, nsy, nsz, nsvx, nsvy, nsvz;
  -- try moving up and forward
  UPDATE ents e SET e.x = :ox, e.y = :oy, e.z = :oz, e.vx = :ovx, e.vy = :ovy, e.vz = :ovz WHERE e.id = :eid;
  EXECUTE PROCEDURE push_entity(eid, 0, 0, 18) RETURNING_VALUES f, nx, ny, nz, als, sts, hit;
  UPDATE ents e SET e.vx = :ovx, e.vy = :ovy, e.vz = 0 WHERE e.id = :eid;
  EXECUTE PROCEDURE fly_move(eid, dt) RETURNING_VALUES clip, hit;
  -- press down the step height
  EXECUTE PROCEDURE push_entity(eid, 0, 0, -18 + ovz * dt) RETURNING_VALUES f, nx, ny, nz, als, sts, hit;
  IF (nz > 0.7e0 AND f < 1) THEN
  BEGIN
    UPDATE ents e SET e.flags = BIN_OR(e.flags, 512) WHERE e.id = :eid;
  END
  ELSE
  BEGIN
    -- the step didn't land on ground: use the move without it
    UPDATE ents e SET e.x = :nsx, e.y = :nsy, e.z = :nsz, e.vx = :nsvx, e.vy = :nsvy, e.vz = :nsvz WHERE e.id = :eid;
  END
END^

-- SV_movestep for monsters: move horizontally, then settle onto the floor
-- within one step up or down. Returns 1 if the move was taken.
CREATE OR ALTER FUNCTION move_step (eid INTEGER, dx DOUBLE PRECISION, dy DOUBLE PRECISION, dz DOUBLE PRECISION)
RETURNS SMALLINT
AS
DECLARE px DOUBLE PRECISION; DECLARE py DOUBLE PRECISION; DECLARE pz DOUBLE PRECISION;
DECLARE mnx DOUBLE PRECISION; DECLARE mny DOUBLE PRECISION; DECLARE mnz DOUBLE PRECISION;
DECLARE mxx DOUBLE PRECISION; DECLARE mxy DOUBLE PRECISION; DECLARE mxz DOUBLE PRECISION;
DECLARE flags INTEGER; DECLARE enemy INTEGER; DECLARE ez_ DOUBLE PRECISION;
DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE pnx DOUBLE PRECISION; DECLARE pny DOUBLE PRECISION; DECLARE pnz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE io SMALLINT; DECLARE iw SMALLINT; DECLARE hit INTEGER;
DECLARE i INTEGER; DECLARE dzz DOUBLE PRECISION;
BEGIN
  SELECT e.x, e.y, e.z, e.minx, e.miny, e.minz, e.maxx, e.maxy, e.maxz, e.flags, e.enemy_id
    FROM ents e WHERE e.id = :eid INTO px, py, pz, mnx, mny, mnz, mxx, mxy, mxz, flags, enemy;
  nx = px + dx; ny = py + dy; nz = pz + dz;

  -- flying and swimming monsters don't step up and down stairs
  IF (BIN_AND(flags, 3) <> 0) THEN
  BEGIN
    i = 0;
    WHILE (i < 2) DO
    BEGIN
      nx = px + dx; ny = py + dy; nz = pz + dz;
      IF (i = 0 AND enemy IS NOT NULL AND enemy > 0) THEN
      BEGIN
        SELECT e.z FROM ents e WHERE e.id = :enemy INTO ez_;
        dzz = pz - COALESCE(ez_, pz);
        IF (dzz > 40) THEN nz = nz - 8;
        IF (dzz < 30) THEN nz = nz + 8;
      END
      EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, px, py, pz, nx, ny, nz, 0)
        RETURNING_VALUES f, ex, ey, ez, pnx, pny, pnz, als, sts, io, iw, hit;
      IF (f = 1) THEN
      BEGIN
        IF (BIN_AND(flags, 2) <> 0 AND point_contents(ex, ey, ez) = -1) THEN RETURN 0;   -- swim monster left water
        UPDATE ents e SET e.x = :ex, e.y = :ey, e.z = :ez WHERE e.id = :eid;
        EXECUTE PROCEDURE link_ent(eid);
        RETURN 1;
      END
      IF (enemy IS NULL OR enemy = 0) THEN LEAVE;
      i = i + 1;
    END
    RETURN 0;
  END

  -- push down from a step height above the wished position
  nz = nz + 18;
  EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, nx, ny, nz, nx, ny, nz - 36, 0)
    RETURNING_VALUES f, ex, ey, ez, pnx, pny, pnz, als, sts, io, iw, hit;
  IF (als = 1) THEN RETURN 0;
  IF (sts = 1) THEN
  BEGIN
    nz = nz - 18;
    EXECUTE PROCEDURE trace_move(eid, mnx, mny, mnz, mxx, mxy, mxz, nx, ny, nz, nx, ny, nz - 36, 0)
      RETURNING_VALUES f, ex, ey, ez, pnx, pny, pnz, als, sts, io, iw, hit;
    IF (als = 1 OR sts = 1) THEN RETURN 0;
  END
  IF (f = 1) THEN
  BEGIN
    -- if monster had the ground pulled out, go ahead and fall
    IF (BIN_AND(flags, 1024) <> 0) THEN
    BEGIN
      UPDATE ents e SET e.x = e.x + :dx, e.y = e.y + :dy, e.flags = BIN_AND(e.flags, BIN_NOT(512)) WHERE e.id = :eid;
      EXECUTE PROCEDURE link_ent(eid);
      RETURN 1;
    END
    RETURN 0;                 -- walked off an edge
  END
  -- the move is ok; a step onto something that isn't the world is fine too
  UPDATE ents e SET e.x = :ex, e.y = :ey, e.z = :ez, e.flags = BIN_OR(BIN_AND(e.flags, BIN_NOT(1024)), 512) WHERE e.id = :eid;
  EXECUTE PROCEDURE link_ent(eid);
  RETURN 1;
END^

-- SV_Physics_Toss: gravity, fly, bounce or stop. Missiles fly straight.
CREATE OR ALTER PROCEDURE toss_move (eid INTEGER, dt DOUBLE PRECISION)
AS
DECLARE mt SMALLINT; DECLARE flags INTEGER;
DECLARE vx DOUBLE PRECISION; DECLARE vy DOUBLE PRECISION; DECLARE vz DOUBLE PRECISION;
DECLARE f DOUBLE PRECISION; DECLARE nx DOUBLE PRECISION; DECLARE ny DOUBLE PRECISION; DECLARE nz DOUBLE PRECISION;
DECLARE als SMALLINT; DECLARE sts SMALLINT; DECLARE hit INTEGER;
DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION; DECLARE cb SMALLINT;
DECLARE backoff DOUBLE PRECISION;
BEGIN
  SELECT e.movetype, e.flags, e.vx, e.vy, e.vz FROM ents e WHERE e.id = :eid INTO mt, flags, vx, vy, vz;
  IF (BIN_AND(flags, 512) <> 0 AND mt <> 9) THEN EXIT;       -- resting on the ground
  IF (mt IN (6, 10)) THEN vz = vz - (SELECT g.gravity FROM game g WHERE g.id = 1) * dt;   -- SV_AddGravity (toss, bounce)
  UPDATE ents e SET e.vz = :vz, e.yaw = MOD(e.yaw + e.avel_yaw * :dt + 360, 360) WHERE e.id = :eid;
  EXECUTE PROCEDURE push_entity(eid, vx * dt, vy * dt, vz * dt) RETURNING_VALUES f, nx, ny, nz, als, sts, hit;
  IF (NOT EXISTS (SELECT 1 FROM ents e WHERE e.id = :eid)) THEN EXIT;
  EXECUTE PROCEDURE link_ent(eid);
  IF (f = 1) THEN EXIT;
  backoff = IIF(mt = 10, 1.5e0, 1);
  EXECUTE PROCEDURE clip_velocity(vx, vy, vz, nx, ny, nz, backoff) RETURNING_VALUES ox, oy, oz, cb;
  -- stop if on ground
  IF (nz > 0.7e0) THEN
  BEGIN
    IF (oz < 60 OR mt <> 10) THEN
    BEGIN
      UPDATE ents e SET e.flags = BIN_OR(e.flags, 512), e.vx = 0, e.vy = 0, e.vz = 0, e.avel_yaw = 0 WHERE e.id = :eid;
      EXIT;
    END
  END
  UPDATE ents e SET e.vx = :ox, e.vy = :oy, e.vz = :oz WHERE e.id = :eid;
END^

SET TERM ; ^
