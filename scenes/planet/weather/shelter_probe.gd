class_name ShelterProbe
extends RefCounted
## How sheltered a body is from the weather, asked of the physics world with six rays from its eye:
## one up (a roof), four along the ground (walls around), one toward where the wind comes from (a
## wall, a hill, a truck in the wind's way: the lee). `probe` only casts; `combine` is pure and turns
## the hits into the numbers the presenters and the forces read, so the rule is testable without a
## scene. Buildings, containers and vehicles stop a ray (Globals.MASK_OBSTACLE); on the dedicated
## server the terrain does too (a hill's lee), on a client it does not (no terrain collision there).
## The canyons' shelter is WeatherLocal's business on both, so a caller standing in a trench leaves
## the lee out (count_lee = false) rather than count it twice.
##
## Named simplifications: a ray sees a wall, not its height, so a low fence shelters like a hangar; a
## roof alone keeps a fifth of the wind and a fifth of the noise; a wall upwind at an angle counts as
## square to the wind.

## A wall or a roof within this (m) counts as around the body.
const REACH_M: float = 8.0
## An obstacle this close toward the wind puts the body in its lee, fully when it is touched.
const LEE_M: float = 14.0
## What a full lee alone takes off the wind on the body (the rest leaks around the obstacle).
const LEE_WIND_CUT: float = 0.8
## Under this wind (m/s) there is nothing to hide from: the upwind ray is not cast.
const CALM_MS: float = 0.5


## The numbers from the hits: {"enclosed": 0..1 (the share of the five rays around that hit),
## "lee": 0..1 (an obstacle upwind, the closer the more), "shelter": 0..1 (what the ears and the eyes
## get: the enclosure, or half a lee), "wind_factor": 0..1 (what the wind on the body keeps)}.
## [param lee_distance_m] < 0 = nothing upwind.
static func combine(roof_hit: bool, side_hits: int, lee_distance_m: float, count_lee: bool = true) -> Dictionary:
	var around: int = clampi(side_hits, 0, 4) + (1 if roof_hit else 0)
	var enclosed: float = float(around) / 5.0
	var lee: float = 0.0
	if count_lee and lee_distance_m >= 0.0 and lee_distance_m < LEE_M:
		lee = 1.0 - lee_distance_m / LEE_M
	return {
		"enclosed": enclosed,
		"lee": lee,
		"shelter": maxf(enclosed, 0.5 * lee),
		"wind_factor": (1.0 - enclosed) * (1.0 - LEE_WIND_CUT * lee),
	}


## Out in the open: nothing around, nothing upwind.
static func open() -> Dictionary:
	return combine(false, 0, -1.0)


## Walled in: a cab, a sealed room. Everything stopped.
static func enclosed() -> Dictionary:
	return combine(true, 4, 0.0)


## Cast the rays from [param eye] on [param body] (left out of the hits) with the local [param up] and
## the [param wind] (world, m/s). Only from a physics frame (direct_space_state is null elsewhere):
## without one, open().
static func probe(body: Node3D, eye: Vector3, up: Vector3, wind: Vector3, mask: int,
		count_lee: bool = true) -> Dictionary:
	if body == null or not body.is_inside_tree():
		return open()
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	if space == null:
		return open()
	var exclude: Array[RID] = []
	if body is CollisionObject3D:
		exclude.append((body as CollisionObject3D).get_rid())
	var n: Vector3 = up.normalized() if not up.is_zero_approx() else Vector3.UP
	var ref: Vector3 = Vector3.FORWARD if absf(n.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var a: Vector3 = n.cross(ref).normalized()
	var b: Vector3 = n.cross(a)
	var roof: bool = _distance(space, eye, n, REACH_M, mask, exclude) >= 0.0
	var sides: int = 0
	for d: Vector3 in [a, -a, b, -b]:
		if _distance(space, eye, d, REACH_M, mask, exclude) >= 0.0:
			sides += 1
	var lee_distance: float = -1.0
	var flat: Vector3 = wind - n * wind.dot(n)
	if flat.length() > CALM_MS:
		lee_distance = _distance(space, eye, -flat.normalized(), LEE_M, mask, exclude)
	return combine(roof, sides, lee_distance, count_lee)


## Distance (m) to the first obstacle along [param dir] from [param from] within [param reach], -1 for none.
static func _distance(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, reach: float, mask: int,
		exclude: Array[RID]) -> float:
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * reach)
	params.collision_mask = mask
	params.exclude = exclude
	# NOT `:=` — an untyped Dictionary from the physics server breaks inference.
	var hit = space.intersect_ray(params)
	if hit.is_empty():
		return -1.0
	return from.distance_to(hit["position"])
