extends GutTest
## Suite for a HIGHWAY on a grade-limited profile in [GradeBed]: the bed's
## visual top is two carriageways with the median strip handed to the
## structure material, the collision stays one slab across the whole bed,
## and the corundum surface bakes lane UVs and a vertex tint.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_grade_bed_highway.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const MPD := RADIUS * PI / 180.0

var _origin := PlanetChunk.snap_to_f32(
		RoadBridge.lonlat_to_dir(LON0 + 500.0 / (MPD * cos(deg_to_rad(LAT))), LAT)
		* (RADIUS + 100.0))


func _road(road_type: String, extra: Dictionary) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	for i in 51:
		var d := float(i) * 20.0
		cl.append(Vector2(LON0 + d / (MPD * clat), LAT))
		cum.append(d)
	var road := {"feature_id": 3, "centerline": cl, "_cum_lengths": cum,
			"road_type": road_type, "max_slope_degrees": 4}
	road.merge(extra)
	return road


func _flat(_dir: Vector3) -> float:
	return 100.0


func _r(v: Vector3) -> float:
	return (v + _origin).length()


func _bed(road: Dictionary, want_visual := true, uv_mode := RoadRibbon.UvMode.FLOW,
		tint := Callable()) -> Dictionary:
	var prof := GradeProfile.compute(road, _flat, false)
	assert_true(prof["ok"])
	return GradeBed.build_piece(road["centerline"], road["_cum_lengths"], prof, [],
			MPD, RADIUS, _flat, 10.0, _origin, want_visual, true, uv_mode, tint)


func test_profile_carries_the_lane_count_and_lane_width() -> void:
	var prof := GradeProfile.compute(_road("highway", {}), _flat, false)
	assert_eq(int(prof["lanes"]), 4)
	assert_almost_eq(float(prof["hw_m"]), 7.25, 1e-9, "sized from the lanes")
	var two := GradeProfile.compute(_road("highway", {"lanes": 2, "width": 12.0}), _flat, false)
	assert_eq(int(two["lanes"]), 2)
	assert_almost_eq(float(two["hw_m"]), 3.75, 1e-9, "width ignored")


func test_highway_bed_is_two_carriageways_and_a_structure_median() -> void:
	var bed := _bed(_road("highway", {}))
	var verts: PackedVector3Array = bed["verts"]
	assert_gt(verts.size(), 0)
	assert_eq(verts.size() % 8, 0, "2 strips × 2 + 4 skirt vertices per station")
	var top := RADIUS + 100.0 + RoadTerrain.SURFACE_THICKNESS_M
	for k in verts.size() / 8:
		var a := k * 8
		for j in 4:
			assert_almost_eq(_r(verts[a + j]), top, 0.01, "top vertices on the profile")
		# Per strip the hi (+perp) vertex comes first: strip 0 (-7.25, -0.25)
		# is [-0.25, -7.25], strip 1 (0.25, 7.25) is [7.25, 0.25].
		assert_almost_eq(verts[a].distance_to(verts[a + 1]), 7.0, 0.02, "strip 0: two lanes")
		assert_almost_eq(verts[a + 2].distance_to(verts[a + 3]), 7.0, 0.02, "strip 1: two lanes")
		assert_almost_eq(verts[a].distance_to(verts[a + 3]), 0.5, 0.02, "the median gap")
		assert_almost_eq(verts[a + 1].distance_to(verts[a + 2]), 14.5, 0.03, "the whole bed")
		assert_eq(verts[a + 4], verts[a + 2], "the +perp skirt hangs from the +hw edge")
		assert_eq(verts[a + 6], verts[a + 1], "the -perp skirt hangs from the -hw edge")
	var median: Dictionary = bed["median"]
	var mv: PackedVector3Array = median["verts"]
	assert_eq(mv.size(), verts.size() / 8 * 2, "two median vertices per station")
	assert_eq((median["indices"] as PackedInt32Array).size(), (mv.size() / 2 - 1) * 6)
	for k in mv.size() / 2:
		assert_almost_eq(mv[k * 2].distance_to(mv[k * 2 + 1]), 0.5, 0.02, "0.5 m strip")
		assert_almost_eq(_r(mv[k * 2]), top, 0.01, "flush with the carriageways")
	assert_eq((bed["colors"] as PackedColorArray).size(), verts.size(), "colours paired")


func test_collision_is_one_slab_across_the_median() -> void:
	var bed := _bed(_road("highway", {}), false)
	var faces: PackedVector3Array = bed["faces"]
	assert_eq((bed["verts"] as PackedVector3Array).size(), 0)
	assert_eq(faces.size() % 18, 0, "three quads per station pair")
	# The top quad's two edges are the bed's own edges: 14.5 m apart.
	assert_almost_eq(faces[0].distance_to(faces[2]), 14.5, 0.03, "no gap in the collision")


func test_a_road_bed_is_unchanged() -> void:
	var bed := _bed(_road("road", {"width": 6.0, "lanes": 2}))
	var verts: PackedVector3Array = bed["verts"]
	assert_eq(verts.size() % 6, 0, "one strip: six vertices per station")
	assert_eq((bed["median"]["verts"] as PackedVector3Array).size(), 0, "no median")
	assert_almost_eq(verts[0].distance_to(verts[1]), 6.0, 0.02)


func test_corundum_surface_bakes_lane_uvs_and_tint() -> void:
	var tint := func(d: Vector3) -> Color:
		return Color(0.9, d.x, 0.1)
	var bed := _bed(_road("highway", {}), true, RoadRibbon.UvMode.LANE, tint)
	var uvs: PackedVector2Array = bed["uvs"]
	var colors: PackedColorArray = bed["colors"]
	var verts: PackedVector3Array = bed["verts"]
	for k in verts.size() / 8:
		var a := k * 8
		# Strip 0 (-7.25, -0.25) heads -along: u grows toward -perp.
		assert_almost_eq(uvs[a].x, 0.0, 1e-5, "strip 0 hi edge: the tile's u = 0")
		assert_almost_eq(uvs[a + 1].x, 2.0, 1e-5, "strip 0 lo edge: two lanes across")
		assert_almost_eq(uvs[a + 2].x, 2.0, 1e-5, "strip 1 hi edge")
		assert_almost_eq(uvs[a + 3].x, 0.0, 1e-5, "strip 1 lo edge")
		var d := (verts[a + 2] + _origin).normalized()
		assert_almost_eq(colors[a + 2].g, d.x, 1e-3, "the +hw edge carries tint(dir)")
		assert_almost_eq(colors[a + 2].r, 0.9, 1e-6)
	var plain := _bed(_road("highway", {}))
	assert_eq((plain["colors"] as PackedColorArray)[0], Color.WHITE)
