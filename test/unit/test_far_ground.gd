extends GutTest
## Every ground shows from afar (FarGround): a far chunk is on the celestial layer, where no Godot light
## reaches, so each of its surfaces must light itself — through terrain_far_light, or as a flat stand-in
## of its colour from afar. Sandbox showed black squares wherever a ground could not.

const FAR_GROUND := preload("res://scenes/planet/far_ground.gd")
const BIOMES := "res://scenes/planet/biomes/"
const SYSTEM := "res://scenes/systems/tarsis/"
const SAND := "res://assets/_universe/environment/terrain/terrain_biome.tres"
const CORUNDUM := "res://assets/_universe/_shared/materials/mat_mineral_corundum_pure/corundum_outcrop_surface.tres"
const GRASS := "res://assets/_universe/environment/terrain/grass_ground.tres"


func test_the_ground_shaders_light_themselves() -> void:
	for path: String in [SAND, CORUNDUM, "res://assets/_universe/environment/terrain/regolith_grey.tres"]:
		assert_true(FAR_GROUND.lights_itself(load(path)), "%s lights itself from afar" % path.get_file())
		assert_null(FAR_GROUND.material_for(load(path)), "%s keeps its own material" % path.get_file())


func test_a_standard_material_gets_a_lit_stand_in() -> void:
	var grass: Material = load(GRASS)
	assert_false(FAR_GROUND.lights_itself(grass), "a StandardMaterial3D cannot")
	var stand_in := FAR_GROUND.material_for(grass) as ShaderMaterial
	assert_not_null(stand_in)
	assert_eq(stand_in.shader, FAR_GROUND.FLAT_SHADER)
	assert_true(FAR_GROUND.lights_itself(stand_in), "and its stand-in does")
	var albedo: Vector3 = stand_in.get_shader_parameter("far_albedo")
	assert_gt(albedo.x + albedo.y + albedo.z, 0.05, "not black")


func test_a_texture_averages_to_its_colour() -> void:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.4))
	var average := FAR_GROUND.texture_average(ImageTexture.create_from_image(image))
	assert_almost_eq(average.r, 0.2, 0.01)
	assert_almost_eq(average.g, 0.6, 0.01)


## The guard for every ground to come: a biome's own ground and a planet's terrain material must show
## from afar, whatever they are made of.
func test_every_ground_of_the_game_shows_from_afar() -> void:
	var checked := 0
	for file: String in DirAccess.get_files_at(BIOMES):
		if not file.ends_with(".tres"):
			continue
		var biome := load(BIOMES + file) as BiomeDefinition
		if biome == null or biome.is_liquid or biome.terrain_material_override == null:
			continue
		_assert_shows(biome.terrain_material_override, file)
		checked += 1
	for file: String in DirAccess.get_files_at(SYSTEM):
		if not file.ends_with(".tscn"):
			continue
		var found := RegEx.create_from_string('path="([^"]+)"[^\\]]*id="([^"]+)"')
		var text := FileAccess.get_file_as_string(SYSTEM + file)
		var material_id := RegEx.create_from_string('terrain_material = ExtResource\\("([^"]+)"\\)').search(text)
		if material_id == null:
			continue
		for resource: RegExMatch in found.search_all(text):
			if resource.get_string(2) == material_id.get_string(1):
				_assert_shows(load(resource.get_string(1)), file)
				checked += 1
	assert_gt(checked, 10, "the biomes and the planets were read")


func test_a_far_chunk_wears_its_stand_ins_and_takes_them_off() -> void:
	var mesh := ArrayMesh.new()
	for material: Material in [load(SAND), load(GRASS)]:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var mi: MeshInstance3D = autofree(MeshInstance3D.new())
	mi.mesh = mesh
	FAR_GROUND.apply(mi, true)
	assert_null(mi.get_surface_override_material(0), "the sand lights itself")
	assert_eq(mi.get_surface_override_material(1), FAR_GROUND.material_for(load(GRASS)), "the grass is replaced")
	FAR_GROUND.apply(mi, false)
	assert_null(mi.get_surface_override_material(1), "near again: its own material")


func _assert_shows(material: Material, where: String) -> void:
	assert_true(FAR_GROUND.lights_itself(material) or FAR_GROUND.material_for(material) != null,
			"%s: %s would be black from afar" % [where, material.resource_path.get_file()])


## A far chunk's quads stay small enough for the planet's curve: a flat quad sags by side^2 / 8R in its
## middle, and Sandbox's 3.5 km veil showed a grid wherever that reached the kilometre.
func test_far_chunks_are_cut_into_quads_of_50_km_at_most() -> void:
	var sandbox := PlanetData.new()
	sandbox.radius = 6356000.0
	for nside: int in [1, 2, 4, 8, 16, 32, 64]:
		var res := sandbox.get_resolution_for_lod(3, nside)
		var quad := HEALPix.pixel_side_length(nside, sandbox.radius) / float(res)
		assert_lte(quad, PlanetData.FAR_QUAD_MAX_M * 1.05, "n%d: %.0f km quads" % [nside, quad / 1000.0])
		assert_eq(res % 2, 0, "n%d: an even count, for the LOD-seam stitch" % nside)
	assert_eq(sandbox.get_resolution_for_lod(0, 64), sandbox.chunk_resolution, "near chunks untouched")
