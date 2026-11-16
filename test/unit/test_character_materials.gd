extends GutTest
## Every surface of the character gets a realistic, opaque material, shared between puppets.
##
## The glTF's own materials are alpha BLEND (no depth: dust and other depth-reading effects went through
## the avatar, playtest 2026-11-11) with mirror clear coats on cloth and hair. CharacterMaterials
## replaces them with overrides; these checks pin that no surface is left transparent, that each mesh is
## recognised for what it is, and that two puppets share the same material instances (one per role and
## texture, not one per avatar).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_character_materials.gd -gexit

const CHARACTER_SCENE := "res://assets/_universe/characters/humanoids/man_ddurieux.glb"


func _model() -> Node:
	var model: Node = (load(CHARACTER_SCENE) as PackedScene).instantiate()
	add_child_autofree(model)
	CharacterMaterials.apply(model)
	return model


func _surfaces(model: Node) -> Array:
	var out: Array = []
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var inst := node as MeshInstance3D
		for i in inst.mesh.get_surface_count():
			out.append([inst, i, inst.get_active_material(i)])
	return out


func test_no_surface_is_alpha_blended() -> void:
	for s in _surfaces(_model()):
		var mat: Material = s[2]
		assert_not_null(mat, "%s has a material" % s[0].name)
		if mat is BaseMaterial3D:
			assert_ne((mat as BaseMaterial3D).transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
					"%s is in the opaque pass" % s[0].name)
		elif mat is ShaderMaterial:
			assert_false((mat as ShaderMaterial).shader.code.contains("blend_mix") and
					(mat as ShaderMaterial).shader.code.contains("depth_draw_never"), "%s writes depth" % s[0].name)


func test_meshes_are_recognised() -> void:
	assert_eq(CharacterMaterials.role_of("test1_test1_male_muscle_13290"), CharacterMaterials.Role.SKIN)
	assert_eq(CharacterMaterials.role_of("test1_high-poly"), CharacterMaterials.Role.EYE)
	assert_eq(CharacterMaterials.role_of("test1_eyebrow004"), CharacterMaterials.Role.HAIR)
	assert_eq(CharacterMaterials.role_of("test1_short02"), CharacterMaterials.Role.HAIR)
	assert_eq(CharacterMaterials.role_of("test1_teeth"), CharacterMaterials.Role.TEETH)
	assert_eq(CharacterMaterials.role_of("test1_shoes03"), CharacterMaterials.Role.SHOES)
	assert_eq(CharacterMaterials.role_of("test1_male_casualsuit01"), CharacterMaterials.Role.CLOTH)


func test_a_baked_body_wears_the_skin_shaders() -> void:
	var look: CharacterAppearance = CharacterAppearance.preset("default_male")
	var near := CharacterMaterials.human_material(&"Face", look, true) as ShaderMaterial
	var far := CharacterMaterials.human_material(&"Face", look, false) as ShaderMaterial
	assert_eq(near.shader, CharacterMaterials.SKIN_SHADER, "close up: the skin's own lighting")
	assert_eq(far.shader, CharacterMaterials.SKIN_FAR_SHADER, "from afar: the light one")
	assert_same(CharacterMaterials.human_material(&"Face", look, true), near, "shared between avatars")
	assert_not_null((CharacterMaterials.human_material(&"Sclera_Cornea", look, true) as ShaderMaterial).next_pass,
			"wet eyes close up")


func test_two_puppets_share_their_materials() -> void:
	var a: Array = _surfaces(_model())
	var b: Array = _surfaces(_model())
	assert_eq(a.size(), b.size())
	for k in a.size():
		assert_same(a[k][2], b[k][2], "%s: one shared material, not one per avatar" % a[k][0].name)
