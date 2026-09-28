extends GutTest
## A free body beside an orbital station drifts the way orbital mechanics says (Clohessy-Wiltshire):
## checked against the equations' EXACT solution, not against our own numbers.
##
## Station axes (StationOrbit.attitude_at): +Y radial out, -Z along the motion, X against the orbit
## normal. Exact solution for a body let go at rest (relative) x0 above: radial (4 - 3 cos nt)·x0, along
## the motion 6 (sin nt - nt)·x0 — after one orbit, back at x0 and 12π·x0 BEHIND (+Z here).

const SANDBOX_RADIUS_M := 6356000.0
const ALTITUDE_M := 400000.0
const SANDBOX_MASS_EARTHS := 0.788


func _orbit() -> StationOrbit:
	return StationOrbit.new(SANDBOX_RADIUS_M + ALTITUDE_M, 0.0, 0.0, 0.0,
			SANDBOX_MASS_EARTHS * Planet.MASS_EARTH, 0.0)


## One orbit of relative motion, integrated with RK4 (the test checks the equations, not an integrator).
func _drift(start: Vector3, n: float, seconds: float, dt: float = 1.0) -> Vector3:
	var p: Vector3 = start
	var v: Vector3 = Vector3.ZERO
	var steps: int = int(round(seconds / dt))
	var h: float = seconds / float(steps)
	for i: int in range(steps):
		var a1: Vector3 = StationOrbit.hill_acceleration(p, v, n)
		var p2: Vector3 = p + v * h * 0.5
		var v2: Vector3 = v + a1 * h * 0.5
		var a2: Vector3 = StationOrbit.hill_acceleration(p2, v2, n)
		var p3: Vector3 = p + v2 * h * 0.5
		var v3: Vector3 = v + a2 * h * 0.5
		var a3: Vector3 = StationOrbit.hill_acceleration(p3, v3, n)
		var p4: Vector3 = p + v3 * h
		var v4: Vector3 = v + a3 * h
		var a4: Vector3 = StationOrbit.hill_acceleration(p4, v4, n)
		p += (v + v2 * 2.0 + v3 * 2.0 + v4) * (h / 6.0)
		v += (a1 + a2 * 2.0 + a3 * 2.0 + a4) * (h / 6.0)
	return p


func test_the_orbit_turns_once_in_an_hour_and_three_quarters() -> void:
	var orbit: StationOrbit = _orbit()
	assert_almost_eq(orbit.mean_motion(), 1.0092e-3, 0.002e-3)
	assert_almost_eq(orbit.period_seconds(), 6225.0, 5.0)


func test_a_body_ahead_or_behind_stays_where_it_is() -> void:
	# Same orbit, another phase: an equilibrium, with no pull at all.
	var n: float = _orbit().mean_motion()
	assert_eq(StationOrbit.hill_acceleration(Vector3(0.0, 0.0, -500.0), Vector3.ZERO, n), Vector3.ZERO)
	assert_eq(StationOrbit.hill_acceleration(Vector3(0.0, 0.0, 800.0), Vector3.ZERO, n), Vector3.ZERO)


func test_a_body_beside_the_orbit_plane_is_pulled_back_to_it() -> void:
	var n: float = _orbit().mean_motion()
	var a: Vector3 = StationOrbit.hill_acceleration(Vector3(100.0, 0.0, 0.0), Vector3.ZERO, n)
	assert_almost_eq(a.x, -n * n * 100.0, 1.0e-12)
	assert_almost_eq(a.y, 0.0, 1.0e-12)
	assert_almost_eq(a.z, 0.0, 1.0e-12)


func test_let_go_above_it_falls_behind() -> void:
	var orbit: StationOrbit = _orbit()
	var p: Vector3 = _drift(Vector3(0.0, 100.0, 0.0), orbit.mean_motion(), orbit.period_seconds())
	assert_almost_eq(p.y, 100.0, 1.0, "back at its height after one orbit")
	assert_almost_eq(p.z, 12.0 * PI * 100.0, 5.0, "behind by 12π·x0 (+Z is backward)")
	assert_almost_eq(p.x, 0.0, 1.0e-6)


func test_let_go_below_it_moves_ahead() -> void:
	var orbit: StationOrbit = _orbit()
	var p: Vector3 = _drift(Vector3(0.0, -100.0, 0.0), orbit.mean_motion(), orbit.period_seconds())
	assert_almost_eq(p.z, -12.0 * PI * 100.0, 5.0, "lower is faster: ahead (-Z)")


func test_the_station_hands_the_pull_over_in_world_coordinates() -> void:
	var station: OrbitalStation = add_child_autofree(OrbitalStation.new())
	station.set_process(false)
	station._orbit = _orbit()
	station.global_basis = Basis(Vector3.RIGHT, 0.7) * Basis(Vector3.UP, 1.3)
	var local_pos := Vector3(20.0, 150.0, -40.0)
	var local_vel := Vector3(0.1, -0.2, 0.3)
	var axes: Basis = station.global_basis.orthonormalized()
	var expected: Vector3 = axes * StationOrbit.hill_acceleration(local_pos, local_vel, _orbit().mean_motion())
	var got: Vector3 = station.relative_acceleration(station.global_position + axes * local_pos, axes * local_vel)
	assert_almost_eq(got.x, expected.x, 1.0e-12)
	assert_almost_eq(got.y, expected.y, 1.0e-12)
	assert_almost_eq(got.z, expected.z, 1.0e-12)
