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


func test_the_outfit_tab_never_leaves_the_body_naked() -> void:
	# No underwear yet: the torso's suits have no "None", the shoes keep theirs.
	var creator: CharacterCreator = _creator()
	creator._open_tab(&"outfit")
	var none: String = creator.tr("%%CHAR_NONE")
	var firsts: Array = _outfit_pickers(creator).map(func(p: OptionButton) -> bool: return p.get_item_text(0) == none)
	assert_true(firsts.has(false), "a picker without None (the suits)")
	assert_true(firsts.has(true), "a picker with None (the shoes)")
	var at: int = firsts.find(false)
	for i in _outfit_pickers(creator)[at].item_count:  # every suit worn in turn: still dressed
		var picker: OptionButton = _outfit_pickers(creator)[at]  # the rows are built again after a choice
		picker.select(i)
		picker.item_selected.emit(i)
		assert_eq(CharacterAppearance.bare_zones(creator.look.garments), [], "dressed after choice %d" % i)


func _outfit_pickers(creator: CharacterCreator) -> Array:
	return creator._rows.find_children("*", "OptionButton", true, false).filter(
			func(p: OptionButton) -> bool: return not p.is_queued_for_deletion())


func test_a_line_die_draws_that_line_only() -> void:
	var creator: CharacterCreator = _creator()
	creator._open_tab(&"face")
	creator._open_subtab(&"jaw")
	var key: String = "mod:Chin_Width"
	assert_true(creator._row_buttons.has(key), "the chin's width has its die")
	var before: CharacterAppearance = creator.look.duplicate_appearance()
	var changed: bool = false
	for i in 6:
		(creator._row_buttons[key][0] as Button).pressed.emit()
		changed = changed or not is_equal_approx(LookFields.value(creator.look, key), LookFields.value(before, key))
	assert_true(changed, "the die draws the line")
	for other: String in LookFields.menu_keys(&"face", &"jaw"):
		if other != key:
			assert_eq(LookFields.value(creator.look, other), LookFields.value(before, other), other)


func test_a_menu_lock_locks_its_lines_and_unlock_all_clears() -> void:
	var creator: CharacterCreator = _creator()
	creator._open_tab(&"skin")
	creator._menu_lock.pressed.emit()
	for key: String in LookFields.menu_keys(&"skin", &""):
		assert_true(creator._locks.get(key, false), key)
	var before: CharacterAppearance = creator.look.duplicate_appearance()
	creator._randomise_all()
	for key: String in LookFields.menu_keys(&"skin", &""):
		assert_eq(LookFields.value(creator.look, key), LookFields.value(before, key), "%s kept by all random" % key)
	assert_true((creator._row_buttons["prop:skin_tone"][0] as Button).disabled, "a locked line's die is off")
	assert_false(creator._unlock_all.disabled)
	creator._unlock_all.pressed.emit()
	assert_true(creator._locks.is_empty())
	assert_true(creator._unlock_all.disabled)
	creator._step_back()
	assert_eq(creator.look.encode(), before.encode(), "a draw is an undo step")


func test_an_expression_button_holds_a_face_not_a_look() -> void:
	var creator: CharacterCreator = _creator()
	var before: String = creator.look.encode()
	var could_undo: bool = creator._history.can_undo()
	var laugh: Button = creator._preview._expressions[&"laugh"]
	laugh.pressed.emit()
	assert_eq(creator._preview.expression(), &"laugh")
	var face: FaceLife = creator._preview._puppet.get_node("FaceLife")
	assert_eq(face.expression, &"laugh")
	for key: StringName in creator._preview._expressions:
		assert_eq((creator._preview._expressions[key] as Button).button_pressed, key == &"laugh", "%s pressed" % key)
	assert_eq(creator.look.encode(), before, "an expression is presentation: the look is the same")
	assert_eq(creator._history.can_undo(), could_undo, "and no undo step")
	assert_eq(CreatorPreview.EXPRESSION_BUTTONS.size(), FaceLife.EXPRESSIONS.size(), "a button per expression")
