@tool
extends Node3D

@export var enabled = false
var rotation_speed = 10.0

func _process(delta: float) -> void:
	if enabled:
		$danger_light/light_bulb.rotation.x += delta * rotation_speed

	$danger_light/light_bulb/SpotLight3D.visible = enabled
	$danger_light/light_bulb/SpotLight3D2.visible = enabled

