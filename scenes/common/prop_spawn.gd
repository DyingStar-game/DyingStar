class_name PropSpawn
extends RefCounted

## Placing a networked prop in a world whose frames MOVE. Three primitives, shared by everything that
## spawns a prop server-side (the dev spawn wheel today; mining_zone / mining_depot / rock each still
## carry their own copy of this and should migrate here).
##
## The rule they exist to enforce: a prop must be parented to the networked frame it sits on (the
## planet, the city) and its position expressed LOCALLY to that frame. A prop left at the root
## (parent_id = "") is pinned in world space while the planet moves at ~3e10 — it instantly drifts
## away and the client renders it flying into space. See mining_zone.gd for the original of this.

## Nearest ancestor that is a networked object (it carries a `uuid`) — the frame a prop must be
## parented to. Null when there is none (the prop then lives at the root, in world coordinates).
static func find_net_parent(node: Node) -> Node:
	var n: Node = node.get_parent()
	while n != null and not ("uuid" in n):
		n = n.get_parent()
	return n

## The uuid of that frame, or "" — this is what travels as `parent_id`.
static func net_parent_uuid(net_parent: Node) -> String:
	return str(net_parent.uuid) if net_parent != null and "uuid" in net_parent else ""

## A WORLD position expressed in the frame of `net_parent` — the form the network expects for a
## parented prop. Identity when there is no parent (world coordinates then).
static func to_parent_local(net_parent: Node, world_position: Vector3) -> Vector3:
	if net_parent is Node3D:
		return (net_parent as Node3D).global_transform.affine_inverse() * world_position
	return world_position

## Where the ground is under `world_position`, along `up`. Casts down from `search` metres above to
## `search` metres below and returns the WORLD hit position, or null when there is nothing there
## (a hole, or a prop dropped over the void).
##
## The hit is validated in DOUBLE precision: at this project's astronomic coordinates the ray's own
## origin is imprecise in Jolt's float32 narrowphase, so a ray can "catch" a collider far away and
## report a hit metres off. Anything further than the search span is an artefact and is rejected.
## Must be called from the physics step — direct_space_state is null outside it.
static func ground_point(space: PhysicsDirectSpaceState3D, world_position: Vector3, up: Vector3,
		search: float = 30.0, exclude: Array[RID] = []) -> Variant:
	if space == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(
			world_position + up * search, world_position - up * search,
			Globals.MASK_OBSTACLE, exclude)
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var ground: Vector3 = hit["position"]
	if ground.distance_to(world_position) > search * 1.5:
		return null  # float32 artefact: the ray hit something that is nowhere near where we aimed
	return ground
