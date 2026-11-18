extends GutTest
## LayoutData reads a village or city layout once for every reader. A layout that does not instantiate must
## give empty parts, never a null node to the readers: in a release build a method called on a null typed
## node crashes the game (a player's game crashed at the menu's warm-up, 2026-11-18). A layout that does
## instantiate is read through the same path by test_village_bed.gd (LayoutFootprint.of).

const PARTS: Array[String] = ["footprint", "roads", "pads", "fences", "signs"]


func _assert_empty(parts: Dictionary) -> void:
	for key: String in PARTS:
		assert_true(parts.has(key), "the part %s is there" % key)
		assert_true(parts[key].is_empty(), "the part %s is empty" % key)


func test_no_scene_gives_empty_parts() -> void:
	_assert_empty(LayoutData.of_scene(null, "res://nowhere.tscn"))


func test_a_scene_that_does_not_instantiate_gives_empty_parts() -> void:
	# An empty PackedScene has no node to instantiate: instantiate() returns null (with an engine error).
	_assert_empty(LayoutData.of_scene(PackedScene.new(), "res://empty.tscn"))
	assert_engine_error_count(1, "the engine's instantiate error")
	assert_push_error("does not instantiate", "LayoutData says which layout it left empty")


func test_a_missing_layout_gives_empty_parts() -> void:
	_assert_empty(LayoutData.of("res://scenes/does_not_exist_layout.tscn"))

