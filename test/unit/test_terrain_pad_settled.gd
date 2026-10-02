extends GutTest
## A building's pad is measured ONCE: the server persists the altitude it levelled the ground to in the
## building's terrain_settled field (Horizon zone 6), and every later server (restart, wake, hand-over)
## and every client levels the ground from it — no relief sample, no wait for an elevation tile. These
## pin down when the persisted measure is trusted, and that it survives Horizon's JSON.

const RADIUS := 6356000.0
const RELIEF := "relief-test"


func _data() -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = RELIEF
	return data


func _rec(uuid: String = "prop:b1") -> Dictionary:
	return PadBed.record(uuid, 12.3456789, -4.5678901, 0.4, 11.0, 50.0, 8.0, 0.0)


func _settled(entry: Dictionary, uuid: String = "prop:b1", relief: String = RELIEF) -> Dictionary:
	return {"relief": relief, "pads": {uuid: entry}}


# ── PlanetData.register_pad ──────────────────────────────────────────────

func test_settled_stats_are_used_instead_of_the_relief() -> void:
	var data := _data()  # no height pack: the relief would read 0 m everywhere
	var rec := _rec()
	rec["settled"] = {"z": 42.0, "span": 3.0, "talus_m": 9.0}
	data.register_pad(rec)
	assert_true(data.has_pads())
	assert_eq(data.pad_altitude(_rec()), 42.0, "the persisted altitude, not the 0 m the relief gives")


func test_a_settled_pad_does_not_wait_for_its_tiles() -> void:
	var data := _data()
	data.chunk_heightmaps_dir = "res://does_not_exist_chunks"  # every tile unreadable
	data.register_pad(_rec("prop:starved"))
	assert_true(data.pads_incomplete(), "a pad to measure waits for its tiles")
	var rec := _rec()
	rec["settled"] = {"z": 42.0, "span": 3.0, "talus_m": 9.0}
	data.register_pad(rec)
	assert_eq(data.pad_altitude(_rec()), 42.0, "a measured pad levels the ground at once")


# ── When the persisted measure is trusted ────────────────────────────────

func _measured(data: PlanetData) -> Dictionary:
	data.register_pad(_rec())
	return data.pad_settled_entry("prop:b1")


func test_the_published_entry_gives_back_the_registered_stats() -> void:
	var data := _data()
	var entry := _measured(data)
	assert_false(entry.is_empty())
	var st := data.pad_settled_stats(_rec(), _settled(entry))
	assert_eq(st.get("z"), data.pad_altitude(_rec()))


func test_the_entry_survives_horizons_json() -> void:
	var data := _data()
	var entry := _measured(data)
	entry["z"] = 8338.123456789  # an altitude with more digits than JSON keeps
	var expected := PadBed.quantise_stats(entry)
	var back = JSON.parse_string(JSON.stringify(_settled(entry)))
	var st := data.pad_settled_stats(_rec(), back)
	assert_false(st.is_empty(), "the geometry still matches after the round trip")
	assert_eq(st, expected, "bit for bit the stats the server registered")


func test_a_moved_building_is_measured_again() -> void:
	var data := _data()
	var entry := _measured(data)
	var moved := PadBed.record("prop:b1", 12.3457789, -4.5678901, 0.4, 11.0, 50.0, 8.0, 0.0)
	assert_true(data.pad_settled_stats(moved, _settled(entry)).is_empty())


func test_a_resized_building_is_measured_again() -> void:
	var data := _data()
	var entry := _measured(data)
	var wider := PadBed.record("prop:b1", 12.3456789, -4.5678901, 0.4, 14.0, 50.0, 8.0, 0.0)
	assert_true(data.pad_settled_stats(wider, _settled(entry)).is_empty())


func test_a_re_exported_relief_is_measured_again() -> void:
	var data := _data()
	var entry := _measured(data)
	assert_true(data.pad_settled_stats(_rec(), _settled(entry, "prop:b1", "old-relief")).is_empty())


func test_nothing_is_trusted_before_the_relief_is_known() -> void:
	var data := _data()
	var entry := _measured(data)
	data.relief_signature = ""
	assert_true(data.pad_settled_stats(_rec(), _settled(entry, "prop:b1", "")).is_empty())


func test_another_pad_s_entry_is_not_taken() -> void:
	var data := _data()
	var entry := _measured(data)
	assert_true(data.pad_settled_stats(_rec(), _settled(entry, "prop:other")).is_empty())


# ── The live building on the server ──────────────────────────────────────

func _server_planet() -> Dictionary:
	var planet := Planet.new()
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	terrain.planet_data = _data()
	terrain.is_server = true
	planet.add_child(terrain)
	add_child_autofree(planet)
	return {"planet": planet, "data": terrain.planet_data}


func _networked_building(planet: Node3D, altitude: float, settled: Dictionary = {}) -> Node3D:
	var building := Node3D.new()
	building.position = Vector3(RADIUS + altitude, 0.0, 0.0)
	# Square on the surface (+Y along the radial +X): straightening it would change the pad's yaw,
	# and a persisted measure is rightly dropped for a building that turned.
	building.basis = Basis(Vector3(0, 0, 1), deg_to_rad(-90.0))
	var pad := TerrainPad.new()
	var box := CSGBox3D.new()
	box.name = "Ground"
	box.size = Vector3(22.0, 0.2, 100.0)
	pad.add_child(box)
	building.add_child(pad)
	var sync := PropSync.new()
	sync.name = "PropSync"
	sync.uuid = "b1"
	sync.terrain_settled = settled
	building.add_child(sync)
	planet.add_child(building)
	return building


func _ground_alt(building: Node3D) -> float:
	return (building.get_child(0) as TerrainPad).ground_reference_global().length() - RADIUS


func test_the_server_persists_the_measure_once_the_building_is_seated() -> void:
	var t := _server_planet()
	var building := _networked_building(t["planet"], 40.0)
	for _i in 3:
		await get_tree().process_frame
	var sync := PropSync.of(building)
	assert_eq(sync.terrain_settled.get("relief"), RELIEF)
	var entry: Dictionary = (sync.terrain_settled.get("pads", {}) as Dictionary).get("prop:b1", {})
	assert_false(entry.is_empty(), "the pad's measure is in the building's data")
	assert_almost_eq(float(entry["z"]), 0.0, 1e-6)
	assert_almost_eq(_ground_alt(building), 0.0, TerrainPad.SNAP_EPSILON_M, "seated before persisting")


func test_a_measured_building_levels_from_its_data() -> void:
	# Measured by an earlier server at 5 m; the relief here would say 0 m. Taking 5 m proves no
	# sample was taken — the building is seated on the persisted platform.
	var t := _server_planet()
	var building := _networked_building(t["planet"], 5.0)
	var pad := building.get_child(0) as TerrainPad
	var entry := PadBed.settled_entry(pad.build_record(), {"z": 5.0, "span": 0.0, "talus_m": 4.0})
	PropSync.of(building).terrain_settled = _settled(entry)
	for _i in 3:
		await get_tree().process_frame
	assert_eq((t["data"] as PlanetData).pad_altitude(pad.build_record()), 5.0)
	assert_almost_eq(_ground_alt(building), 5.0, TerrainPad.SNAP_EPSILON_M, "not moved down to 0 m")


func test_a_pad_that_waited_for_its_tiles_still_seats_and_persists() -> void:
	# The first boot in the logs: the tiles under a village were not there yet, the retry gave the pads
	# their altitude later — and nothing called the buildings back, left floating and never persisted.
	var t := _server_planet()
	var data := t["data"] as PlanetData
	data.chunk_heightmaps_dir = "res://does_not_exist_chunks"  # every tile unreadable
	var building := _networked_building(t["planet"], 40.0)
	for _i in 3:
		await get_tree().process_frame
	assert_true(data.pads_incomplete(), "waiting for its tiles")
	assert_true(PropSync.of(building).terrain_settled.is_empty(), "nothing measured yet")

	data.chunk_heightmaps_dir = ""  # the tiles arrive
	var terrain: PlanetTerrain = (t["planet"] as Node).get_node("PlanetTerrain")
	terrain._poll_starved_pads()
	for _i in 3:
		await get_tree().process_frame
	assert_false(data.pads_incomplete())
	assert_almost_eq(_ground_alt(building), 0.0, TerrainPad.SNAP_EPSILON_M, "seated once caught up")
	assert_false(PropSync.of(building).terrain_settled.is_empty(), "and its measure persisted")


func test_a_pose_replayed_rounded_keeps_its_measure() -> void:
	# A restart replays the pose Horizon persisted, rounded to 5 mm: its quantised longitude may land
	# one step off the one measured. One step keeps the measure; two are a real move.
	var data := _data()
	var entry := _measured(data)
	var one := PadBed.record("prop:b1", 12.3456789 + PadSettings.Q_DEG, -4.5678901, 0.4, 11.0, 50.0, 8.0, 0.0)
	var two := PadBed.record("prop:b1", 12.3456789 + 2.0 * PadSettings.Q_DEG, -4.5678901, 0.4,
			11.0, 50.0, 8.0, 0.0)
	assert_false(data.pad_settled_stats(one, _settled(entry)).is_empty(), "one rounding step")
	assert_true(data.pad_settled_stats(two, _settled(entry)).is_empty(), "two steps: measured again")


func test_a_building_s_rotation_is_persisted_finer_than_the_snap_threshold() -> void:
	# Persisted at 0.005 rad (0.29°), a building came back tilted past SNAP_EPSILON_DEG on every
	# restart, was straightened and re-measured — the loop terrain_settled exists to end.
	var building := Node3D.new()
	assert_lt(rad_to_deg(PropNet.rotation_quantum(building)), TerrainPad.SNAP_EPSILON_DEG / 2.0)
	building.free()
	var rb := RigidBody3D.new()
	assert_eq(PropNet.rotation_quantum(rb), 0.005, "physics bodies keep the coarse step")
	rb.free()


# ── The roads a pad cuts, kept pad by pad ────────────────────────────────
#
# Every pad change used to re-cut the roads of EVERY pad: ~20 ms a pad on tarsis_3, quadratic in the
# pads, 35 s of main thread on a cold boot measuring fifty of them. The table is now updated for the
# changed pad only, and must stay equal to the full rebuild it replaced.

class RoadData extends PlanetData:
	var roads: Array = []

	func has_roads() -> bool:
		return true

	func get_roads_for_chunk(_hp_nside: int, _hp_ipix: int) -> Array:
		return roads


func _road(fid: int, a: Vector2, b: Vector2, mpd: float) -> Dictionary:
	return {"feature_id": fid, "centerline": PackedVector2Array([a, b]),
			"_cum_lengths": PackedFloat64Array([0.0, a.distance_to(b) * mpd]), "half_width_m": 3.0}


func _road_data() -> RoadData:
	var data := RoadData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	var mpd := RADIUS * PI / 180.0
	data.roads = [
		_road(1, Vector2(-0.01, 0.0), Vector2(0.01, 0.0), mpd),         # east-west, through both pads
		_road(2, Vector2(0.0, -0.01), Vector2(0.0, 0.01), mpd),         # north-south, through the first
		_road(3, Vector2(0.5, 0.5), Vector2(0.51, 0.5), mpd),           # far away: cut by nobody
	]
	return data


func _assert_incremental_equals_full(data: RoadData, why: String) -> void:
	assert_eq(data._pad_road_excl, data._build_pad_road_exclusions(data._pads), why)


func test_road_cuts_follow_each_pad_without_rebuilding_them_all() -> void:
	var data := _road_data()
	var a := PadBed.record("prop:a", 0.0, 0.0, 0.0, 10.0, 15.0, 8.0, 0.0)
	var b := PadBed.record("prop:b", 0.002, 0.0, 0.0, 10.0, 15.0, 8.0, 0.0)
	data.register_pad(a)
	assert_true(data.road_exclusions_for_feature(1).size() > 0, "the pad cuts the road through it")
	assert_true(data.road_exclusions_for_feature(2).size() > 0)
	assert_eq(data.road_exclusions_for_feature(3), [], "and not a road far away")
	_assert_incremental_equals_full(data, "one pad")
	data.register_pad(b)
	_assert_incremental_equals_full(data, "two pads on the same road")
	var moved := PadBed.record("prop:a", 0.0, 0.003, 0.0, 10.0, 15.0, 8.0, 0.0)
	data.register_pad(moved)  # 330 m north: off road 1, still on road 2
	_assert_incremental_equals_full(data, "a pad moved")
	data.unregister_pad("prop:b")
	_assert_incremental_equals_full(data, "a pad gone")
	data.unregister_pad("prop:a")
	assert_eq(data._pad_road_excl, {}, "no pad, no cut")
