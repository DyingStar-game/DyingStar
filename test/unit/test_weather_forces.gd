extends GutTest
## WeatherForces, the wind's push, checked by hand: ½ρ·C·A·|v|·v, proportional to the air's density
## and to the square of the wind, along it; a body at rest takes the whole push and still air pushes
## nothing; on foot the push becomes a capped drift, in the air a capped acceleration.

## Tarsis III at its reference sphere (ClimateProfile tarsis_3: 1.265 kg/m³).
const RHO_TARSIS := 1.265


func test_a_gale_on_a_standing_body() -> void:
	var f : Vector3 = WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3(30.0, 0.0, 0.0))
	assert_almost_eq(f.x, 341.55, 0.1, "½ × 1.265 × 0.6 × 900")
	assert_almost_eq(f.y, 0.0, 1e-9)
	assert_almost_eq(f.z, 0.0, 1e-9)
	assert_almost_eq(WeatherForces.drag_force(RHO_TARSIS * 2.0, 1.0, 0.6, Vector3(30.0, 0.0, 0.0)).x,
			2.0 * 341.55, 0.2, "proportional to the density")
	assert_almost_eq(WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3(60.0, 0.0, 0.0)).x,
			4.0 * 341.55, 0.4, "proportional to the square of the wind")
	var slanted : Vector3 = WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3(3.0, 0.0, 4.0))
	assert_almost_eq(slanted.normalized().dot(Vector3(0.6, 0.0, 0.8)), 1.0, 1e-9, "along the wind")
	assert_eq(WeatherForces.drag_force(0.0, 1.0, 0.6, Vector3(30.0, 0.0, 0.0)), Vector3.ZERO, "no air, no push")
	assert_eq(WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3.ZERO), Vector3.ZERO, "calm")


func test_the_winds_own_share_of_the_drag() -> void:
	assert_eq(WeatherForces.wind_push(RHO_TARSIS, 1.0, 3.0, Vector3(20.0, 0.0, 0.0), Vector3.ZERO), Vector3.ZERO,
			"still air: the drive's own drag is all there is")
	var k : float = 0.5 * RHO_TARSIS * 3.0
	var rest : Vector3 = WeatherForces.wind_push(RHO_TARSIS, 1.0, 3.0, Vector3.ZERO, Vector3(30.0, 0.0, 0.0))
	assert_almost_eq(rest.x, k * 900.0, 1e-6, "a parked truck takes the full push")
	var head : Vector3 = WeatherForces.wind_push(RHO_TARSIS, 1.0, 3.0, Vector3(20.0, 0.0, 0.0), Vector3(-10.0, 0.0, 0.0))
	assert_lt(head.x, 0.0, "a headwind drags")
	assert_almost_eq(head.x, -900.0 * k + 400.0 * k, 1e-6, "k(|w-v|(w-v) - |-v|(-v)): 30 m/s of air against 20")
	var tail : Vector3 = WeatherForces.wind_push(RHO_TARSIS, 1.0, 3.0, Vector3(20.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0))
	assert_gt(tail.x, 0.0, "a tailwind pushes")
	assert_almost_eq(tail.x, -100.0 * k + 400.0 * k, 1e-6)


func test_on_foot_the_push_becomes_a_drift_and_in_the_air_an_acceleration_both_capped() -> void:
	var f : Vector3 = WeatherForces.drag_force(RHO_TARSIS, WeatherForces.PLAYER_DRAG, WeatherForces.PLAYER_AREA_M2,
			Vector3(30.0, 0.0, 0.0))
	assert_almost_eq(WeatherForces.drift_velocity(f, 80.0).x, 4.27, 0.01, "nothing held: 80 kg at 30 m/s slip 4.3 m/s")
	var hold : float = WeatherForces.hold_force(80.0, 9.6)
	assert_almost_eq(hold, 307.2, 1e-6, "the feet hold 0.4 of the weight on Tarsis III")
	assert_almost_eq(WeatherForces.drift_velocity(f, 80.0, hold).x, (341.55 - 307.2) / 80.0, 0.01,
			"held: only the excess slips, 0.4 m/s")
	var breeze : Vector3 = WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3(10.0, 0.0, 0.0))
	assert_eq(WeatherForces.drift_velocity(breeze, 80.0, hold), Vector3.ZERO, "a breeze slides nobody")
	assert_almost_eq(WeatherForces.acceleration(f, 80.0).x, 4.27, 0.01, "4.3 m/s² in the air")
	var gale : Vector3 = WeatherForces.drag_force(RHO_TARSIS, 1.0, 0.6, Vector3(60.0, 0.0, 0.0))
	assert_almost_eq(WeatherForces.drift_velocity(gale, 80.0).length(), WeatherForces.DRIFT_CAP_MS, 1e-9,
			"17 m/s of drift capped at 8")
	assert_almost_eq(WeatherForces.acceleration(gale, 80.0).length(), WeatherForces.ACCEL_CAP_MS2, 1e-9,
			"17 m/s² capped at 15")
	assert_eq(WeatherForces.drift_velocity(f, 0.0), Vector3.ZERO, "no mass, no drift (never divide by it)")


func test_along_the_ground_drops_the_updraft() -> void:
	assert_eq(WeatherForces.along_ground(Vector3(3.0, 5.0, 4.0), Vector3.UP), Vector3(3.0, 0.0, 4.0))
	assert_eq(WeatherForces.along_ground(Vector3(3.0, 5.0, 4.0), Vector3.ZERO), Vector3(3.0, 5.0, 4.0),
			"no up known: as is")
	var tilted : Vector3 = WeatherForces.along_ground(Vector3(0.0, 10.0, 0.0), Vector3(0.0, 1.0, 1.0))
	assert_almost_eq(tilted.dot(Vector3(0.0, 1.0, 1.0).normalized()), 0.0, 1e-9, "nothing left along the up")
