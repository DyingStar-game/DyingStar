extends GutTest
## Suite for [GradeProfile] — the designer's grade rule and the ground's
## verdict along a railway (cutting, tunnel, viaduct or nothing).
##
## The terrain is a Callable of the along-distance, expressed through a
## direction sampler exactly as PlanetData provides one, so nothing touches a
## heightmap and the profile is what the client and the server both compute.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_railway_profile.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const Kind := GradeSettings.Kind


## A straight east-west railway of [param length_m], two tracks.
func _road(length_m: float, tracks: int = 2) -> Dictionary:
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
	return {"feature_id": 3, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": tracks}


## Metres east of the road start for a direction.
static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return (lon - LON0) * mpd * cos(deg_to_rad(LAT))


## Wrap an along → altitude function into a direction sampler.
func _sampler(f: Callable) -> Callable:
	return func(dir: Vector3) -> float:
		return float(f.call(_east_m(dir)))


func _flat(_s: float) -> float:
	return 100.0


func _gentle(s: float) -> float:
	return 100.0 + 0.02 * s


## 10 % climb over the first 400 m, then a 40 m plateau. The extra centimetre
## keeps the stations off the exact GORGE_MIN_M / TUNNEL_MIN_COVER_M thresholds,
## which a lon/lat round trip would otherwise decide by rounding.
func _steep_then_flat(s: float) -> float:
	return 100.0 + 0.10 * minf(s, 400.0) + 0.001 * minf(s, 10.0)


## A 15 m deep valley from 1000 to 1100 m.
func _valley(s: float) -> float:
	if s >= 1000.0 and s <= 1100.0:
		return 85.0
	return 100.0


## A 3 m dip from 1050 to 1065 m — too short for a viaduct, and away from
## the 200 m knots so the track does not sag into it.
func _dip(s: float) -> float:
	if s >= 1050.0 and s <= 1065.0:
		return 97.0
	return 100.0


## A 12 m bump 20 m long — cover enough for a tunnel, length not.
func _short_bump(s: float) -> float:
	if s >= 1000.0 and s <= 1020.0:
		return 112.0
	return 100.0


func _compute(f: Callable, length_m: float = 3000.0) -> Dictionary:
	return GradeProfile.compute(_road(length_m), _sampler(f), false)


# ── The window walk ──────────────────────────────────────────────────────

func test_flat_ground_gives_a_flat_track_and_one_ground_segment() -> void:
	var p := _compute(_flat)
	assert_true(p["ok"])
	for z in p["knots_z"]:
		assert_almost_eq(float(z), 100.0, 1e-6)
	assert_almost_eq(GradeProfile.z_track_at(p, 1234.5), 100.0, 1e-6)
	assert_eq((p["segments"] as Array).size(), 1)
	assert_eq(int(p["segments"][0]["kind"]), Kind.GROUND)
	assert_almost_eq(float(p["segments"][0]["lo"]), 0.0, 1e-6)
	assert_almost_eq(float(p["segments"][0]["hi"]), 3000.0, 1e-6)


func test_grade_under_the_cap_is_followed() -> void:
	var p := _compute(_gentle)
	var ka: PackedFloat64Array = p["knots_along"]
	var kz: PackedFloat64Array = p["knots_z"]
	for i in ka.size():
		assert_almost_eq(kz[i], _gentle(ka[i]), 1e-6, "knot %d follows the ground" % i)
	for seg in p["segments"]:
		assert_eq(int(seg["kind"]), Kind.GROUND)


func test_grade_over_the_cap_keeps_the_track_level() -> void:
	# 10 % over the first window: 20 m of climb in 200 m, more than the 8 m
	# the grade allows → the track stays at its start altitude.
	var p := _compute(_steep_then_flat)
	var kz: PackedFloat64Array = p["knots_z"]
	assert_almost_eq(kz[0], 100.0, 1e-6)
	assert_almost_eq(kz[1], 100.0, 1e-6, "first window is level")
	assert_almost_eq(kz[2], 100.0, 1e-6, "second window: ground is 40 m up, still level")
	# The plateau stays 40 m above a level track for ever → tunnel all along.
	var seg := GradeProfile.segment_at(p, 2000.0)
	assert_eq(int(seg["kind"]), Kind.TUNNEL)


func test_grade_over_the_cap_climbs_at_the_cap() -> void:
	# The policy chosen for the railways (RailwaySettings.CLIMB_AT_MAX_GRADE):
	# 10 % ground, the track climbs the 8 m a 200 m window allows at 4 %,
	# window after window, until it reaches the 140 m plateau — then rides it.
	var p := GradeProfile.compute(_road(3000.0), _sampler(_steep_then_flat), true)
	var kz: PackedFloat64Array = p["knots_z"]
	assert_almost_eq(kz[0], 100.0, 1e-6)
	for i in range(1, 6):
		assert_almost_eq(kz[i], 100.0 + 8.0 * i, 1e-6, "window %d climbs 8 m" % i)
	assert_almost_eq(kz[6], 140.01, 1e-6, "on the plateau, the ground is followed")
	var seg := GradeProfile.segment_at(p, 2000.0)
	assert_eq(int(seg["kind"]), Kind.GROUND, "no tunnel: the track came up to the plateau")


func test_default_policy_is_the_railway_setting() -> void:
	var by_setting := GradeProfile.compute(_road(3000.0), _sampler(_steep_then_flat))
	var explicit := GradeProfile.compute(_road(3000.0), _sampler(_steep_then_flat),
			RailwaySettings.CLIMB_AT_MAX_GRADE)
	assert_eq(by_setting["knots_z"], explicit["knots_z"])


func test_last_partial_window_is_judged_by_its_own_length() -> void:
	# 2 % ground on a 2 050 m road: the last 50 m window must be followed
	# (1 m of climb in 50 m), not refused because 1 m < "8 m".
	var road := _road(2050.0)
	var end: float = (road["_cum_lengths"] as PackedFloat64Array)[-1]
	assert_gt(fmod(end, 200.0), 1.0, "the road must end mid-window for this test")
	var p := GradeProfile.compute(road, _sampler(_gentle), false)
	var ka: PackedFloat64Array = p["knots_along"]
	var kz: PackedFloat64Array = p["knots_z"]
	assert_almost_eq(ka[ka.size() - 1], end, 1e-6)
	assert_almost_eq(kz[kz.size() - 1], _gentle(end), 1e-6)


# ── Classification ───────────────────────────────────────────────────────

func test_steep_rise_makes_a_cutting_then_a_tunnel() -> void:
	var p := _compute(_steep_then_flat)
	# Ground − track grows 10 cm per metre from s=0: a cutting until it
	# reaches 10 m at s=100, a tunnel after.
	var kinds: Array = []
	for seg in p["segments"]:
		kinds.append(int(seg["kind"]))
	assert_eq(kinds, [Kind.GROUND, Kind.GORGE, Kind.TUNNEL],
			"level start, cutting, then the tunnel — got %s" % [kinds])
	var gorge: Dictionary = p["segments"][1]
	assert_almost_eq(float(gorge["lo"]), 5.0, 1e-6, "s=0 is level ground, the cut starts at the next station")
	assert_almost_eq(float(gorge["hi"]), 100.0, 1e-6)
	assert_lt(float(gorge["max_depth"]), 10.0)
	var tunnel: Dictionary = p["segments"][2]
	assert_almost_eq(float(tunnel["hi"]), 3000.0, 1e-6)
	assert_almost_eq(float(tunnel["max_depth"]), 40.01, 1e-4)


func test_tunnel_too_short_to_bore_becomes_a_cutting() -> void:
	var p := _compute(_short_bump)
	for seg in p["segments"]:
		assert_ne(int(seg["kind"]), Kind.TUNNEL, "a 20 m bump is dug, not bored")
	var seg := GradeProfile.segment_at(p, 1010.0)
	assert_eq(int(seg["kind"]), Kind.GORGE)
	assert_almost_eq(float(seg["max_depth"]), 12.0, 1e-6)


func test_valley_makes_a_viaduct() -> void:
	var p := _compute(_valley)
	var bridges: Array = []
	for seg in p["segments"]:
		if int(seg["kind"]) == Kind.BRIDGE:
			bridges.append(seg)
	assert_eq(bridges.size(), 1)
	assert_almost_eq(float(bridges[0]["lo"]), 1000.0, 1e-6)
	assert_almost_eq(float(bridges[0]["hi"]), 1105.0, 1e-6, "the run ends at the first station back on the ground")
	assert_almost_eq(float(bridges[0]["max_gap"]), 15.0, 1e-6)


func test_short_shallow_dip_is_left_to_the_skirts() -> void:
	var p := _compute(_dip)
	var seg := GradeProfile.segment_at(p, 1055.0)
	assert_eq(int(seg["kind"]), Kind.GROUND, "3 m for 15 m is closed by the bed, not bridged")
	assert_almost_eq(float(seg["max_gap"]), 3.0, 1e-6, "the gap is remembered for the skirt height")
	assert_eq((p["segments"] as Array).size(), 1, "absorbed runs merge with their neighbours")


func test_segment_at_bounds() -> void:
	var p := _compute(_valley)
	assert_eq(int(GradeProfile.segment_at(p, -5.0)["kind"]), Kind.GROUND)
	assert_eq(int(GradeProfile.segment_at(p, 1000.0)["kind"]), Kind.BRIDGE, "lo is inclusive")
	assert_eq(int(GradeProfile.segment_at(p, 1104.99)["kind"]), Kind.BRIDGE)
	assert_eq(int(GradeProfile.segment_at(p, 1105.0)["kind"]), Kind.GROUND, "hi is exclusive")
	assert_eq(int(GradeProfile.segment_at(p, 99999.0)["kind"]), Kind.GROUND)


func test_profile_is_deterministic() -> void:
	var a := _compute(_steep_then_flat)
	var b := _compute(_steep_then_flat)
	assert_eq(a["knots_z"], b["knots_z"])
	assert_eq(a["stations_terrain"], b["stations_terrain"])
	assert_eq((a["segments"] as Array).size(), (b["segments"] as Array).size())


func test_bed_width_follows_tracks() -> void:
	assert_almost_eq(float(_compute(_flat)["hw_m"]), 3.44, 1e-6)
	var one := GradeProfile.compute(_road(1000.0, 1), _sampler(_flat))
	assert_almost_eq(float(one["hw_m"]), 1.72, 1e-6)
	var none := GradeProfile.compute(_road(1000.0, 0), _sampler(_flat))
	assert_almost_eq(float(none["hw_m"]), 2.5, 1e-6)


func test_malformed_road_is_refused() -> void:
	assert_false(GradeProfile.compute({}, _sampler(_flat))["ok"])
	var road := _road(1000.0)
	road["_cum_lengths"] = PackedFloat64Array([0.0])
	assert_false(GradeProfile.compute(road, _sampler(_flat), false)["ok"])


# ── Viaduct spans and plans ──────────────────────────────────────────────

func test_spans_of_describes_the_valley_in_roadbridge_shape() -> void:
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(_valley), false)
	var spans := GradeProfile.spans_of(p, road)
	assert_eq(spans.size(), 1)
	var s: Dictionary = spans[0]
	assert_eq(str(s["kind"]), "railway")
	assert_eq(int(s["feature_id"]), 3)
	assert_almost_eq(float(s["along_start"]), 1000.0, 1e-6)
	assert_almost_eq(float(s["road_width_m"]), 6.88, 1e-6)
	assert_almost_eq(float(s["max_depth_m"]), 15.0, 1e-6)
	var mid: Vector3 = s["mid_dir"]
	var east := _east_m(mid)
	assert_between(east, 1000.0, 1105.0, "midpoint lies inside the span")
	assert_true(RoadBridge.spans_owned_by(spans, 64,
			HEALPix.vec2pix_nest(64, mid)).size() == 1)


func test_plan_of_pins_the_deck_to_the_track() -> void:
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(_valley), false)
	var span: Dictionary = GradeProfile.spans_of(p, road)[0]
	var plan := GradeProfile.plan_of(p, span, road, RADIUS)
	assert_true(plan["ok"])
	var top := RADIUS + RoadTerrain.SURFACE_OFFSET + 100.0
	assert_almost_eq(float(plan["deck_lo_r"]), top, 1e-6)
	assert_almost_eq(float(plan["deck_hi_r"]), top, 1e-6)
	assert_almost_eq(float(plan["deck_lo_along"]), 998.0, 1e-6, "abutment margin")
	assert_almost_eq(float(plan["deck_hi_along"]), 1107.0, 1e-6)
	assert_almost_eq(float(plan["ramp_lo_m"]), 0.0, 1e-9)
	assert_almost_eq(float(plan["ramp_hi_m"]), 0.0, 1e-9)
	assert_almost_eq(float(plan["excl_lo_along"]), float(plan["deck_lo_along"]), 1e-9)
	assert_almost_eq(float((plan["top_r_at"] as Callable).call(1050.0)), top, 1e-6)
	var excl := GradeProfile.exclusions_of([plan])
	assert_eq(excl.size(), 1)
	assert_almost_eq((excl[0] as Vector2).x, 998.0, 1e-6)
	assert_almost_eq((excl[0] as Vector2).y, 1107.0, 1e-6)
	assert_eq(PlanetData.bridge_span_key(span), "rw_f3_1000")


func test_plan_carries_the_profile_knots_inside_the_deck() -> void:
	# A valley straddling a 200 m knot: the deck must know about the kink.
	var valley := func(s: float) -> float:
		return 85.0 if (s >= 1150.0 and s <= 1250.0) else 100.0 + 0.015 * s
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(valley), false)
	var span: Dictionary = GradeProfile.spans_of(p, road)[0]
	var plan := GradeProfile.plan_of(p, span, road, RADIUS)
	var extra: PackedFloat64Array = plan["extra_stations"]
	assert_true(extra.has(1200.0), "knot at 1200 m is inside the deck — got %s" % [extra])


# ── The viaduct deck ─────────────────────────────────────────────────────

func test_viaduct_deck_follows_the_kinked_profile() -> void:
	# A valley straddling the 1200 m knot, where the track goes from level to
	# a 1.5 % climb: the deck must kink there too, not run straight.
	var valley := func(s: float) -> float:
		return 85.0 if (s >= 1150.0 and s <= 1250.0) else 100.0 + 0.015 * s
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(valley), false)
	var span: Dictionary = GradeProfile.spans_of(p, road)[0]
	var plan := GradeProfile.plan_of(p, span, road, RADIUS)
	var geo := BridgeDeck.build(GradeSettings.viaduct_profile(RailwaySettings.BALLAST_MATERIAL_PATH), plan, road, RADIUS,
			_sampler(valley))
	assert_false(geo.is_empty())
	var stations: PackedFloat64Array = geo["stations"]
	assert_true(stations.has(1200.0), "the knot is a deck station")
	var origin: Vector3 = geo["origin"]
	var arrays: Array = (geo["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var checked := 0
	for v in verts:
		var world: Vector3 = origin + v
		var along := _east_m(world.normalized())
		if along < float(plan["deck_lo_along"]) + 0.5 or along > float(plan["deck_hi_along"]) - 0.5:
			continue
		var want := RADIUS + RoadTerrain.SURFACE_OFFSET + GradeProfile.z_track_at(p, along)
		assert_almost_eq(world.length(), want, 0.05, "deck top on the profile at %.0f m" % along)
		checked += 1
	assert_gt(checked, 10)
	# Closed solid: every edge of the collision shape paired in both directions.
	var faces: PackedVector3Array = (geo["shape"] as ConcavePolygonShape3D).get_faces()
	var edges: Dictionary = {}
	for i in range(0, faces.size(), 3):
		for e in 3:
			var a: Vector3 = faces[i + e]
			var b: Vector3 = faces[i + (e + 1) % 3]
			var key := "%s|%s" % [a, b]
			var rev := "%s|%s" % [b, a]
			if edges.has(rev):
				edges[rev] -= 1
				if edges[rev] == 0:
					edges.erase(rev)
			else:
				edges[key] = int(edges.get(key, 0)) + 1
	assert_eq(edges.size(), 0, "the viaduct is a closed solid")


func test_long_viaduct_is_split_into_consecutive_decks() -> void:
	var valley := func(s: float) -> float:
		return 60.0 if (s >= 500.0 and s <= 1500.0) else 100.0
	var road := _road(3000.0)
	var p := GradeProfile.compute(road, _sampler(valley), false)
	var spans := GradeProfile.spans_of(p, road)
	assert_eq(spans.size(), 3, "1 005 m of valley → three decks under 400 m")
	for i in spans.size():
		var s: Dictionary = spans[i]
		assert_eq(bool(s["abut_lo"]), i == 0)
		assert_eq(bool(s["abut_hi"]), i == spans.size() - 1)
		if i > 0:
			assert_almost_eq(float(s["along_start"]), float(spans[i - 1]["along_end"]), 1e-6,
					"decks meet end to end")
	var mid := GradeProfile.plan_of(p, spans[1], road, RADIUS)
	assert_almost_eq(float(mid["deck_lo_along"]), float(spans[1]["along_start"]), 1e-9,
			"no margin at an inner junction")
	var first := GradeProfile.plan_of(p, spans[0], road, RADIUS)
	assert_almost_eq(float(first["deck_lo_along"]),
			float(spans[0]["along_start"]) - GradeSettings.VIADUCT_ABUTMENT_M, 1e-9)
	assert_almost_eq(float(first["deck_hi_along"]), float(spans[0]["along_end"]), 1e-9)
	# Keys stay unique.
	assert_ne(PlanetData.bridge_span_key(spans[0]), PlanetData.bridge_span_key(spans[1]))
