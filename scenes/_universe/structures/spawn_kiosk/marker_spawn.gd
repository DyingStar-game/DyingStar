class_name MarkerSpawn
extends RefCounted

## SERVER: hand a networked prop out at a designer-placed marker, if the box over the marker is empty.
## Shared by the machines that do it — the item dispensers (ItemDispenser), the garage's vehicle
## terminal among them, and the props a building holds from the start (FixtureSpawn) — which only
## decide WHAT to hand out and WHEN.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")


## The GORC type of [param scene]: its PropSync's type_name, else the root's own `type_name` (a Vehicle
## carries its networking itself, without PropSync). "" when it has neither, and then it is not
## networked and must not be spawned. Instanced without entering the tree (no _ready runs): cache it.
static func scene_type(scene: PackedScene) -> String:
	if scene == null:
		return ""
	var probe: Node = scene.instantiate()
	var type_name: String = ""
	var sync: PropSync = PropSync.of(probe)
	if sync != null:
		type_name = str(sync.type_name)
	elif "type_name" in probe:
		type_name = str(probe.type_name)
	probe.free()
	return type_name


## The networked building [param node] belongs to: its nearest networked ancestor
## (PropSync.networked_from), or null.
static func building_of(node: Node) -> Node:
	return PropSync.networked_from(node.get_parent()) if node != null else null


## First body of [param mask] (solids by default) in the box of [param size] (m) over [param marker] —
## its bottom [param lift] m above the marker so the floor does not count — or null when the box is
## empty. The bodies under [param exclude_root] (the building: walls, floor, the machine itself) are
## left out, they would always fill it — not the networked props that came into it (_collect_body_rids).
## Only during a physics frame (a space query anywhere else silently finds nothing).
static func blocker(marker: Node3D, size: Vector3, lift: float, exclude_root: Node,
		mask: int = Globals.MASK_SOLID) -> Object:
	var box := BoxShape3D.new()
	box.size = size
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = box
	var xf: Transform3D = marker.global_transform
	params.transform = Transform3D(xf.basis, xf.origin + xf.basis.y.normalized() * (lift + size.y * 0.5))
	params.collision_mask = mask
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var exclude: Array[RID] = []
	_collect_body_rids(exclude_root if exclude_root != null else marker, exclude)
	params.exclude = exclude
	var hits: Array[Dictionary] = marker.get_world_3d().direct_space_state.intersect_shape(params, 1)
	return hits[0].get("collider") if not hits.is_empty() else null


## The bodies of [param node] and of what it is built of. A networked prop of its own under it (a
## part or a tool handed out, parented to the depot it lies in) is not the building's: it is left in
## — leaving it out kept a dispenser's flap shut on the tool in its hatch.
static func _collect_body_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		var sync := PropSync.of(child)
		if sync != null and sync.uuid != "":
			continue
		_collect_body_rids(child, out)


## Hand [param scene] (network type [param type_name]) to the network at [param marker], placed in the
## frame of the networked parent it sits on (the planet): a prop left in world coordinates would drift
## away with the moving planet. [param uuid] is the prop's (a new one when empty). Returns it.
static func spawn(scene: PackedScene, type_name: String, marker: Node3D, uuid: String = "") -> String:
	var net_parent: Node = PropSpawn.find_net_parent(marker)
	var world: Transform3D = marker.global_transform
	var local_pos: Vector3 = PropSpawn.to_parent_local(net_parent, world.origin)
	var local_basis: Basis = world.basis
	if net_parent is Node3D:
		local_basis = (net_parent as Node3D).global_basis.inverse() * world.basis
	var local_rot: Vector3 = local_basis.orthonormalized().get_euler()
	if uuid == "":
		uuid = UUID_UTIL.v4()
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": type_name,
		"uuid": uuid,
		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
		"rotation": {"x": local_rot.x, "y": local_rot.y, "z": local_rot.z},
		"scenename": scene.resource_path.trim_prefix("res://"),
		"parent_id": PropSpawn.net_parent_uuid(net_parent),
	})
	return uuid
