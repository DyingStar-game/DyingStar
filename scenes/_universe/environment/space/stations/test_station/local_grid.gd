extends Node3D

var parenting = false

var spawn_position: Vector3 = Vector3.ZERO

func _enter_tree() -> void:
	pass

func _ready() -> void:
	global_position = spawn_position
