extends Node3D
## Reusable placeholder: drop this script on a Node3D placed in a scene to spawn a NETWORKED prop
## at this exact spot with a DETERMINISTIC uuid, so it stays the SAME object across server restarts
## (the database upserts by uuid -> no duplicate pile-up, no manual cleanup). On the server it spawns
## the real prop then frees itself; on clients it just frees itself (the server copy is authoritative).
##
## The uuid is seeded from `stable_id` (if set) or from the STABLE local placement (the parent's
## frame) + the parent uuid -- never from global_position, which drifts in a moving world frame and
## would give a new uuid every restart (that was the mining_depot double-spawn bug).
##
## Generalises the scenes/_universe/structures/industrial/mines/mining_depot.gd placeholder pattern. Server-authoritative.

## Prop type as known by Horizon (must match a ds_genericprops/props/<type>_def.json).
@export var prop_type: String = ""
## Scene the real prop instances from, e.g. "scenes/_universe/props/containers/crate.tscn".
@export var scenename: String = ""
## Optional explicit stable id. Leave empty to derive one from the local placement + parent.
@export var stable_id: String = ""
## Initial replicated data for the prop (channel payload). Optional.
@export var initial_data: Dictionary = {}
## Protect from the admin cleanup tool (designer-placed world infrastructure should not be deletable).
@export var protected: bool = true

func _ready() -> void:
	if not GameOrchestrator.is_server():
		queue_free()  # clients keep only the server-spawned authoritative copy
		return
	_spawn_deterministic.call_deferred()

func _spawn_deterministic() -> void:
	# Let networked parents register first (some receive their uuid a frame after spawn).
	await get_tree().create_timer(1.0).timeout
	# Find the nearest networked ancestor, skipping grouping / folder nodes that carry no uuid.
	var net_parent: Node = get_parent()
	while net_parent != null and not ("uuid" in net_parent):
		net_parent = net_parent.get_parent()
	var parent_uuid: String = str(net_parent.uuid) if net_parent != null else ""
	# Express the placement in the parent's frame so it lands at the same spot whatever the grouping.
	var place_xform: Transform3D = global_transform
	if net_parent is Node3D:
		place_xform = (net_parent as Node3D).global_transform.affine_inverse() * global_transform
	var place_pos: Vector3 = place_xform.origin
	var place_rot: Vector3 = place_xform.basis.get_euler()
	# Deterministic seed: stable across restarts (local placement is fixed in the parent's frame).
	var uuid_seed: String = stable_id if stable_id != "" \
		else "%s|%s|%.3f,%.3f,%.3f" % [prop_type, parent_uuid, place_pos.x, place_pos.y, place_pos.z]
	var prop_uuid: String = _stable_uuid(uuid_seed)
	if protected:
		NetworkOrchestrator.protected_prop_uuids[prop_uuid] = true
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": prop_type,
		"uuid": prop_uuid,
		"position": {"x": place_pos.x, "y": place_pos.y, "z": place_pos.z},
		"rotation": {"x": place_rot.x, "y": place_rot.y, "z": place_rot.z},
		"data": initial_data,
		"scenename": scenename,
		"parent_id": parent_uuid,
	})
	queue_free()  # the placeholder's job is done; the real networked prop now exists

## Build a deterministic, valid-format uuid from a seed string. Same seed -> same uuid.
func _stable_uuid(uuid_seed: String) -> String:
	var h: String = uuid_seed.sha256_text()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
