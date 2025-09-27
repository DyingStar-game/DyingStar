@tool
class_name PlanetPlaceholder
extends MeshInstance3D

@export var real_coordinates: Vector3 = Vector3.ZERO:
	set(value):
		real_coordinates = value * 100.0

@export var radius: float = 10

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
