extends Node3D

@export var uuid: String = ""

var type_name = "box50cm"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

func client_channel_data_update(_data: Dictionary) -> void:
    pass
