extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var type_name = "city"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var has_parent: bool = false

func _ready() -> void:
	position = spawn_position

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

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

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
