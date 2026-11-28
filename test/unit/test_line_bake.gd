extends GutTest
## The line bake cut per region (LineBake): a client merges a region when a chunk first needs
## it, reads exact knots wherever it has merged one, and the header's decimated ones elsewhere.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_line_bake.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const DIR := "user://line_bake_test"
var _mpd := RADIUS * PI / 180.0


## A local container that answers like the streamed one: a region is PENDING until let through.
class StreamedPack:
	extends ModifierPack
	var allowed: Dictionary = {}
	var asked: Dictionary = {}

	func is_streamed() -> bool:
		return true

	func tile_state(nside: int, ipix: int) -> int:
		if not has_tile(nside, ipix):
			return TILE_ABSENT
		if nside == LineBake.REGION_NSIDE and not allowed.has(ipix):
			asked[ipix] = true
			return TILE_PENDING
		return TILE_READY


## A 40 km railway east from (LON0, LAT): it crosses region borders.
func _line(length_m: float, fid: int) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		cl.append(Vector2(LON0 + d / (_mpd * clat), LAT + 40.0 * sin(d / 300.0) / _mpd))
		cum.append(d)
	return {"feature_id": fid, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": 2}


static func _terrain(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(-dir.z, dir.x))
	var s := (lon - LON0) * (RADIUS * PI / 180.0) * cos(deg_to_rad(LAT))
	return 800.0 + 120.0 * sin(s / 900.0) + 25.0 * sin(s / 97.0)


func _data() -> PlanetData:
	DirAccess.make_dir_recursive_absolute(DIR)
	var d := PlanetData.new()
	d.planet_name = "line_bake_test"
	d.use_modifier_pack = false
	d.chunk_heightmaps_dir = DIR
	d.radius = RADIUS
	d.grade_bake_local_path = d.grade_bake_path()
	return d


## A PlanetData reading the bake just written through [StreamedPack].
func _streamed(pack: StreamedPack) -> PlanetData:
	var d := _data()
	assert_true(pack.open(d.grade_bake_path()), "the container opens")
	d._grade_bake_doc_mutex.lock()
	d._grade_bake_doc_read = true
	d._open_line_bake(pack)
	d._grade_bake_doc_mutex.unlock()
	return d


func _bake_line(fid: int) -> Array:
	var road := _line(40000.0, fid)
	var prof := GradeProfile.compute(road, func(dir: Vector3) -> float: return _terrain(dir))
	assert_true(prof["ok"], "the line is profiled")
	assert_eq(_data().write_grade_bake([road], {fid: prof}), OK)
	return [road, prof]


func _regions_of(road: Dictionary) -> Dictionary:
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var out := {}
	var s := 0.0
	while s <= cum[cum.size() - 1]:
		out[HEALPix.vec2pix_nest(LineBake.REGION_NSIDE, GradeGeom.dir_at(cl, cum, s))] = true
		s += 100.0
	return out


func test_every_region_merged_gives_the_whole_profile_back() -> void:
	var baked := _bake_line(21)
	var back := _data()._grade_baked_profile(baked[0])
	var prof: Dictionary = baked[1]
	assert_gt(_regions_of(baked[0]).size(), 1, "the line crosses a region border")
	assert_eq(back["knots_along"], prof["knots_along"])
	assert_eq(back["knots_z"], prof["knots_z"])
	assert_eq(str(back["segments"]), str(prof["segments"]))
	assert_eq(back["seg_lo"], prof["seg_lo"])


func test_a_streamed_bake_starts_on_the_decimated_knots_with_every_segment() -> void:
	var baked := _bake_line(22)
	var prof: Dictionary = baked[1]
	var d := _streamed(StreamedPack.new())
	var coarse := d._grade_baked_profile(baked[0])
	assert_lt((coarse["knots_along"] as PackedFloat64Array).size(),
			(prof["knots_along"] as PackedFloat64Array).size(), "only the header's knots")
	assert_eq(str(coarse["segments"]), str(prof["segments"]), "but every segment")
	var ka: PackedFloat64Array = coarse["knots_along"]
	assert_eq(ka[0], (prof["knots_along"] as PackedFloat64Array)[0], "the first knot")
	assert_eq(ka[-1], (prof["knots_along"] as PackedFloat64Array)[-1], "and the last")


func test_a_chunk_waits_for_its_regions_then_reads_exact_knots() -> void:
	var baked := _bake_line(23)
	var road: Dictionary = baked[0]
	var prof: Dictionary = baked[1]
	var pack := StreamedPack.new()
	var d := _streamed(pack)
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var at := 3000.0
	var chunk := HEALPix.vec2pix_nest(8192, GradeGeom.dir_at(cl, cum, at))
	assert_false(d.line_regions_ready(8192, chunk), "its region is not downloaded")
	assert_false(pack.asked.is_empty(), "and was asked for")
	for r: int in pack.asked:
		pack.allowed[r] = true
	assert_true(d.line_regions_ready(8192, chunk), "merged once downloaded")
	var back := d._grade_baked_profile(road)
	for a: float in [at - 500.0, at, at + 700.0]:
		assert_eq(GradeProfile.z_track_at(back, a), GradeProfile.z_track_at(prof, a),
				"exact at %.0f m once its region is merged" % a)


func test_a_coarse_chunk_never_waits() -> void:
	_bake_line(24)
	var d := _streamed(StreamedPack.new())
	assert_true(d.line_regions_ready(8, 100), "coarser than the regions: decimated knots")


func test_the_star_chart_sees_every_crossing_before_any_region() -> void:
	var span := {"feature_id": 3, "along_start": 100.0, "along_end": 350.0,
			"mid_dir": Vector3(0.6, 0.0, 0.8), "span_m": 250.0, "truncated": false}
	var plan := {"ok": true, "feature_id": 3, "excl_lo_along": 80.0, "excl_hi_along": 370.0}
	assert_eq(_data().write_grade_bake([], {},
			{"spans": [span], "plans": {PlanetData.bridge_span_key(span): plan}}), OK)
	var d := _streamed(StreamedPack.new())
	var known := d.known_bridge_spans()
	assert_eq(known.size(), 1, "from the header")
	assert_eq(int(known[0]["feature_id"]), 3)
	assert_almost_eq(float(known[0]["along_end"]), 350.0, 0.01)
	assert_true((d._baked_bridges().get("spans", []) as Array).is_empty(),
			"while the crossing itself waits for its region")


func test_merged_knots_splice_exact_stretches_into_the_decimated_ones() -> void:
	var ka := PackedFloat64Array()
	var kz := PackedFloat64Array()
	for i in 50:
		ka.append(float(i) * 1000.0)
		kz.append(float(i) * 3.0)
	var head := {"ci": PackedInt32Array([0, 10, 20, 30, 40, 49]),
		"ca": PackedFloat64Array([0.0, 10000.0, 20000.0, 30000.0, 40000.0, 49000.0]),
		"cz": PackedFloat64Array([0.0, 30.0, 60.0, 90.0, 120.0, 147.0])}
	var parts := LineBake.coalesce([[15, ka.slice(15, 25), kz.slice(15, 25)],
			[22, ka.slice(22, 28), kz.slice(22, 28)]])
	assert_eq(parts.size(), 1, "overlapping stretches coalesce")
	var m := LineBake.merged_knots(head, parts)
	var out: PackedFloat64Array = m[0]
	assert_eq(out, PackedFloat64Array([0.0, 10000.0, 15000.0, 16000.0, 17000.0, 18000.0,
			19000.0, 20000.0, 21000.0, 22000.0, 23000.0, 24000.0, 25000.0, 26000.0, 27000.0,
			30000.0, 40000.0, 49000.0]))
	assert_true(LineBake.covers_all(LineBake.coalesce([[0, ka, kz]]), 50))
