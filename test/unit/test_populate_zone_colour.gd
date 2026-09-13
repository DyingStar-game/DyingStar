extends GutTest
## A region zone with a `rock_type` prop colours the ground with the rock's
## tints, and an outcrop biome carries the shared hex-tiled rock material that
## PlanetChunk emits as its own surface.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_populate_zone_colour.gd

const RADIUS := 3467000.0


func before_all() -> void:
	RockCatalogue.reload()


func test_zone_with_rock_type_is_matched_and_tinted() -> void:
	# A "full" zone (no geometry) matches every direction, like the decoder's
	# output for a tile entirely inside the polygon.
	var zone := {"biome_type": "outcrop-plateau", "biome_index": 105,
			"coverage": "full", "rock_type": "corundum_blue", "clarity": "milky"}
	var dir := Vector3(0.3, 0.5, 0.8).normalized()
	var hits := PlanetChunk._query_zones_at_direction(dir, [zone])
	assert_eq(hits.size(), 1)
	var first: Dictionary = hits[0]
	assert_eq(str(first["rock_type"]), "corundum_blue")
	var pair := RockCatalogue.colors_of(str(first["rock_type"]))
	var c := RockCatalogue.tint(dir, RADIUS, str(first["rock_type"]))
	for ch in 3:
		assert_between(c[ch], minf(pair[0][ch], pair[1][ch]) - 1e-6,
				maxf(pair[0][ch], pair[1][ch]) + 1e-6)


func test_first_matching_zone_wins_so_export_order_is_the_priority() -> void:
	var sand := {"biome_type": "regolith-sand", "coverage": "full", "rock_type": "corundum_red"}
	var plateau := {"biome_type": "outcrop-plateau", "coverage": "full", "rock_type": "corundum_blue"}
	var hits := PlanetChunk._query_zones_at_direction(Vector3.UP, [sand, plateau])
	assert_eq(str(hits[0]["rock_type"]), "corundum_red", "the exporter put the regolith first")


func test_outcrop_biomes_carry_the_shared_rock_material() -> void:
	var bd := load("res://scenes/planet/biomes/outcrop-plateau.tres") as BiomeDefinition
	assert_not_null(bd)
	assert_eq(bd.biome_type, "outcrop-plateau")
	assert_eq(bd.biome_index, 105)
	assert_false(bd.is_liquid)
	assert_not_null(bd.terrain_material_override, "outcrop rides its own surface material")
	var mat := bd.terrain_material_override as ShaderMaterial
	assert_not_null(mat)
	assert_eq(mat.resource_path,
			"res://assets/_universe/_shared/materials/mat_mineral_corundum_pure/corundum_outcrop_surface.tres")
	assert_almost_eq(float(mat.get_shader_parameter("vertex_color_strength")), 1.0, 1e-6,
			"the texture is tinted by the vertex colour (the rock tint)")
	var volcanic := load("res://scenes/planet/biomes/outcrop-volcanic.tres") as BiomeDefinition
	assert_eq(volcanic.terrain_material_override, bd.terrain_material_override, "one shared material")


func test_new_biomes_are_registered() -> void:
	for bt in ["regolith-dust", "regolith-sand", "regolith-gravel", "regolith-cobble",
			"regolith-crystal", "outcrop-plateau", "outcrop-volcanic",
			"volcanic_geothermal-fumarole_field"]:
		assert_true(PlanetData._BIOME_FILES.has(bt + ".tres"), bt + " listed for packed builds")
		var bd := load("res://scenes/planet/biomes/%s.tres" % bt) as BiomeDefinition
		assert_not_null(bd, bt)
		assert_eq(bd.biome_type, bt)
