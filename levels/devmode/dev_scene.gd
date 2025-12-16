extends Node3D

@export var spawn_node: Node
@export var uuid: String = ""

var is_ready: bool = false
var spawn_points_list: Array[Vector3]:
	set(value):
		spawn_points_list = value
	get:
		return spawn_points_list

func _ready() -> void:
	is_ready = true
