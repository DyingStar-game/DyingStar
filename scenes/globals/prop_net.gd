class_name PropNet
extends RefCounted

## Shared server-side replication helpers for networked props (DRY: GDScript has single inheritance and
## props extend different bodies — RigidBody3D / StaticBody3D / Node3D / VehicleBody3D — so they can't
## share a base class; they call these static helpers instead).
##
## Two calling conventions, both supported (dual-mode, so props can migrate one at a time):
##   • Legacy: the prop root carries the state AND the transform — `PropNet.server_tick(self)`.
##   • Component (PropSync): the state lives on a PropSync child, the transform on its host BODY —
##     `PropNet.server_tick(body, sync)`. The optional `state` arg defaults to `body`, giving the
##     legacy behaviour when omitted.
##
## The state object (root in legacy, PropSync in component mode) MUST expose: `uuid`, `type_name`,
## `has_parent`, `server_last_position`, `server_last_rotation`, and the `hs_server_prop_update` signal;
## and for the client ride helpers also `_ride_local_pos` / `_ride_local_rot`.

## Client: match the freeze mode to the prop's parent. A prop RIDING a moving parent — a crate in a
## truck bed, a crate mounted on a hauling player — must be KINEMATIC so the frozen body follows that
## parent through the scene tree (a STATIC frozen body instead gets its world transform rewritten
## every physics frame, so it stays put while the truck drives off — the "cargo left behind at speed"
## bug). Resting in the world stays STATIC. No-op on non-RigidBody hosts.
static func apply_ride_freeze_mode(body: Node3D) -> void:
	if not (body is RigidBody3D):
		return  # StaticBody3D / Node3D / MeshInstance3D roots have no freeze_mode
	if GameOrchestrator.is_server():
		return  # the server sets KINEMATIC itself on lock; this is the client replica's parenting
	body.freeze_mode = (
		RigidBody3D.FREEZE_MODE_KINEMATIC if _rides_parent(body)
		else RigidBody3D.FREEZE_MODE_STATIC)

## Is this prop carried by / loaded onto a parent that moves under it? Both cases pin a CONSTANT local
## pose, so they share the freeze mode and the render-rate pinning below.
static func _rides_parent(body: Node3D) -> bool:
	var parent: Node = body.get_parent()
	return parent is Vehicle or parent is Player

## Client: apply a replicated LOCAL pose (position/rotation) and remember it so ride_pin can hold it.
## Call from a prop's client_channel_data_update (shared by every networked prop).
static func apply_client_transform(body: Node3D, state = null, data = null) -> void:
	if data == null:  # legacy 2-arg form: apply_client_transform(prop, data)
		data = state
		state = body
	if data.has("position"):
		body.position = Vector3(data["position"]["x"], data["position"]["y"], data["position"]["z"])
		state._ride_local_pos = body.position
	if data.has("rotation"):
		body.rotation = Vector3(data["rotation"]["x"], data["rotation"]["y"], data["rotation"]["z"])
		state._ride_local_rot = body.rotation

## Client: while riding a bed (or mounted on a hauling player), re-assert the constant LOCAL pose
## every render frame. The crate is a physics body, so it otherwise refreshes only at the (slower)
## physics tick and lags the parent, which is interpolated at render rate -> visible jitter. Call from
## a prop's _process; the parent runs first, so a direct set (no lerp) tracks it exactly.
static func ride_pin(body: Node3D, state = null) -> void:
	if GameOrchestrator.is_server():
		return
	if state == null:
		state = body
	if _rides_parent(body):
		body.position = state._ride_local_pos
		body.rotation = state._ride_local_rot

## Call from a prop's _physics_process. Replicates position/rotation when they change. While the prop
## is CARRIED (parented to a Player) or riding a bed (Vehicle) it re-sends position + parent_id every
## frame so Horizon recomputes its global from the parent's current position (otherwise the prop's GORC
## zone goes stale and it despawns for everyone over distance).
static func server_tick(body: Node, state = null) -> void:
	if not GameOrchestrator.is_server():
		return
	if state == null:
		state = body
	var pos: Vector3 = snapped(body.position, Vector3(0.005, 0.005, 0.005))  # 5 mm precision is enough
	var rot: Vector3 = snapped(body.rotation, Vector3(0.01, 0.01, 0.01)) # precision at 0.57 degrees
	var parent: Node = body.get_parent()
	# verify the state object tracks the parent_id (component PropSync always does; a legacy root may not)
	var tracks_parent: bool = "server_last_parent_id" in state
	if parent is Player:
		if not tracks_parent:
			printerr("Prop %s %s has no server_last_parent_id property but parented to player" % [state.type_name, state.uuid])
		if state.server_last_position != pos or state.server_last_rotation != rot or state.server_last_parent_id != str(parent.client_uuid):
			state.emit_signal(
				"hs_server_prop_update",
				state.uuid,
				{"position": pos, "rotation": rot, "parent_id": str(parent.client_uuid)},
				state.type_name,
				true)
			state.server_last_parent_id = str(parent.client_uuid)
		return
	if parent is Vehicle:
		# Loaded in a bed: its LOCAL position is constant, so the change-throttle below would never
		# resend -> Horizon's GORC entry goes stale and later updates (e.g. a retrieve+drop) get
		# dropped. Keep it fresh by re-sending position + parent_id every frame, like carrying.
		if not tracks_parent:
			printerr("Prop %s %s has no server_last_parent_id property but parented to Vehicle" % [state.type_name, state.uuid])
		# NOTE: check compares client_uuid but stores/sends parent.uuid — preserved verbatim from the
		# pre-refactor code (a Vehicle exposes both); behaviour is intentionally unchanged here.
		if state.server_last_position != pos or state.server_last_rotation != rot or state.server_last_parent_id != str(parent.client_uuid):
			state.emit_signal(
				"hs_server_prop_update",
				state.uuid,
				{"position": pos, "rotation": rot, "parent_id": str(parent.uuid)},
				state.type_name,
				true)
			state.server_last_parent_id = str(parent.uuid)
		return
	# Resting in the world. A culled/settled body is frozen and hasn't moved — the throttle below would
	# suppress it anyway, so skip the per-frame work entirely (the PropSync component keeps ticking even
	# when the root's own _physics_process was disabled by culling — see server.gd _freeze_culled_body).
	# A SLEEPING body gets the same skip: it cannot move while asleep, and anything that changes its
	# parent (carry, drop, bed-settle) moves or wakes it first, so no update can be missed.
	if body is RigidBody3D and (body.freeze or body.sleeping):
		return
	# Detect a parent change (dropped to the world, settled into a bed) and resend the parent_id for a
	# few frames: a single lost drop/settle message must not leave the prop stuck under its old parent on
	# clients, and at huge planet coordinates the position throttle can suppress any other resend.
	#
	# The parent's uuid is CACHED per parent instance: both `"uuid" in parent` and `parent.uuid` invoke
	# the host's scripted uuid getter (a get_node_or_null on several hosts) — the profiler's @uuid_getter
	# hot spot, once per prop per tick. Re-resolve only when the parent node actually changes; an EMPTY
	# cached uuid is retried, because a parent can receive its network uuid after we first saw it.
	var parent_id: String = ""
	if parent != null:
		var pid: int = parent.get_instance_id()
		if "_parent_cache_id" in state and state._parent_cache_id == pid and state._parent_uuid_cache != "":
			parent_id = state._parent_uuid_cache
		else:
			parent_id = str(parent.uuid) if "uuid" in parent else ""
			if "_parent_cache_id" in state:
				state._parent_cache_id = pid
				state._parent_uuid_cache = parent_id
	var resend_parent: bool = false
	if tracks_parent and parent_id != state.server_last_parent_id:
		state.server_last_parent_id = parent_id
		resend_parent = true
	if state.server_last_position != pos or state.server_last_rotation != rot or resend_parent:
		var data: Dictionary = {"position": pos, "rotation": rot}
		if resend_parent:
			data["parent_id"] = parent_id
		state.emit_signal("hs_server_prop_update", state.uuid, data, state.type_name, state.has_parent)
		state.server_last_position = pos
		state.server_last_rotation = rot
