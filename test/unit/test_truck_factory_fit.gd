extends GutTest
## The MVP truck's factory fit, checked against the design sheet.
##
## test_vehicle_drive_spec.gd pins the MODEL; this pins the TRUCK — that its scene still carries
## the engines it leaves the works with, and that those engines plus its chassis land on the
## numbers the sheet designed. A hand edit to the .tscn, a renamed export or a tweaked chassis
## value would otherwise change how the truck drives with nothing to say so.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const SHEET_EMPTY_MASS := 1500.0   # mVide of the MVP column
const SANDBOX_GRAVITY := 6.867

var _truck: Vehicle = null

func before_each() -> void:
	# Instantiated but NOT added to the tree: we want the exported values, not a running vehicle
	# (_ready would build wheels, cameras, audio and a loading zone we have no use for here).
	var packed: PackedScene = load(TRUCK)
	assert_not_null(packed, "truck.tscn must load")
	_truck = packed.instantiate() as Vehicle


func after_each() -> void:
	if _truck != null:
		_truck.free()
		_truck = null


## Build the sizing model the same way the vehicle does, from the scene's own values.
func _spec() -> VehicleDriveSpec:
	var spec := VehicleDriveSpec.new()
	spec.motors.assign(_truck.factory_engines)
	spec.wheel_radius = _truck.wheel_radius
	spec.pump_efficiency = _truck.pump_efficiency
	spec.hydraulic_efficiency = _truck.hydraulic_efficiency
	spec.torque_factor = _truck.torque_factor
	spec.drag_coefficient = _truck.drag_coefficient
	spec.frontal_area = _truck.frontal_area_m2
	spec.rolling_coefficient = _truck.rolling_coefficient
	spec.rolling_factor = _truck.rolling_factor
	spec.air_density = _truck.air_density
	spec.gravity = SANDBOX_GRAVITY
	return spec


func test_truck_leaves_the_works_with_three_t1_motors() -> void:
	assert_eq(_truck.factory_engines.size(), 3, "the MVP column of the sheet says 3 T1 motors")
	for e in _truck.factory_engines:
		assert_not_null(e, "no empty slot in the factory fit")
		assert_eq(e.torque_nm, 600.0, "a T1 produces 600 Nm")
		assert_eq(e.power_w, 100000.0, "a T1 draws 100 kW")
		assert_eq(e.tier, 1, "a T1 is tier 1")


func test_chassis_matches_the_mvp_column() -> void:
	assert_almost_eq(_truck.drag_coefficient, 1.0, 0.001, "Cx")
	assert_almost_eq(_truck.frontal_area_m2, 3.0, 0.001, "frontal area (m2)")
	assert_almost_eq(_truck.pump_efficiency * _truck.hydraulic_efficiency, 0.64, 0.001,
			"transmission efficiency, which with the motor's 0.9 gives the sheet's 0.576")
	assert_almost_eq(_truck.torque_factor, 1.0, 0.001, "torque factor")
	assert_almost_eq(_truck.rolling_coefficient, 0.01, 0.0001, "ground rolling resistance")


func test_factory_fit_produces_the_sheet_figures() -> void:
	var spec := _spec()
	assert_true(spec.is_valid(), "a factory-fitted truck is drivable")
	assert_almost_eq(spec.mech_power_w() / 1000.0, 172.8, 0.1, "mech power (kW)")
	assert_almost_eq(spec.mech_torque_nm(), 1800.0, 1.0, "mech torque (Nm)")
	assert_almost_eq(spec.tractive_force_n(), 6000.0, 5.0, "tractive force (N)")
	assert_almost_eq(spec.v_max_motor_ms() * 3.6, 103.68, 0.1, "top speed (km/h)")
	assert_eq(spec.limiting_factor(SHEET_EMPTY_MASS), "MOTOR", "engine-limited, not drag-limited")
	assert_almost_eq(spec.max_acceleration(SHEET_EMPTY_MASS), 3.93, 0.02, "acceleration (m/s2)")
	assert_almost_eq(rad_to_deg(spec.max_slope_rad(SHEET_EMPTY_MASS)), 34.92, 0.05, "slope (deg)")


func test_wheel_radius_follows_the_sheet() -> void:
	# The sheet says 0.30 m and the team decided the sheet wins, so the wheel MESH is due a rescale
	# to 0.60 m diameter. Until that export lands the visible wheel overhangs the physical one by
	# 4 cm — cosmetic, and it changes no measurement. This assertion is what will catch a silent
	# revert to the old 0.34.
	assert_almost_eq(_truck.wheel_radius, 0.30, 0.001,
			"wheel radius must follow the sheet, not the current mesh")
