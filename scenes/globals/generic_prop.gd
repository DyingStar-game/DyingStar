class_name GenericProp
extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var type_name = "generic_prop"
## Whether this prop can be picked up and carried BY HAND. Crates and pallets set this false (they are
## meant to be moved with a vehicle later); boxes stay true. Gates BOTH the carry prompt and the pickup.
@export var carriable: bool = true

## Human-readable "serial" prefix shown on the crate (see serial()). The UUID below is the REAL unique
## key (generated server-side, persisted in ScyllaDB); these two only brand it as "company-type". Defined
## here once so every prop inherits them — set the values per scene in the Inspector.
@export var id_company: String = "ARES"
@export var id_type: String = "HAUL"
## Show only the UUID's first block, uppercased (e.g. ARES-HAUL-8C44B2F9), to fit a small face. The
## identity stays the FULL UUID; this is display-only.
@export var id_short_display: bool = false

## The unique identity of this prop (v4, server-generated, persisted in ScyllaDB, replicated to clients).
## Assigned AFTER instancing (server spawn / client create_generic_object), so the setter refreshes the
## on-crate id labels the moment it arrives.
var uuid: String = "":
	set(value):
		uuid = value
		_update_id_labels()

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO
# Last parent_id replicated + how many more frames to keep resending it after a change, so a
# single lost drop/settle message can't strand this prop under its old parent on clients (PropNet).
var server_last_parent_id: String = ""
var server_parent_resend: int = 0

var has_parent: bool = false
var carried: bool = false             # carried by a player (issue #124)
var server_reparenting: bool = false  # briefly leaving the tree to reparent (carry/drop)

# Last replicated LOCAL pose, re-asserted every render frame while riding a vehicle bed (see _process).
var _ride_local_pos: Vector3 = Vector3.ZERO
var _ride_local_rot: Vector3 = Vector3.ZERO

func _enter_tree() -> void:
	if GameOrchestrator.is_server():
		server_reparenting = false

func _ready() -> void:
	# Apply the spawn position only when one was actually provided. The client
	# create_generic_object path sets position directly (via client_channel_data_update,
	# before add_child) and leaves spawn_position at ZERO; _ready must not clobber that
	# back to the parent origin (the depot crate was spawning under the screen). (#124)
	if spawn_position != Vector3.ZERO:
		position = spawn_position
	# So the carry pickup can resolve this prop by uuid (the client sends what it aims at).
	if carriable:
		add_to_group("carriable")
	# Created already under a vehicle (cargo loaded before we arrived): ride it (KINEMATIC).
	PropNet.apply_ride_freeze_mode(self)
	# Fill the on-crate id frames now if the uuid was already assigned before we entered the tree.
	_update_id_labels()

## Human-readable "company-type-uuid" serial shown on the crate. The UUID is the real unique key; the
## company/type prefix is cosmetic. Empty until the uuid is assigned.
func serial() -> String:
	if uuid == "":
		return ""
	var uuid_display: String = uuid.split("-")[0].to_upper() if id_short_display else uuid
	return "%s-%s-%s" % [id_company, id_type, uuid_display]

## Fill every id "frame" on this crate — the Label3D children in the group "prop_id_label" (one per
## face) — with the current serial. Called from the uuid setter AND _ready, so it survives any order.
func _update_id_labels() -> void:
	if uuid == "":
		return
	var txt: String = serial()
	for node in find_children("*", "Label3D", true, false):
		if node.is_in_group("prop_id_label"):
			(node as Label3D).text = txt

func _physics_process(_delta: float) -> void:
	PropNet.server_tick(self)

func _process(_delta: float) -> void:
	PropNet.ride_pin(self)  # hold the constant local bed pose at render rate (no jitter)

func _exit_tree() -> void:
	# Don't delete on clients when only reparenting (carried/dropped).
	if GameOrchestrator.is_server() and not server_reparenting:
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)

func server_prop_update(data: Dictionary):
	emit_signal(
		"hs_server_prop_update",
		uuid,
		data,
		type_name,
		has_parent
	)


# manage the parent changes
func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true
	PropNet.apply_ride_freeze_mode(self)  # KINEMATIC under a vehicle so it rides the moving truck
	_apply_carry_collision_exception(parent)

## Client: if WE (the local player) are the new parent, we're carrying this prop — ignore
## collisions between us and it so our own move_and_slide isn't blocked. Otherwise clear any
## stale exception so it stays solid to us (on the ground or carried by someone else).
func _apply_carry_collision_exception(parent: Node) -> void:
	if GameOrchestrator.is_server():
		return
	var agent = NetworkOrchestrator.network_agent
	var local_player = agent.player_entity if agent != null and "player_entity" in agent else null
	if local_player == null or not (local_player is PhysicsBody3D):
		return
	if parent == local_player:
		add_collision_exception_with(local_player)
	else:
		remove_collision_exception_with(local_player)

# receive the update from server, in this example, we manage position and rotation properties
func client_channel_data_update(data: Dictionary) -> void:
	PropNet.apply_client_transform(self, data)

# ── Carry contract (issue #124): any generic prop becomes pickable with E ──
func interact(_interactor: Node = null) -> bool:
	return carriable and not carried

func set_carried(value: bool) -> void:
	carried = value
	# A carried prop KEEPS its collision (solid to the world and other players); the carrier
	# adds a collision exception with it instead, so it isn't blocked by what it carries.

func server_parent_change(parent: Node) -> void:
	server_reparenting = true
	reparent(parent)

func send_properties_to_client(parent_uuid: String) -> void:
	server_prop_update({
		"position": position,
		"rotation": rotation,
		"parent_id": parent_uuid,
		"weight": 200,
	})
