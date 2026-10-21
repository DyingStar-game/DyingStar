class_name LightSwitch
extends ToggledPart

## A lamp's switch: on, the lights under it shine and its shade glows -- the emission_on instance
## parameter of the shared painted metal shader, lit where the model's vertex colour says. Nothing to
## show on the server.
##
## A Photocell under it makes it a night light: dusk lights it, dawn puts it out, and between the two
## the switch rules -- whoever lives there always has the last word, until the next dusk or dawn. Its
## first reading only stands in for a lamp nobody has switched yet (show_unset).

## The mesh whose glow follows the switch (the parent by default: the lamp itself).
@export var glow_path: NodePath = ^".."
## A neon tube: switched on live, it strikes a few times before it holds (NeonIgnition).
@export var neon: bool = false


## Someone switched it (the building's state): it holds until the next dusk or dawn.
var _switched: bool = false
var _ignition: Tween


func show_unset() -> void:
	pass  # the night decides (set_lit from the Photocell), or it stays as authored: unlit


func _show(on: bool, animate: bool) -> void:
	_switched = true
	_strike(on, animate)


## The Photocell's call (a LedPanel's and a LightGroup's too): a dusk or a dawn ([param animate]) switches
## it whoever had set it; its first reading only lights a lamp nobody has switched.
func set_lit(on: bool, animate: bool = false) -> void:
	if animate or not _switched:
		_display(on)
		_strike(on, animate)


## Light it or put it out; a neon coming on live strikes first.
func _strike(on: bool, animate: bool) -> void:
	if _ignition != null:
		_ignition.kill()
		_ignition = null
	if neon and on and animate and is_inside_tree():
		_ignition = NeonIgnition.strike(self, _light)
	else:
		_light(on)


func _light(on: bool) -> void:
	for child in get_children():
		if child is Light3D:
			(child as Light3D).visible = on
	var glow := get_node_or_null(glow_path) as GeometryInstance3D
	if glow != null:
		glow.set_instance_shader_parameter(&"emission_on", on)
