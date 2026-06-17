class_name GenericProp
extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var type_name = "generic_prop"

var uuid: String = ""

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

# Client-side smoothing used ONLY while this prop rides a vehicle bed (parent is a Vehicle): the
# server resends its constant LOCAL bed position every frame, so glide instead of stepping at 30 Hz.
var _interp := NetInterpolator.new()

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
	add_to_group("carriable")

func _physics_process(_delta: float) -> void:
	PropNet.server_tick(self)

## Client: glide a bed-riding crate toward its replicated local position (the truck itself is
## interpolated in its own _process, so the crate rides the smooth truck AND smooths its own 30 Hz
## updates). Free crates keep the direct snap in client_channel_data_update — nothing to smooth.
func _process(delta: float) -> void:
	if GameOrchestrator.is_server():
		return
	if get_parent() is Vehicle:
		_interp.update_position(self, delta)

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
	# The local frame just changed: re-snap so the bed smoothing doesn't glide from the old space.
	_interp.snap_next()
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
	# Riding a bed (parent is a Vehicle): smooth the (constant) local position so it doesn't step.
	var riding: bool = get_parent() is Vehicle
	if data.has("position"):
		var local_pos := Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
		if riding:
			_interp.set_position_target(self, local_pos)
		else:
			position = local_pos
	if data.has("rotation"):
		rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)

# ── Carry contract (issue #124): any generic prop becomes pickable with E ──
func interact(_interactor: Node = null) -> bool:
	return not carried

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
