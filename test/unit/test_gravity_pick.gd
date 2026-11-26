extends GutTest
## Which gravity area holds a player (Player.pick_gravity_area): the highest priority, then a directional
## area (a ship's or a station pad's grid) over a point one (a planet), then the last entered -- whatever
## order a reparent re-enters them in.


func test_a_higher_priority_wins_whatever_the_order() -> void:
	var planet := _area(0, true)
	var ship := _area(10, false)
	assert_eq(Player.pick_gravity_area([planet, ship]), ship, "the ship's grid, entered last")
	assert_eq(Player.pick_gravity_area([ship, planet]), ship, "the ship's grid, the planet re-entered after it")


func test_on_a_tie_directional_beats_point() -> void:
	var planet := _area(0, true)
	var pad := _area(0, false)
	assert_eq(Player.pick_gravity_area([planet, pad]), pad, "a station pad over the planet")
	assert_eq(Player.pick_gravity_area([pad, planet]), pad, "even with the planet entered last")


func test_then_the_last_entered() -> void:
	var first := _area(0, true)
	var second := _area(0, true)
	assert_eq(Player.pick_gravity_area([first, second]), second, "two planets' spheres: the last entered")
	var pad_a := _area(0, false)
	var pad_b := _area(0, false)
	assert_eq(Player.pick_gravity_area([pad_a, pad_b]), pad_b, "two pads: the last entered")


func test_nothing_and_skipped_areas() -> void:
	assert_null(Player.pick_gravity_area([]), "no area: weightless")
	var planet := _area(0, true)
	var vehicle: Node3D = autofree(Node3D.new())
	var ship := Area3D.new()  # freed with the vehicle
	ship.monitoring = false
	ship.priority = 10
	vehicle.add_child(ship)
	assert_eq(Player.pick_gravity_area([planet, ship], vehicle), planet,
			"seated in the ship: its own gravity is left out")
	assert_eq(Player.pick_gravity_area([planet, ship]), ship, "on foot: it holds")


## A gravity area of [param priority], a point (planet-like) one or a directional (grid-like) one.
func _area(priority: int, point: bool) -> Area3D:
	var area: Area3D = autofree(Area3D.new())
	area.monitoring = false
	area.priority = priority
	area.gravity_point = point
	return area
