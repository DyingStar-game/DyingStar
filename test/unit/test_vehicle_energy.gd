extends GutTest
## A truck's energy: its batteries, one at a time in bay order (GDD 6.1), drawn on by the torque the
## motors are asked for. No charge, no start; the battery in use stays in while the engine runs. The
## truck is instantiated, not run: the parts are set in its bays by hand.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const BATTERY := "res://scenes/_universe/props/vehicles/battery_t1.tscn"
const ENGINE := "res://scenes/_universe/props/vehicles/engine_t1.tscn"

var _truck: Vehicle = null


func before_each() -> void:
	_truck = (load(TRUCK) as PackedScene).instantiate() as Vehicle


func after_each() -> void:
	_truck.free()


## Put a fresh part of [param scene] in bay [param index], full when it is a battery.
func _fit(scene: String, index: int) -> VehicleComponent:
	var part : VehicleComponent = (load(scene) as PackedScene).instantiate()
	if part is VehicleBattery:
		part.charge_j = part.capacity_j()
	_truck.add_child(part)
	var slot: Node = _truck.bays.all()[index]
	slot.occupant = part
	slot.occupant_uuid = "part-%d" % index
	return part


func test_the_draw_is_the_torque_times_the_coefficient() -> void:
	var battery : VehicleBattery = _fit(BATTERY, 0)
	var before : float = battery.charge_j
	assert_almost_eq(_truck.energy.draw_for_torque(600.0, 1.0), 0.0, 0.001, "fully supplied")
	assert_almost_eq(before - battery.charge_j, 127.0 * 600.0, 0.01, "127 J per N·m per second")
	_truck.energy.draw_for_torque(0.0, 10.0)
	assert_almost_eq(before - battery.charge_j, 127.0 * 600.0, 0.01, "no torque, no draw")


func test_full_throttle_on_one_motor_lasts_about_39_minutes() -> void:
	var spec := VehicleBatterySpec.new()
	var seconds : float = spec.capacity_j / spec.draw_w(600.0)
	assert_almost_eq(seconds / 60.0, 39.4, 0.1, "180 MJ at 127 x 600 W")


func test_one_battery_at_a_time_then_the_next() -> void:
	var first : VehicleBattery = _fit(BATTERY, 0)
	var second : VehicleBattery = _fit(BATTERY, 2)
	assert_eq(_truck.energy.active(), first, "the first in bay order")
	first.charge_j = 1000.0
	_truck.energy.draw_for_torque(1.0, 10.0)  # 1270 J: the first runs dry mid-tick
	assert_true(first.is_empty())
	assert_almost_eq(second.capacity_j() - second.charge_j, 270.0, 0.01, "the next covers the rest")
	assert_eq(_truck.energy.active(), second, "and is now the one in use")
	var levels : Array[Dictionary] = _truck.energy.levels()
	assert_eq(levels.size(), 2, "a dashboard row per battery")
	assert_false(levels[0]["active"])
	assert_true(levels[1]["active"])


func test_no_battery_no_start() -> void:
	_fit(ENGINE, 0)
	_truck.bays.rebuild_drive_spec()
	_truck.toggle_engine()
	assert_false(_truck.is_engine_on(), "a motor alone does not start")
	var battery : VehicleBattery = _fit(BATTERY, 1)
	battery.charge_j = 0.0
	_truck.toggle_engine()
	assert_false(_truck.is_engine_on(), "nor with an empty battery")
	battery.charge_j = 1000.0
	_truck.toggle_engine()
	assert_true(_truck.is_engine_on(), "some charge: it starts")


func test_running_dry_stops_the_engine() -> void:
	_fit(ENGINE, 0)
	var battery : VehicleBattery = _fit(BATTERY, 1)
	_truck._engine_on = true
	battery.charge_j = 0.0
	_truck._cut_if_no_energy()
	assert_false(_truck.is_engine_on())


## Nothing comes out of a running vehicle — not the battery in use, not a spare, not a motor.
func test_no_part_comes_out_while_the_engine_runs() -> void:
	var motor : VehicleComponent = _fit(ENGINE, 0)
	var battery : VehicleBattery = _fit(BATTERY, 1)
	var spare : VehicleBattery = _fit(BATTERY, 3)
	var bays : Array = _truck.bays.all()
	_truck._engine_on = true
	assert_ne(_truck.bays.removal_refused(bays[1]), "", "the battery in use stays in")
	assert_ne(_truck.bays.removal_refused(bays[3]), "", "so does a spare")
	assert_ne(_truck.bays.removal_refused(bays[0]), "", "and the motor")
	_truck._engine_on = false
	for index: int in [0, 1, 3]:
		assert_eq(_truck.bays.removal_refused(bays[index]), "", "engine off: bay %d gives its part back" % index)
	assert_not_null(motor)
	assert_not_null(battery)
	assert_not_null(spare)


## The key works at any speed, both ways: a motor needs no standstill to start, and the driver can
## always cut it. It used to refuse a start above 3 km/h, silently.
func test_the_ignition_works_at_any_speed() -> void:
	_fit(ENGINE, 0)
	_fit(BATTERY, 1)
	_truck.bays.rebuild_drive_spec()
	_truck.linear_velocity = Vector3(0.0, 0.0, -50.0 / 3.6)  # 50 km/h
	_truck.toggle_engine()
	assert_true(_truck.is_engine_on(), "started while rolling")
	_truck.toggle_engine()
	assert_false(_truck.is_engine_on(), "and cut while rolling")
