extends StaticBody3D


@onready var lights: Node3D = %Lights
@onready var interior: Node3D = %Interior


func spin_lights(rotation_step: float) -> void:
	interior.rotate_y(rotation_step)


func toggle_lights(toggle: bool) -> void:
	lights.visible = toggle
