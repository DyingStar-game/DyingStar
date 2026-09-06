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

# ── Manual perf counters (dormant — flip prof_on to re-arm) ──────────────────────────────────────────
# The engine profiler cannot be trusted on this path: it once reported 5.9 ms for a SINGLE
# server_tick call — inclusive time plus per-call instrumentation overhead on a tiny function called
# ~200x per frame (that misread cost a whole investigation; see the jolt-broadphase memory). These
# counters measure the real layers with two Time calls per tick. Server-side; server.gd _perf_tick
# prints and resets them every 2 s. Off in normal operation.
#
# Armed from OUTSIDE the code, never by editing this file: a const meant preprod could only be probed
# by rebuilding and redeploying an image, which is why the 2026-08 TPS collapse ended up diagnosed by
# reading /proc instead of by reading the rig that already existed. Three ways in, first match wins,
# because no single one reaches every way this server is started:
#   1. `--perf` on the command line          — a launcher script, or the editor's Main Run Args.
#   2. `DS_PERF=1` in the environment        — a container, where there is no command line to edit.
#   3. `[debug] perf=true` in server.ini     — a run from the Godot editor, where the other two mean
#                                              changing project settings just to take a measurement.
# server.gd prints WHICH one spoke at boot, so a log never leaves it ambiguous.
static var prof_on: bool = false
## Human-readable origin of prof_on, for the boot line. "off" when the rig is dormant.
static var prof_source: String = "off"

static func _static_init() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	if "--perf" in args:
		prof_on = true
		prof_source = "--perf"
		return
	if OS.get_environment("DS_PERF") == "1":
		prof_on = true
		prof_source = "DS_PERF=1"
		return
	# Same file and same `srvini=` override as NetworkOrchestrator.load_server_config(), read directly
	# here because the counters must be armed before any autoload has had a chance to run.
	var ini: String = "server.ini"
	for a: String in args:
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return
	# A hand-edited ini writes `perf=true` without quotes, and ConfigFile hands that back as a String
	# in some files and as a bool in others — accept both rather than silently staying off.
	var v: Variant = cfg.get_value("debug", "perf", false)
	var on: bool = (
		(v is bool and bool(v))
		or (v is int and int(v) != 0)
		or (v is String and String(v).strip_edges().to_lower() in ["true", "1", "yes"])
	)
	if on:
		prof_on = true
		prof_source = ini + " [debug] perf"
static var prof_calls: int = 0        # server_tick invocations
static var prof_tick_usec: int = 0    # INCLUSIVE: body + emit dispatch + _on_prop_update
static var prof_emits: int = 0        # invocations that actually replicated
## type_name -> emits in the window. `emits=25/f` with `awake=4` says a fixed handful of props
## replicates every single tick while the world is at rest; only their TYPE says which code path is
## re-sending them, and guessing from the source has already sent one investigation down a dead end.
static var prof_emit_types: Dictionary = {}
## Summed |Δposition| in millimetres over the emits that came from the generic (world-resting) path.
## An emitter that never rests is either JITTERING (a few mm per tick, a contact that never settles)
## or actually MOVING (centimetres per tick, e.g. still falling) — those are different bugs with
## different fixes, and the emit count alone cannot tell them apart.
static var prof_emit_dpos_mm: float = 0.0
static var prof_emit_dpos_n: int = 0
## Emits per BRANCH of server_tick. `prof_emits` counts what reaches server.gd's handler, which every
## caller of PropSync.server_prop_update also feeds — so a type that emits every tick cannot be traced
## back to a code path by the totals alone. Deduction has already been wrong twice here; these three
## counters answer it directly. carried/riding re-send unconditionally BY DESIGN (they keep the
## Horizon GORC entry fresh), so a high `carried` is expected — a high `world` is not.
static var prof_emit_carried: int = 0   # parent is Player
static var prof_emit_riding: int = 0    # parent is Vehicle
static var prof_emit_world: int = 0     # resting in the world: the change-throttled path
static var prof_handler_usec: int = 0 # time inside _on_prop_update only (the dictionary building)
static var prof_flush_usec: int = 0   # time inside send_props_update_to_horizon (JSON + websocket)
static var prof_flushes: int = 0
static var prof_flush_entries: int = 0
## Bytes of JSON actually handed to the websocket. Modelling the payload from the source gives the
## right order of magnitude, but only the wire says what the position floats really serialise to.
static var prof_flush_bytes: int = 0
# Physics-tick breakdown (étape 0b): TIME_PHYSICS_PROCESS measured 24 ms with active3d=0, so the cost
# is either in our _physics_process callbacks or in Jolt. These buckets cover every server-side
# callback that runs in the physics tick; whatever TIME_PHYSICS_PROCESS has left over is Jolt.
static var prof_player_usec: int = 0  # player_server _physics_process (move_and_slide, raycasts)
static var prof_player_calls: int = 0
static var prof_terrain_usec: int = 0 # planet_terrain _physics_process (x18 planets)
## Vehicle._physics_process. The preprod world holds ~25 of them, and each runs four scans per tick
## (occupants, rollover, cargo pin, bay scan) BEFORE the idle-sleep early-out — so a yard of parked,
## sleeping trucks still costs every tick. Instrumented because 70% of the server's wall clock sits
## outside every callback we measure, and this is the largest uninstrumented one in the tree.
static var prof_vehicle_usec: int = 0
static var prof_vehicle_calls: int = 0
static var prof_srv_usec: int = 0     # server.gd _physics_process (the network flushes)
# Breakdown of the player tick (étape 0c): walking took it from 0.25 ms to 4.7 ms for ONE player.
# The paths that only run while moving forward are the prime suspects (vault / step-up probes).
static var prof_p_pre_usec: int = 0   # spawn queue, stance, carried item, carry prompt, dialog
static var prof_p_vault_usec: int = 0 # _try_start_vault -> VaultProbe.probe (up to 3 raycasts)
static var prof_p_step_usec: int = 0  # _try_start_step_up
static var prof_p_move_usec: int = 0  # move_and_slide
static var prof_p_emit_usec: int = 0  # the hs_server_move replication at the end
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
	prof_emit_types.clear()
	prof_emit_dpos_mm = 0.0
	prof_emit_dpos_n = 0
	prof_emit_carried = 0
	prof_emit_riding = 0
	prof_emit_world = 0
	prof_handler_usec = 0
	prof_flush_usec = 0
	prof_flushes = 0
	prof_flush_entries = 0
	prof_flush_bytes = 0
	prof_player_usec = 0
	prof_player_calls = 0
	prof_terrain_usec = 0
	prof_vehicle_usec = 0
	prof_vehicle_calls = 0
	prof_srv_usec = 0
	prof_p_pre_usec = 0
	prof_p_vault_usec = 0
	prof_p_step_usec = 0
	prof_p_move_usec = 0
	prof_p_emit_usec = 0
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

## Call from a prop's _physics_process. Replicates position/rotation when they change — on EVERY path,
## including while the prop is CARRIED (parented to a Player) or riding a bed (Vehicle). Those two send
## `parent_id` alongside the pose so Horizon recomputes the global from the parent's current position;
## what they no longer do is re-send it every frame.
##
## History, because the comments here described the opposite for three months: before 6bd746827e
## (2026-06-20, "Network optimisation") both parented branches emitted unconditionally. That commit
## added the change-throttle but forgot to assign `server_last_position` / `server_last_rotation` in
## them, so the comparison never converged and the optimisation was a no-op — measured 2026-09-06 at
## 24 bed-loaded crates re-sent 45x/s, ~107 KB/s of identical JSON to Horizon and ~9% of the client's
## frame budget, for cargo whose LOCAL pose is constant by construction.
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
	# so no update can be missed. Carried / bed-loaded props are still exempt from THIS early-out: a
	# carried prop is frozen while it rides, so bailing out here would stop replicating it exactly
	# while the carrier walks. They reach the change-throttle below like everything else.
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
			if prof_on:
				prof_emit_carried += 1
			state.emit_signal(
				"hs_server_prop_update",
				state.uuid,
				{"position": pos, "rotation": rot, "parent_id": str(parent.client_uuid)},
				state.type_name,
				true)
			state.server_last_parent_id = str(parent.client_uuid)
			state.server_last_position = pos
			state.server_last_rotation = rot
		return
	if parent is Vehicle:
		# Loaded in a bed: its LOCAL pose is constant while the truck drives, so this throttle is
		# expected to go quiet — that is the point, not a symptom. A retrieve or a drop reparents the
		# prop, which changes `parent_id` and re-opens the gate on the very next tick.
		if not tracks_parent:
			printerr("Prop %s %s has no server_last_parent_id property but parented to Vehicle" % [state.type_name, state.uuid])
		# Compare against what we STORE and SEND — parent.uuid. The previous code compared
		# parent.client_uuid, a property `Vehicle` (extends VehicleBody3D) does not declare at all: it
		# never raised only because the first term of the `or` was permanently true and short-circuited
		# it. Fixing the throttle without fixing this would have turned a bandwidth bug into a crash.
		var _vehicle_id: String = str(parent.uuid)
		if state.server_last_position != pos or state.server_last_rotation != rot or state.server_last_parent_id != _vehicle_id:
			if prof_on:
				prof_emit_riding += 1
			state.emit_signal(
				"hs_server_prop_update",
				state.uuid,
				{"position": pos, "rotation": rot, "parent_id": _vehicle_id},
				state.type_name,
				true)
			state.server_last_parent_id = _vehicle_id
			state.server_last_position = pos
			state.server_last_rotation = rot
		return
	# Detect a parent change (dropped to the world, settled into a bed) and resend the parent_id for a
	# few frames: a single lost drop/settle message must not leave the prop stuck under its old parent on
	# clients, and at huge planet coordinates the position throttle can suppress any other resend.
	#
	# The frame is DERIVED from the tree — PropSpawn.parent_frame_uuid walks up to the nearest node
	# carrying a network uuid — so no caller ever gets to name a frame the body is not actually in.
	#
	# Its result is CACHED per parent instance: resolving it walks the ancestors and reads scripted
	# uuid getters (a get_node_or_null on several hosts), which is the profiler's @uuid_getter hot
	# spot, once per prop per tick. Re-resolve only when the immediate parent node actually changes;
	# an EMPTY cached uuid is retried, because an ancestor can receive its network uuid after we
	# first saw it.
	var parent_id: String = ""
	if parent != null:
		var pid: int = parent.get_instance_id()
		if "_parent_cache_id" in state and state._parent_cache_id == pid and state._parent_uuid_cache != "":
			parent_id = state._parent_uuid_cache
		else:
			parent_id = PropSpawn.parent_frame_uuid(body)
			if "_parent_cache_id" in state:
				state._parent_cache_id = pid
				state._parent_uuid_cache = parent_id
	var resend_parent: bool = false
	if tracks_parent and parent_id != state.server_last_parent_id:
		state.server_last_parent_id = parent_id
		resend_parent = true
	if state.server_last_position != pos or state.server_last_rotation != rot or resend_parent:
		if prof_on:
			prof_emit_dpos_mm += (pos - state.server_last_position).length() * 1000.0
			prof_emit_dpos_n += 1
			prof_emit_world += 1
		var data: Dictionary = {"position": pos, "rotation": rot}
		if resend_parent:
			data["parent_id"] = parent_id
		state.emit_signal("hs_server_prop_update", state.uuid, data, state.type_name, state.has_parent)
		state.server_last_position = pos
		state.server_last_rotation = rot
