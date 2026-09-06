extends GutTest
## Suite for [BridgePlan] — the numbers a deck and its ramps are built from.
##
## Four in-game complaints are defended here, and each one has a test that
## fails on the old behaviour:
##
##   · the deck was HORIZONTAL at a single sampled altitude, so a rim higher
##     than the midpoint blocked the truck → the deck must be level AND above
##     the HIGHER rim;
##   · that same single sample buried the deck's far end on the high rim, which
##     read as "the bridge stops before the edge" → both rims are sampled;
##   · there were no ramps at all → a ramp per side, at the configured
##     gradient, ending BELOW the ground so there is no lip to catch a wheel;
##   · a ramp is EXTENDED until it reaches the ground, never truncated —
##     truncating puts back the step the ramp exists to remove.
##
## The terrain is injected as a Callable, so no heightmap is touched. That is
## also the property that keeps the client and the server in agreement: same
## sampler in, bit-identical plan out.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_bridge_plan.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6

var _profile: BridgeProfile


func before_each() -> void:
	_profile = BridgeProfile.new()


## A straight east-west road of [param length_m], as a decoded pack record.
## Same shape as test_road_bridge.gd's, so both suites talk about the same road.
func _road(length_m: float) -> Dictionary:
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
	return {"feature_id": 7, "centerline": cl, "_cum_lengths": cum,
			"road_type": "road", "half_width_m": 3.0}


## A span over [param a] → [param b] metres along that road, with the rim
## directions the real detector would have produced.
func _span(road: Dictionary, a: float, b: float) -> Dictionary:
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var pa := RoadBridge.lonlat_at(cl, cum, a)
	var pb := RoadBridge.lonlat_at(cl, cum, b)
	var pm := RoadBridge.lonlat_at(cl, cum, 0.5 * (a + b))
	return {
		"feature_id": 7, "along_start": a, "along_end": b,
		"span_m": b - a, "road_width_m": 6.0,
		"start_lonlat": pa, "end_lonlat": pb,
		"start_dir": RoadBridge.lonlat_to_dir(pa.x, pa.y),
		"end_dir": RoadBridge.lonlat_to_dir(pb.x, pb.y),
		"mid_dir": RoadBridge.lonlat_to_dir(pm.x, pm.y),
		"truncated": false,
	}


## Flat ground at 100 m everywhere.
func _flat(_dir: Vector3) -> float:
	return 100.0


## Ground that rises 2 % eastward, so the two rims of an east-west span differ.
## Longitude east of LON0, in metres, times the gradient.
func _east_slope(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return 100.0 + 0.02 * (lon - LON0) * mpd * cos(deg_to_rad(LAT))


## Ground climbing 10 % eastward — steeper than the 5° ramp, so the east ramp
## can only meet it by being extended a long way.
func _steep_east(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	var mpd := RADIUS * PI / 180.0
	return 100.0 + 0.10 * (lon - LON0) * mpd * cos(deg_to_rad(LAT))


func _plan(sampler: Callable, a: float = 4000.0, b: float = 4250.0,
		length: float = 10000.0) -> Dictionary:
	var road := _road(length)
	return BridgePlan.compute(_profile, _span(road, a, b), road, RADIUS, sampler)


# ── The deck ───────────────────────────────────────────────────────────

func test_each_deck_end_clears_its_own_rim() -> void:
	# The deck follows its two rims instead of being pinned to the higher one.
	# Pinning is what left the low end standing in the air by the whole rim
	# difference — 236 m at the worst tarsis_3 crossing, which no ramp climbs.
	var p := _plan(_east_slope)
	assert_true(p["ok"], "a plain span must plan")
	var clear: float = RoadTerrain.SURFACE_OFFSET + _profile.deck_clearance_m
	assert_gte(float(p["deck_lo_r"]) - RADIUS,
			float(p["start_alt_m"]) + clear - 1e-6,
			"the west end stands a clearance above the west rim")
	assert_gte(float(p["deck_hi_r"]) - RADIUS,
			float(p["end_alt_m"]) + clear - 1e-6, "and the east end above its own")
	assert_false(bool(p["deck_slope_clamped"]),
			"a 2 %% cross-gorge slope is well inside the 5 deg cap")


func test_the_two_rims_are_sampled_separately() -> void:
	var p := _plan(_east_slope)
	assert_gt(absf(float(p["end_alt_m"]) - float(p["start_alt_m"])), 1.0,
			"a 2 %% slope over a 250 m gorge must show as several metres")


func test_a_gentle_deck_takes_the_rims_own_gradient() -> void:
	# Within the cap the deck IS the line between its two ends, so its gradient
	# is the ground's and both ramps stay short.
	var p := _plan(_east_slope)
	var drop: float = absf(float(p["deck_hi_r"]) - float(p["deck_lo_r"]))
	var run: float = float(p["deck_hi_along"]) - float(p["deck_lo_along"])
	assert_almost_eq(drop / run, 0.02, 0.002,
			"the deck matches the 2 %% ground it spans")
	assert_lt(maxf(float(p["ramp_lo_m"]), float(p["ramp_hi_m"])), 20.0,
			"so neither ramp has a rim difference left to make up")


func test_deck_slope_is_capped() -> void:
	# 10 % ground against a 5 deg (8.7 %) cap: the deck descends at exactly the
	# cap and the low side's ramp absorbs the rest — never a step.
	var p := _plan(_steep_east)
	assert_true(bool(p["deck_slope_clamped"]), "the cap bit")
	var drop: float = absf(float(p["deck_hi_r"]) - float(p["deck_lo_r"]))
	var run: float = float(p["deck_hi_along"]) - float(p["deck_lo_along"])
	assert_almost_eq(drop / run, _profile.deck_tan(), 1e-6,
			"and the deck runs at the cap, not past it")
	assert_gt(float(p["deck_hi_r"]), float(p["deck_lo_r"]),
			"tilting the right way — the east rim is the high one")


func test_a_capped_deck_still_clears_the_high_rim() -> void:
	# The cap is applied by lowering the LOW end, never the high one: dropping
	# the high end would bury the deck in the rim it leaves from.
	var p := _plan(_steep_east)
	var clear: float = RoadTerrain.SURFACE_OFFSET + _profile.deck_clearance_m
	assert_gte(float(p["deck_hi_r"]) - RADIUS,
			float(p["end_alt_m"]) + clear - 1e-6,
			"the high end keeps its clearance")


func test_deck_keeps_a_cutback_of_solid_ground_at_each_end() -> void:
	var p := _plan(_flat)
	assert_almost_eq(float(p["deck_lo_along"]),
			4000.0 - _profile.road_cutback_m, 1e-6,
			"the abutment rests on ground, not on the lip of the crack")
	assert_almost_eq(float(p["deck_hi_along"]),
			4250.0 + _profile.road_cutback_m, 1e-6, "same on the far side")


func test_the_abutment_is_sized_on_the_terrain_grid() -> void:
	# The regression that put a hole between the canyon edge and the bridge.
	#
	# crack_offset draws a near-vertical wall, but the mesh only samples it at
	# grid vertices: the last vertex OUTSIDE the crack is the last solid ground,
	# and it can sit a whole spacing beyond the analytic rim. The canyon you see
	# and collide with is therefore up to one spacing wider PER SIDE than the
	# one the plan measures, so a two-metre abutment ends in mid-air.
	var road := _road(10000.0)
	var span := _span(road, 4000.0, 4250.0)
	var spacing := 25.0  # tarsis_3's finest grid
	var p := BridgePlan.compute(_profile, span, road, RADIUS, _flat, spacing)
	var want: float = _profile.abutment_grid_spans * spacing
	assert_almost_eq(float(p["cutback_m"]), want, 1e-9,
			"the abutment is measured in grid spacings")
	assert_gt(want, spacing,
			"and overlaps MORE than one spacing, which is the worst case")
	assert_almost_eq(float(p["deck_lo_along"]), 4000.0 - want, 1e-6,
			"so the deck lands on ground that is actually drawn")
	assert_almost_eq(float(p["deck_hi_along"]), 4250.0 + want, 1e-6)


func test_a_fine_grid_falls_back_to_the_stated_cutback() -> void:
	# On a planet meshed finely enough, the grid stops being the constraint and
	# road_cutback_m is honoured as written.
	var road := _road(10000.0)
	var p := BridgePlan.compute(_profile, _span(road, 4000.0, 4250.0), road,
			RADIUS, _flat, 0.1)
	assert_almost_eq(float(p["cutback_m"]), _profile.road_cutback_m, 1e-9)


# ── The ramps ──────────────────────────────────────────────────────────

func test_ramp_length_matches_the_rise_over_the_slope() -> void:
	# On flat ground the ramp descends from deck_clearance_m above the road
	# surface to ramp_bury_m below it.
	var p := _plan(_flat)
	var want: float = ((_profile.deck_clearance_m + _profile.ramp_bury_m)
			/ _profile.ramp_tan())
	assert_almost_eq(float(p["ramp_lo_m"]), want, 0.05, "west ramp")
	assert_almost_eq(float(p["ramp_hi_m"]), want, 0.05, "east ramp")


func test_ramps_are_asymmetric_on_sloping_ground() -> void:
	# Even with the deck following the ground, the two ramps differ: the west
	# one descends WITH ground that is itself falling, so it closes on it more
	# slowly and has to run further.
	var p := _plan(_east_slope)
	assert_gt(float(p["ramp_lo_m"]), float(p["ramp_hi_m"]) + 1.0,
			"the downhill ramp is the longer one")


func test_ramp_toe_ends_below_the_ground() -> void:
	# Checked by reconstructing the ramp surface at the toe and comparing it to
	# the ground: a ramp stopping AT ground level leaves a lip a wheel catches.
	var p := _plan(_flat)
	var toe_r: float = (float(p["deck_lo_r"])
			- float(p["ramp_lo_m"]) * _profile.ramp_tan())
	var ground_r: float = RADIUS + 100.0 + RoadTerrain.SURFACE_OFFSET
	assert_almost_eq(toe_r, ground_r - _profile.ramp_bury_m, 0.01,
			"the toe is driven ramp_bury_m under the road surface")


func test_ribbon_is_cut_where_the_ramp_breaks_ground() -> void:
	var p := _plan(_flat)
	# The cut is inside the geometry: the buried last stretch is not exposed.
	assert_gt(float(p["excl_lo_along"]), float(p["toe_lo_along"]),
			"the cut sits short of the buried toe")
	assert_lt(float(p["excl_hi_along"]), float(p["toe_hi_along"]))
	# On flat ground the gap between them is exactly the burial depth.
	var want: float = _profile.ramp_bury_m / _profile.ramp_tan()
	assert_almost_eq(float(p["excl_lo_along"]) - float(p["toe_lo_along"]),
			want, 0.05, "burial depth over the gradient")


func test_exclusion_covers_the_whole_flat_deck() -> void:
	var p := _plan(_flat)
	assert_lt(float(p["excl_lo_along"]), float(p["deck_lo_along"]),
			"no ribbon may survive under the deck")
	assert_gt(float(p["excl_hi_along"]), float(p["deck_hi_along"]))


func test_a_climbing_road_gets_a_longer_ramp_not_a_truncated_one() -> void:
	# Ground rising at 10 % against a ramp falling at tan(5°) ≈ 8.7 %: the two
	# close on each other, so lengthening lands it and nothing is truncated.
	# The rise to cover is measured from the DECK END, one cutback beyond the
	# rim, where the ground already stands cutback x grade higher.
	var p := _plan(_steep_east)
	assert_true(p["ok"])
	assert_false(bool(p["clamped"]), "there is road left, so the ramp lands")
	# The deck end already stands a clearance above the ground BELOW IT, so the
	# rise the ramp has to give up is just that clearance plus the burial.
	var want: float = ((_profile.deck_clearance_m + _profile.ramp_bury_m)
			/ (0.10 + _profile.ramp_tan()))
	assert_almost_eq(float(p["ramp_hi_m"]), want, 0.2,
			"the east ramp meets the rising ground")
	assert_almost_eq(float(p["ramp_hi_tan"]), _profile.ramp_tan(), 1e-9,
			"and keeps the configured gradient — no need to steepen")


func test_ground_falling_faster_than_the_ramp_steepens_it() -> void:
	# The other side of that same road, and the case lengthening CANNOT fix:
	# the deck is referenced to the high (east) rim, so the west end starts
	# ~25 m up, and ground falling at 10 % against a ramp falling at 8.7 %
	# means the gap WIDENS with every metre. No length lands there; only a
	# steeper ramp connects, and the search takes the gentlest one that does.
	var p := _plan(_steep_east)
	assert_true(bool(p["steepened"]), "the low side had to be steepened")
	assert_false(bool(p["clamped"]), "and it did land")
	assert_gt(float(p["ramp_lo_tan"]), 0.10,
			"a ramp that lands must fall faster than the ground does")
	assert_lte(float(p["ramp_lo_tan"]),
			tan(deg_to_rad(_profile.ramp_max_slope_deg)) + 1e-9,
			"but never past ramp_max_slope_deg")
	assert_lte(float(p["ramp_lo_m"]), _profile.ramp_steep_max_m + 1.0,
			"and is fitted to a sane run, not to the whole search window")


func test_ramp_is_clamped_only_when_the_road_runs_out() -> void:
	# A span that starts 3 m into the road leaves no room to ramp down.
	var p := _plan(_flat, 3.0, 260.0, 10000.0)
	assert_true(p["ok"], "the deck is still worth building")
	assert_true(bool(p["clamped"]), "and the shortfall is reported")
	assert_lte(float(p["toe_lo_along"]), 3.0)


# ── Contracts ──────────────────────────────────────────────────────────

func test_plan_is_deterministic() -> void:
	# The client and the server each compute this locally and must agree to the
	# last bit; nothing about a bridge is replicated.
	var a := _plan(_east_slope)
	var b := _plan(_east_slope)
	for k in ["deck_top_r", "deck_lo_along", "deck_hi_along",
			"toe_lo_along", "toe_hi_along", "excl_lo_along", "excl_hi_along"]:
		assert_eq(float(a[k]), float(b[k]), "%s must be bit-identical" % k)


func test_exclusions_never_run_off_the_road() -> void:
	# The ribbon cutter clamps to the piece it is drawing, but an exclusion that
	# ran past the road's end would still be a sign the ramp search walked off
	# it — and a ramp built out there would hang in space.
	var road := _road(9000.0)
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var road_hi: float = cum[cum.size() - 1]
	for pair in [[10.0, 300.0], [4000.0, 4250.0], [8700.0, 8990.0]]:
		var p := BridgePlan.compute(_profile,
				_span(road, float(pair[0]), float(pair[1])), road,
				RADIUS, _flat)
		assert_true(p["ok"], "span %s plans" % [pair])
		assert_gte(float(p["toe_lo_along"]), cum[0],
				"geometry starts on the road")
		assert_lte(float(p["toe_hi_along"]), road_hi, "and ends on it")
		assert_gte(float(p["excl_lo_along"]), cum[0],
				"and so does the stretch of ribbon it displaces")
		assert_lte(float(p["excl_hi_along"]), road_hi)


func test_a_malformed_road_is_refused_rather_than_half_planned() -> void:
	# `ok` false must mean BOTH "no deck" and "no ribbon cut", or the road would
	# be cut open over a gorge with nothing spanning it.
	var bad := {"centerline": PackedVector2Array(),
			"_cum_lengths": PackedFloat64Array()}
	var p := BridgePlan.compute(_profile, {}, bad, RADIUS, _flat)
	assert_false(bool(p["ok"]))


func test_profile_defaults_are_the_documented_ones() -> void:
	assert_almost_eq(_profile.deck_clearance_m, 0.50, 1e-9)
	assert_almost_eq(_profile.ramp_slope_deg, 5.0, 1e-9)
	assert_almost_eq(_profile.ramp_bury_m, 0.50, 1e-9)
	assert_almost_eq(_profile.road_cutback_m, 2.0, 1e-9)
