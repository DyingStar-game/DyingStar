extends GutTest
## Suite for the terrain notch — the box cut straight down under a vehicle lift
## on a sloped cliff (TerrainNotch, PadBed.notch_record).
##
## What has to hold, each one a bug the game would show:
##   · inside the box the ground is the floor, outside it is untouched, and the
##     notch never fills (ground already under the floor stays there);
##   · a notch beside a building pad leaves the pad's ground exactly as it was;
##   · the reach and the refinement are bounded by the box alone (no apron, no
##     talus), so the index and the chunk rebuilds see the notch where it cuts;
##   · a notch shares no level with anything (PadLevels) and cuts no road;
##   · moving its floor is a change of geometry (a re-registration rebuilds);
##   · TerrainNotch.record_for states the box the lift describes: from its origin
##     out along +Z, the floor `depth` under the origin.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_terrain_notch.gd

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0

var _notch: Dictionary


func before_each() -> void:
	# 24 m wide (east-west) × 200 m long (north-south), centred on the equator at lon 0, floor at 50 m.
	_notch = PadBed.notch_record("notch|a", 0.0, 0.0, 0.0, 12.0, 100.0, 50.0)


func _at(east_m: float, north_m: float) -> Vector2:
	return Vector2(east_m / MPD, north_m / MPD)


# ── The record ───────────────────────────────────────────────────────────

func test_record_is_a_notch_with_an_authored_floor() -> void:
	assert_true(PadBed.is_notch(_notch))
	assert_eq(float(_notch["z"]), 50.0)
	assert_eq(float(_notch["talus_m"]), 0.0)
	assert_eq(float(_notch["apron_m"]), 0.0)
	assert_false(PadBed.is_notch(PadBed.record("pad", 0.0, 0.0, 0.0, 10.0, 10.0, 8.0, 0.0)))


func test_moving_the_floor_is_a_change_of_geometry() -> void:
	var deeper := PadBed.notch_record("notch|a", 0.0, 0.0, 0.0, 12.0, 100.0, 40.0)
	assert_false(PadBed.same_geometry(_notch, deeper), "a new floor must rebuild the chunks")
	assert_true(PadBed.same_geometry(_notch, PadBed.quantise(_notch)))


func test_reach_is_the_box_alone() -> void:
	assert_almost_eq(PadBed.reach_m(_notch), 100.0 + PadSettings.REACH_MARGIN_M, 1e-6)


# ── The cut ──────────────────────────────────────────────────────────────

func test_inside_the_box_the_ground_is_the_floor() -> void:
	for p in [_at(0.0, 0.0), _at(11.0, 90.0), _at(-11.0, -99.0)]:
		assert_eq(PadBed.apply(800.0, p, [_notch], MPD), 50.0)


func test_outside_the_box_the_ground_is_untouched() -> void:
	for p in [_at(13.0, 0.0), _at(0.0, 101.0), _at(-30.0, -150.0)]:
		assert_eq(PadBed.apply(800.0, p, [_notch], MPD), 800.0)


func test_a_notch_never_fills() -> void:
	assert_eq(PadBed.apply(20.0, _at(0.0, 0.0), [_notch], MPD), 20.0,
			"ground already under the floor must stay where it is")


func test_coarse_clamp_cuts_a_band_wider() -> void:
	assert_eq(PadBed.shaved(800.0, _at(20.0, 0.0), [_notch], MPD, 10.0), 50.0)
	assert_eq(PadBed.shaved(800.0, _at(30.0, 0.0), [_notch], MPD, 10.0), 800.0)


func test_a_pad_beside_a_notch_keeps_its_ground() -> void:
	# A building pad 300 m east of the notch, with its own talus.
	var pad := PadBed.record("pad_b", 300.0 / MPD, 0.0, 0.0, 10.0, 10.0, 8.0, 0.0)
	pad["z"] = 120.0
	pad["talus_m"] = 40.0
	for e in [290.0, 315.0, 330.0, 360.0]:
		var p := _at(e, 0.0)
		assert_eq(PadBed.apply(150.0, p, [_notch, pad], MPD), PadBed.apply(150.0, p, [pad], MPD),
				"the notch must not change the pad's ground at %.0f m" % e)
	# And the pad does not stop the notch cutting.
	assert_eq(PadBed.apply(800.0, _at(0.0, 0.0), [pad, _notch], MPD), 50.0)


func test_refinement_follows_the_box() -> void:
	assert_true(PadBed.near([_notch], _at(13.0, 0.0), MPD, 4.0), "just outside the wall: refined")
	assert_false(PadBed.near([_notch], _at(40.0, 0.0), MPD, 4.0), "far from the wall: not refined")


# ── What a notch takes no part in ────────────────────────────────────────

func test_a_notch_touches_no_apron() -> void:
	var pad := PadBed.record("pad_b", 0.0, 0.0, 0.0, 10.0, 10.0, 8.0, 0.0)
	assert_false(PadBed.aprons_touch(_notch, pad, MPD))
	assert_false(PadBed.aprons_touch(pad, _notch, MPD))


func test_a_notch_cuts_no_road() -> void:
	var cl := PackedVector2Array([_at(-50.0, 0.0), _at(50.0, 0.0)])
	var cum := PackedFloat64Array([0.0, 100.0])
	assert_eq(PadBed.road_exclusion(_notch, cl, cum, MPD).size(), 0)


# ── The node's record ────────────────────────────────────────────────────

func test_record_for_runs_along_plus_z_from_the_origin() -> void:
	# A node standing on the equator at lon 0, up = +X (radial), +Z pointing north (+Y in the world),
	# its X axis east. In Godot's lon convention (atan2(-z, x)) east at lon 0 is -Z.
	var up := Vector3(1, 0, 0)
	var north := Vector3(0, 1, 0)
	var east := Vector3(0, 0, -1)
	var rel := Transform3D(Basis(east, up, north), up * (RADIUS + 300.0))
	var data := PlanetData.new()
	data.radius = RADIUS
	var rec := TerrainNotch.record_for(data, rel, 24.0, 200.0, 250.0, "notch|n")
	assert_false(rec.has("_refusal"), str(rec.get("_refusal", "")))
	assert_almost_eq(float(rec["hx"]), 12.0, 0.01)
	assert_almost_eq(float(rec["hy"]), 100.0, 0.01)
	assert_almost_eq(float(rec["z"]), 50.0, 0.01, "floor = origin altitude (300) - depth (250)")
	# The centre is 100 m north of the node.
	assert_almost_eq(float(rec["lat"]) * MPD, 100.0, 0.05)
	assert_almost_eq(float(rec["lon"]) * MPD, 0.0, 0.05)
	# Cut at the node's own foot, not past the far end.
	assert_eq(PadBed.apply(800.0, Vector2(0.0, 1.0 / MPD), [rec], MPD), 50.0)
	assert_eq(PadBed.apply(800.0, Vector2(0.0, 205.0 / MPD), [rec], MPD), 800.0)


func test_record_for_refuses_an_empty_notch() -> void:
	var data := PlanetData.new()
	data.radius = RADIUS
	var rel := Transform3D(Basis.IDENTITY, Vector3(RADIUS, 0, 0))
	assert_true(TerrainNotch.record_for(data, rel, 24.0, 0.0, 10.0, "n").has("_refusal"))
	assert_true(TerrainNotch.record_for(data, rel, 24.0, 10.0, 0.0, "n").has("_refusal"))
