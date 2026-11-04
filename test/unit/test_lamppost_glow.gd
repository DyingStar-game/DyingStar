extends GutTest
## The 3.4 m street lamp's bulb is emissive in its GLB: its Photocell switches it with the light
## (EmissiveGlow over the vehicles' LampGlow), or it shone at noon with its SpotLight3D off.

const LAMP := "res://scenes/_universe/props/furniture/furn_lamppost_outdoor_3.4m.tscn"
const GLOW_SCRIPT := preload("res://scenes/_universe/props/lighting/emissive_glow.gd")


## The emission energy of every glass surface of [param model], by surface.
func _glass_energies(model: Node, names: PackedStringArray) -> Array[float]:
	var out: Array[float] = []
	for n: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i) as BaseMaterial3D
			if mat != null and names.has(mat.resource_name):
				out.append(mat.emission_energy_multiplier)
	return out


func test_the_photocell_switches_the_bulb_with_the_light() -> void:
	var lamp: Node3D = load(LAMP).instantiate()
	add_child_autofree(lamp)
	var glow: Node = lamp.get_node("Glow")
	assert_eq(glow.get_script(), GLOW_SCRIPT, "an EmissiveGlow")
	var photocell := lamp.get_node("SpotLight3D/Photocell") as Photocell
	assert_true(photocell.targets.has(glow), "the photocell drives the glow")
	assert_true(photocell.targets.has(lamp.get_node("SpotLight3D")), "and the light")
	var lit := _glass_energies(lamp.get_node("Model"), glow.glass_materials)
	assert_gt(lit.size(), 0, "the bulb's glass is found in the model")
	glow.set_lit(false)
	for e: float in _glass_energies(lamp.get_node("Model"), glow.glass_materials):
		assert_eq(e, 0.0, "out by day")
	glow.set_lit(true)
	assert_eq(_glass_energies(lamp.get_node("Model"), glow.glass_materials), lit, "lit again at night")
	KnownEngineErrors.forgive_floor_material(self)
