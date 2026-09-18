extends GutTest
## GUT suite for VehicleDriveSpec — the game-side twin of the vehicle design spreadsheet.
##
## It pins the FIVE reference vehicles of that sheet (Buggy, Car, MVP truck, Heavy truck,
## Dumper). A disagreement between the code and the sheet would raise no error and print no
## warning: it would silently produce vehicles that do not drive the way they were designed.
## That is exactly the kind of drift only a pinned test catches.
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://test/unit
##   -gtest=test_vehicle_drive_spec.gd

# ── Planet constants (Sandbox), from the sheet ────────────────
const RHO := 1.26
const GRAVITY := 6.867      # 9.81 * 0.7
const CR := 0.01

# ── T1 motor, from the sheet ──────────────────────────────────
const T1_POWER_W := 100000.0
const T1_TORQUE_NM := 600.0
const T1_EFFICIENCY := 0.9

const PUMP := 0.8
const HYDRAULIC := 0.8

# Relative tolerance: the sheet prints rounded values, we compare against what it shows.
const REL := 0.001
const DEG_TOL := 0.02

## The five reference chassis, verbatim from the sheet's columns.
const VEHICLES := {
	"buggy": {
		"cx": 0.25, "area": 1.8, "r": 0.1, "empty": 500.0, "laden": 750.0,
		"motors": 1, "torque_factor": 0.5,
		"p_meca_kw": 57.6, "torque_meca": 300.0, "omega": 192.0, "traction": 3000.0,
		"roll_empty": 34.34, "roll_laden": 51.50,
		"slope_empty_deg": 59.74, "slope_laden_deg": 34.92, "aero_empty_ms": 102.3,
	},
	"car": {
		"cx": 0.3, "area": 2.52, "r": 0.2, "empty": 1200.0, "laden": 1800.0,
		"motors": 2, "torque_factor": 0.6,
		"p_meca_kw": 115.2, "torque_meca": 720.0, "omega": 160.0, "traction": 3600.0,
		"roll_empty": 82.40, "roll_laden": 123.61,
		"slope_empty_deg": 25.27, "slope_laden_deg": 16.33, "aero_empty_ms": 85.9,
	},
	"mvp": {
		"cx": 1.0, "area": 3.0, "r": 0.3, "empty": 1500.0, "laden": 2700.0,
		"motors": 3, "torque_factor": 1.0,
		"p_meca_kw": 172.8, "torque_meca": 1800.0, "omega": 96.0, "traction": 6000.0,
		"roll_empty": 103.01, "roll_laden": 185.41,
		"slope_empty_deg": 34.92, "slope_laden_deg": 18.28, "aero_empty_ms": 55.9,
	},
	"heavy": {
		"cx": 0.8, "area": 10.0, "r": 0.5, "empty": 14000.0, "laden": 32000.0,
		"motors": 15, "torque_factor": 1.25,
		"p_meca_kw": 864.0, "torque_meca": 11250.0, "omega": 76.8, "traction": 22500.0,
		"roll_empty": 961.38, "roll_laden": 2197.44,
		"slope_empty_deg": 12.95, "slope_laden_deg": 5.30, "aero_empty_ms": 65.4,
	},
	"dumper": {
		"cx": 1.0, "area": 13.32, "r": 0.8, "empty": 32000.0, "laden": 68000.0,
		"motors": 50, "torque_factor": 2.0,
		"p_meca_kw": 2880.0, "torque_meca": 60000.0, "omega": 48.0, "traction": 75000.0,
		"roll_empty": 2197.44, "roll_laden": 4669.56,
		"slope_empty_deg": 19.35, "slope_laden_deg": 8.66, "aero_empty_ms": 93.1,
	},
}


# ── Helpers ───────────────────────────────────────────────────

func _t1() -> VehicleEngineSpec:
	var spec := VehicleEngineSpec.new()
	spec.power_w = T1_POWER_W
	spec.torque_nm = T1_TORQUE_NM
	spec.efficiency = T1_EFFICIENCY
	return spec


func _motors(count: int) -> Array[VehicleEngineSpec]:
	var fitted: Array[VehicleEngineSpec] = []
	for _i in range(count):
		fitted.append(_t1())
	return fitted


func _spec_for(key: String) -> VehicleDriveSpec:
	var v: Dictionary = VEHICLES[key]
	var spec := VehicleDriveSpec.new()
	spec.motors = _motors(int(v["motors"]))
	spec.wheel_radius = float(v["r"])
	spec.pump_efficiency = PUMP
	spec.hydraulic_efficiency = HYDRAULIC
	spec.torque_factor = float(v["torque_factor"])
	spec.drag_coefficient = float(v["cx"])
	spec.frontal_area = float(v["area"])
	spec.rolling_coefficient = CR
	spec.rolling_factor = 1.0
	spec.air_density = RHO
	spec.gravity = GRAVITY
	return spec


func _assert_rel(got: float, want: float, what: String) -> void:
	assert_almost_eq(got, want, absf(want) * REL + 0.01, what)


# ── The sheet, row by row ─────────────────────────────────────

func test_mechanical_power_matches_sheet() -> void:
	for key in VEHICLES:
		_assert_rel(_spec_for(key).mech_power_w() / 1000.0, float(VEHICLES[key]["p_meca_kw"]),
				"%s mech power (kW)" % key)


func test_mechanical_torque_matches_sheet() -> void:
	# The efficiencies are deliberately NOT applied to torque — the sheet applies them to power
	# only, and that asymmetry is what puts the top speed where it was designed.
	for key in VEHICLES:
		_assert_rel(_spec_for(key).mech_torque_nm(), float(VEHICLES[key]["torque_meca"]),
				"%s mech torque (Nm)" % key)


func test_omega_max_matches_sheet() -> void:
	for key in VEHICLES:
		_assert_rel(_spec_for(key).omega_max_rads(), float(VEHICLES[key]["omega"]),
				"%s omega max (rad/s)" % key)


func test_tractive_force_matches_sheet() -> void:
	for key in VEHICLES:
		_assert_rel(_spec_for(key).tractive_force_n(), float(VEHICLES[key]["traction"]),
				"%s tractive force (N)" % key)


func test_rolling_force_matches_sheet() -> void:
	for key in VEHICLES:
		var v: Dictionary = VEHICLES[key]
		var spec := _spec_for(key)
		_assert_rel(spec.rolling_force_n(float(v["empty"])), float(v["roll_empty"]),
				"%s rolling force empty (N)" % key)
		_assert_rel(spec.rolling_force_n(float(v["laden"])), float(v["roll_laden"]),
				"%s rolling force laden (N)" % key)


func test_max_slope_matches_sheet() -> void:
	for key in VEHICLES:
		var v: Dictionary = VEHICLES[key]
		var spec := _spec_for(key)
		assert_almost_eq(rad_to_deg(spec.max_slope_rad(float(v["empty"]))),
				float(v["slope_empty_deg"]), DEG_TOL, "%s max slope empty (deg)" % key)
		assert_almost_eq(rad_to_deg(spec.max_slope_rad(float(v["laden"]))),
				float(v["slope_laden_deg"]), DEG_TOL, "%s max slope laden (deg)" % key)


func test_aero_top_speed_matches_sheet() -> void:
	for key in VEHICLES:
		var v: Dictionary = VEHICLES[key]
		assert_almost_eq(_spec_for(key).v_max_aero_ms(float(v["empty"])),
				float(v["aero_empty_ms"]), 0.1, "%s aero top speed empty (m/s)" % key)


func test_mvp_top_speed_and_acceleration() -> void:
	# Top SPEED is pinned on the MVP alone, because the sheet's "Proue" row is frozen at 1.885 m
	# (= TAU * 0.3) for all five columns instead of following each wheel radius. It is therefore
	# only right where the radius really is 0.3 — the MVP. The other four columns of the sheet
	# report wrong top speeds, and this code deliberately computes the correct ones.
	var spec := _spec_for("mvp")
	var empty: float = float(VEHICLES["mvp"]["empty"])
	assert_almost_eq(spec.v_max_motor_ms(), 28.8, 0.01, "MVP top speed (m/s)")
	assert_almost_eq(spec.v_max_motor_ms() * 3.6, 103.68, 0.05, "MVP top speed (km/h)")
	assert_almost_eq(spec.motor_rpm_max(), 916.7, 0.5, "MVP motor speed at top speed (rpm)")
	assert_eq(spec.limiting_factor(empty), "MOTOR", "MVP is engine-limited, not drag-limited")
	assert_almost_eq(spec.max_acceleration(empty), 3.93, 0.01, "MVP acceleration empty (m/s2)")
	assert_almost_eq(spec.time_to_speed(empty, 100.0 / 3.6), 7.07, 0.02, "MVP 0-100 empty (s)")


func test_laden_acceleration_uses_the_laden_mass() -> void:
	# The sheet's "Bilan chargé" block divides by mVide instead of mCharge (checked on all five
	# columns), so the laden figures it prints are far too optimistic. We compute the real ones:
	# 12.9 s to 100 km/h, not the 7.17 s it shows.
	var spec := _spec_for("mvp")
	var laden: float = float(VEHICLES["mvp"]["laden"])
	assert_almost_eq(spec.max_acceleration(laden), 2.15, 0.01, "MVP acceleration laden (m/s2)")
	assert_almost_eq(spec.time_to_speed(laden, 100.0 / 3.6), 12.90, 0.05, "MVP 0-100 laden (s)")


# ── The model's own character ─────────────────────────────────

func test_fitting_more_motors_adds_pull_but_not_speed() -> void:
	# The whole point of the feature: power and torque both scale with the motor count, so it
	# cancels out of omega = P / C. A second engine pulls harder, it does not go faster.
	for count in [1, 2, 3, 4]:
		var spec := _spec_for("mvp")
		spec.motors = _motors(count)
		_assert_rel(spec.tractive_force_n(), 2000.0 * count,
				"tractive force with %d motors" % count)
		assert_almost_eq(spec.v_max_motor_ms(), 28.8, 0.01,
				"top speed must not depend on the motor count (%d fitted)" % count)


func test_single_motor_matches_the_reference_screenshot() -> void:
	# A one-motor MVP is the configuration captured in the design screenshot we were handed.
	# Matching it to two decimals confirms the whole chain of formulas, not just one row.
	var spec := _spec_for("mvp")
	spec.motors = _motors(1)
	var empty: float = float(VEHICLES["mvp"]["empty"])
	assert_almost_eq(rad_to_deg(spec.max_slope_rad(empty)), 10.61, 0.02,
			"1 motor: max slope (deg)")
	assert_almost_eq(spec.max_acceleration(empty), 1.26, 0.01, "1 motor: acceleration (m/s2)")
	assert_almost_eq(spec.time_to_speed(empty, 100.0 / 3.6), 21.97, 0.05, "1 motor: 0-100 (s)")


# ── Empty is a valid state ────────────────────────────────────

func test_no_engine_returns_zero_everywhere_and_never_divides_by_zero() -> void:
	var spec := _spec_for("mvp")
	spec.motors = []
	assert_false(spec.is_valid(), "a vehicle with no engine is not drivable")
	assert_eq(spec.motor_count(), 0, "no motors fitted")
	assert_almost_eq(spec.mech_power_w(), 0.0, 0.0001, "no power")
	assert_almost_eq(spec.mech_torque_nm(), 0.0, 0.0001, "no torque")
	assert_almost_eq(spec.omega_max_rads(), 0.0, 0.0001, "no angular speed")
	assert_almost_eq(spec.v_max_motor_ms(), 0.0, 0.0001, "no top speed")
	assert_almost_eq(spec.tractive_force_n(), 0.0, 0.0001, "no tractive force")
	assert_almost_eq(spec.max_acceleration(1500.0), 0.0, 0.0001, "no acceleration")
	assert_almost_eq(rad_to_deg(spec.max_slope_rad(1500.0)), 0.0, 0.0001, "climbs nothing")
	assert_eq(spec.limiting_factor(1500.0), "NONE", "nothing is limiting, there is no engine")
	assert_eq(spec.time_to_speed(1500.0, 27.78), INF, "never reaches any speed")


func test_degenerate_inputs_do_not_crash() -> void:
	var spec := _spec_for("mvp")
	spec.wheel_radius = 0.0
	assert_almost_eq(spec.tractive_force_n(), 0.0, 0.0001, "zero wheel radius yields no force")
	spec = _spec_for("mvp")
	assert_almost_eq(spec.max_acceleration(0.0), 0.0, 0.0001, "zero mass does not divide by zero")
	spec = _spec_for("mvp")
	spec.gravity = 0.0
	assert_almost_eq(rad_to_deg(spec.max_slope_rad(1500.0)), 0.0, 0.0001, "no gravity, no slope")


func test_an_underpowered_engine_never_pulls_backwards() -> void:
	# Rolling resistance can exceed what a tiny engine produces. The net force must floor at 0,
	# not go negative and make the vehicle accelerate the wrong way.
	var spec := _spec_for("mvp")
	var weak := _t1()
	weak.torque_nm = 1.0
	var fitted: Array[VehicleEngineSpec] = [weak]
	spec.motors = fitted
	assert_almost_eq(spec.net_force_n(1500.0), 0.0, 0.0001, "net force floors at zero")
	assert_almost_eq(spec.max_acceleration(1500.0), 0.0, 0.0001, "and so does acceleration")
