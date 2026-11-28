extends GutTest
## The sky's up (PlayerSunLight.sky_up) is the planet's radial, not the up of whatever holds the body:
## aboard a ship rolled upside down, the day, the night and the air must not turn with the hull.

const RADIUS := 1000.0


func test_aboard_a_rolled_ship_the_sky_up_is_the_planet_radial() -> void:
	var planet := _planet()
	var ship := Node3D.new()
	planet.add_child(ship)
	ship.position = Vector3(0.0, RADIUS + 50.0, 0.0)
	ship.rotate_z(PI)  # upside down: the ship's own up points at the ground
	var observer := Node3D.new()
	ship.add_child(observer)
	observer.position = Vector3(3.0, 1.0, 0.0)
	var ship_up: Vector3 = ship.global_basis.y.normalized()
	var radial: Vector3 = (observer.global_position - planet.global_position).normalized()
	var up: Vector3 = PlayerSunLight.sky_up(observer, ship_up)
	assert_almost_eq(up, radial, Vector3.ONE * 0.0001, "the radial from the planet's centre")
	assert_lt(up.dot(ship_up), 0.0, "not the upside-down ship's up")


func test_in_deep_space_it_falls_back_on_the_body_up() -> void:
	var observer := Node3D.new()
	add_child_autofree(observer)
	observer.position = Vector3(10.0, 20.0, 30.0)
	assert_eq(PlayerSunLight.sky_up(observer, Vector3.RIGHT), Vector3.RIGHT, "no planet: the fallback")


## A bare planet with just enough data to stand in the tree, away from the origin.
func _planet() -> Planet:
	var planet := Planet.new()
	planet.planet_data = PlanetData.new()
	planet.planet_data.planet_name = "SkyUpTest"
	planet.planet_data.radius = RADIUS
	add_child_autofree(planet)
	planet.position = Vector3(5000.0, -200.0, 1200.0)
	return planet
