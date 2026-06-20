class_name PropNet
extends RefCounted

## Shared server-side replication helpers for networked props (DRY: GDScript has single
## inheritance and props extend different bodies — RigidBody3D / StaticBody3D / VehicleBody3D —
## so they can't share a base class; they call these static helpers instead).
##
## A prop using server_tick MUST expose: `uuid`, `type_name`, `has_parent`,
## `server_last_position`, `server_last_rotation` and the `hs_server_prop_update` signal.
## A prop using the client ride helpers (apply_client_transform / ride_pin) MUST also expose
## `_ride_local_pos` and `_ride_local_rot`.

## Client: match the freeze mode to the prop's parent. A bed-riding crate must be KINEMATIC so the
## frozen body follows the moving truck through the scene tree (a STATIC frozen body instead gets its
## world transform rewritten every physics frame, so it stays put while the truck drives off — the
## "cargo left behind at speed" bug). Resting in the world stays STATIC.
static func apply_ride_freeze_mode(prop: RigidBody3D) -> void:
	if GameOrchestrator.is_server():
		return  # the server sets KINEMATIC itself on lock; this is the client replica's parenting
	prop.freeze_mode = (
		RigidBody3D.FREEZE_MODE_KINEMATIC if prop.get_parent() is Vehicle
		else RigidBody3D.FREEZE_MODE_STATIC)

## Client: apply a replicated LOCAL pose (position/rotation) and remember it so ride_pin can hold it.
## Call from a prop's client_channel_data_update (shared by every networked prop).
static func apply_client_transform(prop: Node3D, data: Dictionary) -> void:
	if data.has("position"):
		prop.position = Vector3(data["position"]["x"], data["position"]["y"], data["position"]["z"])
		prop._ride_local_pos = prop.position
	if data.has("rotation"):
		prop.rotation = Vector3(data["rotation"]["x"], data["rotation"]["y"], data["rotation"]["z"])
		prop._ride_local_rot = prop.rotation

## Client: while riding a bed, re-assert the constant LOCAL pose every render frame. The crate is a
## physics body, so it otherwise refreshes only at the (slower) physics tick and lags the truck,
## which is interpolated at render rate -> visible jitter. Call from a prop's _process; the parent
## (truck) runs first, so a direct set (no lerp) tracks it exactly.
static func ride_pin(prop: Node3D) -> void:
	if GameOrchestrator.is_server():
		return
	if prop.get_parent() is Vehicle:
		prop.position = prop._ride_local_pos
		prop.rotation = prop._ride_local_rot

## Call from a prop's _physics_process. Replicates position/rotation when they change. While
## the prop is CARRIED (parented to a Player), re-sends position + parent_id every frame so
## Horizon recomputes its global from the parent's current position (otherwise the prop's
## GORC zone goes stale and it despawns for everyone over distance).
static func server_tick(prop: Node) -> void:
	if not GameOrchestrator.is_server():
		return
	var pos: Vector3 = snapped(prop.position, Vector3(0.005, 0.005, 0.005))  # 5 mm precision is enough for a prop
	var rot: Vector3 = snapped(prop.rotation, Vector3(0.01, 0.01, 0.01)) # it's precision at 0.57 degrees
	var parent: Node = prop.get_parent()
	# verify if the object has the server_last_parent_id property
	var tracks_parent: bool = "server_last_parent_id" in prop
	if parent is Player:
		if not tracks_parent:
			printerr("Prop %s %s has no server_last_parent_id property but parented to player" % [prop.type_name, prop.uuid])
		if prop.server_last_position != pos or prop.server_last_rotation != rot or prop.server_last_parent_id != str(parent.client_uuid):
			prop.emit_signal(
				"hs_server_prop_update",
				prop.uuid,
				{"position": pos, "rotation": rot, "parent_id": str(parent.client_uuid)},
				prop.type_name,
				true)
			prop.server_last_parent_id = str(parent.client_uuid)
		return
	if parent is Vehicle:
		# Loaded in a bed: its LOCAL position is constant, so the change-throttle below would never
		# resend -> Horizon's GORC entry goes stale and later updates (e.g. a retrieve+drop) get
		# dropped. Keep it fresh by re-sending position + parent_id every frame, like carrying.
		if not tracks_parent:
			printerr("Prop %s %s has no server_last_parent_id property but parented to Vehicle" % [prop.type_name, prop.uuid])
		if prop.server_last_position != pos or prop.server_last_rotation != rot or prop.server_last_parent_id != str(parent.client_uuid):
			prop.emit_signal(
				"hs_server_prop_update",
				prop.uuid,
				{"position": pos, "rotation": rot, "parent_id": str(parent.uuid)},
				prop.type_name,
				true)
			prop.server_last_parent_id = str(parent.uuid)
		return
	# Not carried. Detect a parent change (dropped to the world, settled into a bed) and resend the
	# parent_id for a few frames: a single lost drop/settle message must not leave the prop stuck
	# under its old parent on clients, and at huge planet coordinates the position throttle below can
	# suppress any other resend. parent_id only travels when it actually changes (no per-frame spam).
	var parent_id: String = (str(parent.uuid) if (parent != null and "uuid" in parent) else "")
	var resend_parent: bool = false
	if tracks_parent and parent_id != prop.server_last_parent_id:
		prop.server_last_parent_id = parent_id
		resend_parent = true
	if prop.server_last_position != pos or prop.server_last_rotation != rot or resend_parent:
		var data: Dictionary = {"position": pos, "rotation": rot}
		if resend_parent:
			data["parent_id"] = parent_id
		prop.emit_signal("hs_server_prop_update", prop.uuid, data, prop.type_name, prop.has_parent)
		prop.server_last_position = pos
		prop.server_last_rotation = rot
