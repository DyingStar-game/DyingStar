extends RigidBody3D

class_name box50cm
@onready var isInsideBox4m: bool = false
@export var uuid: String = ""

signal hs_server_prop_move
var type_name = "box50cm"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_global_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

func _ready() -> void:
	global_position = spawn_position

func _physics_process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		if server_last_global_position != global_position or server_last_global_rotation != global_rotation:
			emit_signal("hs_server_prop_move", uuid, global_position, global_rotation, "box50cm")
			server_last_global_position = global_position
			server_last_global_rotation = global_rotation
