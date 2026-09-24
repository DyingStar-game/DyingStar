extends GutTest
## Suite for the terrain pad — the levelled platform under a building.
##
## Four things have to hold, and each one is a bug the game would show:
##   · the platform's altitude ignores a spike in the footprint (the median);
##   · the cross-section is CONTINUOUS at both ends of the talus, or the
##     ground tears where the pad stops;
##   · the talus is never steeper than PadSettings.TALUS_SLOPE, or the player
##     hops in place on it (the lesson GradeSettings.GORGE_WALL_SLOPE records);
##   · two overlapping pads are resolved the same way whatever order the index
##     hands them in, or the mesh and the collision carve a shared vertex
##     differently.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_terrain_pad.gd

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0

var _rec: Dictionary


func before_each() -> void:
	# 20 × 30 m footprint, 8 m apron, sitting on the equator at lon 0.
	_rec = PadBed.record("pad_a", 0.0, 0.0, 0.0, 10.0, 15.0, 8.0, 0.0)
	_rec["z"] = 100.0


## A direction [param east_m] metres east of the pad centre.
func _east(east_m: float) -> Vector2:
	return Vector2(east_m / MPD, 0.0)


# ── The record ───────────────────────────────────────────────────────────

func test_quantise_is_idempotent() -> void:
	var once := PadBed.quantise(_rec)
	var twice := PadBed.quantise(once)
	for k in ["lon", "lat", "yaw", "hx", "hy", "apron_m", "z_off"]:
		assert_eq(float(twice[k]), float(once[k]),
				"quantising twice must not move '%s'" % k)


func test_quantise_absorbs_a_float32_round_trip() -> void:
	# What Horizon does to the server's transform before the client sees it.
	var jittered := _rec.duplicate()
	jittered["lon"] = float(PackedFloat32Array([0.30000001192]) [0])
	jittered["lat"] = 0.3
	var a := PadBed.quantise(jittered)
	var b := PadBed.quantise({"uuid": "pad_a", "lon": 0.3, "lat": 0.3, "yaw": 0.0,
			"hx": 10.0, "hy": 15.0, "apron_m": 8.0, "z_off": 0.0})
	assert_true(PadBed.same_geometry(a, b),
			"a float32 round-trip must not give the client a different pad")


func test_same_geometry_sees_a_real_move() -> void:
	var moved := _rec.duplicate()
	moved["lon"] = float(_rec["lon"]) + 0.001   # ~110 m
	assert_false(PadBed.same_geometry(PadBed.quantise(moved), _rec))


# ── The altitude ─────────────────────────────────────────────────────────

func test_altitude_is_the_median_and_ignores_a_spike() -> void:
	# A flat 40 m ground with one boulder 400 m high under a corner.
	# Compared with `==` and not is_equal_approx: a 36 × 46 m pad on a 6 356 km
	# body spans ~7e-6 rad, so EVERY sample direction is "approximately equal"
	# to every other. Exact equality is right here — the sampler is handed the
	# very values sample_dirs produced.
	var spike := PadBed.sample_dirs(_rec, MPD)[0]
	var sampler := func(d: Vector3) -> float:
		return 440.0 if d == spike else 40.0
	var stats := PadBed.pad_stats(_rec, sampler, MPD)
	assert_almost_eq(float(stats["z"]), 40.0, 1e-6,
			"one spike must not lift the platform")
	assert_almost_eq(float(stats["span"]), 400.0, 1e-6,
			"the span still reports it, which is what warns the designer")


func test_altitude_splits_cut_and_fill_on_a_regular_slope() -> void:
	# A 10 % slope running east: the median lands on the centre of the pad,
	# so the cut on the high side equals the fill on the low side.
	var sampler := func(d: Vector3) -> float:
		return HEALPix.vec2lonlat(d).x * MPD * 0.1
	var stats := PadBed.pad_stats(_rec, sampler, MPD)
	assert_almost_eq(float(stats["z"]), 0.0, 1e-3,
			"the platform sits at the middle of a regular slope")


func test_height_offset_raises_the_platform() -> void:
	var raised := PadBed.record("pad_a", 0.0, 0.0, 0.0, 10.0, 15.0, 8.0, 3.0)
	var sampler := func(_d: Vector3) -> float: return 40.0
	assert_almost_eq(float(PadBed.pad_stats(raised, sampler, MPD)["z"]), 43.0, 1e-6)


# ── The cross-section ────────────────────────────────────────────────────

func test_footprint_and_apron_are_dead_flat() -> void:
	for e: float in [0.0, 5.0, 9.99, 10.0, 15.0, 17.99, 18.0]:
		assert_eq(PadBed.apply(60.0, _east(e), [_rec], MPD), 100.0,
				"%.2f m east is inside footprint+apron" % e)


func test_talus_is_continuous_at_both_ends() -> void:
	var h := 60.0                                   # 40 m below the platform
	var apron: float = float(_rec["apron_m"])
	var edge: float = float(_rec["hx"]) + apron     # 18 m: where the talus starts
	var width := absf(h - 100.0) / PadSettings.TALUS_SLOPE
	assert_eq(PadBed.apply(h, _east(edge), [_rec], MPD), 100.0,
			"at the apron edge the ground is still the platform")
	assert_eq(PadBed.apply(h, _east(edge + width), [_rec], MPD), h,
			"at the toe the ground is exactly the natural relief again")
	assert_eq(PadBed.apply(h, _east(edge + width + 50.0), [_rec], MPD), h,
			"past the toe the pad does not exist")


func test_talus_never_exceeds_the_slope() -> void:
	# Every height difference the cap admits: TALUS_MAX_M × TALUS_SLOPE.
	for dh: float in [-60.0, -40.0, -12.0, -2.0, 2.0, 12.0, 40.0, 60.0]:
		var h := 100.0 + dh
		var prev := 100.0
		var step := 0.25
		var e := float(_rec["hx"]) + float(_rec["apron_m"])
		while e < float(_rec["hx"]) + float(_rec["apron_m"]) + 200.0:
			e += step
			var y := PadBed.apply(h, _east(e), [_rec], MPD)
			assert_lte(absf(y - prev) / step, PadSettings.TALUS_SLOPE + 1e-6,
					"Δh=%.0f m: the talus must stay walkable" % dh)
			prev = y


func test_past_the_cap_the_talus_steepens_but_stays_continuous() -> void:
	# A building halfway down a cliff: the width bound wins and the slope gives.
	# The ground must still MEET the relief — a step there would be a hole.
	# TerrainPad flags this case in the inspector; nothing here should hide it.
	var h := 100.0 - 2.0 * PadSettings.TALUS_MAX_M * PadSettings.TALUS_SLOPE
	var toe: float = float(_rec["hx"]) + float(_rec["apron_m"]) + PadSettings.TALUS_MAX_M
	assert_eq(PadBed.apply(h, _east(toe), [_rec], MPD), h, "the toe still lands on the relief")
	assert_gt((100.0 - h) / PadSettings.TALUS_MAX_M, PadSettings.TALUS_SLOPE,
			"and it is steeper than promised — that is what the warning is for")


func test_the_pad_fills_as_well_as_it_cuts() -> void:
	# The whole point against a railway cutting, which only ever lowers.
	assert_gt(PadBed.apply(60.0, _east(0.0), [_rec], MPD), 60.0, "low side is banked up")
	assert_lt(PadBed.apply(140.0, _east(0.0), [_rec], MPD), 140.0, "high side is dug out")


func test_rotation_turns_the_footprint() -> void:
	var turned := PadBed.record("pad_a", 0.0, 0.0, PI / 2.0, 10.0, 15.0, 8.0, 0.0)
	turned["z"] = 100.0
	# 14 m east: inside the 15 m half-length once the pad is turned a quarter
	# turn, outside the 10 m half-width when it is not.
	assert_eq(PadBed.apply(60.0, _east(14.0), [turned], MPD), 100.0)
	assert_ne(PadBed.apply(60.0, _east(30.0), [turned], MPD), 100.0)


# ── Overlapping pads ─────────────────────────────────────────────────────

func test_overlapping_pads_do_not_depend_on_the_order() -> void:
	var b := PadBed.record("pad_b", 0.00035, 0.0, 0.0, 10.0, 15.0, 8.0, 0.0)
	b["z"] = 130.0
	for e: float in [-20.0, 0.0, 10.0, 19.0, 25.0, 40.0, 60.0]:
		var ab := PadBed.apply(60.0, _east(e), [_rec, b], MPD)
		var ba := PadBed.apply(60.0, _east(e), [b, _rec], MPD)
		assert_eq(ab, ba, "%.0f m east must not depend on the index's order" % e)


func test_nearest_picks_the_pad_you_stand_on() -> void:
	var b := PadBed.record("pad_b", 0.00035, 0.0, 0.0, 10.0, 15.0, 8.0, 0.0)
	b["z"] = 130.0
	assert_eq(str(PadBed.nearest([_rec, b], _east(0.0), MPD)["rec"]["uuid"]), "pad_a")
	assert_eq(str(PadBed.nearest([_rec, b], _east(39.0), MPD)["rec"]["uuid"]), "pad_b")


# ── The refinement predicate and the index's bound ───────────────────────

func test_reach_is_an_upper_bound_on_what_apply_moves() -> void:
	var reach := PadBed.reach_m(_rec)
	# The steepest case the cross-section admits: a full TALUS_MAX_M of talus.
	var h := 100.0 - PadSettings.TALUS_MAX_M * PadSettings.TALUS_SLOPE
	assert_eq(PadBed.apply(h, _east(reach), [_rec], MPD), h,
			"nothing moves at the reach — the index's neighbour ring depends on it")


func test_near_covers_everything_apply_touches() -> void:
	var pitch := 12.4
	var e := 0.0
	while e < PadBed.reach_m(_rec) + 100.0:
		var h := 40.0
		if PadBed.apply(h, _east(e), [_rec], MPD) != h:
			assert_true(PadBed.near([_rec], _east(e), MPD, pitch),
					"%.1f m east is moved, so its cell must be refined" % e)
		e += 0.5


func test_coarse_shave_clamps_and_never_lifts() -> void:
	var edge: float = float(_rec["hx"]) + float(_rec["apron_m"])
	# Ground ABOVE the platform is cut down to it — that is what keeps a coarse
	# triangle from sloping up through the building's floor.
	for e: float in [0.0, 5.0, 17.0, edge + 1.0, edge + 17.9]:
		assert_eq(PadBed.shaved(140.0, _east(e), [_rec], MPD, 18.0), 100.0,
				"%.1f m east: no coarse vertex near the pad may sit above it" % e)
	# Ground BELOW is left alone: no mesa grows around a building on fill.
	assert_eq(PadBed.shaved(60.0, _east(0.0), [_rec], MPD, 18.0), 60.0)
	# Past the band the pad does not exist at all.
	assert_eq(PadBed.shaved(140.0, _east(edge + 18.1), [_rec], MPD, 18.0), 140.0,
			"and the coarse grid is back on the relief one band later")


# ── The measured talus cap ───────────────────────────────────────────────
#
# The cap is what keeps the refinement band honest: GradeRefine re-meshes every
# cell within PadBed.reach_m 8 × 8 finer, so a pad with 2 m of ground to make
# up must not claim the band a cliffside one needs (measured on tarsis_3: the
# blanket bound cost 772 ms of mesh per chunk, the measured one 72 ms). What
# must never break is that `near` still covers everything `apply` moves.

func test_measured_cap_shrinks_the_reach() -> void:
	var tight := _rec.duplicate()
	tight["talus_m"] = 14.0
	assert_lt(PadBed.reach_m(tight), PadBed.reach_m(_rec),
			"a pad on gentle ground must ask for a smaller band")
	assert_eq(PadBed.talus_cap(tight), 14.0)
	assert_eq(PadBed.talus_cap(_rec), PadSettings.TALUS_MAX_M,
			"an unregistered record falls back to the bound, the safe answer")


func test_measured_cap_never_exceeds_the_bound() -> void:
	var silly := _rec.duplicate()
	silly["talus_m"] = 10_000.0
	assert_eq(PadBed.talus_cap(silly), PadSettings.TALUS_MAX_M,
			"the seam guarantee wins over any measurement")


func test_near_still_covers_apply_with_a_measured_cap() -> void:
	var tight := _rec.duplicate()
	tight["talus_m"] = 14.0
	var pitch := 12.4
	for dh: float in [-30.0, -7.0, 7.0, 30.0]:
		var h := 100.0 + dh
		var e := 0.0
		while e < PadBed.reach_m(tight) + 60.0:
			if PadBed.apply(h, _east(e), [tight], MPD) != h:
				assert_true(PadBed.near([tight], _east(e), MPD, pitch),
						"Δh=%.0f m, %.1f m east is moved but its cell is not refined" % [dh, e])
			e += 0.5


func test_nothing_moves_past_the_reach_with_a_measured_cap() -> void:
	var tight := _rec.duplicate()
	tight["talus_m"] = 14.0
	# The reach is what PadIndex buckets on: a chunk further than this never
	# hears about the pad, so the rule must already be silent there.
	for h: float in [20.0, 60.0, 140.0, 400.0]:
		assert_eq(PadBed.apply(h, _east(PadBed.reach_m(tight)), [tight], MPD), h,
				"h=%.0f m: the pad must not reach past the pixels it is bucketed in" % h)


# ── The authoring node: the box IS the footprint ─────────────────────────
#
# TerrainPad takes its footprint from a child CSGBox3D so the whole setting is
# done with the resize handles in the 3-D view. These cover what that reading
# has to get right; the geometry it feeds is covered above.

func _pad_with_box(size: Vector3, name: String = "Ground",
		scale: Vector3 = Vector3.ONE) -> TerrainPad:
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = name
	box.size = size
	box.scale = scale
	pad.add_child(box)
	add_child_autofree(pad)
	return pad


func test_footprint_comes_from_the_box() -> void:
	var pad := _pad_with_box(Vector3(22.0, 0.2, 100.0))
	assert_eq(pad.footprint_half_extents(), Vector2(11.0, 50.0),
			"the box's FULL size, halved — Godot's own BoxShape3D convention")


func test_box_height_is_ignored() -> void:
	var thin := _pad_with_box(Vector3(22.0, 0.2, 100.0))
	var tall := _pad_with_box(Vector3(22.0, 40.0, 100.0))
	assert_eq(thin.footprint_half_extents(), tall.footprint_half_extents(),
			"the height is the designer's to choose; only X and Z are read")


func test_scaling_the_box_scales_the_footprint() -> void:
	var pad := _pad_with_box(Vector3(20.0, 1.0, 40.0), "Ground", Vector3(2.0, 1.0, 0.5))
	assert_eq(pad.footprint_half_extents(), Vector2(20.0, 10.0),
			"dragging a handle scales the node, and the ground must follow")


func test_any_csgbox_is_taken_when_none_is_named_Ground() -> void:
	var pad := _pad_with_box(Vector3(8.0, 1.0, 6.0), "Emprise")
	assert_eq(pad.footprint_half_extents(), Vector2(4.0, 3.0),
			"an existing scene should not have to be renamed to work")


func test_no_box_means_no_pad() -> void:
	var pad := TerrainPad.new()
	add_child_autofree(pad)
	assert_eq(pad.footprint_half_extents(), Vector2.ZERO)
	assert_gt(pad._get_configuration_warnings().size(), 0,
			"and the inspector must say so rather than fail silently")


func test_the_footprint_survives_the_marker_being_freed() -> void:
	# At runtime TerrainPad reads the box once and frees it — a CSGBox3D is a
	# mesh generator, and this one exists only to be dragged in the editor.
	var pad := _pad_with_box(Vector3(22.0, 0.2, 100.0))
	var want := pad.footprint_half_extents()
	pad.get_node("Ground").free()
	assert_eq(pad.footprint_half_extents(), want,
			"the cached reading is what a spawned building is levelled by")


# ── The lifecycle a networked building goes through ──────────────────────
#
# A prop streamed in by Horizon is REPARENTED: PropSync.client_parent_change /
# server_parent_change call Node.reparent(), which fires _exit_tree then
# _enter_tree — and _ready does NOT run again. Registering in _ready meant the
# pad was torn down by the reparent and never came back, so a building that
# arrived over the network levelled nothing. These pin that down.

## A bare PlanetTerrain with a PlanetData, enough for TerrainPad to resolve and
## register against. initialize() is never called, so the terrain stays inert:
## no chunk is built and nothing is rebuilt.
func _terrain_stub() -> Dictionary:
	var root := Node3D.new()
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	terrain.planet_data = data
	root.add_child(terrain)
	add_child_autofree(root)
	return {"root": root, "terrain": terrain, "data": data}


## A building standing on the surface, under [param holder].
func _building_on(holder: Node3D) -> TerrainPad:
	var building := Node3D.new()
	building.position = Vector3(RADIUS, 0.0, 0.0)
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(22.0, 0.2, 100.0)
	pad.add_child(box)
	building.add_child(pad)
	holder.add_child(building)
	return pad


func test_a_building_registers_its_pad_when_it_enters_the_tree() -> void:
	var t := _terrain_stub()
	_building_on(t["root"])
	await get_tree().process_frame     # the registration is deferred, once
	assert_true((t["data"] as PlanetData).has_pads(),
			"entering the tree is what registers a pad")


func test_the_pad_survives_a_reparent() -> void:
	# THE regression: this is what a Horizon-streamed building does the moment
	# its parent_id arrives, and what the player's own zone churn re-does.
	var t := _terrain_stub()
	var pad := _building_on(t["root"])
	await get_tree().process_frame
	var data := t["data"] as PlanetData
	assert_true(data.has_pads(), "registered once")
	var other := Node3D.new()
	(t["root"] as Node3D).add_child(other)
	(pad.get_parent() as Node3D).reparent(other)
	await get_tree().process_frame
	assert_true(data.has_pads(),
			"a reparent must not leave the ground un-levelled for good")


func test_leaving_the_tree_gives_the_ground_back() -> void:
	# A building going out of GORC range is freed; its pad must go with it, or
	# the terrain would keep a platform under a building that is not there.
	var t := _terrain_stub()
	var pad := _building_on(t["root"])
	await get_tree().process_frame
	var data := t["data"] as PlanetData
	assert_true(data.has_pads())
	(pad.get_parent() as Node3D).get_parent().remove_child(pad.get_parent())
	await get_tree().process_frame
	assert_false(data.has_pads(), "the pad leaves with the building")


func test_a_prop_still_in_universe_coordinates_is_refused() -> void:
	# Between its spawn and Horizon's parent change, a prop sits under the
	# universe root in TRUE coordinates — 1e10 m from the body. Registering
	# then would level a patch of ground somewhere else entirely.
	var t := _terrain_stub()
	var building := Node3D.new()
	building.position = Vector3(3.3e10, 0.0, 0.0)
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(22.0, 0.2, 100.0)
	pad.add_child(box)
	building.add_child(pad)
	(t["root"] as Node3D).add_child(building)
	await get_tree().process_frame
	assert_false((t["data"] as PlanetData).has_pads(),
			"a building nowhere near the surface levels nothing")


# ── Sitting the building down on its platform ────────────────────────────
#
# The platform is at the MEDIAN of the relief under the footprint, not at the
# relief under the building's origin — so a building placed before the pad
# existed floats above it or sinks into it. In the editor that is one press of
# Snap to planet surface; at runtime nobody presses anything, and a building
# streamed in by Horizon carries a pose stored long before any pad existed.
# The server corrects it and replicates, so every client converges.

## Like _terrain_stub, but rooted on a real (inert) Planet, because the snap
## only touches a building standing directly on a body — never one riding a
## vehicle or held by a player.
func _server_planet_stub() -> Dictionary:
	var planet := Planet.new()          # planet_data left null: _ready stays inert
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	terrain.planet_data = data
	terrain.is_server = true
	planet.add_child(terrain)
	add_child_autofree(planet)
	return {"planet": planet, "terrain": terrain, "data": data}


## The altitude of what must land on the platform: the box's TOP face, not the
## building's origin. A floor is a SLAB — levelling the ground to the building's
## origin puts the terrain in the plane of the surface the player walks on.
func _ground_alt(building: Node3D) -> float:
	var pad := building.get_child(0) as TerrainPad
	return pad.ground_reference_global().length() - RADIUS


func _building_at(planet: Node3D, altitude: float) -> Node3D:
	var building := Node3D.new()
	building.position = Vector3(RADIUS + altitude, 0.0, 0.0)
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(22.0, 0.2, 100.0)
	pad.add_child(box)
	building.add_child(pad)
	planet.add_child(building)
	return building


func test_the_server_sits_a_floating_building_on_its_platform() -> void:
	# Without a height pack the platform lands at 0 m; the building starts 40 m
	# above it, which is exactly the Horizon case — a stored pose from before
	# the pad existed.
	var t := _server_planet_stub()
	var building := _building_at(t["planet"], 40.0)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(_ground_alt(building), 0.0, TerrainPad.SNAP_EPSILON_M,
			"the building's underside must end up ON the ground the pad levelled")


func test_a_buried_building_is_lifted_too() -> void:
	var t := _server_planet_stub()
	var building := _building_at(t["planet"], -25.0)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(_ground_alt(building), 0.0, TerrainPad.SNAP_EPSILON_M)


func test_snap_building_false_leaves_the_building_alone() -> void:
	# A building meant to stand off its platform — on stilts, a gantry.
	var t := _server_planet_stub()
	var building := _building_at(t["planet"], 40.0)
	(building.get_child(0) as TerrainPad).snap_building = false
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(building.position.length() - RADIUS, 40.0, 0.01,
			"the pad still levels the ground, the building stays put")


func test_the_client_never_moves_a_networked_building() -> void:
	# The server owns a prop's pose. A client correcting it locally would fight
	# the next replicated update and jitter.
	var t := _server_planet_stub()
	(t["terrain"] as PlanetTerrain).is_server = false
	var building := _building_at(t["planet"], 40.0)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(building.position.length() - RADIUS, 40.0, 0.01)


func test_the_snap_is_radial_so_the_pad_does_not_wander() -> void:
	# Moving the building must not change WHERE the ground is levelled, or the
	# correction and the platform would chase each other.
	var t := _server_planet_stub()
	var building := _building_at(t["planet"], 40.0)
	var before := (building.position as Vector3).normalized()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq((building.position as Vector3).normalized().distance_to(before), 0.0, 1e-9,
			"same longitude and latitude, only the altitude changed")


# ── Standing the building square on the surface ──────────────────────────
#
# "Snapped to the surface" is two things: the right altitude AND the right
# orientation. Correcting only the altitude leaves a tilted building with its
# ORIGIN perfectly on the platform and its far end metres into the ground —
# over the 97 m of a cargo depot, one degree buries the far end by 1.7 m. That
# is why the gap printed at the origin can read +0.01 m while the player sees
# the terrain inside the building.

func _tilted_building(planet: Node3D, altitude: float, tilt_deg: float) -> Node3D:
	var building := Node3D.new()
	building.position = Vector3(RADIUS + altitude, 0.0, 0.0)
	# Local "up" here is +X (the building sits on the +X axis of the body), so
	# a square building has its +Y along +X. Start it tilted from that.
	# +90° about +Z sends +Y to −X, so the sign is negative to land on +X.
	building.basis = Basis(Vector3(0, 0, 1), deg_to_rad(-(90.0 + tilt_deg)))
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(22.0, 0.2, 100.0)
	pad.add_child(box)
	building.add_child(pad)
	planet.add_child(building)
	return building


func _tilt_of(building: Node3D) -> float:
	return rad_to_deg(building.basis.y.normalized().angle_to(
			(building.position as Vector3).normalized()))


func test_the_server_stands_a_tilted_building_square() -> void:
	var t := _server_planet_stub()
	var building := _tilted_building(t["planet"], 0.0, 6.0)
	assert_almost_eq(_tilt_of(building), 6.0, 0.01, "starts tilted")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(_tilt_of(building), 0.0, TerrainPad.SNAP_EPSILON_DEG,
			"a building streamed in with a stored pose must end up square on the ground")


func test_straightening_preserves_the_heading() -> void:
	var t := _server_planet_stub()
	var building := _tilted_building(t["planet"], 0.0, 6.0)
	var up_before: Vector3 = (building.position as Vector3).normalized()
	var heading_before := (-(building.basis.z) - up_before * (-(building.basis.z)).dot(up_before)).normalized()
	await get_tree().process_frame
	await get_tree().process_frame
	var heading_after := (-(building.basis.z)).normalized()
	assert_almost_eq(heading_before.angle_to(heading_after), 0.0, deg_to_rad(0.5),
			"the building must not spin on the spot while being straightened")


func test_a_square_building_is_left_alone() -> void:
	var t := _server_planet_stub()
	# Already seated: the box is 0.2 m thick and centred on the pad, so its top
	# face is 0.1 m ABOVE the origin — put the origin 0.1 m down and the ground
	# reference already sits on the platform.
	var building := _tilted_building(t["planet"], -0.1, 0.0)
	var before := building.transform
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq((building.transform.origin - before.origin).length(), 0.0, 0.01)
	assert_almost_eq(_tilt_of(building), 0.0, TerrainPad.SNAP_EPSILON_DEG)


func test_the_ground_sits_at_the_top_face_of_the_box() -> void:
	# The rule that makes the box read itself: the ground is at its TOP face,
	# so sinking the box until it vanishes into the floor is proof the ground
	# is below the floor — no arithmetic about the box's own thickness.
	var pad := _pad_with_box(Vector3(22.0, 0.2, 100.0))
	assert_almost_eq(pad.ground_reference_global().y - pad.global_position.y, 0.1, 1e-6,
			"the ground reference is the box's top face")
	var deep := _pad_with_box(Vector3(22.0, 2.0, 100.0))
	assert_almost_eq(deep.ground_reference_global().y - deep.global_position.y, 1.0, 1e-6,
			"a thicker box raises its top face, and the ground with it")


# ── Cutting a road under the building ────────────────────────────────────
#
# A road ribbon is a slab laid ON the terrain, so over a levelled platform it
# sits its own thickness above it — and therefore above the building's floor.
# Measured on tarsis_3: a path 10.8 cm above the platform, 3 of its vertices
# inside a cargo depot. A path does not run through a warehouse: it stops at
# the wall, exactly as RoadCut.split already makes it stop under a viaduct.

## A straight road running east through the pad's latitude band, [param north_m]
## north of its centre, from 100 m west to 100 m east. Along 0 is the west end.
func _road_east(north_m: float) -> Array:
	var lat := north_m / MPD
	var cl := PackedVector2Array([Vector2(-100.0 / MPD, lat), Vector2(100.0 / MPD, lat)])
	var cum := PackedFloat64Array([0.0, 200.0])
	return [cl, cum]


func test_a_road_crossing_the_footprint_is_cut() -> void:
	var r := _road_east(0.0)
	var cuts := PadBed.road_exclusion(_rec, r[0], r[1], MPD)
	assert_eq(cuts.size(), 1, "one crossing, one interval")
	# The footprint reaches 10 m either side of the centre, so the road is
	# inside from along 90 to along 110, widened by the cut margin.
	assert_almost_eq((cuts[0] as Vector2).x, 89.5, 1.0)
	assert_almost_eq((cuts[0] as Vector2).y, 110.5, 1.0)


func test_a_road_that_misses_the_footprint_is_left_whole() -> void:
	# 25 m north: past the 15 m half-length, so nothing is cut.
	var r := _road_east(25.0)
	assert_eq(PadBed.road_exclusion(_rec, r[0], r[1], MPD).size(), 0)


func test_the_apron_is_not_cut() -> void:
	# 20 m north: outside the footprint (15 m) but well inside the apron
	# (15 + 8 = 23 m). That is the ground a vehicle parks on — a path across it
	# is exactly right, so it must survive.
	var r := _road_east(20.0)
	assert_eq(PadBed.road_exclusion(_rec, r[0], r[1], MPD).size(), 0,
			"a path may cross the apron; only the building's own footprint cuts it")


func test_the_cut_covers_every_point_the_footprint_holds() -> void:
	# The guarantee that matters: no sliver of asphalt survives inside the
	# building. Every sample the rule says is inside must fall in an interval.
	var r := _road_east(0.0)
	var cuts := PadBed.road_exclusion(_rec, r[0], r[1], MPD)
	var cl: PackedVector2Array = r[0]
	var s := 0.0
	while s <= 200.0:
		var p := cl[0].lerp(cl[1], s / 200.0)
		if PadBed.sdf_m(_rec, p, MPD) <= 0.0:
			var covered := false
			for c: Vector2 in cuts:
				if s >= c.x and s <= c.y:
					covered = true
					break
			assert_true(covered, "along %.1f m is inside the building and not cut" % s)
		s += 0.1


func test_the_cut_widens_by_the_ribbons_half_width() -> void:
	# The centreline is what is walked, but the ribbon's CORNER is what pokes
	# through the wall: on a road crossing at an angle it reaches half a width
	# further in. Measured on tarsis_3 before this was taken into account: 55 cm
	# of asphalt left inside a cargo depot, 15 cm above its floor.
	var r := _road_east(0.0)
	var narrow := PadBed.road_exclusion(_rec, r[0], r[1], MPD, 0.0)
	var wide := PadBed.road_exclusion(_rec, r[0], r[1], MPD, 3.0)
	assert_eq(narrow.size(), 1)
	assert_eq(wide.size(), 1)
	assert_almost_eq((narrow[0] as Vector2).x - (wide[0] as Vector2).x, 3.0, 0.3,
			"a 3 m half-width pushes the cut 3 m further out on each side")
	assert_almost_eq((wide[0] as Vector2).y - (narrow[0] as Vector2).y, 3.0, 0.3)
