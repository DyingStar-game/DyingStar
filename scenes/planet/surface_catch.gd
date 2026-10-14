class_name SurfaceCatch
extends RefCounted
## The real ground for the server's below-surface catch (PlayerServer, Vehicle).
##
## The catch measures a body against the THEORETICAL surface, the relief sampled at
## the body's own point (PlanetData.carved_surface_dist). The collision the body
## stands on is a grid of triangles ~25 m apart, and on a sharp convex crest the
## triangles run under the relief: 7.6 m on a tarsis_3 crater rim
## (39.593 W 24.443 N). A player standing on that collision was "7 m under the
## ground", thrown back onto the theoretical surface, fell back onto the triangles,
## and was thrown again: he hopped on the spot.
##
## So once the theoretical test says "below", the WORLD collision is asked: a ray
## from just above the theoretical surface down to under the body finds the
## topmost solid there. If it is at the body's feet, the body stands on it; if it is
## above, the body really went through it and is put back ON it.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")
## The ray starts this far above the theoretical surface (m).
const RAY_LIFT_M := 1.0


## Distance from the centre of [param planet] of the topmost world-layer solid along
## [param dir] (planet frame), searched from just above [param surface_dist] down to
## [param margin] under [param body_dist]. -1.0 when there is none: no collision is
## built there, the theoretical surface is all there is.
static func ground_dist(space: PhysicsDirectSpaceState3D, planet: Node3D, dir: Vector3,
		surface_dist: float, body_dist: float, margin: float, exclude: Array[RID]) -> float:
	if space == null:
		return -1.0
	var basis := planet.global_transform.basis
	var from: Vector3 = planet.global_position + basis * (dir * (surface_dist + RAY_LIFT_M))
	var to: Vector3 = planet.global_position + basis * (dir * (body_dist - margin))
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 << (GlobalsDefs.LAYER_WORLD - 1), exclude)
	q.hit_back_faces = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return -1.0
	return (basis.inverse() * ((hit["position"] as Vector3) - planet.global_position)).length()
