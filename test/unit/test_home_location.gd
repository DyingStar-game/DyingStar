extends GutTest
## HomeLocation: the player's home on the chart, from anywhere on its planet. It is remembered in the
## planet's frame (the planet turns, the home stays put on it), kept for the next sessions, and drawn
## by one marker of its own.

const PLAYER := "test-home-location-player"


func after_each() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(HomeLocation.SAVE_PATH) == OK and cfg.has_section(PLAYER):
		cfg.erase_section(PLAYER)
		cfg.save(HomeLocation.SAVE_PATH)


func test_the_home_is_marked_in_the_planet_s_frame() -> void:
	var planet := _planet("Sandbox")
	planet.rotation = Vector3(0.0, 1.0, 0.3)  # a turning planet: its frame is what counts
	var village := Node3D.new()
	village.position = Vector3(1000.0, 6356000.0, -20.0)
	village.rotation.y = PI / 2.0
	planet.add_child(village)
	var apartment := Node3D.new()
	apartment.position = Vector3(0.0, 0.0, 5.2)
	village.add_child(apartment)
	HomeLocation.remember(apartment, PLAYER)
	var anchor := planet.get_node(NodePath(HomeLocation.ANCHOR_NAME)) as Node3D
	var expected: Vector3 = village.transform * apartment.transform * HomeLocation.APARTMENT_MIDDLE
	assert_almost_eq(anchor.position, expected, Vector3.ONE * 1e-3, "the middle of the container")
	var marker := anchor.get_child(0) as MapMarker
	assert_eq(marker.label, "%%MAP_MARKER_MY_HOME")
	assert_eq(marker.importance, 1, "drawn over the rest")
	assert_eq(marker.footprint().size, HomeLocation.FOOTPRINT)
	HomeLocation.remember(apartment, PLAYER)
	assert_eq(planet.get_children().filter(func(n: Node) -> bool: return n.name == HomeLocation.ANCHOR_NAME).size(),
			1, "one home, moved rather than doubled")
	planet.free()


func test_a_next_session_finds_it_again() -> void:
	var first := _planet("Sandbox")
	var apartment := Node3D.new()
	apartment.position = Vector3(10.0, 20.0, 30.0)
	first.add_child(apartment)
	HomeLocation.remember(apartment, PLAYER)
	var place: Transform3D = (first.get_node(NodePath(HomeLocation.ANCHOR_NAME)) as Node3D).transform
	first.free()
	var again := _planet("Sandbox")
	HomeLocation.ensure(again, PLAYER)
	assert_eq((again.get_node(NodePath(HomeLocation.ANCHOR_NAME)) as Node3D).transform, place)
	var elsewhere := _planet("Tarsis 4")
	HomeLocation.ensure(elsewhere, PLAYER)
	assert_false(elsewhere.has_node(NodePath(HomeLocation.ANCHOR_NAME)), "only on its own planet")
	assert_eq(HomeLocation.load_home("nobody"), {}, "no home yet")
	again.free()
	elsewhere.free()


## A planet called [param key], not in the tree.
func _planet(key: String) -> Planet:
	var planet := Planet.new()
	planet.planet_data = PlanetData.new()
	planet.planet_data.planet_name = key
	return planet
