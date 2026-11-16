extends GutTest
## The character creator: every category builds its lines, a slider edits the look, the changes become
## undo steps, and saving keeps the look on this machine (CharacterStore) for the next spawn to send.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_character_creator.gd -gexit

const SCENE := "res://ui/character_creator/character_creator.tscn"
const STORE := "user://test_character_creator.cfg"


const LIBRARY := "user://test_character_creator_sheets"


func before_each() -> void:
	CharacterStore.path = STORE
	CharacterStore.clear()
	CharacterLibrary.backend = CharacterLibrary.Local.new(LIBRARY)
	_clear_library()


func after_all() -> void:
	CharacterStore.clear()
	CharacterStore.path = CharacterStore.PATH
	_clear_library()
	CharacterLibrary.backend = CharacterLibrary.Local.new()


func _clear_library() -> void:
	if not DirAccess.dir_exists_absolute(LIBRARY):
		return
	for file: String in DirAccess.get_files_at(LIBRARY):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LIBRARY.path_join(file)))


func _creator(first_enter: bool = false) -> CharacterCreator:
	var creator: CharacterCreator = (load(SCENE) as PackedScene).instantiate()
	creator.first_enter = first_enter
	add_child_autofree(creator)
	return creator


func _sliders(creator: CharacterCreator) -> Array:
	return creator._rows.find_children("*", "HSlider", true, false)


func test_every_category_has_its_lines() -> void:
	var creator: CharacterCreator = _creator()
	for tab: StringName in CharacterCreator.TABS:
		creator._open_tab(tab)
		var subs: Dictionary = CharacterCreator.SUBTABS.get(tab, {&"": ""})
		for sub: StringName in subs:
			if sub != &"":
				creator._open_subtab(sub)
			var controls: int = creator._rows.find_children("*", "Range", true, false).size() \
					+ creator._rows.find_children("*", "Button", true, false).size()
			assert_gt(controls, 0, "%s / %s has something to set" % [tab, sub])


func test_every_face_and_body_slider_is_offered() -> void:
	var creator: CharacterCreator = _creator()
	var offered: int = 0
	for tab: StringName in [&"body", &"face"]:
		creator._open_tab(tab)
		for sub: StringName in CharacterCreator.SUBTABS[tab]:
			creator._open_subtab(sub)
			offered += _sliders(creator).size()
			if sub == &"shape":
				offered -= HumanMacros.MACROS.size() + CharacterAppearance.ORIGINS  # gender, age, height, origins
			if sub == &"overall":
				offered -= FaceAxes.axes().size()  # the overall shape: each moves several sliders
	var hidden: int = 0  # FLAME's identity directions: moved by the overall shape and the random draw, not one by one
	for entry: Dictionary in CharacterAppearance.catalogue()["modifiers"]:
		hidden += 1 if entry["tab"] == "flame" else 0
	assert_eq(offered + hidden, (CharacterAppearance.catalogue()["modifiers"] as Array).size(), "the whole catalogue")


func test_a_slider_edits_the_look_and_becomes_an_undo_step() -> void:
	var creator: CharacterCreator = _creator()
	creator._open_tab(&"face")
	creator._open_subtab(&"nose")
	var before: String = creator.look.encode()
	var bar: HSlider = _sliders(creator)[0]
	bar.value = 0.6
	assert_ne(creator.look.encode(), before, "the look changed")
	creator._commit_pending()
	assert_true(creator._history.can_undo())
	creator._step_back()
	assert_eq(creator.look.encode(), before, "undone")
	creator._step_forward()
	assert_ne(creator.look.encode(), before, "redone")


func test_saving_keeps_the_look_for_the_next_spawn() -> void:
	var creator: CharacterCreator = _creator()
	assert_true(creator._save.disabled, "nothing to save yet")
	creator._randomise_all()
	assert_false(creator._save.disabled)
	creator._on_save()
	assert_true(CharacterStore.saved().equals(creator.look))
	assert_true(CharacterStore.is_pending(), "to be sent on the next spawn")
	assert_true(creator._save.disabled, "saved")
	var sheet: Dictionary = await CharacterLibrary.fetch(CharacterStore.active_id())
	assert_false(sheet.is_empty(), "kept as the player's character sheet too")
	assert_eq((CharacterSheet.read(sheet)["look"] as CharacterAppearance).encode(), creator.look.encode())
	creator._randomise_all()
	creator._on_save()
	assert_eq((await CharacterLibrary.list()).size(), 1, "saving again updates that same sheet")


func test_first_enter_saves_and_asks_to_enter() -> void:
	var creator: CharacterCreator = _creator(true)
	watch_signals(creator)
	creator._on_save()
	assert_signal_emitted(creator, "enter_requested")
	assert_not_null(CharacterStore.saved(), "the look offered is kept")


func test_random_category_keeps_the_rest() -> void:
	var creator: CharacterCreator = _creator()
	var macros: Dictionary = creator.look.macros.duplicate()
	creator._open_tab(&"eyes")
	for i in 5:
		creator._randomise_tab()
	assert_eq(creator.look.macros, macros, "the body did not change")


func test_an_overall_axis_moves_several_sliders() -> void:
	var creator: CharacterCreator = _creator()
	creator._open_tab(&"face")
	assert_eq(creator._subtab[&"face"], &"overall", "the face opens on its overall shape")
	var bars: Array = _sliders(creator)
	assert_eq(bars.size(), FaceAxes.axes().size())
	var before: Dictionary = creator.look.modifiers.duplicate()
	(bars[0] as HSlider).value = 0.6
	var moved: int = 0
	for id: int in creator.look.modifiers:
		if not is_equal_approx(float(creator.look.modifiers[id]), float(before.get(id, 0.0))):
			moved += 1
	assert_gt(moved, 2, "one axis, several sliders")
