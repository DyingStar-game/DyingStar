extends GutTest
## The inside of a home exists only near the camera where something is drawn (InteriorStreamer): the
## apartments are copied as shells, their interiors instanced within LOAD_M and freed past UNLOAD_M, and
## an interior instanced again shows the furniture as the building keeps it.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const DOOR := "Interior/Wardrobe/wardrobe2/wardrobe_door_door_r/DoorR"


func test_a_margin_between_loading_and_freeing() -> void:
	assert_true(InteriorStreamer.wants(false, InteriorStreamer.LOAD_M - 1.0), "near: instanced")
	assert_false(InteriorStreamer.wants(false, InteriorStreamer.LOAD_M + 1.0), "farther: not yet")
	assert_true(InteriorStreamer.wants(true, InteriorStreamer.LOAD_M + 1.0), "loaded, a little farther: kept")
	assert_false(InteriorStreamer.wants(true, InteriorStreamer.UNLOAD_M + 1.0), "far: freed")


func test_headless_every_interior_stays() -> void:
	var building := _building(false)
	for room in _rooms(building).get_children():
		assert_not_null(room.get_node_or_null(^"Interior"), "%s: furnished" % room.name)
	assert_null(building.get_node_or_null(^"InteriorStreamer"))
	KnownEngineErrors.forgive_floor_material(self)


func test_interiors_come_and_go_with_the_camera() -> void:
	var building := _building(true)
	var streamer := building.get_node(^"InteriorStreamer") as InteriorStreamer
	var rooms := _rooms(building)
	assert_eq(_furnished(rooms), 0, "copied as shells")
	for i in rooms.get_child_count():
		await wait_process_frames(1)  # one interior a frame
		streamer.refresh(Vector3(-3.0, 1.3, 1.3))
	assert_eq(_furnished(rooms), rooms.get_child_count(), "all near: all furnished")
	streamer.refresh(Vector3(500.0, 0.0, 0.0))
	assert_eq(_furnished(rooms), 0, "far: all freed")
	KnownEngineErrors.forgive_floor_material(self)


func test_an_interior_instanced_again_shows_the_kept_state() -> void:
	var building := _building(true)
	var streamer := building.get_node(^"InteriorStreamer") as InteriorStreamer
	var key := "0-0-0/" + DOOR
	building.apply_prop_data({"furniture": {key: true}})
	await wait_process_frames(1)  # a fresh frame's budget
	streamer.refresh(Vector3(-3.0, 1.3, 1.3))
	var door := _rooms(building).get_node("0-0-0/" + DOOR) as MovingPart
	assert_true(door.is_on, "open as the building keeps it")
	streamer.refresh(Vector3(500.0, 0.0, 0.0))
	await wait_process_frames(1)
	building.apply_prop_data({"furniture": {key: false}})  # shut meanwhile, nobody near
	await wait_process_frames(1)
	streamer.refresh(Vector3(-3.0, 1.3, 1.3))
	door = _rooms(building).get_node("0-0-0/" + DOOR) as MovingPart
	assert_false(door.is_on, "shut, as it was set while away")
	KnownEngineErrors.forgive_floor_material(self)


## A one-row building of three apartments, its interiors [param streamed] or all there.
func _building(streamed: bool) -> SpawnBuilding:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	PropSync.of(building).uuid = "home-uuid"  # its parts find their building by it
	building.cols = 3
	building.stream_interiors = streamed
	add_child_autofree(building)
	building.apply_prop_data({"apartments": []})
	return building


func _rooms(building: SpawnBuilding) -> Node:
	return building.get_node(^"MultiMeshInstance3D")


func _furnished(rooms: Node) -> int:
	return rooms.get_children().filter(func(r: Node) -> bool: return r.has_node(^"Interior")).size()
