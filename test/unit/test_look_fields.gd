extends GutTest
## LookFields: every field the character creator edits by its key, and the creator's draws over them -- a line's
## die, a menu's "Random", "All random", "Vary" -- keeping the locked fields, the character's sex and origin unless
## drawn, and the face within the creator's limits.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_look_fields.gd -gexit


## A look with something in every kind of field: a random one, a hair style and a beard.
func _look(seed_value: int = 11) -> CharacterAppearance:
	var look: CharacterAppearance = LookFields.random_like(seed_value, 0, CharacterAppearance.ORIGIN_WHITE)
	look.hair = 2
	look.cut = look.style_cut(2)
	look.beard = 1
	look.beard_cut = look.beard_style_cut(1)
	look.canonicalise()
	return look


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return absf(a - b) <= 1.5 / 127.0
	return a == b


func test_every_key_copies_its_field() -> void:
	var from: CharacterAppearance = _look(11)
	var to: CharacterAppearance = LookFields.random_like(99, 1, CharacterAppearance.ORIGIN_AFRICAN)
	var keys: Array = LookFields.all_keys()
	assert_gt(keys.size(), 150, "every slider, colour, choice and garment row")
	for key: String in keys:
		assert_true(LookFields.value(from, key) != null, key)
		LookFields.copy(from, to, key)
		if not key.begins_with("axis:"):  # an axis' copy is a move along it: the next keys move it again
			assert_true(_same(LookFields.value(to, key), LookFields.value(from, key)), key)


func test_every_line_of_the_creator_has_a_known_key() -> void:
	var creator: CharacterCreator = (load("res://ui/character_creator/character_creator.tscn") as PackedScene).instantiate()
	add_child_autofree(creator)
	var keys: Array = LookFields.all_keys()
	for tab: StringName in CharacterCreator.TABS:
		creator._open_tab(tab)
		for sub: StringName in CharacterCreator.SUBTABS.get(tab, {&"": ""}):
			if sub != &"":
				creator._open_subtab(sub)
			var menu: Array = LookFields.menu_keys(tab, sub)
			for key: String in creator._row_buttons:
				assert_true(keys.has(key), "%s / %s: %s is a key" % [tab, sub, key])
				assert_true(menu.has(key), "%s / %s: %s belongs to its menu" % [tab, sub, key])


func test_all_random_keeps_what_is_locked() -> void:
	var look: CharacterAppearance = _look()
	var locked: Array = ["mod:Chin_Width", "axis:%s" % FaceAxes.axes()[0][0], "prop:skin_tone", "hair_style", "cut:curl",
		"prop:eye_colour", "macro:height", "mod:BodyType_Fat"]
	look.modifiers[CharacterAppearance.modifier_id("Chin_Width")] = 0.4
	look.modifiers[CharacterAppearance.modifier_id("BodyType_Fat")] = 0.6
	var locks: Dictionary = {}
	for k: String in locked:
		locks[k] = true
	for seed_value in 12:
		var out: CharacterAppearance = LookFields.draw(look, LookFields.all_keys(), locks, seed_value)
		for k: String in locked:
			assert_true(_same(LookFields.value(out, k), LookFields.value(look, k)), "seed %d: %s kept" % [seed_value, k])


func test_a_menu_draw_changes_its_unlocked_lines_only() -> void:
	var look: CharacterAppearance = _look()
	var menu: Array = LookFields.menu_keys(&"face", &"jaw")
	var locks: Dictionary = {menu[0]: true}
	var others: Array = LookFields.all_keys().filter(func(k: String) -> bool: return not menu.has(k))
	var moved: int = 0
	for seed_value in 10:
		var out: CharacterAppearance = LookFields.draw(look, menu, locks, seed_value)
		assert_true(_same(LookFields.value(out, menu[0]), LookFields.value(look, menu[0])), "the locked line kept")
		for k: String in others:
			if not k.begins_with("axis:"):  # an axis reads the face sliders, the jaw's among them
				assert_true(_same(LookFields.value(out, k), LookFields.value(look, k)), "seed %d: %s untouched" % [seed_value, k])
		for k: String in menu.slice(1):
			if not _same(LookFields.value(out, k), LookFields.value(look, k)):
				moved += 1
		assert_lte(CreatorLimits.load_of(out), CreatorLimits.budget() + 0.01, "the face within the creator's budget")
	assert_gt(moved, 10, "the jaw's sliders are drawn, not left at 0")


func test_draws_keep_the_character_sex_and_origin() -> void:
	var look: CharacterAppearance = _look()
	for seed_value in 8:
		for menu: Array in [LookFields.menu_keys(&"skin", &""), LookFields.menu_keys(&"hair", &""),
				LookFields.menu_keys(&"face", &"overall")]:
			var out: CharacterAppearance = LookFields.draw(look, menu, {}, seed_value)
			assert_eq(out.is_female(), look.is_female())
			assert_eq(LookFields.main_origin(out), LookFields.main_origin(look))
		var all_but_sex: CharacterAppearance = LookFields.draw(look, LookFields.all_keys(), {"macro:gender": true}, seed_value)
		assert_eq(all_but_sex.is_female(), look.is_female(), "the sex locked, all random keeps it")


func test_all_random_without_locks_is_a_random_look() -> void:
	assert_eq(LookFields.draw(_look(), LookFields.all_keys(), {}, 5).encode(), CharacterAppearance.random(5).encode())


func test_vary_moves_a_little_within_the_limits() -> void:
	var look: CharacterAppearance = _look()
	var menu: Array = LookFields.menu_keys(&"face", &"overall")
	var locks: Dictionary = {"axis:%s" % FaceAxes.axes()[1][0]: true}
	var out: CharacterAppearance = LookFields.vary(look, menu, locks, 3)
	var moved: int = 0
	for k: String in menu:
		if k.begins_with("mod:") and not _same(LookFields.value(out, k), LookFields.value(look, k)):
			moved += 1
	assert_gt(moved, 5, "the face moved")
	var locked: String = locks.keys()[0]
	assert_true(_same(LookFields.value(out, locked), LookFields.value(look, locked)), "the locked axis kept")
	for k: String in LookFields.menu_keys(&"body", &"shape"):
		assert_true(_same(LookFields.value(out, k), LookFields.value(look, k)), "%s: another menu untouched" % k)
	assert_lte(CreatorLimits.load_of(out), CreatorLimits.budget() + 0.01)


func test_draws_are_deterministic() -> void:
	var look: CharacterAppearance = _look()
	var menu: Array = LookFields.menu_keys(&"face", &"mouth")
	assert_eq(LookFields.draw(look, menu, {}, 7).encode(), LookFields.draw(look, menu, {}, 7).encode())
	assert_eq(LookFields.vary(look, menu, {}, 7).encode(), LookFields.vary(look, menu, {}, 7).encode())
