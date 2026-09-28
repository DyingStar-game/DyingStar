extends GutTest
## A lava flow rides the generic grade machinery with its own rule
## (GradeProfile DESCENT, see LavaSettings): its surface is the running
## minimum of the ground, depth_m below it — it never rises, so where the
## ground climbs the channel is cut through it; no tunnel, no viaduct; its
## width goes from width_start_m to width_end_m; its banks are steeper than a
## road cutting and meet the crust directly.
##
## Same synthetic-terrain fixture as test_road_profile.gd.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_lava_profile.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const Kind := GradeSettings.Kind


## A straight east-west flow of [param length_m], drawn from the source.
func _lava(length_m: float, over: Dictionary = {}) -> Dictionary:
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(LAT))
	var step_m := 20.0
	var n := int(length_m / step_m) + 1
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	for i in n:
		var d := float(i) * step_m
		cl.append(Vector2(LON0 + d / (mpd * clat), LAT))
		cum.append(d)
	var z := {"feature_id": (1 << 30) + 1, "centerline": cl, "_cum_lengths": cum,
			"road_type": LavaSettings.LAVA_TYPE, "state": "active", "width_start_m": 10.0,
			"width_end_m": 30.0, "width": 30.0, "width_m": 30.0, "half_width_m": 15.0,
			"depth_m": 3.0}
	z.merge(over, true)
	return z


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return (lon - LON0) * mpd * cos(deg_to_rad(LAT))


func _sampler(f: Callable) -> Callable:
	return func(dir: Vector3) -> float:
		return float(f.call(_east_m(dir)))


## Downhill 5 %, a 40 m bump at 1000-1200 m, a 30 m deep valley at 1500-1600 m.
func _bumpy(s: float) -> float:
	var h := 500.0 - 0.05 * s
	if s >= 1000.0 and s <= 1200.0:
		h += 40.0 * sin(PI * (s - 1000.0) / 200.0)
	if s >= 1500.0 and s <= 1600.0:
		h -= 30.0
	return h


func _uphill(s: float) -> float:
	return 100.0 + 0.1 * s


func test_lava_is_a_descent_profiled_line() -> void:
	var z := _lava(100.0)
	assert_true(GradeSettings.is_profiled(z))
	assert_eq(GradeSettings.profile_rule_of(z), GradeSettings.Rule.DESCENT)
	assert_false(GradeSettings.allows_tunnels_of(z))
	assert_false(GradeSettings.allows_bridges_of(z))
	assert_eq(GradeSettings.half_width_of(z), 15.0, "the widest end")
	assert_eq(GradeSettings.bed_material_of(z), LavaSettings.MATERIAL_BY_STATE["active"])
	var road := {"road_type": "road", "max_slope_degrees": 6}
	assert_eq(GradeSettings.profile_rule_of(road), GradeSettings.Rule.GRADE)
	assert_true(GradeSettings.allows_tunnels_of(road))
	assert_eq(GradeSettings.wall_slope_of(road), GradeSettings.GORGE_WALL_SLOPE)


func test_the_surface_never_rises_and_stays_below_the_ground() -> void:
	var z := _lava(2000.0)
	var prof := GradeProfile.compute(z, _sampler(_bumpy))
	assert_true(prof["ok"])
	var kz: PackedFloat64Array = prof["knots_z"]
	var ka: PackedFloat64Array = prof["knots_along"]
	for i in range(1, kz.size()):
		assert_true(kz[i] <= kz[i - 1], "knot %d rises (%.3f → %.3f)" % [i, kz[i - 1], kz[i]])
	var sa: PackedFloat64Array = prof["stations_along"]
	var st: PackedFloat64Array = prof["stations_terrain"]
	for i in sa.size():
		var zt := GradeProfile.z_track_at(prof, sa[i])
		assert_true(zt <= st[i] - 3.0 + 1e-6, "station %.0f m: surface above ground - depth" % sa[i])
	# Over the bump the flow stays level (the lowest ground before it), 40 m deep.
	var before := GradeProfile.z_track_at(prof, 999.0)
	assert_almost_eq(GradeProfile.z_track_at(prof, 1100.0), before, 0.3, "level through the rise")
	assert_eq(ka[0], 0.0)


func test_no_tunnel_no_viaduct_only_ground_or_channel() -> void:
	var prof := GradeProfile.compute(_lava(2000.0), _sampler(_bumpy))
	var gorge := false
	for seg in prof["segments"]:
		assert_true(int(seg["kind"]) in [Kind.GROUND, Kind.GORGE], "segment kind %d" % int(seg["kind"]))
		if int(seg["kind"]) == Kind.GORGE and float(seg["max_depth"]) > 30.0:
			gorge = true
	assert_true(gorge, "the bump is cut by a deep channel")
	assert_true(GradeProfile.spans_of(prof, _lava(2000.0)).is_empty(), "never a viaduct")


func test_width_goes_from_the_source_to_the_end() -> void:
	var prof := GradeProfile.compute(_lava(2000.0), _sampler(_bumpy))
	assert_almost_eq(GradeProfile.hw_at(prof, 0.0), 5.0, 1e-9)
	assert_almost_eq(GradeProfile.hw_at(prof, 2000.0), 15.0, 1e-9)
	assert_almost_eq(GradeProfile.hw_at(prof, 1000.0), 10.0, 1e-9)
	var road := GradeProfile.compute({"feature_id": 9, "road_type": "road", "max_slope_degrees": 6,
			"centerline": _lava(400.0)["centerline"], "_cum_lengths": _lava(400.0)["_cum_lengths"],
			"width_m": 6.0, "half_width_m": 3.0}, _sampler(_bumpy))
	assert_eq(GradeProfile.hw_at(road, 200.0), float(road["hw_m"]), "a road keeps its constant width")
	assert_false(road.has("wall_slope"), "a road profile carries none of the lava keys")


func test_uphill_is_measured() -> void:
	var up := GradeProfile.compute(_lava(1000.0), _sampler(_uphill))
	assert_almost_eq(float(up["uphill_m"]), 100.0, 0.5)
	var kz: PackedFloat64Array = up["knots_z"]
	assert_eq(kz[kz.size() - 1], kz[0], "drawn uphill: the flow stays level, cut into the rise")
	var down := GradeProfile.compute(_lava(1000.0), _sampler(_bumpy))
	assert_lt(float(down["uphill_m"]), 0.0)


func test_channel_banks_meet_the_crust_at_the_lava_slope() -> void:
	var prof := GradeProfile.compute(_lava(2000.0), _sampler(_bumpy))
	var along := 1100.0
	var zt := GradeProfile.z_track_at(prof, along)
	var hw := GradeProfile.hw_at(prof, along)
	var margin := 5.0
	var floor_z := zt - LavaSettings.CHANNEL_SINK_M
	# Inside the carved width: the channel floor, CHANNEL_SINK_M under the lava.
	assert_almost_eq(GradeBed.carved_height(1000.0, prof, along, hw * 0.5, margin), floor_z, 1e-9)
	# No flat margin (floor_margin_k = 0): the bank rises from hw.
	assert_almost_eq(GradeBed.carved_height(1000.0, prof, along, hw + 2.0, margin),
			floor_z + 2.0 * LavaSettings.WALL_SLOPE, 1e-9)
	# The crust edge (hw + overlap) is buried in the bank, CRUST_BURY_M past the meeting line.
	var edge := hw + LavaSettings.crust_overlap_m()
	assert_almost_eq(GradeBed.carved_height(1000.0, prof, along, edge, margin),
			zt + LavaSettings.CRUST_BURY_M * LavaSettings.WALL_SLOPE, 1e-9)
	# Never raised.
	assert_eq(GradeBed.carved_height(zt - 10.0, prof, along, 0.0, margin), zt - 10.0)


func test_bed_follows_the_width_and_the_collision_is_the_visual() -> void:
	var z := _lava(600.0)
	var prof := GradeProfile.compute(z, _sampler(_bumpy))
	var mpd := RADIUS * PI / 180.0
	var sampler := _sampler(_bumpy)
	var origin := HEALPix.lonlat2vec(LON0, LAT) * RADIUS
	var bed := GradeBed.build_piece(z["centerline"], z["_cum_lengths"], prof, [], mpd, RADIUS,
			sampler, 10.0, origin, true, true, RoadRibbon.UvMode.FLOW,
			func(_d: Vector3, _h: float = NAN) -> Color: return Color(0.1, 0.2, 0.5))
	assert_gt((bed["faces"] as PackedVector3Array).size(), 0)
	var verts: PackedVector3Array = bed["verts"]
	assert_gt(verts.size(), 0)
	# The first station's two top vertices are 2 × hw(0) = 10 m apart; the last, 2 × hw(600).
	var stride := 2 + 4
	var w_first := verts[0].distance_to(verts[1])
	var last := (verts.size() / stride - 1) * stride
	var w_last := verts[last].distance_to(verts[last + 1])
	var ov := LavaSettings.crust_overlap_m()
	assert_almost_eq(w_first, 2.0 * (GradeProfile.hw_at(prof, 0.0) + ov), 0.05)
	assert_almost_eq(w_last, 2.0 * (GradeProfile.hw_at(prof, 600.0) + ov), 0.05)
	assert_gt(w_last, w_first)


func test_the_channel_stops_at_the_source_no_slot_behind_it() -> void:
	# A point on the axis of the first segment, BEHIND the source: its
	# projection clamps on the source, and the lateral offset must be the true
	# distance — the perpendicular to the axis (0) cut a slot straight through
	# whatever stood beyond (a crater rim on tarsis_3).
	var z := _lava(2000.0)
	var prof := GradeProfile.compute(z, _sampler(_bumpy))
	var mpd := RADIUS * PI / 180.0
	var behind := Vector2(LON0 - 300.0 / (mpd * cos(deg_to_rad(LAT))), LAT)
	var q := GradeGeom.nearest_on_pieces([z], behind, mpd)
	assert_almost_eq(absf(float(q["lat_m"])), 300.0, 0.5, "the true distance, not 0")
	for native in [false, true]:
		GradeBed.use_native = native
		var ctx := {"pieces": [z], "profiles": {int(z["feature_id"]): prof}, "pads": [],
				"m_per_deg": mpd, "floor_margin": 3.0}
		if native:
			ctx["native"] = GradeBed.make_native([z], ctx["profiles"])
		assert_eq(GradeBed.apply(900.0, behind, ctx), 900.0, "nothing carved 300 m behind the source")
	GradeBed.use_native = true
