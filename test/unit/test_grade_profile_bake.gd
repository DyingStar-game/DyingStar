extends GutTest
## The baked line profiles (tools/bake_grade_profiles.tscn → PlanetData's
## grade_profiles.pack): the bake computes what the game computes, the file
## gives it back bit for bit, and a bake made for other data — another line,
## another relief, other rules — is refused rather than served.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_grade_profile_bake.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const DIR := "user://grade_bake_test"
var _mpd := RADIUS * PI / 180.0


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
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var s := (lon - LON0) * (RADIUS * PI / 180.0) * cos(deg_to_rad(LAT))
	return 800.0 + 120.0 * sin(s / 900.0) + 25.0 * sin(s / 97.0)


func _data() -> PlanetData:
	DirAccess.make_dir_recursive_absolute(DIR)
	var d := PlanetData.new()
	d.planet_name = "grade_bake_test"
	d.use_modifier_pack = false
	d.chunk_heightmaps_dir = DIR
	d.radius = RADIUS
	return d


func _same_profile(a: Dictionary, b: Dictionary) -> bool:
	return a["knots_along"] == b["knots_along"] and a["knots_z"] == b["knots_z"] \
			and a["seg_lo"] == b["seg_lo"] and str(a["segments"]) == str(b["segments"]) \
			and a["along0"] == b["along0"] and a["along1"] == b["along1"] \
			and a["hw_m"] == b["hw_m"] and a["tracks"] == b["tracks"]


func test_stations_read_apart_give_the_same_profile() -> void:
	var road := _line(12000.0, 4)
	var sampler := func(d: Vector3) -> float: return _terrain(d)
	var whole := GradeProfile.compute(road, sampler)
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var alongs := GradeProfile.station_alongs(cum[0], cum[cum.size() - 1])
	# Out of order and in uneven slices, as the bake's workers finish.
	var st := PackedFloat64Array()
	var cuts := [0, 7, 500, 501, 1800, alongs.size()]
	for i in cuts.size() - 1:
		st.append_array(GradeProfile.sample_stations(road, sampler, alongs, cuts[i], cuts[i + 1]))
	var apart := GradeProfile.compute(road, sampler, null, st)
	assert_true(whole["ok"] and apart["ok"])
	assert_true(_same_profile(whole, apart), "parallel stations change the profile")
	assert_eq(whole["stations_terrain"], apart["stations_terrain"])


func test_bake_round_trip_is_bit_identical() -> void:
	var road := _line(9000.0, 5)
	var prof := GradeProfile.compute(road, func(d: Vector3) -> float: return _terrain(d))
	var d := _data()
	assert_eq(d.write_grade_bake([road], {5: prof}), OK)
	var back := _data()._grade_baked_profile(road)
	assert_false(back.is_empty(), "the bake is read back")
	assert_true(_same_profile(back, prof), "the baked profile differs from the computed one")
	assert_false(back.has("stations_along"), "stations are not baked")


func test_a_changed_line_is_not_served_from_the_bake() -> void:
	var road := _line(9000.0, 6)
	var prof := GradeProfile.compute(road, func(d: Vector3) -> float: return _terrain(d))
	assert_eq(_data().write_grade_bake([road], {6: prof}), OK)
	var moved := road.duplicate(true)
	var cl: PackedVector2Array = moved["centerline"]
	cl[3] += Vector2(1e-5, 0.0)
	moved["centerline"] = cl
	assert_true(_data()._grade_baked_profile(moved).is_empty(), "a redrawn line")
	var retyped := road.duplicate(true)
	retyped["tracks"] = 1
	assert_true(_data()._grade_baked_profile(retyped).is_empty(), "a changed property")
	# A cache added at run time is not the line's identity.
	var cached := road.duplicate(true)
	cached["_some_runtime_cache"] = 42
	assert_false(_data()._grade_baked_profile(cached).is_empty(), "an '_' cache")


func test_a_bake_for_other_data_is_refused() -> void:
	var road := _line(9000.0, 8)
	var prof := GradeProfile.compute(road, func(d: Vector3) -> float: return _terrain(d))
	assert_eq(_data().write_grade_bake([road], {8: prof}), OK)
	var other := _data()
	other.max_height += 1.0
	assert_true(other._grade_baked_profile(road).is_empty(), "another elevation scale")
	var version := _data()
	version.chunk_data_version = "not-the-baked-one"
	assert_true(version._grade_baked_profile(road).is_empty(), "another elevation version")


func test_bridges_round_trip_and_refusal() -> void:
	var span := {"feature_id": 3, "along_start": 100.0, "along_end": 350.0,
			"mid_dir": Vector3(0.6, 0.0, 0.8), "span_m": 250.0}
	var plan := {"ok": true, "feature_id": 3, "excl_lo_along": 80.0, "excl_hi_along": 370.0,
			"deck_top_r": RADIUS + 12.5}
	var d := _data()
	var key := PlanetData.bridge_span_key(span)
	assert_eq(d.write_grade_bake([], {}, {"spans": [span], "plans": {key: plan}}), OK)
	var back := _data()._baked_bridges()
	assert_false(back.is_empty(), "the crossings are read back")
	assert_eq(str(back["spans"]), str([span]))
	assert_eq(str((back["plans"] as Dictionary)[key]), str(plan))
	var wider := _data()
	wider.crack_width_m += 10.0
	assert_true(wider._baked_bridges().is_empty(), "another crack network")
	var spared := _data()
	spared.set_crack_exclusions([{"dir": Vector3.UP, "radius": 500.0}])
	assert_true(spared._baked_bridges().is_empty(), "other POIs spared by the cracks")


## The committed packs: every profiled line of every planet scene must be in
## its planet's bake — a re-export without a re-bake makes the game profile
## the lines at run time (tens of minutes for a line round tarsis_3). Fix:
##   godot --headless --path . res://tools/bake_grade_profiles.tscn -- --planet=<name>
## Reads keys only: no tile is downloaded.
func test_grade_profiles_bake_fresh() -> void:
	var tool = load("res://tools/bake_grade_profiles.gd").new()
	var scenes: Dictionary = tool._planet_scenes()
	var checked := 0
	for planet: String in scenes:
		var data: PlanetData = tool._planet_data(planet)
		if data == null or data.chunk_heightmaps_dir == "":
			continue
		data.apply_chunk_manifest()
		# The crossings: the POI spheres set first, as PlanetTerrain does.
		data.set_crack_exclusions(tool._scene_crack_pois(planet))
		if data.corundum_default_biome and data.has_roads():
			checked += 1
			assert_false(data._baked_bridges().is_empty(),
					"%s: the chasm crossings are not baked in %s — re-bake: godot --headless --path . "
					% [planet, data.grade_bake_path()]
					+ "res://tools/bake_grade_profiles.tscn -- --planet=%s" % planet)
		if not data.has_profiled_lines():
			continue
		for road in data._whole_profiled_lines():
			checked += 1
			assert_false(data._grade_baked_profile(road).is_empty(),
					"%s: line fid %d (%s) is not in %s — re-bake: godot --headless --path . "
					% [planet, int(road.get("feature_id", -1)), str(road.get("road_type", "")),
					data.grade_bake_path()]
					+ "res://tools/bake_grade_profiles.tscn -- --planet=%s" % planet)
	tool.free()
	gut.p("%d profiled line(s) and crossing set(s) checked" % checked)
