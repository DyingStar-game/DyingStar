extends GutTest
## The avatar's materials come from the GLB as alpha BLEND: CharacterAnimator.make_opaque puts them in the opaque pass,
## so an avatar writes depth and depth-reading effects (a mine's dust) hide it like a wall (playtest 2026-11-11).


func _model(mat: BaseMaterial3D) -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.material = mat
	mesh.mesh = box
	root.add_child(mesh)
	autofree(root)
	return root


func _blend(texture: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = texture
	return mat


func test_an_opaque_texture_turns_opaque() -> void:
	var image := Image.create(2, 2, false, Image.FORMAT_RGB8)
	var mat := _blend(ImageTexture.create_from_image(image))
	CharacterAnimator.make_opaque(_model(mat))
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)


func test_no_texture_turns_opaque() -> void:
	var mat := _blend(null)
	CharacterAnimator.make_opaque(_model(mat))
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)


func test_a_texture_with_alpha_is_cut_not_blended() -> void:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var mat := _blend(ImageTexture.create_from_image(image))
	CharacterAnimator.make_opaque(_model(mat))
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "eyebrows keep their shape")
	assert_almost_eq(mat.alpha_scissor_threshold, 0.5, 1e-6)


func test_other_modes_are_left_alone() -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	CharacterAnimator.make_opaque(_model(mat))
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH)


func test_no_model_is_no_error() -> void:
	CharacterAnimator.make_opaque(null)
	pass_test("nothing to do")
