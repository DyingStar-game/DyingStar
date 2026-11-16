extends GutTest
## The creator's overall shape (FaceAxes): every axis names real sliders, reads back where a look lies on
## it, and moving it moves its sliders by their shares -- nothing of an axis is stored.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_face_axes.gd -gexit


func test_every_axis_names_creator_sliders() -> void:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FaceAxes.AXES_PATH))
	var labels: Dictionary = {}
	for axis: Dictionary in raw["axes"]:
		for key: String in axis["shares"]:
			assert_ne(CharacterAppearance.modifier_id(key), -1, "%s: %s is a creator slider" % [axis["id"], key])
		assert_false(labels.has(axis["label"]), "one label per axis")
		labels[axis["label"]] = true
	assert_eq(FaceAxes.axes().size(), (raw["axes"] as Array).size())
	assert_gt(FaceAxes.axes().size(), 5)


func test_moving_an_axis_reads_back() -> void:
	for axis: Array in FaceAxes.axes():
		var look := CharacterAppearance.new()
		var shares: Dictionary = axis[2]
		assert_almost_eq(FaceAxes.value_of(look, shares), 0.0, 1e-6, "%s: the neutral face is at 0" % axis[0])
		FaceAxes.move(look, shares, 0.5)
		assert_almost_eq(FaceAxes.value_of(look, shares), 0.5, 0.02, "%s: moved to 0.5, read at 0.5" % axis[0])
		FaceAxes.move(look, shares, -0.5)
		assert_almost_eq(FaceAxes.value_of(look, shares), 0.0, 0.02, "%s: and back" % axis[0])


func test_a_move_keeps_sliders_in_range() -> void:
	var look := CharacterAppearance.new()
	for axis: Array in FaceAxes.axes():
		FaceAxes.move(look, axis[2], 5.0)
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id: int in look.modifiers:
		assert_between(float(look.modifiers[id]), 0.0 if sliders[id]["unipolar"] else -1.0, 1.0)
	var copy: CharacterAppearance = CharacterAppearance.decode(look.encode())
	assert_not_null(copy, "an axis-made look is a valid look")
