extends Node3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var type_name = "city"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

var server_last_position = Vector3.ZERO
var server_last_rotation = Vector3.ZERO

var has_parent: bool = false

func _ready() -> void:
	position = spawn_position

func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

func client_channel_data_update(_data: Dictionary) -> void:
	pass
