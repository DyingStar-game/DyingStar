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
	if carrier is Player:
		prop.emit_signal(
			"hs_server_prop_update",
			prop.uuid,
			{"position": pos, "rotation": rot, "parent_id": str(carrier.client_uuid)},
			prop.type_name,
			true)
		return
	if prop.server_last_position != pos or prop.server_last_rotation != rot:
		prop.emit_signal(
			"hs_server_prop_update",
			prop.uuid,
			{"position": pos, "rotation": rot},
			prop.type_name,
			prop.has_parent)
		prop.server_last_position = pos
		prop.server_last_rotation = rot
