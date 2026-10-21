class_name SightLine
extends RefCounted

## Can an eye see a target: the sight checks of every look-at interaction -- furniture, door handles,
## seats, carriables -- shared by the server, which decides, and the client, which only shows a prompt
## for what it could use. Nothing solid may stand between the eye and the target.
##
## The physics ray says WHAT it met; how FAR is worked out again in the hit shape's own frame, in double
## precision: far out on a planet the physics engine's own numbers can be off by metres. Before, the
## distance was taken to the hit shape's centre, metres from where a long wall is crossed -- a 6.1 m
## container wall read as standing behind what was beyond it, and its neighbour's furniture and a truck's
## parts were offered through it (playtest 2026-10-21).

## Local boxes of the shapes that are not boxes (their debug mesh's bounds), by instance id.
static var _boxes: Dictionary = {}


## A ray for these checks, child of [param parent]: solids only (world, vehicles, props), set by hand
## and tested at once (force_raycast_update works anywhere; a space query only in a physics frame).
static func make_ray(parent: Node) -> RayCast3D:
	var ray := RayCast3D.new()
	ray.enabled = false
	ray.top_level = true  # target_position is a world delta, whatever the parent's transform
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	ray.collision_mask = Globals.MASK_OBSTACLE
	parent.add_child(ray)
	return ray


## True when [param viewer] (a Player, the ray's owner) at [param eye] sees [param target]: the box of a
## door handle on its side, a seat, a furniture part, or the carriable itself. Each kind ignores the body
## that holds it -- a vehicle's coarse hull encloses its handles and seats, a wardrobe its doors; foreign
## walls still hide them.
static func can_see(ray: RayCast3D, eye: Vector3, target: Node, viewer: Node) -> bool:
	if not (target is Node3D):
		return false
	if target.has_method("side_shape"):
		var veh: Node = target.vehicle() if target.has_method("vehicle") else null
		var inside: bool = veh != null and veh.has_method("is_occupied_by") and veh.is_occupied_by(viewer)
		var box: Node3D = target.side_shape(inside)
		if box == null:
			return true  # a handle without boxes: never locked
		return not blocked(ray, eye, box.global_position, [viewer, veh])
	if target is VehicleSeat:
		var seat := target as VehicleSeat
		return not blocked(ray, eye, seat.aim_point(), [viewer, seat.vehicle()])
	if target is FurnitureTarget:
		var part := target as FurnitureTarget
		return not blocked(ray, eye, part.aim_point(), [viewer] + part.los_exceptions())
	return first_hit_is(ray, eye, target as Node3D, [viewer])


## True if a solid not in [param exceptions] stands between [param from] and [param to].
static func blocked(ray: RayCast3D, from: Vector3, to: Vector3, exceptions: Array) -> bool:
	_cast(ray, from, to, exceptions)
	return ray.is_colliding() and hit_distance(ray, from, to) < from.distance_to(to)


## True if the first solid a ray from [param from] toward [param target] meets is the target itself
## (or a body of it, or one it hangs from: a part on its truck) -- or nothing, or something beyond it. A
## wall, the side of the bed it lies in, bodywork in front: not seen.
static func first_hit_is(ray: RayCast3D, from: Vector3, target: Node3D, exceptions: Array) -> bool:
	var to: Vector3 = from + (target.global_position - from) * 1.05  # a touch past: a thin target is crossed
	_cast(ray, from, to, exceptions)
	if not ray.is_colliding():
		return true
	var c: Object = ray.get_collider()
	if c == target or (c is Node and (target.is_ancestor_of(c) or (c as Node).is_ancestor_of(target))):
		return true
	return hit_distance(ray, from, to) > from.distance_to(target.global_position)


## How far from [param from] the segment to [param to] enters the shape the ray last hit: in that
## shape's frame, against its box (a BoxShape3D exactly, any other shape by its bounds). INF when the
## segment, in double precision, does not cross it at all (the physics ray caught it off the segment).
static func hit_distance(ray: RayCast3D, from: Vector3, to: Vector3) -> float:
	var body := ray.get_collider() as CollisionObject3D
	if body == null:
		return INF
	var owner_id: int = body.shape_find_owner(ray.get_collider_shape())
	if owner_id == -1:
		return INF
	var shape: Shape3D = body.shape_owner_get_shape(owner_id, 0)
	var frame: Transform3D = body.global_transform * body.shape_owner_get_transform(owner_id)
	var t: float = segment_entry(frame.affine_inverse() * from, frame.affine_inverse() * to, local_box(shape))
	return t * from.distance_to(to) if t < INF else INF


## Where (0..1 along it) the segment [param a] -> [param b] enters [param box], INF if it misses it.
## A segment starting inside enters at 0. Pure (the slab test).
static func segment_entry(a: Vector3, b: Vector3, box: AABB) -> float:
	var d: Vector3 = b - a
	var enter: float = 0.0
	var leave: float = 1.0
	for i in 3:
		var lo: float = box.position[i]
		var hi: float = box.end[i]
		if absf(d[i]) < 1e-12:
			if a[i] < lo or a[i] > hi:
				return INF
			continue
		var t1: float = (lo - a[i]) / d[i]
		var t2: float = (hi - a[i]) / d[i]
		enter = maxf(enter, minf(t1, t2))
		leave = minf(leave, maxf(t1, t2))
		if enter > leave:
			return INF
	return enter


## The box [param shape] fills, in its own frame.
static func local_box(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var size: Vector3 = (shape as BoxShape3D).size
		return AABB(-size * 0.5, size)
	var id: int = shape.get_instance_id()
	if not _boxes.has(id):
		_boxes[id] = shape.get_debug_mesh().get_aabb()
	return _boxes[id]


static func _cast(ray: RayCast3D, from: Vector3, to: Vector3, exceptions: Array) -> void:
	ray.global_position = from
	ray.target_position = to - from
	ray.clear_exceptions()
	for node in exceptions:
		if node is CollisionObject3D:
			ray.add_exception(node)
	ray.force_raycast_update()
