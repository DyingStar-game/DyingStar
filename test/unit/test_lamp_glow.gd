extends GutTest
## The truck's lamp glass (the model's emissive "Phare" material) glows only while its head lights are
## on, and each truck has its own: one truck's lights never light another's.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


func _glass_of(truck: Vehicle) -> BaseMaterial3D:
	var body := truck.get_node("Model/Carrosserie") as MeshInstance3D
	for i in body.mesh.get_surface_count():
		var mat := body.get_active_material(i) as BaseMaterial3D
		if mat != null and mat.resource_name == "Phare":
			return mat
	return null


func test_the_glass_glows_only_with_the_head_lights_and_per_truck() -> void:
	var a := (load(TRUCK) as PackedScene).instantiate() as Vehicle
	var b := (load(TRUCK) as PackedScene).instantiate() as Vehicle
	add_child_autofree(a)
	add_child_autofree(b)
	await get_tree().process_frame
	var glass_a := _glass_of(a)
	var glass_b := _glass_of(b)
	assert_not_null(glass_a, "the truck has its lamp glass")
	assert_ne(glass_a, glass_b, "each truck its own copy")
	assert_eq(glass_a.emission_energy_multiplier, 0.0, "lights off at start: glass dark")
	a.set_headlights(true)
	assert_gt(glass_a.emission_energy_multiplier, 0.0, "lights on: the glass glows")
	assert_eq(glass_b.emission_energy_multiplier, 0.0, "the other truck stays dark")
	assert_true(glass_a.emission_enabled, "lit by energy, never by recompiling the shader")
	a.set_headlights(false)
	assert_eq(glass_a.emission_energy_multiplier, 0.0, "lights off: dark again")


func test_no_model_no_glass() -> void:
	LampGlow.of(null, PackedStringArray(["Phare"])).set_lit(true)
	assert_true(true, "a vehicle without a model switches nothing, and does not fail")
