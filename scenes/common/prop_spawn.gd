class_name PropSpawn
extends RefCounted

## Placing a networked prop in a world whose frames MOVE. The primitives shared by everything that
## spawns a prop server-side (the dev spawn wheel, MiningZonePlanner, MiningZone; mining_depot and
## rock still carry their own copies of stable_uuid / the net-parent walk and should migrate here).
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

## The uuid of the frame `node`'s LOCAL transform is currently expressed in — the value that MUST
## travel as `parent_id` for it. This reads the DIRECT parent on purpose: `position` is local to the
## direct parent and to nothing else, so declaring any other node (an ancestor, a nearby planet)
## publishes coordinates in a frame they were never measured in. "" means "world frame".
##
## Derive, never declare: every sender must call this at send time instead of passing a uuid it chose
## earlier. "The parent Horizon believes in" and "the parent in the scene tree" then stop being two
## states that can drift apart — there is only the tree. Reparent first, send second, and the two are
## consistent by construction. See PropNet.server_tick and Server._on_player_move.
static func parent_frame_uuid(node: Node) -> String:
	return net_parent_uuid(node.get_parent())

## A WORLD position expressed in the frame of `net_parent` — the form the network expects for a
## parented prop. Identity when there is no parent (world coordinates then).
static func to_parent_local(net_parent: Node, world_position: Vector3) -> Vector3:
	if net_parent is Node3D:
		return (net_parent as Node3D).global_transform.affine_inverse() * world_position
	return world_position

## A valid-format uuid derived from `seed_str` — same seed, same uuid, across restarts and across
## servers. This is what lets a server RE-spawn world infrastructure it already spawned (a depot, a
## mining zone, the rocks in a field) and have the database upsert it instead of piling a duplicate
## on every boot. Never use it for something that must be unique per instance; use uuid.v4() there.
static func stable_uuid(seed_str: String) -> String:
	var h: String = seed_str.sha256_text()
	return "%s-%s-%s-%s-%s" % [
		h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

## Orientation of a prop resting on a surface: its local +Y along `normal_world`, plus `yaw` around
## that normal. Returned as EULER ANGLES IN THE PARENT FRAME, because `rotation` travels
## parent-local — and on a planet the parent's +Y is the POLE, not the local up, so a plain
## (0, yaw, 0) lays a prop on its side everywhere except at the pole. Physics used to hide that by
## letting a dropped prop topple as it fell; placing one directly does not.
static func surface_euler(normal_world: Vector3, yaw: float,
		to_parent_local: Transform3D) -> Vector3:
	var up_w: Vector3 = normal_world.normalized()
	# Any reference direction not parallel to the normal yields a tangent to build the basis on.
	var ref: Vector3 = Vector3.FORWARD if absf(up_w.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x_w: Vector3 = ref.cross(up_w).normalized()
	var basis_w := Basis(x_w, up_w, x_w.cross(up_w)).rotated(up_w, yaw)
	return (to_parent_local.basis * basis_w).orthonormalized().get_euler()

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
