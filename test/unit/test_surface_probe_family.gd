extends GutTest
## SurfaceProbe's pure answers: which family a biome or a material belongs to. The footsteps, the tyre
## sounds and the ground dust all stand on these, so a wrong one shows in three places at once.


func _biome(btype: String, override: String = "") -> BiomeDefinition:
	var b := BiomeDefinition.new()
	b.biome_type = btype
	b.surface_family = override
	return b


func test_the_kind_wins_over_the_category() -> void:
	assert_eq(SurfaceProbe.family_of_biome(_biome("aride_desert-dune")), &"sand")
	assert_eq(SurfaceProbe.family_of_biome(_biome("rocky_landform-canyon")), &"rock")


func test_the_category_answers_when_the_kind_is_unknown() -> void:
	assert_eq(SurfaceProbe.family_of_biome(_biome("forest-pine")), &"vegetation")


func test_a_biome_s_own_family_overrides_the_tables() -> void:
	assert_eq(SurfaceProbe.family_of_biome(_biome("aride_desert-dune", "rock")), &"rock")


func test_an_unknown_biome_is_unknown_not_guessed() -> void:
	assert_eq(SurfaceProbe.family_of_biome(_biome("nowhere-nothing")), &"")
	assert_eq(SurfaceProbe.family_of_biome(_biome("")), &"")


func test_a_material_states_its_family_in_its_id() -> void:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "mat_metal_diamondplate2k"
	assert_eq(SurfaceProbe.family_of_material(mat), &"metal")


func test_a_material_without_an_id_is_unknown() -> void:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "shiny_floor"
	assert_eq(SurfaceProbe.family_of_material(mat), &"")
	assert_eq(SurfaceProbe.family_of_material(null), &"")


func test_the_placeholder_blockout_materials_are_rock() -> void:
	for path: String in ["res://assets/_universe/_shared/materials/placeholder_grey.tres",
			"res://assets/_universe/_shared/materials/placeholder_dark.tres"]:
		assert_eq(SurfaceProbe.family_of_material(load(path)), &"rock", path.get_file())


## A CSG blockout has no MeshInstance3D: the collider is the CSG shape carrying use_collision, its
## surfaces the primitives under it. The one under the point wins, a subtracted one never does.
func test_a_csg_blockout_answers_with_the_primitive_under_the_point() -> void:
	var root := CSGCombiner3D.new()
	root.use_collision = true
	var floor_box := CSGBox3D.new()
	floor_box.size = Vector3(10.0, 1.0, 10.0)
	floor_box.material = load("res://assets/_universe/_shared/materials/placeholder_grey.tres")
	root.add_child(floor_box)
	var post := CSGCylinder3D.new()
	post.position = Vector3(20.0, 0.0, 0.0)
	var metal := StandardMaterial3D.new()
	metal.resource_name = "mat_metal_post"
	post.material = metal
	root.add_child(post)
	var hole := CSGBox3D.new()
	hole.operation = CSGShape3D.OPERATION_SUBTRACTION
	var glass := StandardMaterial3D.new()
	glass.resource_name = "mat_glass_hole"
	hole.material = glass
	root.add_child(hole)
	add_child_autofree(root)
	assert_eq(SurfaceProbe.family_of_material(SurfaceProbe._material_of(root, Vector3(1.0, 0.4, 1.0))), &"rock")
	assert_eq(SurfaceProbe.family_of_material(SurfaceProbe._material_of(root, Vector3(20.0, 0.5, 0.0))), &"metal")
