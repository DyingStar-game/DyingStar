class_name EmissiveGlow
extends Node
## The glowing glass of an imported model, switched like a lamp: a Photocell (or a LightGroup) lists it
## among its targets, and the model's emissive materials go out by day and light up at night with the
## light they belong to. Without it a street lamp's bulb, emissive in its GLB, shone at noon while its
## SpotLight3D was off.
##
## The vehicles' LampGlow does the work (each prop its own copy of the glass, off = an emission energy
## of 0): this node only gives it a set_lit a Photocell can call. The authored glow is the "on" state.

## The model whose glass follows the lamp (an instanced GLB, or any node above its meshes).
@export var model_path: NodePath = ^"../Model"
## The names of the model's emissive materials to switch, as the GLB names them.
@export var glass_materials: PackedStringArray = []

var _glow: LampGlow


## The Photocell's call: [param on] lights the glass, off puts it out. A bulb has no ignition to play.
func set_lit(on: bool, _animate: bool = false) -> void:
	if _glow == null:
		_glow = LampGlow.of(get_node_or_null(model_path), glass_materials)
	_glow.set_lit(on)
