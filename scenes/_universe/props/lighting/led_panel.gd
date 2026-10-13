class_name LedPanel
extends Node3D
## A ceiling LED panel a Photocell can switch: its light AND its glowing face. Hiding the light alone
## left the face burning white in a dark room. The face's material is shared by every panel, so it is
## never edited: an unlit panel wears one shared dark material over it instead.

static var _off: StandardMaterial3D = null


## Light the panel, or put it out. [param _animate] is the Photocell's (a panel just switches).
func set_lit(on: bool, _animate: bool = false) -> void:
	for child: Node in get_children():
		if child is Light3D:
			(child as Light3D).visible = on
		elif child is MeshInstance3D:
			(child as MeshInstance3D).material_override = null if on else _off_material()


## The face of an unlit panel: dark, a little metallic, no glow. One for all panels.
static func _off_material() -> StandardMaterial3D:
	if _off == null:
		_off = StandardMaterial3D.new()
		_off.albedo_color = Color(0.12, 0.12, 0.13)
		_off.metallic = 0.6
		_off.roughness = 0.4
	return _off
