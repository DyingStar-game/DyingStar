class_name PropNet
extends RefCounted

## Shared server-side replication helpers for networked props (DRY: GDScript has single
## inheritance and props extend different bodies — RigidBody3D / StaticBody3D / VehicleBody3D —
## so they can't share a base class; they call these static helpers instead).
##
## A prop using server_tick MUST expose: `uuid`, `type_name`, `has_parent`,
## `server_last_position`, `server_last_rotation` and the `hs_server_prop_update` signal.

## Call from a prop's _physics_process. Replicates position/rotation when they change. While
## the prop is CARRIED (parented to a Player), re-sends position + parent_id every frame so
## Horizon recomputes its global from the carrier's current position (otherwise the prop's
## GORC zone goes stale and it despawns for everyone over distance).
static func server_tick(prop: Node) -> void:
	if not GameOrchestrator.is_server():
		return
	var pos: Vector3 = snapped(prop.position, Vector3(0.001, 0.001, 0.001))
	var rot: Vector3 = snapped(prop.rotation, Vector3(0.0001, 0.0001, 0.0001))
	var carrier: Node = prop.get_parent()
	var tracks_parent: bool = "server_last_parent_id" in prop
	if carrier is Player:
		prop.emit_signal(
			"hs_server_prop_update",
			prop.uuid,
			{"position": pos, "rotation": rot, "parent_id": str(carrier.client_uuid)},
			prop.type_name,
			true)
		if tracks_parent:
			prop.server_last_parent_id = str(carrier.client_uuid)
			prop.server_parent_resend = 0
		return
	if carrier is Vehicle:
		# Loaded in a bed: its LOCAL position is constant, so the change-throttle below would never
		# resend -> Horizon's GORC entry goes stale and later updates (e.g. a retrieve+drop) get
		# dropped. Keep it fresh by re-sending position + parent_id every frame, like carrying.
		prop.emit_signal(
			"hs_server_prop_update",
			prop.uuid,
			{"position": pos, "rotation": rot, "parent_id": str(carrier.uuid)},
			prop.type_name,
			true)
		if tracks_parent:
			prop.server_last_parent_id = str(carrier.uuid)
			prop.server_parent_resend = 0
		return
	# Not carried. Detect a parent change (dropped to the world, settled into a bed) and resend the
	# parent_id for a few frames: a single lost drop/settle message must not leave the prop stuck
	# under its old parent on clients, and at huge planet coordinates the position throttle below can
	# suppress any other resend. parent_id only travels when it actually changes (no per-frame spam).
	var pid: String = (str(carrier.uuid) if (carrier != null and "uuid" in carrier) else "")
	if tracks_parent and pid != prop.server_last_parent_id:
		prop.server_last_parent_id = pid
		prop.server_parent_resend = 10
	var resend_parent: bool = tracks_parent and prop.server_parent_resend > 0
	if prop.server_last_position != pos or prop.server_last_rotation != rot or resend_parent:
		var data: Dictionary = {"position": pos, "rotation": rot}
		if resend_parent:
			data["parent_id"] = pid
			prop.server_parent_resend -= 1
		prop.emit_signal("hs_server_prop_update", prop.uuid, data, prop.type_name, prop.has_parent)
		prop.server_last_position = pos
		prop.server_last_rotation = rot
