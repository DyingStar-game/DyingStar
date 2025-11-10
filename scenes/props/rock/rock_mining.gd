extends Node3D

@export var uuid: String = ""

@onready var cutCube = %CSGBox3D

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

func _ready() -> void:
	cutCube.position = Vector3(randf_range(1.8, 3.2), 0, 0)
	cutCube.rotation_degrees = Vector3(0, 0, randf_range(-35, 35))
