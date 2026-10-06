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
