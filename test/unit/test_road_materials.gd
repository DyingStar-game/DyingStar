extends GutTest
## The materials a road is drawn with. An ORMMaterial3D reads its roughness and its METAL from the ORM
## texture's channels; with no texture they read white, and the road is pure metal: no diffuse light,
## black with a glint that turns with the view. The plain asphalt was one (2026-11-13).


func test_every_road_material_takes_the_light() -> void:
	var paths: PackedStringArray = RoadTerrain.material_paths()
	assert_gt(paths.size(), 4, "the fixed ones and the biomes' own")
	for path: String in paths:
		var material: Material = load(path) as Material
		assert_not_null(material, "%s loads" % path)
		assert_true(RoadTerrain.is_lit_material(material), "%s is not an ORM material without its texture" % path)


func test_an_orm_material_without_its_texture_is_told() -> void:
	assert_false(RoadTerrain.is_lit_material(ORMMaterial3D.new()), "metal 1 from a missing texture")
	assert_true(RoadTerrain.is_lit_material(StandardMaterial3D.new()), "a plain material")
	var textured := ORMMaterial3D.new()
	textured.orm_texture = PlaceholderTexture2D.new()
	assert_true(RoadTerrain.is_lit_material(textured), "an ORM material with its texture")
