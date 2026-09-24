@tool
class_name GradeBed
## The bed of a grade-limited line — a railway's ballast, a graded road's
## asphalt — and the ground's answer to it.
##
## Two jobs, one file, because they must agree to the bit:
##
##   · [method build_piece] extrudes the bed along a chunk's stretch of track
##     at the PROFILE's altitude (GradeProfile.z_track_at), not the terrain's:
##     a level top the width of the bed plus two skirts falling to the
##     ground (or SKIRT_BURY_M under it) so a shallow dip shows no daylight
##     under the line. The same function yields the visual arrays and the
##     collision triangles, so what is drawn is what is walked on.
##
##   · [method apply] is the per-vertex terrain rule: where a cutting runs, a
##     grid vertex inside its band is lowered to the cutting's floor or wall.
##     The same context also carries the TERRAIN PADS under the buildings
##     (PadBed), applied after the cutting on what it left: they share the
##     finest-grid gate, the chunk-plus-neighbours reach and the refinement
##     patch, so a chunk holding both carves both or neither and the two
##     never disagree on a shared vertex.
##     It runs in BOTH PlanetChunk vertex loops (mesh and collision) on the
##     pieces of the chunk AND its eight neighbours — road records are an exact
##     partition per HEALPix pixel, so a vertex near a pixel edge would
##     otherwise not see the track just across it, and the two chunks sharing
##     that edge would carve it differently.



## The grade-limited records among [param roads] (railways, graded roads).
static func profiled_pieces(roads: Array) -> Array:
	var out: Array = []
	for r in roads:
		if GradeSettings.is_profiled(r):
			out.append(r)
	return out


## Profiled pieces of the chunk (hp_nside, hp_ipix) plus its eight neighbours,
## deduplicated — the candidate set of every vertex the chunk owns.
static func gather_pieces(data: PlanetData, hp_nside: int, hp_ipix: int) -> Array:
	var out: Array = []
	var seen := {}
	var pix: Array = [hp_ipix]
	for nb in HEALPix.get_neighbors_nest(hp_nside, hp_ipix).values():
		if int(nb) >= 0:
			pix.append(int(nb))
	for ip in pix:
		for r in data.get_roads_for_chunk(hp_nside, int(ip)):
			if not GradeSettings.is_profiled(r):
				continue
			var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
			if cum.is_empty():
				continue
			var key := "%d_%.3f" % [int(r.get("feature_id", -1)), cum[0]]
			if seen.has(key):
				continue
			seen[key] = true
			out.append(r)
	return out


## Cuttings are carved only into the FINEST grid, and only when that grid is
## fine enough to show one — on/off, never faded, so the LOD0 mesh and the
## fine collision (same grid) carve identically. Coarser LODs stay untouched:
## their skirt hides the step against a carved neighbour.
static func carve_enabled(data: PlanetData, hp_nside: int, vtx_spacing_m: float) -> bool:
	if hp_nside <= 0 or hp_nside != (1 << maxi(data.max_quadtree_depth, 0)):
		return false
	return vtx_spacing_m > 0.0 and vtx_spacing_m <= GradeSettings.CARVE_MAX_VTX_SPACING_M


## The per-chunk context of [method apply]: {} when this chunk has nothing to
## carve (no profiled line nearby, or the grid is too coarse).
static func make_ctx(data: PlanetData, hp_nside: int, hp_ipix: int,
		vtx_spacing_m: float) -> Dictionary:
	if not (data.has_profiled_lines() or data.has_pads()) \
			or not carve_enabled(data, hp_nside, vtx_spacing_m):
		return {}
	var ctx := _gather_ctx(data, hp_nside, hp_ipix)
	if not ctx.is_empty():
		ctx["floor_margin"] = floor_margin_m(vtx_spacing_m)
	return ctx


## The context of the COARSE-LOD shave: on a grid too coarse for the cutting
## (every visual LOD but the finest), the terrain within half-width + 1.5
## vertex pitches of a line is clamped to the bed top on ground / cutting
## runs, so the bed is not pierced by an uncarved surface interpolated from
## vertices metres above it. Visual only — the collision is always built on
## the fine grid with make_ctx() — and never wider than the true cutting
## would be at that pitch. {} when nothing is nearby or the fine carve applies.
static func make_coarse_ctx(data: PlanetData, hp_nside: int, hp_ipix: int,
		vtx_spacing_m: float) -> Dictionary:
	if not (data.has_profiled_lines() or data.has_pads()) or vtx_spacing_m <= 0.0 \
			or carve_enabled(data, hp_nside, vtx_spacing_m):
		return {}
	var ctx := _gather_ctx(data, hp_nside, hp_ipix)
	if not ctx.is_empty():
		ctx["coarse_band_m"] = 1.5 * vtx_spacing_m
	return ctx


static func _gather_ctx(data: PlanetData, hp_nside: int, hp_ipix: int) -> Dictionary:
	var pieces: Array = []
	var profiles := {}
	if data.has_profiled_lines():
		for r in gather_pieces(data, hp_nside, hp_ipix):
			var fid := int(r.get("feature_id", -1))
			if not profiles.has(fid):
				profiles[fid] = data.get_grade_profile(fid)
			if (profiles[fid] as Dictionary).is_empty():
				continue
			pieces.append(r)
	var pads: Array = data.pads_for_chunk(hp_nside, hp_ipix) if data.has_pads() else []
	if pieces.is_empty() and pads.is_empty():
		return {}
	return {"pieces": pieces, "profiles": profiles, "pads": pads,
			"m_per_deg": data.radius * PI / 180.0}


## How far the cutting's flat floor reaches past the bed, for a grid whose
## refined sub-cells are [param vtx_spacing_m] / REFINE_K apart: the wall's
## triangulation starts one sub-cell before its analytic foot, so the foot
## must stand at least that far from the bed.
static func floor_margin_m(vtx_spacing_m: float) -> float:
	return maxf(GradeSettings.GORGE_FLOOR_MARGIN_M,
			vtx_spacing_m / float(GradeSettings.REFINE_K) + 0.3)


## The carved height of a terrain vertex at [param lonlat] whose raw height is
## [param h] (metres above the radius), given [param ctx] from [method make_ctx].
##
## On a GROUND or GORGE run the ground is clamped to the cutting's cross
## section: a level floor GORGE_FLOOR_MARGIN_M past the bed, then a wall
## rising GORGE_WALL_SLOPE per metre. `min` — never raised: where the terrain
## is already below the track nothing happens (that is the skirts' or the
## viaduct's business). Tunnel and viaduct runs leave the terrain alone.
##
## Then the pads of [param ctx], if any, level the result (PadBed.apply) —
## those DO raise the ground as well as cut it.
static func apply(h: float, lonlat: Vector2, ctx: Dictionary) -> float:
	if ctx.is_empty():
		return h
	var mpd := float(ctx["m_per_deg"])
	var coarse: bool = ctx.has("coarse_band_m")
	var out := h
	var pieces: Array = ctx.get("pieces", [])
	if not pieces.is_empty():
		var q := GradeGeom.nearest_on_pieces(pieces, lonlat, mpd)
		if q["hit"]:
			var prof: Dictionary = (ctx["profiles"] as Dictionary).get(int(q["fid"]), {})
			if not prof.is_empty():
				if coarse:
					out = shaved_height(out, prof, float(q["along"]), float(q["lat_m"]),
							float(ctx["coarse_band_m"]))
				else:
					out = carved_height(out, prof, float(q["along"]), float(q["lat_m"]),
							float(ctx.get("floor_margin", GradeSettings.GORGE_FLOOR_MARGIN_M)))
	# The pad levels what the cutting left, never the other way round: a
	# building's apron beside a graded road meets the road bed.
	var pads: Array = ctx.get("pads", [])
	if not pads.is_empty():
		if coarse:
			out = PadBed.shaved(out, lonlat, pads, mpd, float(ctx["coarse_band_m"]))
		else:
			out = PadBed.apply(out, lonlat, pads, mpd)
	return out


## The coarse-LOD rule (see make_coarse_ctx): within hw + [param band_m] of
## the line, on ground / cutting runs, the terrain is clamped to the bed top.
static func shaved_height(h: float, prof: Dictionary, along: float, lat_m: float,
		band_m: float) -> float:
	var seg := GradeProfile.segment_at(prof, along)
	if seg.is_empty():
		return h
	var kind := int(seg["kind"])
	if kind != GradeSettings.Kind.GROUND and kind != GradeSettings.Kind.GORGE:
		return h
	if absf(lat_m) > float(prof["hw_m"]) + band_m:
		return h
	return minf(h, GradeProfile.z_track_at(prof, along))


## The cross-section rule of [method apply], on the track-relative
## coordinates (along, lat_m) of a vertex; the flat floor reaches
## [param floor_margin] past the bed.
static func carved_height(h: float, prof: Dictionary, along: float, lat_m: float,
		floor_margin: float = GradeSettings.GORGE_FLOOR_MARGIN_M) -> float:
	var seg := GradeProfile.segment_at(prof, along)
	if seg.is_empty():
		return h
	var kind := int(seg["kind"])
	if kind != GradeSettings.Kind.GROUND and kind != GradeSettings.Kind.GORGE:
		return h
	var hw_floor: float = float(prof["hw_m"]) + floor_margin
	var depth: float = maxf(GradeSettings.TUNNEL_MIN_COVER_M, float(seg["max_depth"]))
	var band: float = hw_floor + depth / GradeSettings.GORGE_WALL_SLOPE \
			+ GradeSettings.GORGE_BAND_MARGIN_M
	var d := absf(lat_m)
	if d > band:
		return h
	var zt := GradeProfile.z_track_at(prof, along)
	var wall := zt + maxf(0.0, d - hw_floor) * GradeSettings.GORGE_WALL_SLOPE
	return minf(h, wall)


## Extrude the bed along one chunk's piece of track.
##
## [param cl]/[param cum] — the piece (absolute along-metres).
## [param profile] — the railway's profile; [param exclusions] — the viaduct
## intervals of that railway (the bed stops at a deck).
## [param sampler] — `func(dir) -> altitude`, for the skirt bottoms.
## [param max_step_m] — longest run between two stations.
## [param origin] — float32-snapped local origin the vertices are stated in.
## [param want_visual] — also build vertices/normals/uvs/indices.
## [param outward] — wind the collision faces so their geometric normal
## points OUT of the bed (true) or into it (false): the caller matches the
## chunk grid's own winding, which PlanetTerrain flips once for the navmesh.
## [param uv_mode] / [param tint] — the top's texturing, see RoadRibbon
## (a highway on the corundum plateau: lane UVs, vertex-tinted).
##
## Returns {verts, norms, uvs, colors, indices, side_indices, faces, median}:
## the first five for a road group (indices are 0-based on `verts`; `indices`
## the top's triangles, `side_indices` the skirts' — so the engraved corundum
## can stay on the top), `faces` the collision triangles, both local to
## [param origin]. `median` is the
## {verts, norms, uvs, indices} of a highway's central strip, for the
## STRUCTURE material's group (empty arrays when the road has no median).
## The collision is always the whole bed: one slab across the median.
static func build_piece(cl: PackedVector2Array, cum: PackedFloat64Array,
		profile: Dictionary, exclusions: Array, m_per_deg: float,
		radius: float, sampler: Callable, max_step_m: float, origin: Vector3,
		want_visual: bool, outward: bool, uv_mode: int = RoadRibbon.UvMode.FLOW,
		tint: Callable = Callable()) -> Dictionary:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var side_indices := PackedInt32Array()
	var faces := PackedVector3Array()
	var md_verts := PackedVector3Array()
	var md_norms := PackedVector3Array()
	var md_uvs := PackedVector2Array()
	var md_indices := PackedInt32Array()
	var median := {"verts": md_verts, "norms": md_norms, "uvs": md_uvs,
			"indices": md_indices}
	var out := {"verts": verts, "norms": norms, "uvs": uvs, "colors": colors,
			"indices": indices, "side_indices": side_indices, "faces": faces,
			"median": median}
	if cl.size() < 2 or cum.size() != cl.size() or profile.is_empty():
		return out
	var hw_m: float = float(profile["hw_m"])
	var hw_deg := hw_m / m_per_deg
	var road_type := str(profile.get("road_type", "railway"))
	var tile_m := RoadTerrain.get_tile_size(road_type)
	var layout := RoadTerrain.lane_layout(road_type, int(profile.get("lanes", 0)), hw_m)
	var strips: Array = layout["strips"]
	var md_strip: Vector2 = layout["median"]
	var has_median := md_strip != Vector2.ZERO
	var tinted := tint.is_valid()
	var step := maxf(max_step_m, 0.5)
	var knots: PackedFloat64Array = profile["knots_along"]
	var seg_lo: PackedFloat64Array = profile["seg_lo"]

	var pieces: Array = [[cl, cum]]
	if not exclusions.is_empty():
		pieces = RoadCut.split(cl, cum, exclusions)

	for piece in pieces:
		var pcl: PackedVector2Array = piece[0]
		var pcum: PackedFloat64Array = piece[1]
		if pcl.size() < 2:
			continue
		# Station positions of this piece: top L/R, skirt bottom L/R, and the
		# frame (centre point, perpendicular, top radius) to place the extra
		# top vertices of a lane layout at any lateral offset.
		var st_tl := PackedVector3Array()
		var st_tr := PackedVector3Array()
		var st_bl := PackedVector3Array()
		var st_br := PackedVector3Array()
		var st_along := PackedFloat64Array()
		var st_up := PackedVector3Array()
		var st_pt := PackedVector2Array()
		var st_perp := PackedVector2Array()
		var st_top := PackedFloat64Array()
		for i in pcl.size() - 1:
			var p0 := pcl[i]
			var p1 := pcl[i + 1]
			var a0: float = pcum[i]
			var a1: float = pcum[i + 1]
			var perp := RoadTerrain.perp_deg(p0, p1)
			if perp == Vector2.ZERO or a1 - a0 <= 1e-9:
				continue
			var alongs := _stations(a0, a1, step, knots, seg_lo, i == pcl.size() - 2)
			for along in alongs:
				var frac: float = (along - a0) / (a1 - a0)
				var pt := p0 + (p1 - p0) * frac
				var zt := GradeProfile.z_track_at(profile, along)
				var pl := pt + perp * hw_deg
				var pr := pt - perp * hw_deg
				var dl := RoadBridge.lonlat_to_dir(pl.x, pl.y)
				var dr := RoadBridge.lonlat_to_dir(pr.x, pr.y)
				var top := radius + zt + RoadTerrain.SURFACE_THICKNESS_M
				var hl: float = float(sampler.call(dl))
				var hr: float = float(sampler.call(dr))
				var bot_l := radius + minf(zt, hl) - GradeSettings.SKIRT_BURY_M
				var bot_r := radius + minf(zt, hr) - GradeSettings.SKIRT_BURY_M
				st_tl.append(PlanetChunk.snap_to_f32(dl * top - origin))
				st_tr.append(PlanetChunk.snap_to_f32(dr * top - origin))
				st_bl.append(PlanetChunk.snap_to_f32(dl * bot_l - origin))
				st_br.append(PlanetChunk.snap_to_f32(dr * bot_r - origin))
				st_along.append(along)
				st_up.append((dl + dr).normalized())
				st_pt.append(pt)
				st_perp.append(perp)
				st_top.append(top)
		var n := st_tl.size()
		if n < 2:
			continue
		# Collision: three quads per station pair — the WHOLE bed, median
		# included (a wheel rolls flat across it).
		for k in n - 1:
			_quad(faces, st_tl[k], st_tl[k + 1], st_tr[k], st_tr[k + 1], outward)
			_quad(faces, st_bl[k], st_bl[k + 1], st_tl[k], st_tl[k + 1], outward)
			_quad(faces, st_tr[k], st_tr[k + 1], st_br[k], st_br[k + 1], outward)
		if not want_visual:
			continue
		# Visual: per station, two top vertices per strip (hi / lo — the +perp
		# side first, like st_tl / st_tr), then left skirt top/bottom and
		# right skirt top/bottom, so each face keeps its own normal.
		var n_strips := strips.size()
		var stride := 2 * n_strips + 4
		var base := verts.size()
		var md_base := md_verts.size()
		for k in n:
			var up: Vector3 = st_up[k]
			var left: Vector3 = (st_tl[k] - st_tr[k]).normalized()
			var along: float = st_along[k]
			var u: float = along / tile_m
			var skirt_l: float = st_tl[k].distance_to(st_bl[k]) / tile_m
			var skirt_r: float = st_tr[k].distance_to(st_br[k]) / tile_m
			var col_l: Color = Color.WHITE
			var col_r: Color = Color.WHITE
			if tinted:
				col_l = tint.call(RoadBridge.lonlat_to_dir(
						st_pt[k].x + st_perp[k].x * hw_deg, st_pt[k].y + st_perp[k].y * hw_deg))
				col_r = tint.call(RoadBridge.lonlat_to_dir(
						st_pt[k].x - st_perp[k].x * hw_deg, st_pt[k].y - st_perp[k].y * hw_deg))
			for strip in strips:
				var s: Vector2 = strip
				for off in [s.y, s.x]:
					var o: float = off
					var t := (o + hw_m) / (2.0 * hw_m)   # 0 at the -hw edge, 1 at +hw
					verts.append(_top_at(st_pt[k], st_perp[k], o, m_per_deg, st_top[k],
							origin, st_tl[k], st_tr[k], hw_m))
					norms.append(up)
					uvs.append(RoadRibbon.surface_uv(uv_mode, along, o, s, tile_m))
					colors.append(col_r.lerp(col_l, t))
			verts.append(st_tl[k]); norms.append(left); colors.append(col_l)
			uvs.append(RoadRibbon.flank_uv(uv_mode, along, 0.0, tile_m))
			verts.append(st_bl[k]); norms.append(left); colors.append(col_l)
			uvs.append(RoadRibbon.flank_uv(uv_mode, along, skirt_l * tile_m, tile_m))
			verts.append(st_tr[k]); norms.append(-left); colors.append(col_r)
			uvs.append(RoadRibbon.flank_uv(uv_mode, along, 0.0, tile_m))
			verts.append(st_br[k]); norms.append(-left); colors.append(col_r)
			uvs.append(RoadRibbon.flank_uv(uv_mode, along, skirt_r * tile_m, tile_m))
			if has_median:
				for off in [md_strip.y, md_strip.x]:
					var o: float = off
					md_verts.append(_top_at(st_pt[k], st_perp[k], o, m_per_deg, st_top[k],
							origin, st_tl[k], st_tr[k], hw_m))
					md_norms.append(up)
					md_uvs.append(Vector2(u, o / tile_m))
		for k in n - 1:
			var a := base + k * stride
			var b := a + stride
			for si in n_strips:
				_quad_idx(indices, a + 2 * si, b + 2 * si, a + 2 * si + 1, b + 2 * si + 1)
			var sk := 2 * n_strips
			_quad_idx(side_indices, a + sk + 1, b + sk + 1, a + sk, b + sk)          # left skirt (bottom → top)
			_quad_idx(side_indices, a + sk + 2, b + sk + 2, a + sk + 3, b + sk + 3)  # right skirt (top → bottom)
			if has_median:
				var ma := md_base + k * 2
				_quad_idx(md_indices, ma, ma + 2, ma + 1, ma + 3)
	out["verts"] = verts
	out["norms"] = norms
	out["uvs"] = uvs
	out["colors"] = colors
	out["indices"] = indices
	out["side_indices"] = side_indices
	out["faces"] = faces
	median["verts"] = md_verts
	median["norms"] = md_norms
	median["uvs"] = md_uvs
	median["indices"] = md_indices
	return out


## A top vertex at lateral offset [param off_m] of a station. The bed's two
## edges are the stored (float32-snapped) stations themselves, so a strip
## that ends on an edge meets the skirt exactly; an inner offset is placed on
## the same sphere as the edges.
static func _top_at(pt: Vector2, perp: Vector2, off_m: float, m_per_deg: float,
		top_r: float, origin: Vector3, edge_l: Vector3, edge_r: Vector3,
		hw_m: float) -> Vector3:
	if is_equal_approx(off_m, hw_m):
		return edge_l
	if is_equal_approx(off_m, -hw_m):
		return edge_r
	var p := pt + perp * (off_m / m_per_deg)
	return PlanetChunk.snap_to_f32(RoadBridge.lonlat_to_dir(p.x, p.y) * top_r - origin)


## Along-values of the stations on one centerline segment [a0, a1]: an even
## subdivision no longer than [param step], plus every profile knot and every
## segment boundary inside, so the bed is exactly piecewise linear where the
## profile is. The end station is only emitted on the last segment (the next
## segment starts with it).
static func _stations(a0: float, a1: float, step: float, knots: PackedFloat64Array,
		seg_lo: PackedFloat64Array, last: bool) -> PackedFloat64Array:
	var n_sub := maxi(1, ceili((a1 - a0) / step))
	var out := PackedFloat64Array()
	for j in n_sub:
		out.append(a0 + (a1 - a0) * float(j) / float(n_sub))
	for k in knots:
		if k > a0 + 1e-6 and k < a1 - 1e-6:
			out.append(k)
	for s in seg_lo:
		if s > a0 + 1e-6 and s < a1 - 1e-6:
			out.append(s)
	if last:
		out.append(a1)
	out.sort()
	# Drop near-duplicates (a knot on a subdivision point).
	var dedup := PackedFloat64Array()
	for v in out:
		if dedup.is_empty() or v - dedup[dedup.size() - 1] > 1e-3:
			dedup.append(v)
	return dedup


## Two triangles for the quad (a0→a1 along, b0→b1 the other edge), with the
## geometric normal (a1-a0)×(b0-a0) when [param outward], reversed otherwise.
static func _quad(faces: PackedVector3Array, a0: Vector3, a1: Vector3,
		b0: Vector3, b1: Vector3, outward: bool) -> void:
	RoadRibbon.quad_faces(faces, a0, a1, b0, b1, outward)


static func _quad_idx(indices: PackedInt32Array, a0: int, a1: int, b0: int, b1: int) -> void:
	RoadRibbon.quad_indices(indices, a0, a1, b0, b1)
