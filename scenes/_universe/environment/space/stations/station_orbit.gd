class_name StationOrbit
extends KeplerOrbit
## Where an orbital station is, as a pure function of time — the way a moon is (see KeplerOrbit and
## Planet._place_at_time), so the server and every client land on the same point with nothing on the
## wire.
##
## A station's elements are given against its body's EQUATOR, not the ecliptic a moon's are given
## against: that is how a real one is described ("51.6° inclination"). The equator is the body's
## orbital-frame XZ plane tipped by its axial tilt, so [method position_at] returns positions in the
## SAME parent frame as a moon's KeplerOrbit. Hence a subclass: a station's orbit IS a Kepler orbit,
## only described against another plane, and everything written for moons (the client placement that
## cancels the spinning parent, the star map's orbit ring and panel) takes it as one.
##
## ⚠️ KeplerOrbit turns its ascending node about Z, the service's convention for planets. About an
## XZ orbital plane that is not a node at all, so it is given 0 here and the node is applied about the
## body's spin axis instead.
##
## ⚠️ KeplerOrbit also runs its orbits CLOCKWISE seen from +Y (from +X toward +Z: angular momentum
## along -Y), while a body spins counter-clockwise about +Y (Planet._place_at_time). Fed a plain
## inclination, a station "like the ISS" came out RETROGRADE, at 128.4° instead of 51.6°: the solver
## is given the supplement, so an inclination below 90° is prograde, as it is for a real station.

## Metres. The orbit is circular: a station keeps its altitude.
var radius_m: float = 0.0

## Body equator (axial tilt) and ascending node, from the orbital plane to the parent frame.
var _to_parent: Basis = Basis.IDENTITY


## [param primary_mass_kg] is the body's mass; the angles are radians. [param axial_tilt_rad] is the
## body's, the same angle Planet._place_at_time tips it by.
func _init(orbit_radius_m: float, inclination_rad: float, ascending_node_rad: float, phase_rad: float,
		primary_mass_kg: float, axial_tilt_rad: float) -> void:
	var r_au: float = orbit_radius_m / AU_M
	super(r_au, r_au, PI - inclination_rad, 0.0, 0.0, phase_rad, primary_mass_kg, 0.0)
	radius_m = orbit_radius_m
	_to_parent = Basis(Vector3.BACK, axial_tilt_rad) * Basis(Vector3.UP, ascending_node_rad)


## The radius at which an orbit lasts [param period_s]: Kepler's third law, r³ = GM·T²/4π². With the
## body's own day, it is the orbit that stays above one point of the ground (synchronous).
static func synchronous_radius(gm: float, period_s: float) -> float:
	return pow(gm * period_s * period_s / (4.0 * PI * PI), 1.0 / 3.0)


## Position in the body's parent frame, metres from the body's centre, at absolute time [param t].
func position_at(t: float) -> Vector3:
	return _to_parent * super.position_at(t)


## World position at [param t] of a station orbiting [param body]: the orbit is given in the body's
## PARENT frame, so it goes through the parent's basis, not the body's (which spins). The same point
## OrbitalStation reaches through Planet.in_frame_of, without needing the station itself — which a
## client far from it never receives.
func world_position_around(body: Node3D, t: float) -> Vector3:
	var frame: Node3D = body.get_parent() as Node3D
	var offset: Vector3 = position_at(t)
	return body.global_position + (frame.global_basis * offset if frame != null else offset)


## The station's orientation at [param t], in the parent frame: +Y away from the body (the floor
## faces it, so its artificial gravity pulls toward the planet below) and -Z along the motion — the
## attitude a real station flies, turning once per orbit.
func attitude_at(t: float) -> Basis:
	var here: Vector3 = position_at(t)
	var up: Vector3 = here.normalized()
	# The velocity's direction, from two nearby points: a circular orbit has no radial component, but
	# the difference is projected on the horizontal anyway so rounding cannot tilt the floor.
	var ahead: Vector3 = position_at(t + 1.0) - position_at(t - 1.0)
	ahead = (ahead - up * ahead.dot(up)).normalized()
	var z: Vector3 = -ahead
	return Basis(up.cross(z), up, z)


## The orbit's angular rate n, rad/s: one turn per period (1.009e-3 at 400 km above SandBox).
func mean_motion() -> float:
	return _mean_motion


## Acceleration of a free body near the station, as seen FROM the station, in the station's own axes
## (attitude_at: +Y radial out, -Z along the motion, X against the orbit normal), for a body at
## [param local_pos] moving at [param local_vel] relative to it, on an orbit of angular rate [param n].
##
## The Clohessy-Wiltshire (Hill) equations — how rendezvous are flown. In their usual axes (x radial out,
## y along the motion, z along the orbit normal): ẍ = 3n²x + 2nẏ, ÿ = -2nẋ, z̈ = -n²z. Nothing is
## invented: a body let go beside the station is on an orbit of its own, and this is the difference
## between that orbit and the station's, which is also why the station's frame is the right one to
## describe it in. Higher is slower: let go 100 m above, it falls some 3.8 km behind in one orbit.
##
## Linearised: good to about d / r (1 % at ~70 km from a station 6 756 km from the centre).
static func hill_acceleration(local_pos: Vector3, local_vel: Vector3, n: float) -> Vector3:
	var n2: float = n * n
	# Ours: x_cw = +Y, y_cw = -Z, z_cw = -X.
	return Vector3(
			-n2 * local_pos.x,
			3.0 * n2 * local_pos.y - 2.0 * n * local_vel.z,
			2.0 * n * local_vel.y)
