extends GutTest
## The T1 battery: its data sheet (the "Calculateur Batterie" tab of the sizing workbook), the part
## as a carriable networked prop, and its charge — drawn, charged, shown, replicated.

const BATTERY_SCENE := "res://scenes/_universe/props/vehicles/battery_t1.tscn"
const ENGINE_SCENE := "res://scenes/_universe/props/vehicles/engine_t1.tscn"

var _part: VehicleBattery = null


func before_each() -> void:
	_part = (load(BATTERY_SCENE) as PackedScene).instantiate() as VehicleBattery
	_part.charge_j = (_part.spec as VehicleBatterySpec).capacity_j


func after_each() -> void:
	_part.free()


func test_the_spec_is_the_sheets_t1() -> void:
	var spec := _part.spec as VehicleBatterySpec
	assert_not_null(spec, "the part carries a battery spec")
	assert_eq(spec.kind, VehicleComponentSpec.Kind.BATTERY)
	assert_eq(spec.tier, 1)
	assert_almost_eq(spec.capacity_j, 180.0e6, 1.0, "180 MJ (50 kWh)")
	assert_almost_eq(spec.max_current_a, 1000.0, 0.01, "1000 A")
	assert_almost_eq(spec.nominal_voltage_v, 500.0, 0.01, "500 V: the motor's 100 kW at 200 A")
	assert_almost_eq(spec.discharge_j_per_nm_s, 127.0, 0.01, "127 J per N·m per second, to validate in game")
	assert_almost_eq(spec.mass_kg, 25.0, 0.01, "as heavy as a T1 motor")


func test_recharge_times_are_the_sheets() -> void:
	var spec := _part.spec as VehicleBatterySpec
	assert_almost_eq(spec.capacity_j / spec.charge_power_w(), 360.0, 0.01, "Temps1: 0-100 % linear, 6 min")
	assert_almost_eq(spec.full_charge_time_s(), 504.0, 0.01, "Temps3: slow at both ends, 8.4 min")
	assert_almost_eq(spec.charge_rate_w(0.1), spec.charge_power_w() / 2.0, 0.01, "0-20 %: half rate")
	assert_almost_eq(spec.charge_rate_w(0.5), spec.charge_power_w(), 0.01, "20-80 %: full rate")
	assert_almost_eq(spec.charge_rate_w(0.9), spec.charge_power_w() / 2.0, 0.01, "80-100 %: half rate")


func test_it_is_a_twin_of_the_t1_motor() -> void:
	var engine : VehicleComponent = (load(ENGINE_SCENE) as PackedScene).instantiate()
	assert_eq(_part.collision_layer, engine.collision_layer, "same layers: carried and aimed at alike")
	assert_eq(_part.collision_mask, engine.collision_mask)
	assert_eq(Globals.collision_aabb(_part, Transform3D.IDENTITY).size,
			Globals.collision_aabb(engine, Transform3D.IDENTITY).size, "same size: fits any bay")
	var sync : PropSync = PropSync.of(_part)
	assert_eq(sync.type_name, "vehicle_component", "replicates as a vehicle component")
	assert_true(sync.enable_carry, "and can be carried")
	assert_eq(_part.id_type, "BAT", "its serial reads ARES-BAT-…")
	assert_not_null(_part.spec.icon, "the battery pictogram")
	engine.free()


func test_drawing_gives_what_is_left_and_no_more() -> void:
	_part.charge_j = 1000.0
	assert_almost_eq(_part.draw(400.0), 400.0, 0.001)
	assert_almost_eq(_part.charge_j, 600.0, 0.001)
	assert_almost_eq(_part.draw(5000.0), 600.0, 0.001, "only what it holds")
	assert_true(_part.is_empty())


func test_charging_follows_the_curve_and_stops_full() -> void:
	var spec := _part.spec as VehicleBatterySpec
	_part.charge_j = 0.5 * spec.capacity_j
	assert_almost_eq(_part.charge(1.0), spec.charge_power_w(), 1.0, "mid-range: full rate")
	_part.charge_j = spec.capacity_j - 10.0
	assert_almost_eq(_part.charge(10.0), 10.0, 0.001, "never past full")
	assert_almost_eq(_part.fraction(), 1.0, 0.0001)


func test_the_gauge_text_is_in_kwh() -> void:
	assert_eq(EnergyFormat.charge(_part.charge_j, _part.capacity_j()), "50.0 / 50.0 kWh")
	assert_eq(EnergyFormat.charge(126.4e6, 180.0e6), "35.1 / 50.0 kWh")
	assert_eq(EnergyFormat.percent(0.874), "87 %")


func test_the_charge_comes_from_the_network() -> void:
	_part.apply_prop_data({"charge_j": 90.0e6, "slot_id": "slot_fl"})
	assert_almost_eq(_part.charge_j, 90.0e6, 1.0, "the replicated charge")
	assert_eq(_part.slot_id, "slot_fl", "and the bay, as any part")
