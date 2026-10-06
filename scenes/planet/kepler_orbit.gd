class_name KeplerOrbit
extends RefCounted

## Double-precision Keplerian orbit, a straight port of the celestial service
## (resourcesDynamic, lib/celestial/orbit/kepler-orbit.ts). It returns a body's position as a PURE
## FUNCTION OF ABSOLUTE TIME, so the server and every client evaluate it independently and land on the
## same point WITHOUT any network traffic — the same design as Planet._apply_spin for rotation. Feeding
## the elements from the network later stays a drop-in (same columns as the DB).
##
## Conventions, shared with the service (its kepler-orbit.ts is the twin of this file, pinned by the
## same closed-form test on both sides, test_kepler_orbit.gd / kepler-orbit.test.ts):
## - the reference plane (the ecliptic for a planet, the planet's own plane for a moon) is XZ, with
##   +Y as its north — the same axis every body spins about (Planet.spin_basis_at), so an axial tilt
##   below 90° IS a prograde rotation, as it reads in the data, and a retrograde one is written like
##   Venus's, as a tilt above 90°;
## - the orbit runs COUNTER-CLOCKWISE seen from +Y, the sense of a positive turn about +Y and so the
##   sense a body spins in: angular momentum along +Y;
## - the perifocal frame reaches the reference frame through Ry(node)·Rx(inclination)·Ry(argPeri),
##   the textbook Rz(Ω)·Rx(i)·Rz(ω) with the up axis renamed.
##
## ⚠️ Until 2026-10-06 the node and the periapsis were turned about Z — an axis lying IN the XZ
## plane — which tipped every orbit out of the ecliptic by its node + periapsis (Tarsis 1 orbited in
## a vertical plane) and ran them clockwise: the angle between a body's spin axis and its orbit was
## never its tilt (SandBox 40° instead of 15°, six planets retrograde). Both sides changed together.

const AU_M := 1.495978707e11
const G := 6.6743e-11
const SOLAR_MASS_KG := 1.98892e30

var _semi_major_axis_m: float
var _eccentricity: float
## Mean motion (rad/s): the average angular rate around the orbit.
var _mean_motion: float
## Mean anomaly at t = 0 (rad).
var _mean_anomaly_epoch: float
## Perifocal -> reference-frame rotation.
var _basis: Basis

## periapsis/apoapsis in METRES-equivalent AU (already scaled if the caller shrinks the system); the
## angles in radians; the masses in KG (primary = the star for a planet, the planet for a moon).
func _init(periapsis_au: float, apoapsis_au: float, inc_rad: float, node_rad: float,
		arg_peri_rad: float, mean_anomaly_rad: float, primary_mass_kg: float,
		object_mass_kg: float) -> void:
	var rp: float = periapsis_au if periapsis_au > 0.0 else apoapsis_au
	var ra: float = apoapsis_au if apoapsis_au > 0.0 else periapsis_au
	if ra < rp:
		var swap: float = rp
		rp = ra
		ra = swap
	_semi_major_axis_m = 0.5 * (rp + ra) * AU_M
	_eccentricity = maxf(0.0, (ra - rp) / maxf(ra + rp, 1e-12))
	# Mean motion from Kepler's third law. NOTE the service scales DISTANCES but not MASS, so a shrunk
	# system orbits faster than reality — reproduced here by passing the same scaled a and raw mass.
	var mu: float = G * ((primary_mass_kg if primary_mass_kg > 0.0 else SOLAR_MASS_KG) + object_mass_kg)
	_mean_motion = sqrt(mu / pow(_semi_major_axis_m, 3.0))
	# Ry(node)·Rx(inc)·Ry(argPeri), outermost first: the periapsis is set within the orbital plane, the
	# plane is tipped about the line of nodes (X), and the node is turned to its longitude about +Y.
	# The service accumulates the same product with its pre-multiplying rotated(): argPeri, inc, node.
	_basis = Basis(Vector3.UP, node_rad) \
			* Basis(Vector3.RIGHT, inc_rad) \
			* Basis(Vector3.UP, arg_peri_rad)
	_mean_anomaly_epoch = mean_anomaly_rad


## Position in the parent frame (metres) at absolute time t seconds. The star sits at the origin for a
## planet; a moon's parent frame is centred on its planet.
func position_at(t: float) -> Vector3:
	var mean_anomaly: float = _normalize_angle(_mean_anomaly_epoch + _mean_motion * t)
	var ecc_anomaly: float = _solve_kepler(mean_anomaly, _eccentricity)
	var a: float = _semi_major_axis_m
	var xp: float = a * (cos(ecc_anomaly) - _eccentricity)
	# -sin: from +X toward -Z is the positive turn about +Y, so the orbit runs the way the body spins.
	var zp: float = -a * sqrt(maxf(1.0 - _eccentricity * _eccentricity, 0.0)) * sin(ecc_anomaly)
	return _basis * Vector3(xp, 0.0, zp)


## Orbital period in seconds (for logs / time-scale tuning).
func period_seconds() -> float:
	return 0.0 if _mean_motion == 0.0 else TAU / _mean_motion


## Newton-Raphson on Kepler's equation E - e·sin(E) = M. Converges in a handful of iterations for the
## near-circular orbits here; the 16-step / 1e-12 cap matches the service.
func _solve_kepler(mean_anomaly: float, e: float) -> float:
	var m: float = _normalize_angle(mean_anomaly)
	var ecc_anomaly: float = PI if e > 0.8 else m
	for _i in 16:
		var f: float = ecc_anomaly - e * sin(ecc_anomaly) - m
		var fp: float = 1.0 - e * cos(ecc_anomaly)
		var step: float = -f / maxf(fp, 1e-12)
		ecc_anomaly += step
		if absf(step) < 1e-12:
			break
	return _normalize_angle(ecc_anomaly)


## Fold an angle into [0, TAU).
func _normalize_angle(angle: float) -> float:
	var x: float = fmod(angle, TAU)
	if x < 0.0:
		x += TAU
	return x
