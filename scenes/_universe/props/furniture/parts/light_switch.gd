class_name LightSwitch
extends ToggledPart

## A lamp's switch: on, the lights under it shine and its shade glows -- the emission_on instance
## parameter of the shared painted metal shader, lit where the model's vertex colour says. Nothing to
## show on the server.

## The mesh whose glow follows the switch (the parent by default: the lamp itself).
@export var glow_path: NodePath = ^".."


func _show(on: bool, animate: bool) -> void:
	set_lit(on, animate)


## Light the lamp or put it out: the same call as a LedPanel's or a LightGroup's.
func set_lit(on: bool, _animate: bool = false) -> void:
	for child in get_children():
		if child is Light3D:
			(child as Light3D).visible = on
	var glow := get_node_or_null(glow_path) as GeometryInstance3D
	if glow != null:
		glow.set_instance_shader_parameter(&"emission_on", on)
