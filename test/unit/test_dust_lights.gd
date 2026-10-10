extends GutTest
## DustLights: the lamps that light the wind's dust are the lit ones in reach of the eye, the ones that
## matter most first, and never more than the shader takes.


func _omni(at: Vector3, energy: float, reach: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.light_energy = energy
	light.omni_range = reach
	light.position = at
	add_child_autofree(light)
	return light


func test_the_nearest_bright_lamps_come_first() -> void:
	var near := _omni(Vector3(5.0, 0.0, 0.0), 2.0, 20.0)
	var far := _omni(Vector3(80.0, 0.0, 0.0), 2.0, 20.0)
	var picked: Array[Light3D] = DustLights.pick([far, near], Vector3.ZERO, 8)
	assert_eq(picked, [near, far] as Array[Light3D], "the nearer of two equal lamps first")


func test_unlit_hidden_or_out_of_reach_lamps_light_nothing() -> void:
	var off := _omni(Vector3(5.0, 0.0, 0.0), 0.0, 20.0)
	var hidden := _omni(Vector3(5.0, 0.0, 0.0), 2.0, 20.0)
	hidden.visible = false
	var gone := _omni(Vector3(DustLights.REACH_M + 30.0, 0.0, 0.0), 2.0, 20.0)
	assert_eq(DustLights.pick([off, hidden, gone], Vector3.ZERO, 8), [] as Array[Light3D])


func test_never_more_than_asked() -> void:
	var lights: Array = []
	for i in 12:
		lights.append(_omni(Vector3(float(i) + 1.0, 0.0, 0.0), 1.0, 10.0))
	assert_eq(DustLights.pick(lights, Vector3.ZERO, DustLights.MAX_LIGHTS).size(), DustLights.MAX_LIGHTS)


func test_a_spot_reaches_its_range() -> void:
	var spot := SpotLight3D.new()
	spot.spot_range = 30.0
	assert_eq(DustLights.reach_of(spot), 30.0)
	var sun := DirectionalLight3D.new()
	assert_eq(DustLights.reach_of(sun), 0.0, "the sun is not a lamp")
	spot.free()
	sun.free()


func test_importance_grows_with_the_light_and_falls_with_the_distance() -> void:
	assert_gt(DustLights.importance(4.0, 30.0, 10.0), DustLights.importance(2.0, 30.0, 10.0), "brighter")
	assert_gt(DustLights.importance(2.0, 60.0, 10.0), DustLights.importance(2.0, 30.0, 10.0), "wider")
	assert_gt(DustLights.importance(2.0, 30.0, 10.0), DustLights.importance(2.0, 30.0, 40.0), "nearer")


func test_no_beams_in_daylight() -> void:
	var sun := DirectionalLight3D.new()
	add_child_autofree(sun)
	sun.light_energy = 2.0
	assert_true(DustLights.daylight(sun), "a sun up: the beams are lost in the day")
	sun.light_energy = 0.0
	assert_false(DustLights.daylight(sun), "night")
	sun.light_energy = 2.0
	sun.visible = false
	assert_false(DustLights.daylight(sun), "a set sun is hidden, its energy left at dusk: night")
	assert_false(DustLights.daylight(null), "no sun: night")
