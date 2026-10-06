extends GutTest
## KeplerOrbit: the orbit of every planet, moon and station as a pure function of time, in the
## conventions the celestial service shares (kepler-orbit.ts): reference plane XZ, north +Y, orbits
## counter-clockwise seen from +Y (the sense a body spins in), Ry(node)·Rx(inc)·Ry(argPeri).
##
## The closed-form case (an inclined circular orbit) is the SAME, number for number, as the service's
## kepler-orbit.test.ts: a divergence between the two solvers would raise no error anywhere, it would
## put a planet somewhere else for the server than for the clients.

const SUN_KG := 1.98892e30
const SANDBOX_STAR_KG := 1.5088e30
const SECONDS_PER_DAY := 86400.0


# Rotations written out by hand, so the expected values owe nothing to Basis.
static func _ry(v: Vector3, angle: float) -> Vector3:
	return Vector3(v.x * cos(angle) + v.z * sin(angle), v.y, -v.x * sin(angle) + v.z * cos(angle))


static func _rx(v: Vector3, angle: float) -> Vector3:
	return Vector3(v.x, v.y * cos(angle) - v.z * sin(angle), v.y * sin(angle) + v.z * cos(angle))


## Where an inclined circular orbit must be: Ry(Ω)·Rx(i)·Ry(ω)·(a·cos M, 0, −a·sin M).
static func _closed_form(a_m: float, inc: float, node: float, arg_peri: float, mean_anomaly: float) -> Vector3:
	var in_plane := Vector3(a_m * cos(mean_anomaly), 0.0, -a_m * sin(mean_anomaly))
	return _ry(_rx(_ry(in_plane, arg_peri), inc), node)


func test_an_inclined_circular_orbit_matches_the_closed_form_shared_with_the_service() -> void:
	# 1 AU circular, inclined 30°, node at 40°, periapsis at 50°: the order of the three rotations
	# matters only because the inclination is not zero, which is the point.
	var inc := deg_to_rad(30.0)
	var node := deg_to_rad(40.0)
	var arg_peri := deg_to_rad(50.0)
	var orbit := KeplerOrbit.new(1.0, 1.0, inc, node, arg_peri, 0.0, SUN_KG, 0.0)
	var a_m: float = KeplerOrbit.AU_M
	var n: float = TAU / orbit.period_seconds()
	for fraction: float in [0.0, 0.25, 1.0 / 3.0, 0.7]:
		var t: float = fraction * orbit.period_seconds()
		var expected: Vector3 = _closed_form(a_m, inc, node, arg_peri, n * t)
		var got: Vector3 = orbit.position_at(t)
		assert_lt(got.distance_to(expected), 1.0, "at %.2f of a period: %s vs %s" % [fraction, got, expected])


func test_a_flat_orbit_stays_in_the_xz_plane() -> void:
	# Node and periapsis anywhere: with no inclination they cannot lift the orbit out of the ecliptic.
	var orbit := KeplerOrbit.new(0.5335, 0.5665, 0.0, deg_to_rad(110.0), deg_to_rad(45.0), deg_to_rad(20.0),
			SANDBOX_STAR_KG, 0.0)
	for i in 8:
		var p: Vector3 = orbit.position_at(orbit.period_seconds() * i / 8.0)
		assert_almost_eq(p.y, 0.0, 1.0, "y = 0 at step %d" % i)


func test_the_orbit_runs_counter_clockwise_seen_from_north() -> void:
	# Angular momentum along +Y: the sense of a positive turn about +Y, which is how a body spins.
	var orbit := KeplerOrbit.new(0.5335, 0.5665, deg_to_rad(1.5), deg_to_rad(110.0), deg_to_rad(45.0), 0.0,
			SANDBOX_STAR_KG, 0.0)
	var p0: Vector3 = orbit.position_at(0.0)
	var momentum: Vector3 = p0.cross(orbit.position_at(600.0) - p0)
	assert_gt(momentum.y, 0.0, "counter-clockwise seen from +Y")


func test_the_inclination_is_measured_from_north() -> void:
	var inc := deg_to_rad(30.0)
	var orbit := KeplerOrbit.new(1.0, 1.0, inc, deg_to_rad(40.0), 0.0, 0.0, SUN_KG, 0.0)
	var quarter: float = orbit.period_seconds() / 4.0
	var normal: Vector3 = orbit.position_at(0.0).cross(orbit.position_at(quarter)).normalized()
	assert_almost_eq(rad_to_deg(normal.angle_to(Vector3.UP)), 30.0, 0.01, "30° between the orbit normal and +Y")


func test_the_body_rises_through_the_plane_at_the_ascending_node() -> void:
	# With the periapsis AT the node (ω = 0) and M = 0, the body sits on the line of nodes, at the
	# node's longitude about +Y, and is climbing: y grows just after.
	var node := deg_to_rad(40.0)
	var orbit := KeplerOrbit.new(1.0, 1.0, deg_to_rad(30.0), node, 0.0, 0.0, SUN_KG, 0.0)
	var at_node: Vector3 = orbit.position_at(0.0)
	var expected: Vector3 = _ry(Vector3(KeplerOrbit.AU_M, 0.0, 0.0), node)
	assert_lt(at_node.distance_to(expected), 1.0, "on the line of nodes, turned about +Y by the node")
	assert_gt(orbit.position_at(600.0).y, 0.0, "ascending: north of the plane just after")


func test_sandbox_keeps_its_period() -> void:
	var orbit := KeplerOrbit.new(0.5335, 0.5665, deg_to_rad(1.5), deg_to_rad(110.0), deg_to_rad(45.0),
			deg_to_rad(20.0), SANDBOX_STAR_KG, 0.788 * Planet.MASS_EARTH)
	assert_almost_eq(orbit.period_seconds() / SECONDS_PER_DAY, 171.05, 0.2, "tarsis.json: 171.05 days")


func test_a_planets_spin_axis_leans_on_its_orbit_by_its_tilt() -> void:
	# SandBox: tilt 15° in the data must be 15° between its spin axis and its orbit's normal — not the
	# 40° the old Z-turned basis produced (and 110° to 169° for six other planets, all retrograde).
	var orbit := KeplerOrbit.new(0.5335, 0.5665, deg_to_rad(1.5), deg_to_rad(110.0), deg_to_rad(45.0),
			deg_to_rad(20.0), SANDBOX_STAR_KG, 0.0)
	var quarter: float = orbit.period_seconds() / 4.0
	var normal: Vector3 = orbit.position_at(0.0).cross(orbit.position_at(quarter)).normalized()
	var spin_axis: Vector3 = Basis(Vector3.BACK, deg_to_rad(15.0)) * Vector3.UP
	# The orbit itself is inclined 1.5° on the ecliptic, so the angle lands within that of the tilt.
	assert_almost_eq(rad_to_deg(normal.angle_to(spin_axis)), 15.0, 1.5, "prograde, tilted by its tilt")
