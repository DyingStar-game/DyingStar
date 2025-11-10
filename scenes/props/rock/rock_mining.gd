extends Node3D

@export var uuid: String = ""

@onready var cutCube = %CSGBox3D
@onready var cutCube2 = %CSGBox3D2

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_global_rotation = Vector3.ZERO

func _ready() -> void:
	cutCube.position = Vector3(randf_range(1.8, 3.2), 0, 0)
	cutCube.rotation_degrees = Vector3(0, 0, randf_range(-35, 35))
	cutCube2.position = Vector3(randf_range(2.5, 3.85), 0, 0)
	cutCube2.rotation_degrees = Vector3(0, -41.0, randf_range(-30, 30))
