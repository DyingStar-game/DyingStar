extends GutTest
## A highway / road with `max_slope_degrees` rides the same grade-limited
## profile as a railway ([GradeProfile]), with its own answers: the grade
## comes from the record, the road CLIMBS at that grade instead of staying
## level, the bed is the road's width on asphalt, and its viaduct spans are
## "profiled_road". A road without the field is not profiled at all.
##
## Same synthetic-terrain fixture as test_railway_profile.gd.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_profile.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const Kind := GradeSettings.Kind


## A straight east-west road of [param length_m]; [param slope_deg] < 0 leaves
## the record ungraded.
func _road(length_m: float, slope_deg: int = 6, road_type: String = "road") -> Dictionary:
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
	var road := {"feature_id": 9, "centerline": cl, "_cum_lengths": cum,
			"road_type": road_type, "width_m": 6.0, "half_width_m": 3.0, "lanes": 2}
	if slope_deg >= 0:
		road["max_slope_degrees"] = slope_deg
	return road


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return (lon - LON0) * mpd * cos(deg_to_rad(LAT))


func _sampler(f: Callable) -> Callable:
	return func(dir: Vector3) -> float:
		return float(f.call(_east_m(dir)))


func _flat(_s: float) -> float:
	return 100.0


## 5 % — under a 6° cap (tan 6° ≈ 10.5 %), over the railway's 4 %.
func _five_percent(s: float) -> float:
	return 100.0 + 0.05 * s


## 20 % climb over the first 400 m, then an 80 m plateau.
func _steep_then_flat(s: float) -> float:
	return 100.0 + 0.20 * minf(s, 400.0) + 0.001 * minf(s, 10.0)


## A 15 m deep valley from 1000 to 1100 m.
func _valley(s: float) -> float:
	if s >= 1000.0 and s <= 1100.0:
		return 85.0
	return 100.0


# ── Routing ──────────────────────────────────────────────────────────────

func test_only_a_graded_highway_or_road_is_profiled() -> void:
	assert_true(GradeSettings.is_profiled(_road(100.0, 6, "road")))
	assert_true(GradeSettings.is_profiled(_road(100.0, 6, "highway")))
	assert_false(GradeSettings.is_profiled(_road(100.0, -1, "road")), "no field → terrain ribbon")
	assert_false(GradeSettings.is_profiled(_road(100.0, 6, "trail")), "a trail never grades")
	assert_true(GradeSettings.is_profiled({"road_type": "railway", "tracks": 1}))


func test_grade_settings_route_road_and_railway_answers() -> void:
	var road := _road(100.0, 6)
	var rail := {"road_type": "railway", "tracks": 2}
	assert_almost_eq(GradeSettings.max_grade_of(road), tan(deg_to_rad(6.0)), 1e-9)
	assert_almost_eq(GradeSettings.max_grade_of(rail), RailwaySettings.MAX_GRADE, 1e-9)
	assert_true(GradeSettings.climbs_at_max_grade_of(road), "a road chases the hill")
	assert_eq(GradeSettings.climbs_at_max_grade_of(rail), RailwaySettings.CLIMB_AT_MAX_GRADE)
	assert_almost_eq(GradeSettings.half_width_of(road), 3.0, 1e-9, "width / 2, not a track rule")
	assert_almost_eq(GradeSettings.half_width_of(rail), 3.44, 1e-9)
	assert_eq(GradeSettings.bed_material_of(road), RoadTerrain.ASPHALT_MATERIAL_PATH)
	assert_eq(GradeSettings.bed_material_of(rail), RailwaySettings.BALLAST_MATERIAL_PATH)
	assert_eq(GradeSettings.span_kind_of(road), GradeSettings.SPAN_KIND_ROAD)
	assert_eq(GradeSettings.span_kind_of(rail), GradeSettings.SPAN_KIND_RAILWAY)


# ── The window walk with the road's grade ────────────────────────────────

func test_profile_carries_the_road_identity() -> void:
	var p := GradeProfile.compute(_road(3000.0), _sampler(_flat))
	assert_true(p["ok"])
	assert_eq(str(p["road_type"]), "road")
	assert_eq(str(p["span_kind"]), GradeSettings.SPAN_KIND_ROAD)
	assert_almost_eq(float(p["max_grade"]), tan(deg_to_rad(6.0)), 1e-9)
	assert_almost_eq(float(p["hw_m"]), 3.0, 1e-9)
	assert_eq(int(p["tracks"]), 0)


func test_grade_under_the_road_cap_is_followed() -> void:
	# 5 % would make a railway (4 %) go level; a 6° road follows it.
	var p := GradeProfile.compute(_road(3000.0), _sampler(_five_percent))
	var ka: PackedFloat64Array = p["knots_along"]
	var kz: PackedFloat64Array = p["knots_z"]
	for i in ka.size():
		assert_almost_eq(kz[i], _five_percent(ka[i]), 1e-6, "knot %d follows the ground" % i)
	for seg in p["segments"]:
		assert_eq(int(seg["kind"]), Kind.GROUND)


func test_road_climbs_at_its_max_grade_when_the_hill_is_steeper() -> void:
	# 20 % ground: every 200 m window the road rises tan(6°)·200 ≈ 21 m,
	# not 40 — and keeps climbing until it reaches the plateau.
	var p := GradeProfile.compute(_road(3000.0), _sampler(_steep_then_flat))
	var kz: PackedFloat64Array = p["knots_z"]
	var reach := tan(deg_to_rad(6.0)) * 200.0
	assert_almost_eq(kz[0], 100.0, 1e-6)
	assert_almost_eq(kz[1], 100.0 + reach, 1e-6, "first window climbs at the cap")
	assert_almost_eq(kz[2], 100.0 + 2.0 * reach, 1e-6, "second window too")
	assert_almost_eq(kz[kz.size() - 1], 180.01, 1e-3, "it reaches the plateau in the end")
	# Ground − road grows ~9.5 cm per metre: a cutting, then a tunnel through
	# the slope, and plain ground again once the road is up on the plateau.
	var kinds: Array = []
	for seg in p["segments"]:
		kinds.append(int(seg["kind"]))
	assert_eq(kinds, [Kind.GROUND, Kind.GORGE, Kind.TUNNEL, Kind.GORGE, Kind.GROUND],
			"cutting → tunnel → cutting → ground, got %s" % [kinds])


func test_a_railway_on_the_same_hill_stays_level() -> void:
	# The control: same terrain, railway policy → level, tunnel for ever.
	var rail := _road(3000.0, -1, "railway")
	rail["tracks"] = 1
	var p := GradeProfile.compute(rail, _sampler(_steep_then_flat), false)
	var kz: PackedFloat64Array = p["knots_z"]
	assert_almost_eq(kz[1], 100.0, 1e-6)
	assert_eq(int(GradeProfile.segment_at(p, 2000.0)["kind"]), Kind.TUNNEL)


func test_valley_makes_a_profiled_road_span() -> void:
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(_valley))
	var spans := GradeProfile.spans_of(p, road)
	assert_eq(spans.size(), 1)
	assert_eq(str(spans[0]["kind"]), GradeSettings.SPAN_KIND_ROAD)
	assert_almost_eq(float(spans[0]["road_width_m"]), 6.0, 1e-6, "the road's own width")
	var plan := GradeProfile.plan_of(p, spans[0], road, RADIUS)
	assert_true(plan["ok"])
	assert_eq(str(plan["kind"]), GradeSettings.SPAN_KIND_ROAD)
	assert_true(GradeSettings.is_profile_span(spans[0]))
	assert_false(GradeSettings.is_profile_span({"kind": ""}), "a crack span is not")
	assert_eq(GradeSettings.viaduct_profile_for_span(spans[0]).deck_material_path,
			RoadTerrain.ASPHALT_MATERIAL_PATH, "asphalt deck")
	assert_ne(PlanetData.bridge_span_key(spans[0]),
			PlanetData.bridge_span_key({"kind": "", "feature_id": 9, "along_start": 1000.0}),
			"never the same key as a crack span of the same road")
