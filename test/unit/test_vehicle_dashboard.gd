extends GutTest
## VehicleDashboard: laid out to the screen's shape, a fixed row of warning lights whose colours follow
## the real dashboards (green on, amber caution, red danger, faint off), and the power used replicated
## from the server.


func test_the_viewport_takes_the_screens_shape() -> void:
	var size: Vector2i = VehicleDashboard.viewport_size_for(Vector2(0.54, 0.083))
	assert_eq(size.y, VehicleDashboard.SCREEN_HEIGHT_PX)
	assert_almost_eq(float(size.x) / size.y, 0.54 / 0.083, 0.01, "the truck's strip, about 6.5:1, not 16:9")
	assert_eq(VehicleDashboard.viewport_size_for(Vector2.ZERO).y, VehicleDashboard.SCREEN_HEIGHT_PX, "no screen: a sane default")


func test_the_lights_colours() -> void:
	assert_eq(VehicleDashboard.light_colour(true), VehicleDashboard.GREEN)
	assert_eq(VehicleDashboard.light_colour(false), VehicleDashboard.OFF_COLOR, "off: faint, still in place")
	assert_eq(VehicleDashboard.handbrake_colour(true, 0.0, 0.7), VehicleDashboard.RED, "parked: steady red")
	var blink: Array = [VehicleDashboard.handbrake_colour(true, 20.0, 0.1), VehicleDashboard.handbrake_colour(true, 20.0, 0.3)]
	assert_ne(blink[0], blink[1], "driven against it: it blinks")
	assert_eq(VehicleDashboard.limiter_colour(true, false), VehicleDashboard.AMBER)
	assert_eq(VehicleDashboard.limiter_colour(true, true), VehicleDashboard.RED, "holding the truck back")
	assert_eq(VehicleDashboard.limiter_colour(false, false), VehicleDashboard.OFF_COLOR)
	assert_eq(VehicleDashboard.load_colour(true), VehicleDashboard.RED, "overloaded")
	assert_eq(VehicleDashboard.door_colour(false, 50.0, 40.0, true), VehicleDashboard.OFF_COLOR, "every door shut: grey")
	assert_eq(VehicleDashboard.door_colour(true, 10.0, 40.0, true), VehicleDashboard.ORANGE, "a door open")
	assert_eq(VehicleDashboard.door_colour(true, 10.0, 40.0, false), VehicleDashboard.OFF_COLOR, "dark half of the beat")
	assert_eq(VehicleDashboard.door_colour(true, 35.0, 40.0, true), VehicleDashboard.RED, "the wind is about to shut it")
	assert_eq(VehicleDashboard.door_colour(true, 90.0, INF, true), VehicleDashboard.ORANGE, "a hatch: the wind never shuts it")


func test_the_screen_builds_its_strip() -> void:
	var dash: VehicleDashboard = (load("res://scenes/_universe/vehicles/vehicle_dashboard.tscn") as PackedScene).instantiate()
	add_child_autofree(dash)
	for icon: TextureRect in [dash._lights, dash._handbrake, dash._limiter, dash._load, dash._doors]:
		assert_not_null(icon.texture, "each warning light has its pictogram")
	assert_not_null(dash._power, "a power gauge in place of the RPM")


func test_the_power_share_of_a_drive_force() -> void:
	assert_eq(Vehicle.power_share(0.0, 8000.0), 0.0, "coasting: no power")
	assert_eq(Vehicle.power_share(-4000.0, 8000.0), 0.5, "reverse counts too")
	assert_eq(Vehicle.power_share(20000.0, 8000.0), 1.0, "capped")
	assert_eq(Vehicle.power_share(100.0, 0.0), 0.0, "no motor: nothing")

func test_a_bays_box_shows_the_fitted_part() -> void:
	assert_null(VehicleDashboard.bay_icon(null), "a free bay: an empty box")
	var part: Node = autofree(load("res://scenes/_universe/props/vehicles/vehicle_component.gd").new())
	part.spec = load("res://scenes/_universe/vehicles/specs/battery_t1.tres")
	assert_eq(VehicleDashboard.bay_icon(part), load(VehicleDashboard.ICON_DIR + "battery.png"), "a battery: its pictogram, the battery light")
	assert_eq(VehicleDashboard.bay_colour(true), VehicleDashboard.GREEN, "fitted and working: green")
	assert_eq(VehicleDashboard.bay_colour(false), VehicleDashboard.BAY_FREE_COLOR, "free: grey")
	part.spec = load("res://scenes/_universe/vehicles/specs/engine_t1.tres")
	assert_eq(VehicleDashboard.bay_icon(part), load(VehicleDashboard.ICON_DIR + "motor.png"), "an engine: its pictogram, the motor light")
