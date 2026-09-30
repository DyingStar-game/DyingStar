extends GutTest
## PropRegistry: the server keeps every prop of its zones as data and only builds the ones where
## someone is. These tests cover the bookkeeping alone (no scene tree): where an item is indexed, how
## it moves between indexes, and that forgetting it takes its children along.


func _event(uuid: String, type: String = "miningrock", od: Dictionary = {}) -> Dictionary:
	return {"data": {"object_uuid": uuid, "object_type": type, "object_data": od}}


func test_upsert_records_then_merges() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a", "miningrock", {"generated": false}))
	r.upsert(_event("a", "miningrock", {"fractures": [1]}))
	var od: Dictionary = r.get_entry("a")["event"]["data"]["object_data"]
	assert_eq(r.size(), 1, "same uuid twice = one entry")
	assert_eq(od.get("generated"), false, "earlier state kept")
	assert_eq(od.get("fractures"), [1], "new state merged")


func test_merge_data_stores_vectors_as_horizon_dictionaries() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a"))
	r.merge_data("a", {"position": Vector3(1, 2, 3)})
	assert_eq(r.get_entry("a")["event"]["data"]["object_data"]["position"], {"x": 1.0, "y": 2.0, "z": 3.0})


func test_ground_item_is_found_by_either_chunk_key() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a"))
	r.place_ground("a", "planet", Vector3.ONE, PackedStringArray(["hp_n8192_p5", "hp_n64_p0"]))
	assert_eq(r.uuids_on_chunk("planet", "hp_n8192_p5"), ["a"], "the pins' fine key")
	assert_eq(r.uuids_on_chunk("planet", "hp_n64_p0"), ["a"], "the zone's export key")
	assert_true(PropRegistry.on_resident_chunk(r.get_entry("a"), {"hp_n64_p0": true}))
	assert_false(PropRegistry.on_resident_chunk(r.get_entry("a"), {"hp_n8192_p6": true}))


func test_replacing_moves_the_item_between_chunks() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a"))
	r.place_ground("a", "planet", Vector3.ONE, PackedStringArray(["k1"]))
	r.place_ground("a", "planet", Vector3.ONE, PackedStringArray(["k2"]))
	assert_eq(r.uuids_on_chunk("planet", "k1"), [], "left its old chunk")
	assert_eq(r.uuids_on_chunk("planet", "k2"), ["a"])


func test_radius_query_uses_each_items_own_radius() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("small", "box"))
	r.upsert(_event("station", "spacestation"))
	r.place_radius("small", "space", Vector3(1000, 0, 0), 200.0)
	r.place_radius("station", "space", Vector3(1000, 0, 0), 12000.0)
	assert_eq(r.uuids_near("space", Vector3.ZERO, 1.0), ["station"], "1 km away: only the big one")
	var both: Array = r.uuids_near("space", Vector3(900, 0, 0), 1.0)
	both.sort()
	assert_eq(both, ["small", "station"], "100 m away: both")


func test_radius_query_with_a_wider_factor_keeps_items_alive() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a", "box"))
	r.place_radius("a", "space", Vector3(300, 0, 0), 200.0)
	assert_eq(r.uuids_near("space", Vector3.ZERO, 1.0), [], "beyond the load radius")
	assert_eq(r.uuids_near("space", Vector3.ZERO, 1.6), ["a"], "within the unload radius")


func test_radius_query_is_per_world() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("a", "box"))
	r.place_radius("a", "planetA", Vector3.ZERO, 200.0)
	assert_eq(r.uuids_near("space", Vector3.ZERO, 1.0), [], "a viewer in space sees nothing of planetA")


func test_waiting_items_become_placeable_when_their_parent_arrives() -> void:
	var r := PropRegistry.new()
	r.upsert(_event("cargo"))
	r.place_waiting("cargo", "truck")
	assert_eq(r.take_waiting("truck"), ["cargo"])
	assert_eq(r.take_waiting("truck"), [], "taken once")


func test_forget_takes_the_children_along() -> void:
	var r := PropRegistry.new()
	for u in ["truck", "crate", "engine", "rock"]:
		r.upsert(_event(u))
	r.place_ground("truck", "planet", Vector3.ONE, PackedStringArray(["k"]))
	r.place_child("crate", "truck")
	r.place_child("engine", "crate")
	r.place_ground("rock", "planet", Vector3.ONE, PackedStringArray(["k"]))
	r.live["truck"] = true
	var dropped: Array = r.forget("truck").map(func(e): return e["uuid"])
	assert_eq(dropped, ["truck", "crate", "engine"], "parents before children")
	assert_false(r.has("crate"))
	assert_false(r.live.has("truck"))
	assert_eq(r.uuids_on_chunk("planet", "k"), ["rock"], "the neighbour stays")
	assert_false(r.children_of.has("truck"))


func test_subtree_lists_parents_first() -> void:
	var r := PropRegistry.new()
	for u in ["a", "b", "c"]:
		r.upsert(_event(u))
	r.place_ground("a", "p", Vector3.ONE, PackedStringArray(["k"]))
	r.place_child("b", "a")
	r.place_child("c", "b")
	assert_eq(r.subtree("a"), ["a", "b", "c"])


func test_item_defs_reads_the_existence_channel() -> void:
	var def := {"channels": [
		{"zone": 0, "distance": 150.0}, {"zone": 6, "distance": 203.0}, {"zone": 3, "distance": 500.0}]}
	assert_eq(ItemDefs.existence_distance(def), 203.0, "zone 6 wins even when another is wider")
	assert_eq(ItemDefs.existence_distance({"channels": [{"zone": 0, "distance": 200.0}]}), 200.0,
		"no zone 6: the widest channel")
	assert_eq(ItemDefs.existence_distance({}), 0.0)


func test_item_defs_loads_the_project_definitions() -> void:
	ItemDefs.reset()
	assert_eq(ItemDefs.zone6_distance("miningrock"), 203.0)
	assert_almost_eq(ItemDefs.load_radius("miningrock", 1.2), 243.6, 0.01)
	assert_eq(ItemDefs.load_radius("no_such_type", 1.2), 0.0, "unknown type: 0 = keep it loaded")


func test_a_vehicle_unloaded_by_the_server_is_not_deleted() -> void:
	var deleted: Array = []
	var v := Vehicle.new()
	v.uuid = "truck-uuid"
	v._server_live = true
	v.hs_server_prop_delete.connect(func(u: String, _t: String) -> void: deleted.append(u))
	v.server_reparenting = true  # what _free_without_delete sets before queue_free
	v.free()
	assert_eq(deleted, [], "dormancy / hand-over: no delete for Horizon")


func test_a_destroyed_vehicle_is_deleted() -> void:
	var deleted: Array = []
	var v := Vehicle.new()
	v.uuid = "truck-uuid"
	v._server_live = true
	v.hs_server_prop_delete.connect(func(u: String, _t: String) -> void: deleted.append(u))
	v.free()
	assert_eq(deleted, ["truck-uuid"])
