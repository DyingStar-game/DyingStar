extends GutTest
## [PlayerLocation] answers where a body is, the way the services spell it — the frame a point of
## interest, a presence and a mission zone all share. Built here from a body of our own rather than
## the live universe: a test that needs the real solar system would be a test of the data, not of
## the arithmetic.

const RADIUS: float = 6.0e6


func before_each() -> void:
	# No agent, no network: the helpers must answer for a bare body with no registry behind it.


func test_a_body_in_deep_space_is_its_own_position() -> void:
	var free := Node3D.new()
	add_child_autofree(free)
	free.global_position = Vector3(4.0, 5.0, 6.0)
	var where: Dictionary = PlayerLocation.presence_of(free)
	assert_eq(str(where["scene"]), "space", "no body under it: it is in open space")
	assert_eq(str(where["system"]), "", "and in no system")
	assert_eq(where["position"] as Vector3, Vector3(4.0, 5.0, 6.0))


func test_a_body_on_a_planet_carries_the_body_and_its_orbit() -> void:
	var planet := _planet("tarsis_3", Vector3(1000.0, 0.0, 0.0))
	var player := Node3D.new()
	add_child_autofree(player)
	planet.add_child(player)
	player.position = Vector3(0.0, RADIUS, 0.0)
	var where: Dictionary = PlayerLocation.presence_of(player)
	assert_eq(str(where["scene"]), "tarsis_3", "the body key, which everything agrees on")
	assert_eq(where["position"] as Vector3, Vector3(1000.0, RADIUS, 0.0),
			"the orbit, then the stand point inside it")


func test_the_body_key_prefers_planet_data_over_the_node_name() -> void:
	var planet := _planet("tarsis_3", Vector3.ZERO)
	assert_eq(PlayerLocation.body_key_of(planet), "tarsis_3")
	planet.planet_data.planet_name = ""
	assert_eq(PlayerLocation.body_key_of(planet), str(planet.name),
			"with no data the node name is the only key left")


## A body standing alone: a Planet with its data and an orbital position, no parent, no registry.
func _planet(key: String, orbital: Vector3) -> Planet:
	var planet := Planet.new()
	planet.planet_data = PlanetData.new()
	planet.planet_data.planet_name = key
	planet.planet_data.radius = RADIUS
	planet.orbital_position = orbital
	add_child_autofree(planet)
	return planet
