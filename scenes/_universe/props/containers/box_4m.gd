class_name Box4m

extends RigidBody3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var inside_space: World3D

@export var uuid: String = ""

var type_name = "box"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

func _ready() -> void:
	# A 4 m hauling box is a normal `prop` body (collision set in the .tscn). The old "contained"
	# layer-swap (moving inside items onto a private layer) was removed — items rest inside on its
	# colliders like any other prop.
	global_position = spawn_position
	global_rotation = spawn_rotation

func _physics_process(_delta: float) -> void:
	PropNet.server_tick(self)

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
