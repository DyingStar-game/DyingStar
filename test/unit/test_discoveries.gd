extends GutTest
## Places discovered by players and the names they propose (Discovery, server/discoveries.gd, PlaceWatcher):
## who becomes the discoverer, that a discovery is never created twice (a second create would wipe a name
## ARES approved), and that only its discoverer may name it, by the rule.

const Fixture := preload("res://test/unit/stargrot_fixture.gd")
const PLAYER := "6f0d6c58-2a59-4a2f-9a0e-2f1c2b7f4a10"
const OTHER := "0b7b8c1e-5d3a-4c1f-8e0e-9a6d5c4b3a21"
const CAVE_UUID := "4b9b5f0e-0000-5000-8000-000000000001"

var _registry: Dictionary = {}
var _spawned: Array = []
var _updates: Array = []
var _now := 100000


func before_all() -> void:
	CaveNetwork.warm()


## A Discoveries wired to a fake server: an in-memory registry, a recorded spawn and recorded updates.
func _discoveries() -> Discoveries:
	_registry = {}
	_spawned = []
	_updates = []
	var found := Discoveries.new()
	found.registry_data = func(uuid: String) -> Dictionary: return _registry.get(uuid, {})
	found.spawn_prop = func(data: Dictionary) -> void:
		_spawned.append(data)
		_registry[str(data["uuid"])] = data.duplicate()
	found.update_prop = func(uuid: String, props: Dictionary, type: String) -> void:
		_updates.append([uuid, props, type])
		(_registry[uuid] as Dictionary).merge(props, true)
	found.now_ms = func() -> int: return _now
	found.now_unix = func() -> int: return 1793400000
	add_child_autofree(found)  # _ready: settles SETTLE_MS from now
	found._inventory_url = ""  # no service call from a test
	return found


func _location() -> Dictionary:
	return {"system": "tarsis", "scene": "tarsis_3", "x": 1.0, "y": 2.0, "z": 3.0}


func test_names_follow_the_rule() -> void:
	assert_eq(PlaceNameRule.clean("  Gouffre   d'Élise  "), "Gouffre d'Élise", "edges trimmed, spaces made one")
	assert_eq(PlaceNameRule.error_key("Gouffre d'Élise"), "", "letters with accents, apostrophe, space")
	assert_eq(PlaceNameRule.error_key("Puits-17"), "", "hyphen and digits")
	assert_eq(PlaceNameRule.error_key("  ab  "), "%%PLACE_NAME_TOO_SHORT")
	assert_eq(PlaceNameRule.error_key("x".repeat(PlaceNameRule.MAX_LENGTH + 1)), "%%PLACE_NAME_TOO_LONG")
	assert_eq(PlaceNameRule.error_key("Grotte <b>"), "%%PLACE_NAME_BAD_CHARACTERS")
	assert_eq(PlaceNameRule.error_key("Grotte\tbleue"), "%%PLACE_NAME_BAD_CHARACTERS")
	assert_eq(PlaceNameDialog.error_text("%%PLACE_NAME_TOO_SHORT").contains(str(PlaceNameRule.MIN_LENGTH)), true,
		"the message names the limit")


func test_the_uuid_is_stable_per_place() -> void:
	assert_eq(Discovery.uuid_for("cave", "a"), Discovery.uuid_for("cave", "a"))
	assert_ne(Discovery.uuid_for("cave", "a"), Discovery.uuid_for("cave", "b"))
	assert_ne(Discovery.uuid_for("cave", "a"), Discovery.uuid_for("lake", "a"), "two kinds never share a record")


func test_the_first_player_in_becomes_the_discoverer_once() -> void:
	var discoveries := _discoveries()
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 0, "nothing is created while the zone's objects may still be arriving")
	_now += Discoveries.SETTLE_MS
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 1, "created once settled")
	var data: Dictionary = _spawned[0]
	assert_eq(data["uuid"], Discovery.uuid_for("cave", "site-1"))
	assert_eq(data["type"], Discovery.TYPE)
	assert_eq(data["parent_id"], CAVE_UUID, "a child of the cave: it lives and sleeps with it")
	assert_eq(data["discoverer_id"], PLAYER)
	assert_eq(data["discoverer_name"], "Ada")
	assert_eq(data["status"], Discovery.UNNAMED)
	assert_false(data.has("name"), "no 'name' field: PropSync would rename the node after it")
	discoveries.found(OTHER, "Bob", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 1, "never created again: a second create would wipe an approved name")
	assert_eq(_registry[data["uuid"]]["discoverer_id"], PLAYER, "the second player is not the discoverer")
	discoveries.found(PLAYER, "Ada", "cave", "site-2", "", "tarsis_3", _location())
	assert_eq(_spawned.size(), 1, "no discovery of a place whose prop the server does not hold")


func test_a_new_zone_waits_again_for_its_objects() -> void:
	var discoveries := _discoveries()
	_now += Discoveries.SETTLE_MS
	discoveries.zones_assigned()
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 0, "Horizon is sending the zone's objects again: the discovery may be among them")


func test_only_the_discoverer_names_it_by_the_rule() -> void:
	var discoveries := _discoveries()
	_now += Discoveries.SETTLE_MS
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	var uuid := Discovery.uuid_for("cave", "site-1")
	assert_ne(discoveries.propose(PLAYER, "nope", "Gouffre"), "", "an unknown discovery")
	assert_ne(discoveries.propose(OTHER, uuid, "Gouffre"), "", "someone else")
	assert_ne(discoveries.propose(PLAYER, uuid, "<>"), "", "a name against the rule")
	assert_eq(_updates.size(), 0, "nothing written for a refusal")
	assert_eq(discoveries.propose(PLAYER, uuid, "  Gouffre   d'Élise "), "")
	assert_eq(_registry[uuid]["status"], Discovery.PENDING)
	assert_eq(_registry[uuid]["proposed_name"], "Gouffre d'Élise", "stored cleaned")
	assert_eq(_updates[0][2], Discovery.TYPE)
	assert_ne(discoveries.propose(PLAYER, uuid, "Autre nom"), "", "one proposal at a time")
	_registry[uuid]["status"] = Discovery.APPROVED
	assert_ne(discoveries.propose(PLAYER, uuid, "Autre nom"), "", "an approved name stays")
	_registry[uuid]["status"] = Discovery.REFUSED
	assert_eq(discoveries.propose(PLAYER, uuid, "Autre nom"), "", "a refused name may be replaced")


func test_the_node_asks_its_discoverer_only_while_open() -> void:
	var node: Discovery = (load("res://scenes/exploration/discovery.tscn") as PackedScene).instantiate()
	add_child_autofree(node)
	node.apply_prop_data(Discovery.record("cave", "site-9", CAVE_UUID, "tarsis_3", PLAYER, "Ada", 1))
	assert_eq(Discovery.of_place("cave", "site-9"), node, "found by its place")
	assert_true(node.needs_name_from(PLAYER))
	assert_false(node.needs_name_from(OTHER))
	assert_false(node.needs_name_from(""))
	node.apply_prop_data({"status": Discovery.PENDING})
	assert_false(node.needs_name_from(PLAYER), "a name awaits ARES")
	node.apply_prop_data({"status": Discovery.REFUSED})
	assert_true(node.needs_name_from(PLAYER), "asked again after a refusal")
	var lines := PlaceWatcher.banner_lines("cave", node)
	assert_eq(lines[1], TranslationServer.translate("%%PLACE_DISCOVERED_BY") % "Ada")
	node.apply_prop_data({"status": Discovery.APPROVED, "approved_name": "Gouffre d'Élise"})
	assert_eq(PlaceWatcher.banner_lines("cave", node)[0], "Gouffre d'Élise")
	assert_eq(PlaceWatcher.banner_lines("cave", null)[0], TranslationServer.translate("%%PLACE_UNCHARTED_CAVE"))
	remove_child(node)
	assert_null(Discovery.of_place("cave", "site-9"), "forgotten once out of the tree")


func test_which_cave_a_point_is_in() -> void:
	var placement := Fixture.placement()
	var data := Fixture.data(placement)
	var cave := Fixture.fit(placement, data)
	data.stargrot_plans = [{"placement": placement, "cave": cave}]
	var room: Dictionary = cave.graph.rooms[0]
	var height := -6.0
	while height < float(room.size.y) and float(cave.sampler.call("Sample", room.a + Vector3.UP * height)) <= 0.5:
		height += 0.25
	var air: Vector3 = placement.cave_transform() * (room.a + Vector3.UP * (height + 0.2))
	assert_eq(CavePlanetRegistry.site_at(data, air), placement, "in a chamber's air")
	var rock: Vector3 = placement.cave_transform() * ((cave.graph.bounds as AABB).end + Vector3.ONE * 20.0)
	assert_null(CavePlanetRegistry.site_at(data, rock), "outside every cave")
	assert_true(CavePlanetRegistry.inside_rock(data, air))
	assert_false(CavePlanetRegistry.inside_rock(data, rock))


func test_notifications_and_the_star_map_speak_of_the_place() -> void:
	var approved := ChatNetwork.notification_text({"type": "place_name_approved", "data": {"name": "Gouffre"}})
	assert_true(approved.contains("Gouffre"))
	var refused := ChatNetwork.notification_text({"type": "place_name_refused",
		"data": {"name": "Gouffre", "reason": "déjà pris"}})
	assert_true(refused.contains("Gouffre") and refused.contains("déjà pris"))
	var poi := {"scene": "tarsis_3", "x": 10.0, "y": 0.0, "z": 0.0, "name": "Uncharted cave", "ownerType": "player",
		"metadata": Discoveries.poi_metadata("u", {"place_kind": "cave"}, true)}
	var entry := StarMapPoi.service_entry(poi, "tarsis_3")
	assert_eq(entry["kind"], "cave", "drawn as a cave")
	assert_eq(entry["label"], ServiceTypes.text("%%PLACE_UNCHARTED_CAVE"), "uncharted, in the player's language")
	poi["metadata"] = Discoveries.poi_metadata("u", {"place_kind": "cave"}, false)
	poi["name"] = "Gouffre"
	assert_eq(StarMapPoi.service_entry(poi, "tarsis_3")["label"], "Gouffre", "named after the proposal")


func test_a_discovery_stored_without_its_place_is_created_again_once() -> void:
	var discoveries := _discoveries()
	_now += Discoveries.SETTLE_MS
	var uuid := Discovery.uuid_for("cave", "site-1")
	# What Horizon kept of it while it had no definition of the type: the fields, no parent, no name.
	var stored := Discovery.record("cave", "site-1", CAVE_UUID, "tarsis_3", PLAYER, "", 1793300000)
	stored.merge({"type": Discovery.TYPE, "uuid": uuid})
	_registry[uuid] = stored
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 1, "created again")
	var data: Dictionary = _spawned[0]
	assert_eq(data["parent_id"], CAVE_UUID, "under its place this time")
	assert_eq(data["discovered_at"], 1793300000, "what it held is kept")
	assert_eq(data["discoverer_name"], "Ada", "the missing name filled in by its discoverer")
	discoveries.found(PLAYER, "Ada", "cave", "site-1", CAVE_UUID, "tarsis_3", _location())
	assert_eq(_spawned.size(), 1, "once")
