@icon("res://scenes/globals/prop_sync_icon.svg")
class_name PropSync
extends Node

## Networked-prop networking as a COMPONENT instead of an inheritance base. GDScript has single
## inheritance and props extend different bodies (RigidBody3D / StaticBody3D / Node3D / VehicleBody3D /
## MeshInstance3D), so the shared contract cannot live in one base class. Add this node — named exactly
## "PropSync" — as a child of any prop root; it owns the uuid / state / signals and drives replication
## through the PropNet static helpers, reaching its host body via get_parent(). The dispatch
## (server/server.gd, server/client.gd) resolves it with PropSync.of(root) and addresses it.
##
## The host body keeps only thin FORWARDERS for the members other systems reach by raycast
## (interact / set_carried / server_parent_change / send_properties_to_client / uuid / carried);
## everything else — the whole replication contract — lives here, once.

signal hs_server_prop_update
signal hs_server_prop_delete

## Networked type key (was `type_name` on each body). Set per-prop on this node in the scene.
@export var type_name: String = "generic_prop"
## When true the host is pickable/carriable (issue #124): added to group "carriable" and interact()
## honours `carried`. Depots / buildings / static infrastructure leave this false.
@export var enable_carry: bool = false

var uuid: String = ""

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO
# Last parent_id replicated + how many more frames to keep resending it after a change, so a single
# lost drop/settle message can't strand this prop under its old parent on clients (see PropNet).
var server_last_parent_id: String = ""
var server_parent_resend: int = 0
# Cached network uuid of the current parent, keyed by its instance id (see PropNet.server_tick):
# reading `parent.uuid` runs a scripted getter on many hosts — far too hot once per prop per tick.
var _parent_cache_id: int = 0
var _parent_uuid_cache: String = ""

var has_parent: bool = false
var carried: bool = false             # carried by a player (issue #124)
var server_reparenting: bool = false  # briefly leaving the tree to reparent (carry/drop)

# Last replicated LOCAL pose, re-asserted every render frame while riding a vehicle bed (see _process).
var _ride_local_pos: Vector3 = Vector3.ZERO
var _ride_local_rot: Vector3 = Vector3.ZERO

# The host body, resolved once. get_parent() runs per prop per physics frame, which with ~1000 props
# resting on a planet is measurable on its own. Cleared on _enter_tree (the body may have been
# reparented), never held across frees.
var _body_cache: Node3D = null

## Resolve the PropSync child of a prop root, or null when the prop hasn't been migrated yet — callers
## fall back to addressing the root directly, so the migration can proceed one prop at a time.
static func of(root: Node) -> PropSync:
	return root.get_node_or_null("PropSync") as PropSync

## The host body this component drives (its parent in the scene tree).
func _body() -> Node3D:
	if _body_cache == null:
		_body_cache = get_parent() as Node3D
	return _body_cache

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	_body_cache = null  # a reparent (carry / drop / bed-settle) took us out and back in
	if GameOrchestrator.is_server():
		server_reparenting = false
		# Re-arm the tick: the body just changed parent, so it may now be carried or bed-loaded and
		# must replicate every frame again even if the sleep gate below had silenced it.
		set_physics_process(true)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Each side only ever uses ONE of the two per-frame callbacks (server_tick is server-only, ride_pin
	# is client-only): turn the other off entirely — with many props, even an early-return per prop per
	# frame is measurable in the profiler.
	if GameOrchestrator.is_server():
		set_process(false)
	else:
		set_physics_process(false)
	var body := _body()
	if body == null:
		return
	# Apply a provided spawn position only when one was set. Most props receive their pose via
	# client_channel_data_update BEFORE add_child and leave spawn_position ZERO; _ready must not clobber
	# that back to the parent origin (the depot crate was spawning under the screen — issue #124).
	if spawn_position != Vector3.ZERO:
		body.position = spawn_position
	if enable_carry:
		# So the carry pickup can resolve this prop by uuid (the client sends what it aims at).
		body.add_to_group("carriable")
	# Server: stop ticking while the host sleeps (see _on_host_sleeping_state_changed).
	if GameOrchestrator.is_server() and body is RigidBody3D:
		body.sleeping_state_changed.connect(_on_host_sleeping_state_changed)
	# Created already under a vehicle (cargo loaded before we arrived): ride it (KINEMATIC).
	PropNet.apply_ride_freeze_mode(body)

## Server: a settled prop is dead weight — Jolt will not move it, so PropNet.server_tick can only
## recompute a pose and throw it away. Early-returning inside the callback is not enough at this
## scale: with ~1000 rocks resting on a planet, the per-prop GDScript call overhead alone sank the
## server to a few TPS. Stop the callback entirely instead, and re-arm it the moment the body wakes.
##
## Carried (Player) / bed-loaded (Vehicle) props are NEVER gated: they re-send their pose every frame
## precisely because their LOCAL pose is constant, to keep Horizon's GORC entry from going stale.
func _on_host_sleeping_state_changed() -> void:
	var body := _body()
	if not (body is RigidBody3D):
		return  # only ever connected on a RigidBody3D host, but the cache may have gone stale
	var rb: RigidBody3D = body
	set_physics_process(not rb.sleeping or PropNet.rides_parent(rb))

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if uuid == "":
		return  # not networked yet (e.g. an in-scene placeholder before/without dispatch) — don't replicate
	if PropNet.PROF:
		# Measured HERE, not inside server_tick: this is the inclusive per-call cost (body + emit +
		# server.gd's handler), which is exactly what the engine profiler claimed was 5.9 ms.
		var _t0: int = Time.get_ticks_usec()
		PropNet.server_tick(_body(), self)
		PropNet.prof_tick_usec += Time.get_ticks_usec() - _t0
		PropNet.prof_calls += 1
		return
	PropNet.server_tick(_body(), self)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	PropNet.ride_pin(_body(), self)  # hold the constant local bed pose at render rate (no jitter)

func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	# Don't delete on clients, nor on the server when only reparenting (carry/drop): the body (and this
	# child) briefly leave the tree during a reparent, guarded by server_reparenting.
	if GameOrchestrator.is_server() and not server_reparenting:
		emit_signal("hs_server_prop_delete", uuid, type_name)

func server_prop_update(data: Dictionary) -> void:
	if uuid == "":
		return  # not networked yet — nothing to replicate under
	emit_signal("hs_server_prop_update", uuid, data, type_name, has_parent)

func send_properties_to_client(parent_uuid: String) -> void:
	var body := _body()
	server_prop_update({
		"position": body.position,
		"rotation": body.rotation,
		"parent_id": parent_uuid,
		"weight": 200,
	})

## Server: reparent the host, setting server_reparenting FIRST so the resulting _exit_tree isn't seen
## as a despawn (a reparent moves the body — and this child — out of and back into the tree).
func server_parent_change(parent: Node) -> void:
	server_reparenting = true
	_body().reparent(parent)

## Client: apply a new parent to the host and refresh ride / carry state.
func client_parent_change(parent: Node) -> void:
	var body := _body()
	body.reparent(parent)
	has_parent = true
	PropNet.apply_ride_freeze_mode(body)  # KINEMATIC under a vehicle so it rides the moving truck
	_apply_carry_collision_exception(parent)

## Client: if WE (the local player) are the new parent, we're carrying this prop — ignore collisions
## between us and it so our own move_and_slide isn't blocked. Otherwise clear any stale exception so it
## stays solid to us. No-op unless the host is a PhysicsBody3D (only those hold collision exceptions).
func _apply_carry_collision_exception(parent: Node) -> void:
	if GameOrchestrator.is_server():
		return
	var body := _body()
	if not (body is PhysicsBody3D):
		return
	var agent = NetworkOrchestrator.network_agent
	var local_player = agent.player_entity if agent != null and "player_entity" in agent else null
	if local_player == null or not (local_player is PhysicsBody3D):
		return
	if parent == local_player:
		body.add_collision_exception_with(local_player)
	else:
		body.remove_collision_exception_with(local_player)

## Client: apply the replicated transform, then let a custom-state host consume the rest of the payload
## (reception lists, machine state, …) through an optional apply_prop_data(data) method on the body.
func client_channel_data_update(data: Dictionary) -> void:
	var body := _body()
	PropNet.apply_client_transform(body, self, data)
	# Apply the name
	if "name" in data:
		body.name = data["name"]
	if body != null and body.has_method("apply_prop_data"):
		body.apply_prop_data(data)

# ── Carry contract (issue #124): a carriable prop becomes pickable with E ──
func interact(_interactor: Node = null) -> bool:
	return not carried

func set_carried(value: bool) -> void:
	carried = value
	# A carried prop KEEPS its collision (solid to the world and other players); the carrier adds a
	# collision exception with it instead, so it isn't blocked by what it carries.
