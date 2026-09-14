extends GutTest
## Suite for [RoadRibbon] — the terrain-hugging road slab shared by the
## chunk mesh and the chunk collision: an 8 cm top over the ground, flanks
## buried below it, one slab per carriageway, lane UVs and a vertex tint
## for the corundum surface.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_ribbon_strips.gd

const RADIUS := 6356000.0
const LAT := 0.0
const LON0 := 10.0
const MPD := RADIUS * PI / 180.0
const GROUND := 100.0
## Station pitch, degrees: 20 m along the equator.
const PITCH_DEG := 20.0 / MPD

var _origin := PlanetChunk.snap_to_f32(
		RoadBridge.lonlat_to_dir(LON0 + 250.0 / MPD, LAT) * (RADIUS + GROUND))


func _piece(length_m: float, with_cum := true) -> Array:
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 100.0) + 1
	for i in n:
		var d := float(i) * 100.0
		cl.append(Vector2(LON0 + d / MPD, LAT))
		cum.append(500.0 + d)   # absolute along-road distances, not from 0
	return [cl, cum if with_cum else PackedFloat64Array()]


func _flat(_dir: Vector3) -> float:
	return GROUND


func _r(v: Vector3) -> float:
	return (v + _origin).length()


func _strip(strip: Vector2, want_visual := true, uv_mode := RoadRibbon.UvMode.FLOW,
		tint := Callable(), height := Callable()) -> Dictionary:
	var p := _piece(500.0)
	return RoadRibbon.emit_strip(p[0], p[1], strip, MPD, RADIUS, PITCH_DEG,
			height if height.is_valid() else _flat, _origin, want_visual, true,
			uv_mode, 8.0, tint)


func test_slab_top_and_flank_bottom_altitudes() -> void:
	var slab := _strip(Vector2(-3.0, 3.0))
	var verts: PackedVector3Array = slab["verts"]
	assert_gt(verts.size(), 0)
	assert_eq(verts.size() % 6, 0, "six vertices per station")
	var top := RADIUS + GROUND + RoadTerrain.SURFACE_THICKNESS_M
	var bottom := RADIUS + GROUND - RoadTerrain.RIBBON_BURY_M
	for k in verts.size() / 6:
		assert_almost_eq(_r(verts[k * 6]), top, 0.002, "top hi")
		assert_almost_eq(_r(verts[k * 6 + 1]), top, 0.002, "top lo")
		assert_almost_eq(_r(verts[k * 6 + 2]), top, 0.002, "hi flank top")
		assert_almost_eq(_r(verts[k * 6 + 3]), bottom, 0.002, "hi flank bottom")
		assert_almost_eq(_r(verts[k * 6 + 4]), top, 0.002, "lo flank top")
		assert_almost_eq(_r(verts[k * 6 + 5]), bottom, 0.002, "lo flank bottom")
		assert_almost_eq(verts[k * 6].distance_to(verts[k * 6 + 1]), 6.0, 0.01,
				"the top spans the strip")


func test_arrays_are_paired_and_collision_matches_visual() -> void:
	var slab := _strip(Vector2(-3.0, 3.0))
	var verts: PackedVector3Array = slab["verts"]
	assert_eq((slab["norms"] as PackedVector3Array).size(), verts.size())
	assert_eq((slab["uvs"] as PackedVector2Array).size(), verts.size())
	assert_eq((slab["colors"] as PackedColorArray).size(), verts.size())
	var faces: PackedVector3Array = slab["faces"]
	var indices: PackedInt32Array = slab["indices"]
	assert_eq(faces.size(), indices.size(), "one collision triangle per visual triangle")
	var stations := verts.size() / 6
	assert_eq(faces.size(), (stations - 1) * 3 * 6, "three quads per station pair")
	var no_vis := _strip(Vector2(-3.0, 3.0), false)
	assert_eq((no_vis["verts"] as PackedVector3Array).size(), 0, "collision only")
	assert_eq(no_vis["faces"], faces, "the same faces either way")


func test_highway_carriageways_leave_the_median_open() -> void:
	var layout := RoadTerrain.lane_layout("highway", 4, 7.25)
	var left := _strip(layout["strips"][0])
	var right := _strip(layout["strips"][1])
	var lv: PackedVector3Array = left["verts"]
	var rv: PackedVector3Array = right["verts"]
	assert_eq(lv.size(), rv.size(), "same stations")
	for k in lv.size() / 6:
		# Strip 0 is (-7.25, -0.25): its hi edge (index 0) is at -0.25; strip 1
		# is (0.25, 7.25): its lo edge (index 1) is at +0.25 — 0.5 m apart.
		assert_almost_eq(lv[k * 6].distance_to(rv[k * 6 + 1]), 0.5, 0.01, "the median gap")
		assert_almost_eq(lv[k * 6].distance_to(lv[k * 6 + 1]), 7.0, 0.01, "two lanes")


func test_lane_uvs_span_whole_lanes_across_and_metres_along() -> void:
	# The +perp carriageway travels +along (right-hand traffic, left-handed
	# frame): u grows toward +perp, the image's top is at larger along.
	var strip := Vector2(0.25, 7.25)
	var slab := _strip(strip, true, RoadRibbon.UvMode.LANE)
	var uvs: PackedVector2Array = slab["uvs"]
	var verts: PackedVector3Array = slab["verts"]
	for k in verts.size() / 6:
		assert_almost_eq(uvs[k * 6].x, 2.0, 1e-6, "hi edge: two lanes across")
		assert_almost_eq(uvs[k * 6 + 1].x, 0.0, 1e-6, "lo edge: the strip's own edge")
		assert_almost_eq(uvs[k * 6].y, uvs[k * 6 + 1].y, 1e-6, "same along")
	# Along: 500 m from the road's start at the first station, /3 m per tile.
	assert_almost_eq(uvs[0].y, -500.0 / RoadTerrain.GAUFRAGE_ALONG_M, 1e-4)
	assert_lt(uvs[uvs.size() - 6].y, uvs[0].y, "v decreases along the road")
	# The -perp carriageway travels -along: u grows toward -perp, v with along.
	var back := _strip(Vector2(-7.25, -0.25), true, RoadRibbon.UvMode.LANE)
	var buv: PackedVector2Array = back["uvs"]
	var bverts: PackedVector3Array = back["verts"]
	for k in bverts.size() / 6:
		assert_almost_eq(buv[k * 6].x, 0.0, 1e-6, "hi edge (-0.25) is the tile's u = 0")
		assert_almost_eq(buv[k * 6 + 1].x, 2.0, 1e-6, "lo edge (-7.25) is two lanes")
	assert_almost_eq(buv[0].y, 500.0 / RoadTerrain.GAUFRAGE_ALONG_M, 1e-4)
	assert_almost_eq(buv[buv.size() - 6].y - buv[0].y, 500.0 / RoadTerrain.GAUFRAGE_ALONG_M,
			1e-3, "v grows over 500 m of road")
	var flow := _strip(strip, true, RoadRibbon.UvMode.FLOW)
	var fuv: PackedVector2Array = flow["uvs"]
	assert_almost_eq(fuv[0].x, 500.0 / 8.0, 1e-4, "FLOW: along over the tile")
	assert_almost_eq(fuv[0].y, 7.25 / 8.0, 1e-6, "FLOW: offset over the tile")


func test_tint_is_baked_on_every_vertex() -> void:
	var tint := func(d: Vector3) -> Color:
		return Color(0.5, d.x, 0.25)
	var slab := _strip(Vector2(-3.0, 3.0), true, RoadRibbon.UvMode.LANE, tint)
	var colors: PackedColorArray = slab["colors"]
	var verts: PackedVector3Array = slab["verts"]
	assert_eq(colors.size(), verts.size())
	for k in verts.size() / 6:
		var d := (verts[k * 6] + _origin).normalized()
		assert_almost_eq(colors[k * 6].g, d.x, 1e-3, "top hi carries tint(dir)")
		assert_eq(colors[k * 6 + 3], colors[k * 6], "the hi flank shares the hi tint")
	var plain := _strip(Vector2(-3.0, 3.0))
	assert_eq((plain["colors"] as PackedColorArray)[0], Color.WHITE, "no tint: white")


func test_slab_follows_the_ground() -> void:
	var bumpy := func(dir: Vector3) -> float:
		var lon := rad_to_deg(atan2(dir.z, dir.x))
		return GROUND + 2.0 * sin((lon - LON0) * MPD / 40.0)
	var slab := _strip(Vector2(-3.0, 3.0), true, RoadRibbon.UvMode.FLOW, Callable(), bumpy)
	var verts: PackedVector3Array = slab["verts"]
	var seen_low := false
	var seen_high := false
	for k in verts.size() / 6:
		var alt := _r(verts[k * 6]) - RADIUS - RoadTerrain.SURFACE_THICKNESS_M
		var want: float = bumpy.call((verts[k * 6] + _origin).normalized())
		assert_almost_eq(alt, want, 0.01, "the top rides the sampled ground")
		seen_low = seen_low or alt < GROUND - 1.0
		seen_high = seen_high or alt > GROUND + 1.0
	assert_true(seen_low and seen_high, "the stations resolved the bumps")


func test_legacy_piece_without_cum_starts_at_zero() -> void:
	var p := _piece(500.0, false)
	var slab := RoadRibbon.emit_strip(p[0], p[1], Vector2(-3.0, 3.0), MPD, RADIUS,
			PITCH_DEG, _flat, _origin, true, true)
	assert_almost_eq((slab["uvs"] as PackedVector2Array)[0].x, 0.0, 1e-6)
	assert_gt((slab["verts"] as PackedVector3Array).size(), 0)


func test_degenerate_input_is_empty() -> void:
	var slab := RoadRibbon.emit_strip(PackedVector2Array([Vector2(1, 1)]),
			PackedFloat64Array(), Vector2(-1, 1), MPD, RADIUS, PITCH_DEG, _flat,
			Vector3.ZERO, true, true)
	assert_eq((slab["faces"] as PackedVector3Array).size(), 0)
