extends GutTest
## VehicleResistance: the air (½·ρ·Cd·A·v², the planet's ρ) and the tyres (Crr·m·g) hold a vehicle
## back at every throttle -- so at a steady speed the motors push, and draw, what the speed takes.

const RHO := 1.26
const CD := 1.0
const AREA := 3.0
const MASS := 1500.0
const G := 7.77
const CRR := 0.01


func test_the_air_grows_with_the_square_of_the_speed() -> void:
	var at_50: float = VehicleResistance.aero_n(50.0 / 3.6, RHO, CD, AREA)
	var at_100: float = VehicleResistance.aero_n(100.0 / 3.6, RHO, CD, AREA)
	assert_almost_eq(at_100 / at_50, 4.0, 1e-6)
	assert_almost_eq(at_100, 0.5 * RHO * CD * AREA * pow(100.0 / 3.6, 2.0), 1e-6)


func test_thinner_air_holds_back_less_and_no_air_not_at_all() -> void:
	var sea: float = VehicleResistance.aero_n(25.0, 1.27, CD, AREA)
	var plateau: float = VehicleResistance.aero_n(25.0, 0.77, CD, AREA)
	assert_lt(plateau, sea, "the villages' 5130 m on Tarsis III")
	assert_eq(VehicleResistance.aero_n(25.0, 0.0, CD, AREA), 0.0, "an airless world")


func test_the_tyres_cost_the_same_at_any_speed_and_fade_out_at_rest() -> void:
	assert_almost_eq(VehicleResistance.rolling_n(10.0, MASS, G, CRR), CRR * MASS * G, 1e-6)
	assert_almost_eq(VehicleResistance.rolling_n(30.0, MASS, G, CRR), CRR * MASS * G, 1e-6)
	assert_eq(VehicleResistance.rolling_n(0.0, MASS, G, CRR), 0.0, "nothing to push back at rest")
	assert_lt(VehicleResistance.rolling_n(0.2, MASS, G, CRR), CRR * MASS * G)


func test_the_force_opposes_the_motion() -> void:
	var v := Vector3(3.0, 0.0, -20.0)
	var f: Vector3 = VehicleResistance.force(v, RHO, CD, AREA, MASS, G, CRR, true)
	assert_almost_eq(f.normalized().dot(v.normalized()), -1.0, 1e-6)
	assert_eq(VehicleResistance.force(Vector3.ZERO, RHO, CD, AREA, MASS, G, CRR, true), Vector3.ZERO)


func test_in_the_air_only_the_air_holds_back() -> void:
	var v := Vector3(0.0, 0.0, -20.0)
	var flying: float = VehicleResistance.force(v, RHO, CD, AREA, MASS, G, CRR, false).length()
	assert_almost_eq(flying, VehicleResistance.aero_n(20.0, RHO, CD, AREA), 1e-6)


func test_the_truck_holds_its_top_speed_with_the_motors_pushing() -> void:
	# The MVP truck at Tarsis III's air: near 100 km/h the drag is well above a kilonewton, so the
	# motors still push there instead of sitting at 0 % with full batteries.
	var at_100: float = VehicleResistance.force(Vector3(0, 0, -100.0 / 3.6), RHO, CD, AREA, MASS, G, CRR, true).length()
	assert_gt(at_100, 1000.0)
