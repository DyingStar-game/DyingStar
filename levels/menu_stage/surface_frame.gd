class_name SurfaceFrame
extends RefCounted
## Points on a planet's surface given as "so many metres from here, in that direction" — the language
## a stage layout is written in, turned into planet-LOCAL positions (children of the planet node).
##
## Distances run along the great circle from the anchor, so "8 km" is 8 km of ground whatever the
## planet's radius. Bearings are degrees clockwise from the local north, seen from above; north is
## the planet's own axis (local +Y) projected on the ground. `ground` answers the surface distance
## from the centre in a direction — the real relief (PlanetData.crack_aware_surface_dist) in the game,
## a constant in tests.

var anchor_dir : Vector3
var radius : float
## (direction from the centre) -> surface distance from the centre: shared with frames built from this one.
var ground : Callable


func _init(anchor_local: Vector3, p_radius: float, p_ground: Callable) -> void:
	anchor_dir = anchor_local.normalized()
	radius = p_radius
	ground = p_ground


## Unit direction from the centre of the point `distance` metres away along `bearing_deg`.
func dir_at(distance: float, bearing_deg: float) -> Vector3:
	var tangent : Vector3 = _heading(anchor_dir, bearing_deg)
	var arc : float = distance / radius
	return (anchor_dir * cos(arc) + tangent * sin(arc)).normalized()


## The planet-local point there, `lift` metres above the ground.
func point(distance: float, bearing_deg: float, lift: float = 0.0) -> Vector3:
	var dir : Vector3 = dir_at(distance, bearing_deg)
	return dir * (float(ground.call(dir)) + lift)


## A basis standing on the ground at `dir` (up = away from the centre), facing `facing_deg`.
func basis_at(dir: Vector3, facing_deg: float) -> Basis:
	return Basis.looking_at(_heading(dir, facing_deg), dir)


## Bearing (degrees) from the anchor towards a planet-local point.
func bearing_to(local_point: Vector3) -> float:
	var towards : Vector3 = local_point.normalized() - anchor_dir * anchor_dir.dot(local_point.normalized())
	if towards.length_squared() < 1e-18:
		return 0.0
	var north : Vector3 = _north(anchor_dir)
	var east : Vector3 = north.cross(anchor_dir)
	return fposmod(rad_to_deg(atan2(towards.dot(east), towards.dot(north))), 360.0)


static func _heading(dir: Vector3, bearing_deg: float) -> Vector3:
	var north : Vector3 = _north(dir)
	var east : Vector3 = north.cross(dir)
	var b : float = deg_to_rad(bearing_deg)
	return (north * cos(b) + east * sin(b)).normalized()


## The local +Y axis projected on the ground at `dir`; at a pole, where it vanishes, local -Z.
static func _north(dir: Vector3) -> Vector3:
	var north : Vector3 = Vector3.UP - dir * dir.dot(Vector3.UP)
	if north.length_squared() < 1e-12:
		north = Vector3.FORWARD - dir * dir.dot(Vector3.FORWARD)
	return north.normalized()
