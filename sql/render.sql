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
         kx DOUBLE PRECISION, ky DOUBLE PRECISION, pvs VARCHAR(2048) CHARACTER SET ASCII, leaf INTEGER)
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

-- the marked faces (PSQL has no arrays; Quake has visframe): the world's
-- faces in the PVS of the leaf the eye is in (kept until the eye moves to
-- another leaf) at origin 0, and each visible brush model's at its own
CREATE TABLE vis_faces (
  face   INTEGER NOT NULL,
  ent_id INTEGER NOT NULL,
  ox DOUBLE PRECISION NOT NULL, oy DOUBLE PRECISION NOT NULL, oz DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ent_id, face)
);

-- the faces that survive this frame's back-face and frustum tests
CREATE GLOBAL TEMPORARY TABLE sel_faces (
  face   INTEGER NOT NULL,
  ent_id INTEGER NOT NULL,
  ox DOUBLE PRECISION NOT NULL, oy DOUBLE PRECISION NOT NULL, oz DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (ent_id, face)
) ON COMMIT DELETE ROWS;

SET TERM ^ ;

-- mark_faces: R_MarkLeaves. Once per view leaf, every face of every leaf in
-- the PVS goes into VIS_FACES at origin 0 (kept until the eye moves to
-- another leaf); every frame, the brush-model entities whose leaves are in
-- the PVS are added at their own origin.
CREATE OR ALTER PROCEDURE mark_faces (pvs VARCHAR(2048) CHARACTER SET ASCII, vleaf INTEGER)
AS
DECLARE cur INTEGER; DECLARE world INTEGER;
DECLARE eid INTEGER; DECLARE emid INTEGER; DECLARE ox DOUBLE PRECISION; DECLARE oy DOUBLE PRECISION; DECLARE oz DOUBLE PRECISION;
DECLARE leafs VARCHAR(200) CHARACTER SET ASCII; DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE lf INTEGER;
BEGIN
  SELECT g.world_model FROM game g WHERE g.id = 1 INTO world;
  SELECT c.vis_leaf FROM viewcfg c WHERE c.id = 1 INTO cur;
  IF (cur IS DISTINCT FROM vleaf) THEN
  BEGIN
    DELETE FROM vis_faces;
    INSERT INTO vis_faces (face, ent_id, ox, oy, oz)
    SELECT DISTINCT m.face, 0, 0, 0, 0
      FROM leaves l
      JOIN marksurfaces m ON m.id >= l.first_ms AND m.id < l.first_ms + l.num_ms
     WHERE l.id > 0 AND l.contents <> -2 AND l.num_ms > 0
       AND (:pvs = '' OR BIN_AND(POSITION(SUBSTRING(:pvs FROM BIN_SHR(l.id - 1, 2) + 1 FOR 1), '0123456789abcdef') - 1, BIN_SHL(1, BIN_AND(l.id - 1, 3))) <> 0);
    UPDATE viewcfg c SET c.vis_leaf = :vleaf WHERE c.id = 1;
  END
  ELSE DELETE FROM vis_faces v WHERE v.ent_id <> 0;

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
      INSERT INTO vis_faces (face, ent_id, ox, oy, oz) SELECT f.id, :eid, :ox, :oy, :oz FROM faces f WHERE f.model_id = :emid;
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
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII; DECLARE vleaf INTEGER;
DECLARE qx DOUBLE PRECISION; DECLARE qy DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;
  qx = SQRT(1 + kx * kx); qy = SQRT(1 + ky * ky);
  EXECUTE PROCEDURE mark_faces(pvs, vleaf);
  FOR SELECT v.face, v.ent_id, v.ox, v.oy, v.oz
        FROM vis_faces v
        JOIN faces f ON f.id = v.face
       WHERE f.nx * (:ex - v.ox) + f.ny * (:ey - v.oy) + f.nz * (:ez - v.oz) - f.dist > 0
         AND (f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz + f.radius >= :nearz
         AND ABS((f.cx + v.ox - :ex) * :rx + (f.cy + v.oy - :ey) * :ry + (f.cz + v.oz - :ez) * :rz)
             <= ((f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz) * :kx + f.radius * :qx
         AND ABS((f.cx + v.ox - :ex) * :ux + (f.cy + v.oy - :ey) * :uy + (f.cz + v.oz - :ez) * :uz)
             <= ((f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz) * :ky + f.radius * :qy
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
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII; DECLARE vleaf INTEGER;
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
  SELECT v.face, v.ent_id, v.ox, v.oy, v.oz
    FROM vis_faces v
    JOIN faces f ON f.id = v.face
   WHERE f.nx * (:ex - v.ox) + f.ny * (:ey - v.oy) + f.nz * (:ez - v.oz) - f.dist > 0
     AND (f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz + f.radius >= :nearz
     AND ABS((f.cx + v.ox - :ex) * :rx + (f.cy + v.oy - :ey) * :ry + (f.cz + v.oz - :ez) * :rz)
         <= ((f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz) * :kx + f.radius * :qx
     AND ABS((f.cx + v.ox - :ex) * :ux + (f.cy + v.oy - :ey) * :uy + (f.cz + v.oz - :ez) * :uz)
         <= ((f.cx + v.ox - :ex) * :fx + (f.cy + v.oy - :ey) * :fy + (f.cz + v.oz - :ez) * :fz) * :ky + f.radius * :qy;

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

-- the alias models and sprites to draw: entities in the PVS, with their pose
CREATE OR ALTER PROCEDURE frame_ents
RETURNS (id INTEGER, model_id INTEGER, frame INTEGER, skin INTEGER,
         x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION,
         pitch DOUBLE PRECISION, yaw DOUBLE PRECISION, roll DOUBLE PRECISION,
         effects INTEGER, alpha SMALLINT, kind CHAR(1), flags INTEGER)
AS
DECLARE pvs VARCHAR(2048) CHARACTER SET ASCII; DECLARE pe INTEGER; DECLARE leafs VARCHAR(200) CHARACTER SET ASCII;
DECLARE p INTEGER; DECLARE q INTEGER; DECLARE vis SMALLINT; DECLARE lf INTEGER;
DECLARE ex DOUBLE PRECISION; DECLARE ey DOUBLE PRECISION; DECLARE ez DOUBLE PRECISION;
DECLARE fx DOUBLE PRECISION; DECLARE fy DOUBLE PRECISION; DECLARE fz DOUBLE PRECISION;
DECLARE rx DOUBLE PRECISION; DECLARE ry DOUBLE PRECISION; DECLARE rz DOUBLE PRECISION;
DECLARE ux DOUBLE PRECISION; DECLARE uy DOUBLE PRECISION; DECLARE uz DOUBLE PRECISION;
DECLARE w INTEGER; DECLARE h INTEGER; DECLARE sc DOUBLE PRECISION; DECLARE nearz DOUBLE PRECISION;
DECLARE kx DOUBLE PRECISION; DECLARE ky DOUBLE PRECISION; DECLARE vleaf INTEGER;
DECLARE radius DOUBLE PRECISION; DECLARE cf DOUBLE PRECISION;
BEGIN
  EXECUTE PROCEDURE view_setup RETURNING_VALUES ex, ey, ez, fx, fy, fz, rx, ry, rz, ux, uy, uz, w, h, sc, nearz, kx, ky, pvs, vleaf;
  pe = player_ent();
  FOR SELECT e.id, e.model_id, e.frame, e.skin, e.x, e.y, e.z, e.pitch, e.yaw, e.roll, e.effects, e.alpha, m.kind, e.flags, e.leaf, e.leafs,
             MAXVALUE(m.radius, vlen(e.maxx - e.minx, e.maxy - e.miny, e.maxz - e.minz) / 2)
        FROM ents e JOIN models m ON m.id = e.model_id
       WHERE m.kind IN ('M', 'S') AND e.id <> :pe
        INTO id, model_id, frame, skin, x, y, z, pitch, yaw, roll, effects, alpha, kind, flags, lf, leafs, radius
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
