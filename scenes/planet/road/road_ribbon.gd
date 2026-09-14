@tool
class_name RoadRibbon
## The terrain-hugging road SLAB: one strip of one road piece, extruded from
## the centerline as a top face RoadTerrain.SURFACE_THICKNESS_M above the
## ground with two flanks buried RoadTerrain.RIBBON_BURY_M below it.
##
## Shared by the chunk's visual mesh (generate_mesh) and its collision shape
## (generate_collision_shape): both call [method emit_strip] with the same
## stations, the same height sampler and the same lateral interval, so the
## slab the player sees is the slab the server collides with — the contract
## GradeBed.build_piece already honours for a profiled bed.
##
## A road is a LIST of strips (RoadTerrain.lane_layout): a highway's two
## carriageways leave the median gap between them; any other road is one
## strip spanning its whole width.

## How the top face is textured.
enum UvMode {
	## (along / tile_m, offset / tile_m) — the asphalt and path convention.
	FLOW = 0,
	## (offset within the strip / GAUFRAGE_ACROSS_M, along / GAUFRAGE_ALONG_M).
	## The engraved corundum tile's 350 mm axis is its WIDTH, so uv.x runs
	## ACROSS the road; a strip is a whole number of lanes, so u spans
	## 0..n_lanes and the tile's dashed edge lines land on every lane edge.
	LANE = 1,
}


## Top-face UV at [param along_m] metres from the road's start and
## [param off_m] metres from the centerline, for a strip [param strip] (lo, hi).
##
## LANE: the tile is a road marking, read by the driver — the image's
## bottom (uv.y = 1) toward them, its x toward their right. The frame
## (along, perp, up) is LEFT-handed on this planet (see
## RoadTerrain.RIGHT_HAND_TRAFFIC): facing +along, +perp is on the RIGHT.
##   · traffic heading +along: u grows toward +perp, v = -along (the far
##     side, at larger along, is the image's top);
##   · traffic heading -along: u grows toward -perp, v = +along.
## Which carriageway heads which way follows RIGHT_HAND_TRAFFIC; a strip on
## the centerline reads for the +along direction.
static func surface_uv(mode: int, along_m: float, off_m: float, strip: Vector2,
		tile_m: float) -> Vector2:
	if mode == UvMode.LANE:
		if travels_along(strip):
			return Vector2((off_m - strip.x) / RoadTerrain.GAUFRAGE_ACROSS_M,
					-along_m / RoadTerrain.GAUFRAGE_ALONG_M)
		return Vector2((strip.y - off_m) / RoadTerrain.GAUFRAGE_ACROSS_M,
				along_m / RoadTerrain.GAUFRAGE_ALONG_M)
	return Vector2(along_m / tile_m, off_m / tile_m)


## Does traffic on [param strip] head +along (toward the road's end)?
static func travels_along(strip: Vector2) -> bool:
	var centre := strip.x + strip.y
	if absf(centre) < 1e-6:
		return true
	return (centre > 0.0) == RoadTerrain.RIGHT_HAND_TRAFFIC


## Flank UV, [param drop_m] metres below the top edge.
static func flank_uv(mode: int, along_m: float, drop_m: float, tile_m: float) -> Vector2:
	if mode == UvMode.LANE:
		return Vector2(drop_m / RoadTerrain.GAUFRAGE_ACROSS_M,
				along_m / RoadTerrain.GAUFRAGE_ALONG_M)
	return Vector2(along_m / tile_m, drop_m / tile_m)


## Extrude one strip of one road piece as a slab.
##
## [param cl] / [param cum]: the piece's centerline (lon/lat degrees) and the
## along-road distance of each point from the road's TRUE start (the pack
## carries it so the texture runs continuously across chunk boundaries); a
## legacy zone without `cum` accumulates from the piece's start instead.
## [param strip]: (lo, hi) lateral offsets in metres, RoadTerrain.lane_layout
## convention — positive is the `+perp` side.
## [param max_seg_deg]: station pitch, in degrees along the centerline.
## [param height_at]: func(dir: Vector3) -> float, terrain altitude above
## [param radius] — the SAME sampler on the visual and the collision side.
## [param origin]: every position is emitted local to it, snapped to float32
## (the chunk centre for the mesh, the collision origin for the shape).
## [param want_visual]: false builds only the collision faces.
## [param outward]: collision winding, see GradeBed.build_piece.
## [param tint]: func(dir: Vector3) -> Color baked into the vertex colour, or
## an invalid Callable for WHITE.
##
## Returns {verts, norms, uvs, colors, indices, faces}: per station 6 visual
## vertices — top hi/lo, hi flank top/bottom, lo flank top/bottom, each face
## with its own normal — and 3 collision quads per station pair (top, hi
## flank, lo flank).
static func emit_strip(cl: PackedVector2Array, cum: PackedFloat64Array,
		strip: Vector2, m_per_deg: float, radius: float, max_seg_deg: float,
		height_at: Callable, origin: Vector3, want_visual: bool, outward: bool,
		uv_mode: int = UvMode.FLOW, tile_m: float = 8.0,
		tint: Callable = Callable()) -> Dictionary:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	var out := {"verts": verts, "norms": norms, "uvs": uvs, "colors": colors,
			"indices": indices, "faces": faces}
	if cl.size() < 2 or m_per_deg <= 0.0 or max_seg_deg <= 0.0:
		return out
	var have_cum := cum.size() == cl.size()
	var hi_deg := strip.y / m_per_deg
	var lo_deg := strip.x / m_per_deg
	var top_off := RoadTerrain.SURFACE_THICKNESS_M
	var bot_off := -RoadTerrain.RIBBON_BURY_M

	# Stations: top hi/lo and bottom hi/lo, plus the along distance and the
	# radial direction of each.
	var st_th := PackedVector3Array()
	var st_tl := PackedVector3Array()
	var st_bh := PackedVector3Array()
	var st_bl := PackedVector3Array()
	var st_along := PackedFloat64Array()
	var st_dir_h := PackedVector3Array()
	var st_dir_l := PackedVector3Array()
	var along_m := 0.0
	for seg_i in cl.size() - 1:
		var p0 := cl[seg_i]
		var p1 := cl[seg_i + 1]
		var seg_dir := p1 - p0
		var seg_len_deg := seg_dir.length()
		if seg_len_deg < 1e-12:
			continue
		# Metric perpendicular: rotating the raw lon/lat delta is NOT a
		# rotation (see RoadTerrain.perp_deg).
		var perp := RoadTerrain.perp_deg(p0, p1)
		if perp == Vector2.ZERO:
			continue
		var n_sub := maxi(1, ceili(seg_len_deg / max_seg_deg))
		var a0: float = cum[seg_i] if have_cum else along_m
		var a1: float = cum[seg_i + 1] if have_cum else along_m + seg_len_deg * m_per_deg
		for sub_j in n_sub + 1:
			# The end station belongs to the next segment, except on the last one.
			if sub_j == n_sub and seg_i < cl.size() - 2:
				continue
			var frac := float(sub_j) / float(n_sub)
			var pt := p0 + seg_dir * frac
			var pt_h := pt + perp * hi_deg
			var pt_l := pt + perp * lo_deg
			var dh := RoadBridge.lonlat_to_dir(pt_h.x, pt_h.y)
			var dl := RoadBridge.lonlat_to_dir(pt_l.x, pt_l.y)
			var hh: float = float(height_at.call(dh))
			var hl: float = float(height_at.call(dl))
			st_th.append(PlanetChunk.snap_to_f32(dh * (radius + hh + top_off) - origin))
			st_tl.append(PlanetChunk.snap_to_f32(dl * (radius + hl + top_off) - origin))
			st_bh.append(PlanetChunk.snap_to_f32(dh * (radius + hh + bot_off) - origin))
			st_bl.append(PlanetChunk.snap_to_f32(dl * (radius + hl + bot_off) - origin))
			st_along.append(a0 + (a1 - a0) * frac)
			st_dir_h.append(dh)
			st_dir_l.append(dl)
		along_m += seg_len_deg * m_per_deg
	var n := st_th.size()
	if n < 2:
		return out

	# Collision: top, hi flank, lo flank — the GradeBed quad convention.
	for k in n - 1:
		quad_faces(faces, st_th[k], st_th[k + 1], st_tl[k], st_tl[k + 1], outward)
		quad_faces(faces, st_bh[k], st_bh[k + 1], st_th[k], st_th[k + 1], outward)
		quad_faces(faces, st_tl[k], st_tl[k + 1], st_bl[k], st_bl[k + 1], outward)
	if not want_visual:
		return out

	var tinted := tint.is_valid()
	for k in n:
		var dh: Vector3 = st_dir_h[k]
		var dl: Vector3 = st_dir_l[k]
		var side: Vector3 = (st_th[k] - st_tl[k]).normalized()
		var along: float = st_along[k]
		var drop_h: float = st_th[k].distance_to(st_bh[k])
		var drop_l: float = st_tl[k].distance_to(st_bl[k])
		var col_h: Color = tint.call(dh) if tinted else Color.WHITE
		var col_l: Color = tint.call(dl) if tinted else Color.WHITE
		# Top hi / lo.
		verts.append(st_th[k]); norms.append(dh)
		uvs.append(surface_uv(uv_mode, along, strip.y, strip, tile_m)); colors.append(col_h)
		verts.append(st_tl[k]); norms.append(dl)
		uvs.append(surface_uv(uv_mode, along, strip.x, strip, tile_m)); colors.append(col_l)
		# Hi flank top / bottom.
		verts.append(st_th[k]); norms.append(side)
		uvs.append(flank_uv(uv_mode, along, 0.0, tile_m)); colors.append(col_h)
		verts.append(st_bh[k]); norms.append(side)
		uvs.append(flank_uv(uv_mode, along, drop_h, tile_m)); colors.append(col_h)
		# Lo flank top / bottom.
		verts.append(st_tl[k]); norms.append(-side)
		uvs.append(flank_uv(uv_mode, along, 0.0, tile_m)); colors.append(col_l)
		verts.append(st_bl[k]); norms.append(-side)
		uvs.append(flank_uv(uv_mode, along, drop_l, tile_m)); colors.append(col_l)
	for k in n - 1:
		var a := k * 6
		var b := a + 6
		quad_indices(indices, a, b, a + 1, b + 1)          # top
		quad_indices(indices, a + 3, b + 3, a + 2, b + 2)  # hi flank (bottom → top)
		quad_indices(indices, a + 4, b + 4, a + 5, b + 5)  # lo flank (top → bottom)
	return out


## Two collision triangles for the quad (a0, a1) × (b0, b1), wound so the
## front faces [param outward] (or not) — the chunk grid's own convention.
static func quad_faces(faces: PackedVector3Array, a0: Vector3, a1: Vector3,
		b0: Vector3, b1: Vector3, outward: bool) -> void:
	if outward:
		faces.append(a0); faces.append(a1); faces.append(b0)
		faces.append(b0); faces.append(a1); faces.append(b1)
	else:
		faces.append(a0); faces.append(b0); faces.append(a1)
		faces.append(b0); faces.append(b1); faces.append(a1)


## Two visual triangles for the quad (a0, a1) × (b0, b1), as vertex indices.
static func quad_indices(indices: PackedInt32Array, a0: int, a1: int,
		b0: int, b1: int) -> void:
	indices.append(a0); indices.append(a1); indices.append(b0)
	indices.append(b0); indices.append(a1); indices.append(b1)
