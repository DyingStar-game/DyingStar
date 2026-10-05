extends GutTest
## HintSource: play hints from a scene, with no code.


func before_each() -> void:
	PlayHints.clear()


func after_all() -> void:
	PlayHints.clear()


func _source() -> HintSource:
	var source := HintSource.new()
	source.context = &"console"
	var r := HintRow.new()
	r.actions = [&"jump"]
	source.rows = [r]
	return source


func test_offered_while_in_the_tree() -> void:
	var source := _source()
	add_child(source)
	assert_eq(PlayHints.active().size(), 1)
	assert_eq(PlayHints.active()[0]["label"], "%%ACT_JUMP", "the label of the controls page")
	remove_child(source)
	assert_eq(PlayHints.active().size(), 0, "withdrawn on leaving the tree")
	source.free()


func test_inactive_shows_nothing() -> void:
	var source := _source()
	source.active = false
	add_child_autofree(source)
	assert_eq(PlayHints.active().size(), 0)
	source.active = true
	assert_eq(PlayHints.active().size(), 1)


func test_near_only_shows_nothing_without_a_camera_close_by() -> void:
	var anchor := Node3D.new()
	add_child_autofree(anchor)
	anchor.global_position = Vector3(1000.0, 0.0, 0.0)
	var source := _source()
	source.near_m = 5.0
	anchor.add_child(source)
	assert_eq(PlayHints.active().size(), 0)
