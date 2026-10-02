@tool
class_name StationPlaceholder
extends MeshInstance3D

## Universe coordinates of this station: its position x 100 (the setter scales whatever is assigned, and
## _ready / moving it in the editor overwrite it). NOTE: not read anywhere — universe_map recomputes it.
@export var real_coordinates: Vector3 = Vector3.ZERO:
	set(value):
		real_coordinates = value * 100.0

var _last_position: Vector3 = real_coordinates

@warning_ignore("native_method_override")
func get_class() -> String:
	return "StationPlaceholder"

func _ready() -> void:
	real_coordinates = global_position

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		if _last_position != global_position:
			print("Changement dans les coordonnées")
			_last_position = global_position
			real_coordinates = _last_position
