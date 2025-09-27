class_name Box50cm

extends RigidBody3D

signal hs_server_prop_move

@export var uuid: String = ""

var type_name = "box50cm"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_global_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

@onready var is_inside_box4m: bool = false

func _ready() -> void:
	global_position = spawn_position

func _physics_process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		if server_last_global_position != global_position or server_last_global_rotation != global_rotation:
			emit_signal("hs_server_prop_move", uuid, global_position, global_rotation, "box50cm")
			server_last_global_position = global_position
			server_last_global_rotation = global_rotation
