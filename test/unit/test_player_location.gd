extends GutTest
## [PlayerLocation] answers where a body is, the way the services spell it — the frame a point of
## interest, a presence and a mission zone all share. Built here from a body of our own rather than
## the live universe: a test that needs the real solar system would be a test of the data, not of
## the arithmetic.
##
## What is pinned here is the FRAME, because it is the one thing that cannot be checked by looking:
## a place is measured from the body named by `scene`, so it stays true while that body orbits and
## spins. Each test moves or rotates the body and asserts the answer does NOT follow — an absolute
## answer would pass every "where is he" check and fail the moment the universe turned.

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


func test_a_body_on_a_planet_carries_the_body_key_and_the_offset_from_its_centre() -> void:
	var planet := _planet("tarsis_3", Vector3(1000.0, 0.0, 0.0))
	var player := Node3D.new()
	planet.add_child(player)
	add_child_autofree(player)
	player.position = Vector3(0.0, RADIUS, 0.0)
	var where: Dictionary = PlayerLocation.presence_of(player)
	assert_eq(str(where["scene"]), "tarsis_3", "the body key, which everything agrees on")
	assert_eq(where["position"] as Vector3, Vector3(0.0, RADIUS, 0.0),
			"the offset from the planet's centre — NOT its spot in the universe")


func test_the_offset_survives_the_planet_orbiting() -> void:
	# THE property. A place stored as an absolute triple describes a spot the terrain has already
	# left: the planet's node position is rewritten from the Kepler elements every tick, so an
	# absolute number goes stale the moment it is written.
	var planet := _planet("tarsis_3", Vector3.ZERO)
	var player := Node3D.new()
	planet.add_child(player)
	add_child_autofree(player)
	player.position = Vector3(0.0, RADIUS, 0.0)
	var first: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	planet.position = Vector3(3.0e10, -1.5e10, 7.5e10)  # it moved a long way
	var second: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	assert_eq(second, first, "the player did not walk; the planet orbited. The place did not change.")


func test_the_offset_survives_the_planet_spinning() -> void:
	# The other half of the same argument: a body spins on itself, so "where on me" is only a
	# question in the body's OWN rotating frame. to_local carries that frame along with the turn.
	var planet := _planet("tarsis_3", Vector3.ZERO)
	var player := Node3D.new()
	planet.add_child(player)
	add_child_autofree(player)
	player.position = Vector3(0.0, RADIUS, 0.0)
	var first: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	planet.basis = Basis(Vector3.UP, PI * 0.5)  # a quarter turn
	var second: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	assert_almost_eq(second.length(), first.length(), 0.001,
			"still R metres from the centre — a ground spot rides the day around")


func test_the_offset_turns_with_the_planet_so_a_ground_spot_stays_put() -> void:
	# ... and it stays the SAME spot rather than sliding: parented to the body, the player's own
	# coordinates do not change when the body turns, which is what makes a POI on the ground match a
	# player standing on it.
	var planet := _planet("tarsis_3", Vector3.ZERO)
	var player := Node3D.new()
	planet.add_child(player)
	add_child_autofree(player)
	player.position = Vector3(120.0, RADIUS, -35.0)
	var first: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	planet.basis = Basis(Vector3.UP, 0.7)
	var second: Vector3 = PlayerLocation.presence_of(player)["position"] as Vector3
	assert_almost_eq(second.x, first.x, 0.001)
	assert_almost_eq(second.y, first.y, 0.001)
	assert_almost_eq(second.z, first.z, 0.001)


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