extends GutTest
## A POI village stands itself on the ground before spawning its items: their poses are composed with
## the village's, and startup_items.json stored 54 villages of tarsis_3 at the same 8 363 m — the
## buildings came back down on their TerrainPad, the mining depot stayed kilometres up.

const RADIUS := 6356000.0
const VillageScript := preload("res://scenes/_universe/structures/urban/poi_villages.gd")
## A scene small enough to stand for a layout, and a networked prop to spawn from one.
const LAMP := "res://scenes/_universe/props/furniture/furn_lamppost_outdoor_3.4m.tscn"


## An inert Planet with a flat PlanetData (no height pack: the relief reads 0 m everywhere).
func _planet() -> Planet:
	var planet := Planet.new()
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	terrain.planet_data = data
	planet.planet_terrain = terrain
	planet.add_child(terrain)
	add_child_autofree(planet)
	return planet


func _village(planet: Planet, altitude: float, tilt_deg: float) -> Node3D:
	var village := Node3D.new()
	village.set_script(VillageScript)
	village.position = Vector3(RADIUS + altitude, 0.0, 0.0)
	# Square on +X is "+Y along +X" (-90° about Z); tilt it from there, and give it a heading.
	village.basis = Basis(Vector3(0, 0, 1), deg_to_rad(-(90.0 + tilt_deg))) * Basis(Vector3.UP, 0.6)
	planet.add_child(village)
	return village


func test_a_village_stored_too_high_stands_on_the_ground() -> void:
	var village := _village(_planet(), 2723.0, 4.0)
	assert_true(village._stand_on_ground())
	assert_almost_eq(village.position.length() - RADIUS, 0.0, 0.01, "on the ground under its centre")
	assert_almost_eq(rad_to_deg(village.basis.y.angle_to(village.position.normalized())), 0.0, 0.01,
			"standing square: its items are composed with this frame")


func test_a_village_stored_underground_comes_up() -> void:
	var village := _village(_planet(), -800.0, 0.0)
	assert_true(village._stand_on_ground())
	assert_almost_eq(village.position.length() - RADIUS, 0.0, 0.01)


func test_the_heading_is_kept() -> void:
	var village := _village(_planet(), 2723.0, 4.0)
	var up_before: Vector3 = village.position.normalized()
	var fwd_before: Vector3 = village.basis.z - up_before * village.basis.z.dot(up_before)
	village._stand_on_ground()
	var up: Vector3 = village.position.normalized()
	var fwd: Vector3 = village.basis.z - up * village.basis.z.dot(up)
	assert_almost_eq(rad_to_deg(fwd.angle_to(fwd_before)), 0.0, 0.01, "same direction on the ground")


func test_no_elevation_ever_leaves_the_village_where_it_is() -> void:
	# A pack that has no tile there and no streaming source to bring one: reading the relief would
	# give the flat global fallback, kilometres off. Better the stored pose.
	var planet := _planet()
	planet.planet_terrain.planet_data.chunk_heightmaps_dir = "res://does_not_exist_chunks"
	var village := _village(planet, 2723.0, 0.0)
	assert_true(village._stand_on_ground(), "the items still spawn")
	assert_almost_eq(village.position.length() - RADIUS, 2723.0, 0.01, "at the stored pose")


## A networked village spawning a layout, parked before its first share.
func _spawning(planet: Planet) -> Node3D:
	var village := _village(planet, 0.0, 0.0)
	var sync := PropSync.new()
	sync.name = "PropSync"
	sync.uuid = "village-under-test"
	village.add_child(sync)
	village.spawn_scene = LAMP
	village.spawn_items()
	return village


func _frames_until_done(village: Node3D) -> int:
	var frames := 0
	while not village._spawn_steps.is_empty() and frames < 2000:
		await get_tree().process_frame
		frames += 1
	return frames


func test_a_spawn_runs_over_frames_and_ends() -> void:
	var village := _spawning(_planet())
	assert_true(village.is_spawned, "marked at once: every replicated update would start it again")
	assert_false(village._spawn_steps.is_empty(), "nothing is done in the caller's frame")
	var frames: int = await _frames_until_done(village)
	assert_true(village._spawn_steps.is_empty())
	assert_gt(frames, 2)
	assert_eq(village._spawn_todo.size(), 0, "nothing kept")
	assert_true(village.is_spawned)
	assert_false(get_tree().process_frame.is_connected(village._spawn_step))
	assert_false(village._spawn_holds_stream)


func test_a_spawn_is_asked_only_once() -> void:
	var village := _spawning(_planet())
	var steps: Array = village._spawn_steps.duplicate()
	village.spawn_items()
	assert_eq(village._spawn_steps, steps, "not started again")
	await _frames_until_done(village)


func test_a_village_gone_before_the_end_of_its_spawn_leaves_nothing_behind() -> void:
	var planet := _planet()
	var village := _spawning(planet)
	planet.remove_child(village)
	assert_true(village._spawn_steps.is_empty())
	assert_false(village.is_spawned, "the next spawn's to finish")
	assert_false(get_tree().process_frame.is_connected(village._spawn_step))
	assert_false(village._spawn_holds_stream)
	village.free()


func test_a_layout_that_cannot_be_loaded_gives_the_spawn_back() -> void:
	var village := _village(_planet(), 0.0, 0.0)
	var sync := PropSync.new()
	sync.name = "PropSync"
	sync.uuid = "village-under-test"
	village.add_child(sync)
	village.spawn_scene = "res://scenes/no/such/layout.tscn"
	village.spawn_items()
	assert_false(village.is_spawned)
	assert_true(village._spawn_steps.is_empty())


func test_the_stream_waits_for_the_pads_of_a_layout() -> void:
	var agent := Node.new()
	agent.set_script(load("res://test/unit/fixtures/stream_holds_agent.gd"))
	autofree(agent)
	var before = NetworkOrchestrator.network_agent
	NetworkOrchestrator.network_agent = agent
	var village := _village(_planet(), 0.0, 0.0)
	village._hold_stream(true)
	village._hold_stream(true)
	assert_eq(agent.stream_holds, 1, "once a village")
	village._hold_stream(false)
	village._hold_stream(false)
	assert_eq(agent.stream_holds, 0)
	NetworkOrchestrator.network_agent = before


func test_an_item_is_read_into_the_data_of_its_prop() -> void:
	var village := _village(_planet(), 0.0, 0.0)
	var item: Node3D = (load(LAMP) as PackedScene).instantiate()
	assert_true(VillageScript.is_spawnable(item), "the fixture is a networked prop")
	var pose := Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0))
	var data: Dictionary = village._item_data(item, pose, "parent-frame", "Lamp", "village-under-test")
	assert_eq(data["uuid"], VillageScript._item_uuid("village-under-test", "Lamp"))
	assert_eq(data["uuid"], VillageScript._item_uuid("village-under-test", "Lamp"), "the same at each restart")
	assert_eq(data["parent_id"], "parent-frame")
	assert_eq(data["position"], {"x": 1.0, "y": 2.0, "z": 3.0})
	assert_eq(data["scenename"], LAMP.trim_prefix("res://"))
	item.free()
