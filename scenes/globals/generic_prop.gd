class_name GenericProp
extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

var uuid: String = ""

@export var type_name = "generic_prop"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

func _ready() -> void:
	position = spawn_position

func _physics_process(_delta: float) -> void:
	if GameOrchestrator.is_server():
	# this part send the position or rotation if changed since last frame
		var my_position = snapped(position, Vector3(0.001, 0.001, 0.001))
		var my_rotation = snapped(rotation, Vector3(0.0001, 0.0001, 0.0001))
		if server_last_position != my_position or server_last_rotation != my_rotation:
			server_prop_update({
				"position": my_position,
				"rotation": my_rotation,
			})
			server_last_position = my_position
			server_last_rotation = my_rotation

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
	# send the information to the client the server delete this scene
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
