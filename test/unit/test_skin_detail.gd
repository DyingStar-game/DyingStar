extends GutTest
## The skin's details (CharacterAppearance.SKIN_DETAILS, human_skin_detail.gdshaderinc): they travel in the
## look (version 3), a look of version 2 gets defaults that suit its age and tone, they never rebuild the
## body, and HumanAppearance hands them to the skin's shaders.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_skin_detail.gd -gexit

const PUPPET := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"


func before_all() -> void:
	HumanBuilder.generate_lods = false


func after_all() -> void:
	HumanBuilder.generate_lods = true


func test_details_travel_in_the_look() -> void:
	var a: CharacterAppearance = CharacterAppearance.preset("default_male")
	var values := [0.8, 0.1, 0.65, 0.4, 0.9, 0.2]
	for i in CharacterAppearance.SKIN_DETAILS.size():
		a.set(CharacterAppearance.SKIN_DETAILS[i], values[i])
	var b: CharacterAppearance = CharacterAppearance.decode(a.encode())
	assert_not_null(b)
	for i in CharacterAppearance.SKIN_DETAILS.size():
		assert_almost_eq(float(b.get(CharacterAppearance.SKIN_DETAILS[i])), values[i], 0.5 / 255.0, String(CharacterAppearance.SKIN_DETAILS[i]))
	assert_eq(a.to_bytes()[0], CharacterAppearance.VERSION)


func test_details_are_colours_not_shape() -> void:
	var a: CharacterAppearance = CharacterAppearance.random(5)
	var b: CharacterAppearance = a.duplicate_appearance()
	b.freckles = 1.0 - a.freckles
	b.wrinkles = 1.0 - a.wrinkles
	assert_eq(a.shape_hash(), b.shape_hash(), "no new body for a freckle")
	assert_ne(a.look_hash(), b.look_hash())


func test_a_version_2_look_gets_details_that_suit_it() -> void:
	var a: CharacterAppearance = CharacterAppearance.random(9)
	a.macros["age"] = HumanMacros.age_of(70.0)
	var v3: PackedByteArray = a.to_bytes()
	# The same look as version 2 wrote it: no skin details, its slider count at byte 30, nothing after the sliders.
	var v2 := PackedByteArray()
	v2.append_array(v3.slice(0, 30))
	v2.append_array(v3.slice(CharacterAppearance.HEADER_BYTES - 1, v3.size() - 1 - 3 * a.garments.size()))  # no garments
	v2[0] = 2
	var old: CharacterAppearance = CharacterAppearance.from_bytes(v2)
	assert_not_null(old, "a version 2 look is still read")
	assert_eq(old.to_bytes().slice(1, 16), a.to_bytes().slice(1, 16), "the same body")
	assert_eq(old.modifiers, a.modifiers)
	assert_gt(old.wrinkles, 0.5, "a 70-year-old gets lines")
	var young: CharacterAppearance = CharacterAppearance.preset("default_female")
	assert_lt(young.wrinkles, 0.2, "a 28-year-old only faint ones")


func test_random_freckles_go_with_fair_skin() -> void:
	var dark_freckled: int = 0
	var fair: int = 0
	var fair_freckled: int = 0
	for seed_value in 300:
		var a: CharacterAppearance = CharacterAppearance.random(seed_value)
		if a.skin_tone > 0.5 and a.freckles > 0.0:
			dark_freckled += 1
		if a.skin_tone < 0.15:
			fair += 1
			fair_freckled += 1 if a.freckles > 0.0 else 0
	assert_eq(dark_freckled, 0, "no freckles drawn on a dark skin")
	assert_gt(fair_freckled, 0, "some fair people are freckled (%d of %d)" % [fair_freckled, fair])


func test_the_shaders_get_them() -> void:
	var puppet: Node3D = (load(PUPPET) as PackedScene).instantiate()
	add_child_autofree(puppet)
	var looks: HumanAppearance = puppet.get_node("HumanAppearance")
	var a: CharacterAppearance = CharacterAppearance.preset("default_male")
	a.freckles = 0.6
	a.eye_bags = 0.4
	looks.set_appearance_now(a)
	for mesh: MeshInstance3D in [looks.body_mesh(), looks.head_mesh()]:
		var detail: Vector4 = mesh.get_instance_shader_parameter(&"skin_detail")
		assert_almost_eq(detail.x, 0.6, 0.01, "freckles")
		var marks: Vector4 = mesh.get_instance_shader_parameter(&"skin_marks")
		assert_almost_eq(marks.x, 0.4, 0.01, "shadows under the eyes")
		assert_between(marks.z, 0.0, 1.0, "the person's seed")
	var face: ShaderMaterial = CharacterMaterials.human_material(&"Face", a) as ShaderMaterial
	assert_not_null(face.get_shader_parameter(&"region_texture"))
	assert_not_null(face.get_shader_parameter(&"wrinkle_texture"))
	var far: ShaderMaterial = CharacterMaterials.human_material(&"Face", a, false) as ShaderMaterial
	assert_not_null(far.get_shader_parameter(&"region_texture"), "from afar too: redness, shadows, tone")
