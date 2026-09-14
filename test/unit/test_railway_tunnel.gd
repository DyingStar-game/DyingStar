extends GutTest
## Suite for [GradeTunnel] (tube, headwalls, bore test) and
## [GradeRefine] (the finer terrain patch around cuttings and mouths).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_railway_tunnel.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const MPD := RADIUS * PI / 180.0
const Kind := GradeSettings.Kind


func _road(length_m: float) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		cl.append(Vector2(LON0 + d / (MPD * clat), LAT))
		cum.append(d)
	return {"feature_id": 3, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": 2}


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	return (lon - LON0) * MPD * cos(deg_to_rad(LAT))


func _sampler(f: Callable) -> Callable:
	return func(dir: Vector3) -> float:
		return float(f.call(_east_m(dir)))


## Level ground, then a 40 m mountain from 500 m on: tunnel from 500.
func _mountain(s: float) -> float:
	return 140.0 if s >= 500.0 else 100.0


var _origin := PlanetChunk.snap_to_f32(
		RoadBridge.lonlat_to_dir(LON0 + 500.0 / (MPD * cos(deg_to_rad(LAT))), LAT)
		* (RADIUS + 100.0))


func _r(v: Vector3) -> float:
	return (v + _origin).length()


func test_inside_bore_is_the_tube_volume_only() -> void:
	var road := _road(2000.0)
	var p := GradeProfile.compute(road, _sampler(_mountain), false)
	var seg := GradeProfile.segment_at(p, 1000.0)
	assert_eq(int(seg["kind"]), Kind.TUNNEL)
	var lo: float = float(seg["lo"])
	var bw := GradeTunnel.bore_half_width(float(p["hw_m"]))
	assert_true(GradeTunnel.inside_bore(p, 1000.0, 0.0, 103.0))
	assert_true(GradeTunnel.inside_bore(p, 1000.0, bw - 0.1, 103.0))
	assert_false(GradeTunnel.inside_bore(p, 1000.0, bw + 0.1, 103.0), "outside the walls")
	assert_false(GradeTunnel.inside_bore(p, 1000.0, 0.0, 100.1), "the floor is not inside")
	assert_false(GradeTunnel.inside_bore(p, 1000.0, 0.0, 120.0), "above the roof")
	assert_true(GradeTunnel.inside_bore(p, lo - GradeSettings.PORTAL_HOOD_M + 0.5, 0.0, 103.0),
			"the hood in front of the face counts")
	assert_false(GradeTunnel.inside_bore(p, lo - GradeSettings.PORTAL_HOOD_M - 1.0, 0.0, 103.0))
	assert_false(GradeTunnel.inside_bore(p, 100.0, 0.0, 103.0), "no tunnel there")


func test_a_tooth_triangle_crossing_the_bore_is_detected() -> void:
	# One vertex on the carved floor in front of the mouth, one 10 m up the
	# face just past it, one on the floor to the side: none is inside the
	# bore, the triangle slices through it.
	var road := _road(2000.0)
	var p := GradeProfile.compute(road, _sampler(_mountain), false)
	var lo: float = float(GradeTunnel.profile_tunnels(p)[0]["lo"])
	var clat := cos(deg_to_rad(LAT))
	var at := func(along: float, lat_m: float, z: float) -> Vector3:
		return RoadBridge.lonlat_to_dir(LON0 + along / (MPD * clat), LAT + lat_m / MPD) * (RADIUS + z)
	var floor_a: Vector3 = at.call(lo - 1.7, 0.0, 100.0)
	var high: Vector3 = at.call(lo, 0.0, 110.0)
	var floor_b: Vector3 = at.call(lo - 1.7, 1.5, 100.0)
	assert_false(GradeTunnel.inside_bore(p, lo - 1.7, 0.0, 100.0), "floor vertex is not inside")
	assert_false(GradeTunnel.inside_bore(p, lo, 0.0, 110.0), "the high vertex is above the roof")
	assert_true(GradeTunnel.tri_hits_bore([road], {3: p}, MPD, RADIUS, floor_a, high, floor_b),
			"yet the triangle crosses the bore")
	# A floor triangle in front of the mouth, and a triangle beside the tube, do not.
	assert_false(GradeTunnel.tri_hits_bore([road], {3: p}, MPD, RADIUS,
			at.call(lo - 10.0, -2.0, 100.0), at.call(lo - 8.0, 2.0, 100.0), at.call(lo - 8.0, -2.0, 100.0)))
	var bw := GradeTunnel.bore_half_width(float(p["hw_m"]))
	assert_false(GradeTunnel.tri_hits_bore([road], {3: p}, MPD, RADIUS,
			at.call(lo + 5.0, bw + 0.5, 100.0), at.call(lo + 7.0, bw + 3.0, 104.0), at.call(lo + 5.0, bw + 3.0, 104.0)))
	# Far from any tunnel: nothing.
	assert_false(GradeTunnel.tri_hits_bore([road], {3: p}, MPD, RADIUS,
			at.call(100.0, 0.0, 100.0), at.call(102.0, 0.0, 110.0), at.call(100.0, 1.0, 100.0)))


func test_tube_and_headwalls_are_built_once_and_sit_on_the_track() -> void:
	var road := _road(2000.0)
	var p := GradeProfile.compute(road, _sampler(_mountain), false)
	var geo := GradeTunnel.build_piece(road["centerline"], road["_cum_lengths"], p,
			RADIUS, _origin, true, true)
	var verts: PackedVector3Array = geo["verts"]
	var faces: PackedVector3Array = geo["faces"]
	assert_gt(verts.size(), 0)
	assert_eq(faces.size() % 3, 0)
	assert_eq(faces.size(), (geo["indices"] as PackedInt32Array).size(),
			"one collision triangle per visual triangle")
	var bw := GradeTunnel.bore_half_width(float(p["hw_m"]))
	var lo_alt := INF
	var hi_alt := -INF
	var min_along := INF
	var max_along := -INF
	for v in verts:
		var alt := _r(v) - RADIUS
		lo_alt = minf(lo_alt, alt)
		hi_alt = maxf(hi_alt, alt)
		var e := _east_m((v + _origin).normalized())
		min_along = minf(min_along, e)
		max_along = maxf(max_along, e)
	assert_almost_eq(lo_alt, 100.0 - GradeTunnel.FOOT_M - 1.0, 0.05, "the headwall's foot")
	assert_almost_eq(hi_alt, 100.0 + GradeSettings.BORE_H_M + GradeSettings.TUNNEL_WALL_M
			+ GradeSettings.PORTAL_COLLAR_M, 0.05, "the headwall's crown")
	assert_almost_eq(min_along, 500.0 - GradeSettings.PORTAL_HOOD_M, 0.6, "the hood starts in front of the face")
	assert_almost_eq(max_along, 2000.0 + GradeTunnel.HEADWALL_THICKNESS_M * 0.5, 1.0)
	# Determinism.
	var again := GradeTunnel.build_piece(road["centerline"], road["_cum_lengths"], p,
			RADIUS, _origin, false, true)
	assert_eq(again["faces"], faces)
	# Two adjacent pieces build the tube once between them: a station is
	# shared, no ring is duplicated, and the headwall belongs to one piece.
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var a := GradeTunnel.build_piece(cl.slice(0, 26), cum.slice(0, 26), p, RADIUS, _origin, false, true)
	var b := GradeTunnel.build_piece(cl.slice(25), cum.slice(25), p, RADIUS, _origin, false, true)
	assert_eq((a["faces"] as PackedVector3Array).size() + (b["faces"] as PackedVector3Array).size(),
			faces.size(), "split pieces build exactly the whole tube")


func test_piece_without_a_tunnel_builds_nothing() -> void:
	var road := _road(2000.0)
	var p := GradeProfile.compute(road, _sampler(_mountain), false)
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var geo := GradeTunnel.build_piece(cl.slice(0, 10), cum.slice(0, 10), p, RADIUS, _origin, true, true)
	assert_eq((geo["faces"] as PackedVector3Array).size(), 0)


# ── The refinement patch ─────────────────────────────────────────────────

## A synthetic chunk: a flat (res+1)² grid of directions around the track,
## with the coarse carve already applied, and the patch built on it.
func _patch(res: int, f: Callable, outward: bool = true) -> Dictionary:
	var road := _road(2000.0)
	var p := GradeProfile.compute(road, _sampler(f), false)
	var pd := PlanetData.new()
	pd.radius = RADIUS
	pd.max_quadtree_depth = 13
	pd.chunk_resolution = res
	var ctx := {"pieces": [road], "profiles": {3: p}, "m_per_deg": MPD}
	# Grid: 13.5 m cells centred on along = 500 m (the mouth), lat = 0.
	var clat := cos(deg_to_rad(LAT))
	var cell := 13.5
	var grid_dirs: Array = []
	var grid_h := PackedFloat64Array()
	var band := PackedByteArray()
	grid_h.resize((res + 1) * (res + 1))
	band.resize((res + 1) * (res + 1))
	for yi in res + 1:
		var row := PackedVector3Array()
		for xi in res + 1:
			var along := 500.0 + (float(xi) - 0.5 * res) * cell
			var lat_m := (float(yi) - 0.5 * res) * cell
			var dir := RoadBridge.lonlat_to_dir(LON0 + along / (MPD * clat), LAT + lat_m / MPD)
			row.append(dir)
			var raw: float = f.call(along)
			var h := GradeBed.apply(raw, HEALPix.vec2lonlat(dir), ctx)
			var idx := yi * (res + 1) + xi
			grid_h[idx] = h
			if h != raw:
				band[idx] = 1
		grid_dirs.append(row)
	var sampler := _sampler(f)
	# The HEALPix cell of the grid's centre stands in for the chunk: the patch
	# only uses it to place its re-sampled sub-vertices.
	var centre: Vector3 = grid_dirs[res / 2][res / 2]
	var ipix := HEALPix.vec2pix_nest(8192, centre)
	var out := GradeRefine.build(pd, 8192, ipix, res, grid_dirs, grid_h, band, ctx,
			PackedByteArray(), sampler, outward)
	return {"patch": out, "profile": p, "grid_h": grid_h, "grid_dirs": grid_dirs, "band": band}


func test_patch_refines_the_carved_cells_and_seals_their_borders() -> void:
	var r := _patch(8, func(s: float) -> float: return 109.0 if s >= 500.0 else 100.0)
	var patch: Dictionary = r["patch"]
	assert_false(patch.is_empty(), "a cutting refines something")
	var quads: PackedByteArray = patch["quads"]
	var refined := 0
	for q in quads:
		refined += int(q)
	assert_gt(refined, 0)
	assert_lt(refined, quads.size(), "not every cell is refined")
	var tris: PackedInt32Array = patch["tris"]
	assert_eq(tris.size() % 3, 0)
	var k := GradeSettings.REFINE_K
	assert_lt(tris.size() / 3, refined * k * k * 2 + 1, "at most 2k² triangles per cell")
	# Every sub-vertex on the chunk's outer border lies on the coarse edge.
	var pos: Array = patch["pos"]
	var frac: PackedVector2Array = patch["frac"]
	var quad_of: PackedInt32Array = patch["quad_of"]
	var res := 8
	var grid_dirs: Array = r["grid_dirs"]
	var grid_h: PackedFloat64Array = r["grid_h"]
	var checked := 0
	for i in pos.size():
		var qi: int = quad_of[i]
		@warning_ignore("integer_division")
		var yi: int = qi / res
		var xi: int = qi % res
		var f: Vector2 = frac[i]
		# The cutting runs along x, so the refined cells reach the x = res
		# border: its sub-vertices must lie on the coarse edge there — except
		# on the edge the bed itself crosses (rows res/2 - 1 and res/2, the
		# track at lat 0), which both chunks re-sample and carve.
		if xi == res - 1 and f.x == 1.0 and (yi < res / 2 - 1 or yi > res / 2):
			var ia := yi * (res + 1) + res
			var ib := ia + res + 1
			var a: Vector3 = (grid_dirs[yi][res] as Vector3) * (RADIUS + grid_h[ia])
			var b: Vector3 = (grid_dirs[yi + 1][res] as Vector3) * (RADIUS + grid_h[ib])
			assert_almost_eq((pos[i] as Vector3).distance_to(a.lerp(b, f.y)), 0.0, 1e-3,
					"border sub-vertex interpolated on the coarse edge")
			checked += 1
	assert_gt(checked, 0)


func test_patch_drops_the_triangles_crossing_the_bore() -> void:
	var r := _patch(8, _mountain)
	var patch: Dictionary = r["patch"]
	assert_false(patch.is_empty(), "a mouth refines something")
	var p: Dictionary = r["profile"]
	var road := _road(2000.0)
	var pos: Array = patch["pos"]
	var tris: PackedInt32Array = patch["tris"]
	var grid_dirs: Array = r["grid_dirs"]
	var grid_h: PackedFloat64Array = r["grid_h"]
	var res := 8
	var n_coarse := (res + 1) * (res + 1)
	for t in range(0, tris.size(), 3):
		for e in 3:
			var idx := tris[t + e]
			var world: Vector3
			if idx < n_coarse:
				@warning_ignore("integer_division")
				world = (grid_dirs[idx / (res + 1)][idx % (res + 1)] as Vector3) * (RADIUS + grid_h[idx])
			else:
				world = pos[idx - n_coarse]
			var q := GradeGeom.nearest_on_pieces([road], HEALPix.vec2lonlat(world), MPD)
			assert_false(GradeTunnel.inside_bore(p, float(q["along"]), float(q["lat_m"]),
					world.length() - RADIUS), "no surviving triangle has a vertex in the bore")
	# Stronger: no surviving triangle CROSSES the bore either (the teeth).
	var profiles := {3: p}
	for t in range(0, tris.size(), 3):
		var w: Array[Vector3] = []
		for e in 3:
			var idx := tris[t + e]
			if idx < n_coarse:
				@warning_ignore("integer_division")
				w.append((grid_dirs[idx / (res + 1)][idx % (res + 1)] as Vector3) * (RADIUS + grid_h[idx]))
			else:
				w.append(pos[idx - n_coarse])
		assert_false(GradeTunnel.tri_hits_bore([road], profiles, MPD, RADIUS, w[0], w[1], w[2]),
				"no surviving triangle crosses the bore")
	# And the winding follows the request.
	var n_out := 0
	for t in range(0, tris.size(), 3):
		var w: Array[Vector3] = []
		for e in 3:
			var idx := tris[t + e]
			if idx < n_coarse:
				@warning_ignore("integer_division")
				w.append((grid_dirs[idx / (res + 1)][idx % (res + 1)] as Vector3) * (RADIUS + grid_h[idx]))
			else:
				w.append(pos[idx - n_coarse])
		if (w[1] - w[0]).cross(w[2] - w[0]).dot(w[0]) > 0.0:
			n_out += 1
	assert_eq(n_out, tris.size() / 3, "every triangle wound outward as asked")


func test_patch_is_deterministic() -> void:
	var a: Dictionary = _patch(6, _mountain)["patch"]
	var b: Dictionary = _patch(6, _mountain)["patch"]
	assert_eq(a["tris"], b["tris"])
	assert_eq((a["pos"] as Array).size(), (b["pos"] as Array).size())
	for i in (a["pos"] as Array).size():
		assert_eq(a["pos"][i], b["pos"][i])


func test_no_railway_no_patch() -> void:
	var pd := PlanetData.new()
	pd.radius = RADIUS
	assert_true(GradeRefine.build(pd, 8192, 0, 4, [], PackedFloat64Array(), PackedByteArray(),
			{}, PackedByteArray(), Callable(), true).is_empty())
