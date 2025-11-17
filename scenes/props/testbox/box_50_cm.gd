class_name Box50cm

extends RigidBody3D

signal hs_server_prop_update

@export var uuid: String = ""

var type_name = "box50cm"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

var has_parent: bool = false

@onready var is_inside_box4m: bool = false

func _ready() -> void:
	position = spawn_position

func _physics_process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		if server_last_position != position or server_last_global_rotation != global_rotation:
			emit_signal(
				"hs_server_prop_update",
				uuid,
				{
					"position": position,
					"rotation": rotation,
				},
				"box",
				has_parent
			)
			server_last_position = position
			server_last_global_rotation = global_rotation

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
