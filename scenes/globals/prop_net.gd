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

# ── TEMPORARY profiling (TPS drops, étape 0) ──────────────────────────────────────────────────────
# The engine profiler cannot be trusted on this path: it reported 5.9 ms for a SINGLE server_tick call,
# which this code cannot cost. That number is inclusive time (the emit reaches server.gd _on_prop_update)
# plus the profiler's own per-call instrumentation, which dwarfs a function this small called ~170x per
# frame. These counters measure the three layers separately, with two Time calls per tick instead of a
# full instrumentation frame. Server-side only; server.gd _perf_tick prints and resets them.
# Remove (or flip PROF) once the drop is diagnosed.
const PROF: bool = true
static var prof_calls: int = 0        # server_tick invocations
static var prof_tick_usec: int = 0    # INCLUSIVE: body + emit dispatch + _on_prop_update
static var prof_emits: int = 0        # invocations that actually replicated
static var prof_handler_usec: int = 0 # time inside _on_prop_update only (the dictionary building)
static var prof_flush_usec: int = 0   # time inside send_props_update_to_horizon (JSON + websocket)
static var prof_flushes: int = 0
static var prof_flush_entries: int = 0
# Physics-tick breakdown (étape 0b): TIME_PHYSICS_PROCESS measured 24 ms with active3d=0, so the cost
# is either in our _physics_process callbacks or in Jolt. These buckets cover every server-side
# callback that runs in the physics tick; whatever TIME_PHYSICS_PROCESS has left over is Jolt.
static var prof_player_usec: int = 0  # player_server _physics_process (move_and_slide, raycasts)
static var prof_player_calls: int = 0
static var prof_terrain_usec: int = 0 # planet_terrain _physics_process (x18 planets)
static var prof_srv_usec: int = 0     # server.gd _physics_process (the network flushes)
# Breakdown of the player tick (étape 0c): walking took it from 0.25 ms to 4.7 ms for ONE player.
# The paths that only run while moving forward are the prime suspects (vault / step-up probes).
static var prof_p_pre_usec: int = 0   # spawn queue, stance, carried item, carry prompt, dialog
static var prof_p_vault_usec: int = 0 # _try_start_vault -> VaultProbe.probe (up to 3 raycasts)
static var prof_p_step_usec: int = 0  # _try_start_step_up
static var prof_p_move_usec: int = 0  # move_and_slide
static var prof_p_emit_usec: int = 0  # the hs_server_move replication at the end
# Wall-clock span from the FIRST to the LAST _physics_process callback in the tick, measured by two
# PerfBracket nodes at extreme process_physics_priority. TIME_PHYSICS_PROCESS minus this span is the
# engine's own work (Jolt step + sync), with no script callback left hiding inside it.
static var prof_span_t0: int = 0
static var prof_span_usec: int = 0
# Étape 0d: 97% of the walking cost is collision queries (engine + move_and_slide). These counters
# discriminate between the two candidate causes — a move_and_slide that keeps re-iterating against an
# unstable contact, versus terrain collision chunks being built/freed under the walking player.
static var prof_slide_count: int = 0  # summed get_slide_collision_count() over the window
static var prof_slide_ticks: int = 0  # move_and_slide calls, to average the above
static var prof_chunk_loads: int = 0
static var prof_chunk_unloads: int = 0

static func prof_reset() -> void:
	prof_calls = 0
	prof_tick_usec = 0
	prof_emits = 0
	prof_handler_usec = 0
	prof_flush_usec = 0
	prof_flushes = 0
	prof_flush_entries = 0
	prof_player_usec = 0
	prof_player_calls = 0
	prof_terrain_usec = 0
	prof_srv_usec = 0
	prof_p_pre_usec = 0
	prof_p_vault_usec = 0
	prof_p_step_usec = 0
	prof_p_move_usec = 0
	prof_p_emit_usec = 0
	prof_span_usec = 0
	prof_slide_count = 0
	prof_slide_ticks = 0
	prof_chunk_loads = 0
	prof_chunk_unloads = 0

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
		RigidBody3D.FREEZE_MODE_KINEMATIC if rides_parent(body)
		else RigidBody3D.FREEZE_MODE_STATIC)

## Is this prop carried by / loaded onto a parent that moves under it? Both cases pin a CONSTANT local
## pose, so they share the freeze mode, the render-rate pinning below, and the exemption from the
## server-side "settled props stop ticking" gate (PropSync).
static func rides_parent(body: Node3D) -> bool:
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
	if rides_parent(body):
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
	var parent: Node = body.get_parent()
	# Resting in the world: a FROZEN (culled) or SLEEPING body cannot move, so the change-throttle at
	# the bottom would suppress its update anyway — bail out BEFORE reading the pose. `body.rotation`
	# decomposes the basis into Euler angles and the physics server re-dirties that cache every frame,
	# so with ~1000 rocks settled on a planet this read alone dominated the server tick (4 TPS).
	# Anything that changes a resting body's parent (carry, drop, bed-settle) moves or wakes it first,
	# so no update can be missed. Carried / bed-loaded props are exempt: they deliberately re-send
	# every frame — even perfectly still — to keep their Horizon GORC entry fresh (see below).
	var rides: bool = parent is Player or parent is Vehicle  # same test as rides_parent, on the Node we hold
	if body is RigidBody3D and (body.freeze or body.sleeping) and not rides:
		return
	var pos: Vector3 = snapped(body.position, Vector3(0.005, 0.005, 0.005))  # 5 mm precision is enough
	var rot: Vector3 = snapped(body.rotation, Vector3(0.01, 0.01, 0.01)) # precision at 0.57 degrees
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
