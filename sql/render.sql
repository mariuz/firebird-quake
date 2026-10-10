-- render.sql – r_bsp.c, r_surf.c and r_alias.c as a query.
--
-- FRAME_FACES is the frame: for the leaf the eye is in, every leaf in its
-- PVS that is in front of the camera is marked, their faces are collected
-- (DISTINCT, like Quake's visframe marking), back faces are dropped and the
-- survivors are transformed to view space, clipped to the near plane and
-- projected. One row per polygon vertex: screen x/y, depth, and the texel
-- coordinates (s, t) that texinfo gives that point. Brush-model entities
-- (doors, plats, ammo boxes) are added the same way at their own origin.
-- JavaScript rasterises the polygons: perspective-correct texturing from
-- the miptex plus the face's lightmap, exactly Quake's surface cache.
--
-- FRAME_ENTS lists the alias models and sprites in the PVS: the browser
-- transforms their vertices (an MDL frame is ~200 vertices; shipping them
-- through SQL every frame would be the one thing slower than drawing them).

SET TERM ^ ;

CREATE OR ALTER PROCEDURE view_setup
RETURNS (ex DOUBLE PRECISION, ey DOUBLE PRECISION, ez DOUBLE PRECISION,
         fx DOUBLE PRECISION, fy DOUBLE PRECISION, fz DOUBLE PRECISION,
         rx DOUBLE PRECISION, ry DOUBLE PRECISION, rz DOUBLE PRECISION,
         ux DOUBLE PRECISION, uy DOUBLE PRECISION, uz DOUBLE PRECISION,
         w INTEGER, h INTEGER, scale_ DOUBLE PRECISION, nearz DOUBLE PRECISION,
         kx DOUBLE PRECISION, ky DOUBLE PRECISION, pvs d_pvs, leaf INTEGER)
AS
DECLARE yaw DOUBLE PRECISION; DECLARE pitch DOUBLE PRECISION; DECLARE fov DOUBLE PRECISION;
DECLARE sy DOUBLE PRECISION; DECLARE cy DOUBLE PRECISION; DECLARE sp DOUBLE PRECISION; DECLARE cp DOUBLE PRECISION;
DECLARE stepz DOUBLE PRECISION; DECLARE punch DOUBLE PRECISION; DECLARE dead SMALLINT;
BEGIN
  SELECT e.x, e.y, e.z + p.view_ofs, e.yaw, p.pitch + p.punchangle, p.stepz, e.deadflag
    FROM player p JOIN ents e ON e.id = p.ent_id WHERE p.id = 1 INTO ex, ey, ez, yaw, pitch, stepz, dead;
  ez = ez - COALESCE(stepz, 0);
  SELECT c.w, c.h, c.fov, c.near_z FROM viewcfg c WHERE c.id = 1 INTO w, h, fov, nearz;
  sy = SIN(yaw * 0.0174532925e0); cy = COS(yaw * 0.0174532925e0);
  sp = SIN(pitch * 0.0174532925e0); cp = COS(pitch * 0.0174532925e0);
  fx = cp * cy; fy = cp * sy; fz = -sp;
  rx = sy; ry = -cy; rz = 0;
  ux = sp * cy; uy = sp * sy; uz = cp;
  IF (dead = 1) THEN
  BEGIN
    -- the dead lie on their side: roll the view 60 degrees
    sp = rx; cp = ry;
    rx = sp * 0.5e0 + ux * 0.866e0; ry = cp * 0.5e0 + uy * 0.866e0; rz = rz * 0.5e0 + uz * 0.866e0;
    ux = -sp * 0.866e0 + ux * 0.5e0; uy = -cp * 0.866e0 + uy * 0.5e0; uz = uz * 0.5e0;
  END
  scale_ = (w / 2e0) / TAN(fov * 0.5e0 * 0.0174532925e0);
  kx = (w / 2e0) / scale_;
  ky = (h / 2e0) / scale_;
  leaf = point_leaf(ex, ey, ez);
  SELECT l.pvs FROM leaves l WHERE l.id = :leaf INTO pvs;
  IF (pvs IS NULL) THEN pvs = '';
  SUSPEND;
END^

SET TERM ; ^

-- the world's faces in the PVS of each view leaf visited (R_MarkLeaves' result, kept per leaf: the first
-- visit to a leaf marks them, a return to it costs nothing), emptied with the map by loadMap. Each row
-- carries the face's plane and bounding sphere, so the frame queries cull without a join to faces
CREATE TABLE leaf_faces (
  vleaf INTEGER NOT NULL,
  face  INTEGER NOT NULL,
  nx DOUBLE PRECISION NOT NULL, ny DOUBLE PRECISION NOT NULL, nz DOUBLE PRECISION NOT NULL, dist DOUBLE PRECISION NOT NULL,
  cx DOUBLE PRECISION NOT NULL, cy DOUBLE PRECISION NOT NULL, cz DOUBLE PRECISION NOT NULL, radius DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (vleaf, face)
);
CREATE TABLE leaf_marked (
  vleaf INTEGER NOT NULL PRIMARY KEY
);

-- the visible brush-model entities' faces, each at its entity's origin, with the plane and sphere as in
-- leaf_faces (PSQL has no arrays; Quake has visframe); the world's are in leaf_faces under viewcfg.vis_leaf.
-- Rebuilt by mark_faces when the view leaf changes or a brush entity moved, appeared or went: vis_ents
-- is every brush entity as it was when vis_faces was last built
CREATE TABLE vis_faces (
  face   INTEGER NOT NULL,
  ent_id INTEGER NOT NULL,
  ox DOUBLE PRECISION NOT NULL, oy DOUBLE PRECISION NOT NULL, oz DOUBLE PRECISION NOT NULL,
  nx DOUBLE PRECISION NOT NULL, ny DOUBLE PRECISION NOT NULL, nz DOUBLE PRECISION NOT NULL, dist DOUBLE PRECISION NOT NULL,
  cx DOUBLE PRECISION NOT NULL, cy DOUBLE PRECISION NOT NULL, cz DOUBLE PRECISION NOT NULL, radius DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ent_id, face)
);
CREATE TABLE vis_ents (
  ent_id   INTEGER NOT NULL PRIMARY KEY,
  model_id INTEGER NOT NULL,
  x DOUBLE PRECISION NOT NULL, y DOUBLE PRECISION NOT NULL, z DOUBLE PRECISION NOT NULL
);

-- the faces that survive this frame's back-face and frustum tests
CREATE GLOBAL TEMPORARY TABLE sel_faces (
  face   INTEGER NOT NULL,
  ent_id INTEGER NOT NULL,
  ox DOUBLE PRECISION NOT NULL, oy DOUBLE PRECISION NOT NULL, oz DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ent_id, face)
) ON COMMIT DELETE ROWS;

SET TERM ^ ;

-- mark_faces: R_MarkLeaves. The first time the eye is in a leaf, every face of every leaf in its PVS goes
-- into leaf_faces under it (a return to a leaf finds them there: no 15 ms spike crossing a door again);
-- viewcfg.vis_leaf says which leaf the frame queries read. The brush-model entities whose leaves are in
-- the PVS go into vis_faces at their own origin, built again only when the leaf changed or a brush
-- entity is not as vis_ents last saw it (moved, appeared, went, changed model): a frame where nothing
-- of that happened, which is most of them, keeps the rows.
CREATE OR ALTER PROCEDURE mark_faces (pvs d_pvs, vleaf INTEGER)
AS
DECLARE cur INTEGER; DECLARE world INTEGER; DECLARE changed SMALLINT = 0; DECLARE n1 INTEGER; DECLARE n2 INTEGER;
DECLARE eid INTEGER; DECLARE emid INTEGER; DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION;
DECLARE leafs VARCHAR(200) CHARACTER SET ASCII; DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE lf INTEGER;
BEGIN
  SELECT g.world_model FROM game g WHERE g.id = 1 INTO world;
  SELECT c.vis_leaf FROM viewcfg c WHERE c.id = 1 INTO cur;
  IF (cur IS DISTINCT FROM vleaf) THEN
  BEGIN
    IF (NOT EXISTS (SELECT 1 FROM leaf_marked k WHERE k.vleaf = :vleaf)) THEN
    BEGIN
      INSERT INTO leaf_faces (vleaf, face, nx, ny, nz, dist, cx, cy, cz, radius)
      SELECT DISTINCT :vleaf, m.face, f.nx, f.ny, f.nz, f.dist, f.cx, f.cy, f.cz, f.radius
        FROM leaves l
        JOIN marksurfaces m ON m.id >= l.first_ms AND m.id < l.first_ms + l.num_ms
        JOIN faces f ON f.id = m.face
       WHERE l.id > 0 AND l.contents <> -2 AND l.num_ms > 0
         AND (:pvs = '' OR BIN_AND(POSITION(SUBSTRING(:pvs FROM BIN_SHR(l.id - 1, 2) + 1 FOR 1), '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(l.id - 1, 3))) <> 0);
      INSERT INTO leaf_marked (vleaf) VALUES (:vleaf);
    END
    UPDATE viewcfg c SET c.vis_leaf = :vleaf WHERE c.id = 1;
    changed = 1;
  END
  IF (changed = 0) THEN
  BEGIN
    SELECT COUNT(*) FROM vis_ents INTO n1;
    SELECT COUNT(*) FROM ents e JOIN models m ON m.id = e.model_id WHERE m.kind = 'B' AND e.model_id <> :world INTO n2;
    -- (looked at from vis_ents: a few primary-key probes; the count catches a brush entity that appeared)
    IF (n1 <> n2 OR EXISTS (SELECT 1 FROM vis_ents v LEFT JOIN ents e ON e.id = v.ent_id
                             WHERE e.id IS NULL OR e.model_id <> v.model_id OR e.x <> v.x OR e.y <> v.y OR e.z <> v.z)) THEN
      changed = 1;
  END
  IF (changed = 0) THEN EXIT;
  DELETE FROM vis_faces;
  DELETE FROM vis_ents;
  INSERT INTO vis_ents (ent_id, model_id, x, y, z)
  SELECT e.id, e.model_id, e.x, e.y, e.z FROM ents e JOIN models m ON m.id = e.model_id WHERE m.kind = 'B' AND e.model_id <> :world;

  FOR SELECT e.id, e.model_id, e.x, e.y, e.z, e.leafs FROM ents e JOIN models m ON m.id = e.model_id
       WHERE m.kind = 'B' AND e.model_id <> :world INTO eid, emid, ox, oy, oz, leafs
  DO
  BEGIN
    vis = 0;
    IF (leafs IS NULL OR pvs = '') THEN vis = 1;
    ELSE
    BEGIN
      p = 2;
      WHILE (p <= CHAR_LENGTH(leafs)) DO
      BEGIN
        q = POSITION(',', leafs, p);
        IF (q = 0) THEN LEAVE;
        lf = CAST(SUBSTRING(leafs FROM p FOR q - p) AS INTEGER);
        IF (lf > 0 AND BIN_AND(POSITION(SUBSTRING(pvs FROM BIN_SHR(lf - 1, 2) + 1 FOR 1), '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(lf - 1, 3))) <> 0) THEN BEGIN vis = 1; LEAVE; END
        p = q + 1;
      END
    END
    IF (vis = 1) THEN
      INSERT INTO vis_faces (face, ent_id, ox, oy, oz, nx, ny, nz, dist, cx, cy, cz, radius)
      SELECT f.id, :eid, :ox, :oy, :oz, f.nx, f.ny, f.nz, f.dist, f.cx, f.cy, f.cz, f.radius FROM faces f WHERE f.model_id = :emid;
  END
END^

-- FRAME_FACES_FAST: the faces to draw, one row each. SQL decides what is
-- visible (PVS, back faces, frustum); the painter transforms the vertices it
-- already holds from the BSP. About a tenth of the rows of FRAME_FACES.
CREATE OR ALTER PROCEDURE frame_faces_fast
RETURNS (face INTEGER, ent_id INTEGER, ox DOUBLE PRECISION, oy DOUBLE PRECISION, oz DOUBLE PRECISION)
AS
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE w INTEGER; DECLARE h INTEGER; DECLARE sc DOUBLE PRECISION; DECLARE nearz DOUBLE PRECISION;
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE pvs d_pvs; DECLARE vleaf INTEGER;
DECLARE qx DOUBLE PRECISION; DECLARE qy DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;
  qx = SQRT(1 + kx * kx); qy = SQRT(1 + ky * ky);
  EXECUTE PROCEDURE mark_faces(pvs, vleaf);
  -- the world's faces in the view leaf's PVS, at origin 0
  ent_id = 0; ox = 0; oy = 0; oz = 0;
  FOR SELECT f.face
        -- the leaf's rows carry each face's plane and sphere: no join to faces per candidate
        FROM leaf_faces f
       WHERE f.vleaf = :vleaf AND f.nx * :ex + f.ny * :ey + f.nz * :ez - f.dist > 0
         AND (f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz + f.radius >= :nearz
         AND ABS((f.cx - :ex) * :rx + (f.cy - :ey) * :ry + (f.cz - :ez) * :rz)
             <= ((f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz) * :kx + f.radius * :qx
         AND ABS((f.cx - :ex) * :ux + (f.cy - :ey) * :uy + (f.cz - :ez) * :uz)
             <= ((f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz) * :ky + f.radius * :qy
        INTO face
  DO SUSPEND;
  -- then the visible brush models' faces, each at its entity's origin
  FOR SELECT v.face, v.ent_id, v.ox, v.oy, v.oz
        FROM vis_faces v
       WHERE v.nx * (:ex - v.ox) + v.ny * (:ey - v.oy) + v.nz * (:ez - v.oz) - v.dist > 0
         AND (v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz + v.radius >= :nearz
         AND ABS((v.cx + v.ox - :ex) * :rx + (v.cy + v.oy - :ey) * :ry + (v.cz + v.oz - :ez) * :rz)
             <= ((v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz) * :kx + v.radius * :qx
         AND ABS((v.cx + v.ox - :ex) * :ux + (v.cy + v.oy - :ey) * :uy + (v.cz + v.oz - :ez) * :uz)
             <= ((v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz) * :ky + v.radius * :qy
        INTO face, ent_id, ox, oy, oz
  DO SUSPEND;
END^

-- FRAME_FACES: the same faces, projected vertex by vertex in SQL.
CREATE OR ALTER PROCEDURE frame_faces
RETURNS (face INTEGER, seq INTEGER, vf DOUBLE PRECISION, vr DOUBLE PRECISION, vu DOUBLE PRECISION,
         sx DOUBLE PRECISION, sy DOUBLE PRECISION, s DOUBLE PRECISION, t DOUBLE PRECISION, ent_id INTEGER)
AS
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE w INTEGER; DECLARE h INTEGER; DECLARE sc DOUBLE PRECISION; DECLARE nearz DOUBLE PRECISION;
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE pvs d_pvs; DECLARE vleaf INTEGER;
DECLARE hw DOUBLE PRECISION; DECLARE hh DOUBLE PRECISION; DECLARE qx DOUBLE PRECISION; DECLARE qy DOUBLE PRECISION;
DECLARE vseq INTEGER; DECLARE eid INTEGER; DECLARE fid INTEGER; DECLARE cur INTEGER; DECLARE curent INTEGER;
BEGIN
  EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;
  hw = w / 2e0; hh = h / 2e0;
  qx = SQRT(1 + kx * kx); qy = SQRT(1 + ky * ky);
  EXECUTE PROCEDURE mark_faces(pvs, vleaf);

  -- select the faces that face the eye and whose sphere is in the frustum
  -- (a pass over the marked faces alone: joining the vertices first would
  -- walk every vertex of every face in the PVS), then one cursor over their
  -- vertices. The (face, seq) primary key walks each face's vertices in
  -- order, so no sort is needed. The view transform and the projection are
  -- in the select list: evaluated by the engine, they cost a fraction of the
  -- same arithmetic as PSQL statements. Vertices behind the near plane
  -- project to NULL; the painter clips those edges in view space.
  DELETE FROM sel_faces;
  INSERT INTO sel_faces (face, ent_id, ox, oy, oz)
  SELECT f.face, 0, 0, 0, 0
    FROM leaf_faces f
   WHERE f.vleaf = :vleaf AND f.nx * :ex + f.ny * :ey + f.nz * :ez - f.dist > 0
     AND (f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz + f.radius >= :nearz
     AND ABS((f.cx - :ex) * :rx + (f.cy - :ey) * :ry + (f.cz - :ez) * :rz)
         <= ((f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz) * :kx + f.radius * :qx
     AND ABS((f.cx - :ex) * :ux + (f.cy - :ey) * :uy + (f.cz - :ez) * :uz)
         <= ((f.cx - :ex) * :fx + (f.cy - :ey) * :fy + (f.cz - :ez) * :fz) * :ky + f.radius * :qy;
  INSERT INTO sel_faces (face, ent_id, ox, oy, oz)
  SELECT v.face, v.ent_id, v.ox, v.oy, v.oz
    FROM vis_faces v
   WHERE v.nx * (:ex - v.ox) + v.ny * (:ey - v.oy) + v.nz * (:ez - v.oz) - v.dist > 0
     AND (v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz + v.radius >= :nearz
     AND ABS((v.cx + v.ox - :ex) * :rx + (v.cy + v.oy - :ey) * :ry + (v.cz + v.oz - :ez) * :rz)
         <= ((v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz) * :kx + v.radius * :qx
     AND ABS((v.cx + v.ox - :ex) * :ux + (v.cy + v.oy - :ey) * :uy + (v.cz + v.oz - :ez) * :uz)
         <= ((v.cx + v.ox - :ex) * :fx + (v.cy + v.oy - :ey) * :fy + (v.cz + v.oz - :ez) * :fz) * :ky + v.radius * :qy;

  cur = -1; curent = -1;
  FOR SELECT v.ent_id, f.id, fv.seq,
             (fv.x + v.ox - :ex) * :fx + (fv.y + v.oy - :ey) * :fy + (fv.z + v.oz - :ez) * :fz,
             (fv.x + v.ox - :ex) * :rx + (fv.y + v.oy - :ey) * :ry + (fv.z + v.oz - :ez) * :rz,
             (fv.x + v.ox - :ex) * :ux + (fv.y + v.oy - :ey) * :uy + (fv.z + v.oz - :ez) * :uz,
             fv.x * f.sx + fv.y * f.sy + fv.z * f.sz + f.soff,
             fv.x * f.tx + fv.y * f.ty + fv.z * f.tz + f.toff
        FROM sel_faces v
        JOIN faces f ON f.id = v.face
        JOIN face_verts fv ON fv.face = f.id
        INTO eid, fid, vseq, vf, vr, vu, s, t
  DO
  BEGIN
    IF (fid <> cur OR eid <> curent OR vseq = 0) THEN
    BEGIN
      cur = fid; curent = eid; face = fid; ent_id = eid;
    END
    seq = vseq;
    IF (vf >= nearz) THEN
    BEGIN
      sx = hw + vr * sc / vf; sy = hh - vu * sc / vf;
    END
    ELSE
    BEGIN
      sx = NULL; sy = NULL;
    END
    SUSPEND;
  END
END^

-- a client's colours, top * 16 + bottom: the player's (game.player_colors, set by the console's color) or a
-- bot's (bots.colors); 0 for none (the skin as painted)
CREATE OR ALTER FUNCTION client_colors (c INTEGER) RETURNS SMALLINT
AS
BEGIN
  IF (c = 1) THEN RETURN COALESCE((SELECT g.player_colors FROM game g WHERE g.id = 1), 0);
  RETURN COALESCE((SELECT b.colors FROM bots b WHERE b.c = :c), 0);
END^

-- the alias models and sprites to draw: entities in the PVS, with their pose, and the colours of the client
-- whose colormap a player model or a corpse carries (R_TranslatePlayerSkin: the painter recolours the skin)
CREATE OR ALTER PROCEDURE frame_ents
RETURNS (id INTEGER, model_id INTEGER, frame INTEGER, skin INTEGER,
         x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION,
         pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, roll DOUBLE PRECISION,
         effects INTEGER, alpha SMALLINT, kind CHAR(1), flags INTEGER, colors SMALLINT)
AS
DECLARE pvs d_pvs; DECLARE pe INTEGER; DECLARE leafs VARCHAR(200) CHARACTER SET ASCII;
DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE lf INTEGER;
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE w INTEGER; DECLARE h INTEGER; DECLARE sc DOUBLE PRECISION; DECLARE nearz DOUBLE PRECISION;
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE vleaf INTEGER;
DECLARE radius DOUBLE PRECISION; DECLARE cf DOUBLE PRECISION; DECLARE cm SMALLINT;
BEGIN
  EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;
  pe = player_ent();
  FOR SELECT e.id, e.model_id, e.frame, e.skin, e.x, e.y, e.z, e.pitch, e.yaw, e.roll, e.effects, e.alpha, m.kind, e.flags, e.leaf, e.leafs,
             MAXVALUE(m.radius, vlen(e.maxx - e.minx, e.maxy - e.miny, e.maxz - e.minz) / 2), e.colormap
        FROM ents e JOIN models m ON m.id = e.model_id
       WHERE m.kind IN ('M', 'S') AND e.id <> :pe
        INTO id, model_id, frame, skin, x, y, z, pitch, yaw, roll, effects, alpha, kind, flags, lf, leafs, radius, cm
  DO
  BEGIN
    cf = (x - ex) * fx + (y - ey) * fy + (z - ez) * fz;
    IF (cf + radius + 32 < nearz) THEN CONTINUE;                       -- behind the camera
    IF (ABS((x - ex) * rx + (y - ey) * ry + (z - ez) * rz) > (cf + radius) * kx + radius + 32) THEN CONTINUE;
    vis = 0;
    IF (pvs = '') THEN vis = 1;
    ELSE IF (leafs IS NOT NULL) THEN
    BEGIN
      p = 2;
      WHILE (p <= CHAR_LENGTH(leafs)) DO
      BEGIN
        q = POSITION(',', leafs, p);
        IF (q = 0) THEN LEAVE;
        lf = CAST(SUBSTRING(leafs FROM p FOR q - p) AS INTEGER);
        IF (lf > 0 AND BIN_AND(POSITION(SUBSTRING(pvs FROM BIN_SHR(lf - 1, 2) + 1 FOR 1), '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(lf - 1, 3))) <> 0) THEN BEGIN vis = 1; LEAVE; END
        p = q + 1;
      END
    END
    ELSE vis = pvs_visible(pvs, COALESCE(lf, point_leaf(x, y, z)));
    IF (vis = 0) THEN CONTINUE;
    colors = IIF(cm > 0, client_colors(cm), 0);
    SUSPEND;
  END
END^

SET TERM ; ^

-- the light style values of this frame: 'a'..'z' → 0..2
CREATE OR ALTER VIEW frame_lightstyles AS
SELECT l.style,
       (ASCII_VAL(SUBSTRING(l.pattern FROM 1 + MOD(CAST(FLOOR(g.time_ * 10) AS INTEGER), CHAR_LENGTH(l.pattern)) FOR 1)) - 97) / 12.5e0 AS value_
  FROM lightstyles l CROSS JOIN game g
 WHERE g.id = 1;
