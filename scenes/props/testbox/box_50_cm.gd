extends RigidBody3D

class_name box50cm
@onready var isInsideBox4m: bool = false

var type_name = "box50cm"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP
var is_remote: bool = false

func _ready() -> void:
	global_position = spawn_position
