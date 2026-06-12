extends Node3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var type_name = "box"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

# func _ready() -> void:
# 	position = spawn_position

func _physics_process(_delta: float) -> void:
	PropNet.server_tick(self)

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(data: Dictionary) -> void:
	if data.has("position"):
		spawn_position = Vector3(
			data["position"]["x"],
			data["position"]["y"],
			data["position"]["z"]
		)
		position = spawn_position

	if data.has("rotation"):
		spawn_rotation = Vector3(
			data["rotation"]["x"],
			data["rotation"]["y"],
			data["rotation"]["z"]
		)
		rotation = spawn_rotation

func _exit_tree() -> void:
	if GameOrchestrator.is_server():
		emit_signal(
			"hs_server_prop_delete",
			uuid,
			type_name
		)
