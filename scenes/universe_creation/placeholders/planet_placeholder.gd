@tool
class_name PlanetPlaceholder
extends MeshInstance3D

## Position in the real universe: the node's position x 100, kept up to date in the editor. Display only.
@export var real_coordinates: Vector3 = Vector3.ZERO:
	set(value):
		real_coordinates = value * 100.0

## Radius of the placeholder sphere in the editor (scene units); real_radius follows it.
@export var radius: float = 10

## Radius in the real universe: radius x 100, kept up to date in the editor. Display only.
@export var real_radius: float = 0.0:
	set(value):
		real_radius = value * 100.0


var _last_position: Vector3 = real_coordinates

@warning_ignore("native_method_override")
func get_class() -> String:
	return "PlanetPlaceholder"

func _ready() -> void:
	real_coordinates = global_position

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():

		if mesh:
			mesh.radius = radius
			mesh.height = radius * 2.0

		real_radius = radius

		if _last_position != global_position:
			print("Changement dans les coordonnées")
			_last_position = global_position
			real_coordinates = _last_position
