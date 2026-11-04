extends GutTest
## Spinner turns its node about its axis, each one out of step with the others (a field of wind
## turbines), the same way on every client: phase and speed come from where it stands, the angle
## from the shared clock.

const TURBINE := "res://scenes/_universe/structures/industrial/power/wind_turbine.tscn"


func test_it_turns_about_its_axis() -> void:
	var spinner := _spinner(Vector3.ZERO)
	var before := spinner.basis
	spinner._process(0.5)
	assert_ne(spinner.basis, before, "it turned")
	assert_almost_eq(spinner.basis.z.dot(Vector3.BACK), 1.0, 0.0001, "about its forward axis only")


func test_two_spinners_turn_out_of_step() -> void:
	var a := _spinner(Vector3(0, 0, 0))
	var b := _spinner(Vector3(25, 0, 0))
	assert_ne(a.angle_at(100.0), b.angle_at(100.0), "not the same phase")
	assert_ne(a._speed, b._speed, "not the same speed")


func test_the_same_place_gives_the_same_turn() -> void:
	var a := _spinner(Vector3(12, 0, 7))
	var b := _spinner(Vector3(12, 0, 7))
	assert_eq(a.angle_at(100.0), b.angle_at(100.0), "every client sees the same field")
	assert_eq(a._speed, b._speed)


## A client that joins later starts each rotor where the others see it by then: the angle is read
## from the shared clock, not counted from the moment the node entered the tree.
func test_the_angle_follows_the_shared_clock() -> void:
	var s := _spinner(Vector3(3, 0, 4))
	assert_almost_eq(s.angle_at(10.0), fposmod(s.angle_at(0.0) + s._speed * 10.0, TAU), 1e-9,
			"ten seconds later, ten seconds further")
	assert_almost_eq(Globals.reference_time(), Time.get_unix_time_from_system(), 60.0,
			"an absolute clock, not one since boot")


func test_the_turbine_rotor_spins() -> void:
	var turbine: Node3D = load(TURBINE).instantiate()
	var rotor := turbine.get_node_or_null("Rotor")
	assert_true(rotor is Spinner, "its blades turn")
	if rotor is Spinner:
		assert_eq(rotor.get_child_count(), 3, "three blades on the rotor")
	turbine.free()


func _spinner(at: Vector3) -> Spinner:
	var spinner := Spinner.new()
	spinner.position = at
	add_child_autofree(spinner)
	return spinner
