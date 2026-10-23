class_name LampGlow
extends RefCounted
## The glowing glass of a vehicle's lamps (the model's emissive materials, named by the vehicle): lit
## only while its lights are on. Each vehicle gets its own copy of each glass material, the model's
## being shared by every vehicle built from it, so one truck's lights never light another's. Off is an
## emission energy of 0 rather than emission turned off, so a switch never recompiles a shader.

var _lit_energy: Dictionary = {}  # this vehicle's own glass material -> its emission energy when lit


## The glass of [param model]: every surface whose material's name is in [param names] gets its own
## copy. A null model, or no such material, gives a LampGlow that does nothing.
static func of(model: Node, names: PackedStringArray) -> LampGlow:
	var glow := LampGlow.new()
	if model == null or names.is_empty():
		return glow
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		for i in mesh_node.mesh.get_surface_count():
			var glass := mesh_node.get_active_material(i) as BaseMaterial3D
			if glass == null or not names.has(glass.resource_name):
				continue
			var own := glass.duplicate() as BaseMaterial3D
			mesh_node.set_surface_override_material(i, own)
			glow._lit_energy[own] = glass.emission_energy_multiplier
	return glow


## Light the glass ([param on]) or put it out.
func set_lit(on: bool) -> void:
	for glass: BaseMaterial3D in _lit_energy:
		glass.emission_energy_multiplier = _lit_energy[glass] if on else 0.0
