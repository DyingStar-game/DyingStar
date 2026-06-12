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

var has_parent: bool = false
var carried: bool = false             # carried by a player (issue #124)
var server_reparenting: bool = false  # briefly leaving the tree to reparent (carry/drop)

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

# receive the update from server, in this example, we manage position and rotation properties
func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
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
	# A carried prop generates no collision (a frozen body would block the carrier).
	for c in get_children():
		if c is CollisionShape3D:
			c.disabled = value

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
