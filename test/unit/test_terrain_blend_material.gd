## Pins the fringe material's non-obvious settings, each of which was arrived at by measurement and
## any of which a later "tidy-up" would plausibly undo.
##
## None of this is testable by looking at the game: a wrong render_priority makes the band vanish
## entirely, and depth_test_disabled makes it show THROUGH walls — both read as "the feature is
## broken" rather than as "someone changed one word".
##
## godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_terrain_blend_material.gd
extends GutTest

const MATERIAL_PATH := "res://assets/_universe/_shared/materials/terrain_blend.tres"
const SHADER_PATH := "res://assets/_universe/_shared/shaders/terrain_blend.gdshader"
const TERRAIN_PATH := "res://assets/_universe/environment/terrain/terrain_biome.tres"

var _mat: ShaderMaterial = null


func before_all() -> void:
	_mat = load(MATERIAL_PATH) as ShaderMaterial


func test_the_material_exists_and_runs_the_fringe_shader() -> void:
	assert_not_null(_mat, "the shared fringe material must load")
	assert_not_null(_mat.shader, "it must carry a shader")
	assert_eq(_mat.shader.resource_path, SHADER_PATH, "it must be the fringe shader")


func test_render_priority_leaves_the_band_visible() -> void:
	# The aerial-perspective quad sits at -100 and overwrites every pixel it covers, reading a
	# screen copy taken once BEFORE the whole alpha list. Anything below -100 is drawn first, is
	# absent from that copy, and is then erased: the band would simply never appear.
	assert_gt(_mat.render_priority, -100,
			"render_priority must stay above -100 or the aerial pass erases the fringe")


func test_the_shader_keeps_its_depth_decisions() -> void:
	# The render_mode LINE, not the whole file: the comments above it name the modes that were
	# deliberately REJECTED, so searching the source wholesale matches those explanations -- which
	# is exactly what this test did at first, failing on the comment that justifies the choice.
	var mode: String = _render_mode_line()
	assert_ne(mode, "", "the shader must declare a render_mode")
	assert_true(mode.contains("depth_draw_never"),
			"the overlay must not write depth — it is coplanar with a surface that already did")
	assert_false(mode.contains("depth_test_disabled"),
			"depth_test_disabled would show the fringe THROUGH walls and through the terrain")
	assert_true(mode.contains("specular_disabled"),
			"without it the overlay adds a second specular lobe: a glossy ring around every object")


func test_the_band_colour_matches_what_the_terrain_renders() -> void:
	# GroundLook scales the biome colour by the terrain's own albedo_multiplier. If the terrain is
	# retuned and nothing reads the new value, the band drifts to a different shade than the ground
	# beside it — silently, because no code path fails.
	var terrain := load(TERRAIN_PATH) as ShaderMaterial
	assert_not_null(terrain, "the terrain material must load")
	var mult: Variant = terrain.get_shader_parameter(&"albedo_multiplier")
	assert_not_null(mult,
			"terrain_biome must still expose albedo_multiplier — GroundLook reads it at runtime")


func test_the_noise_is_actually_assigned() -> void:
	# An unassigned sampler reads as white, which yields a flat band brighter than the ground: a
	# failure that looks like a tuning problem and sends you hunting in the wrong place.
	assert_not_null(_mat.get_shader_parameter(&"blend_noise"),
			"the fringe needs its noise texture, or the limit comes out perfectly level")


func test_the_flat_path_is_the_default() -> void:
	# The template must NOT claim a ground albedo: it is the material used by biomes that have no
	# texture, and GroundLook only sets blend_use_albedo on the duplicates it makes per texture.
	assert_false(bool(_mat.get_shader_parameter(&"blend_use_albedo")),
			"the template is the flat-colour material; only per-texture copies use an albedo")


func _render_mode_line() -> String:
	for line in FileAccess.get_file_as_string(SHADER_PATH).split("
"):
		var t: String = line.strip_edges()
		if t.begins_with("render_mode"):
			return t
	return ""
