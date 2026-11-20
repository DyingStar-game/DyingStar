extends GutTest
## CreatorLimits: a face's load (the catalogue face sliders, weighted per tab) kept within the fitted budget -- where a
## look is shown and where the creator's sliders stop; never in what is stored.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_creator_limits.gd -gexit

var _strength: float


func before_each() -> void:
	_strength = CreatorLimits.strength
	CreatorLimits.strength = 1.0


func after_each() -> void:
	CreatorLimits.strength = _strength


func _id(key: String) -> int:
	var id: int = CharacterAppearance.modifier_id(key)
	assert_ne(id, -1, key)
	return id


## A look with every slider of the face tabs at the end of its travel.
func _pushed() -> CharacterAppearance:
	var look: CharacterAppearance = CharacterAppearance.random(5)
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in sliders.size():
		if ["head", "eyes", "nose", "mouth", "jaw", "ears"].has(String(sliders[id]["tab"])):
			look.modifiers[id] = 1.0
	return look


func test_the_mouth_weighs_most_and_flame_nothing() -> void:
	assert_almost_eq(CreatorLimits.weight(_id("Mouth_Lips_UpperAngle")), 1.0, 1e-6, "the mouth: the heaviest tab")
	assert_gt(CreatorLimits.weight(_id("Eye_Size")), CreatorLimits.weight(_id("Nose_NoseHeight")))
	assert_eq(CreatorLimits.weight(_id("FLAME_Identity_00")), 0.0, "FLAME's directions are real faces'")
	assert_lt(CreatorLimits.budget(), 1.0)


func test_random_looks_and_presets_are_untouched() -> void:
	for seed_value in 300:
		var look: CharacterAppearance = CharacterAppearance.random(seed_value)
		assert_eq(CreatorLimits.load_of(look), 0.0, "seed %d: a random face is FLAME's, it carries no load" % seed_value)
		assert_eq(CreatorLimits.limit(look).encode(), look.encode())
	for name: String in ["default_male", "default_female"]:
		var preset: CharacterAppearance = CharacterAppearance.preset(name)
		assert_eq(CreatorLimits.limit(preset).encode(), preset.encode(), name)


func test_limit_shrinks_into_the_budget_and_keeps_the_stored_look() -> void:
	var look: CharacterAppearance = _pushed()
	var stored: String = look.encode()
	var shown: CharacterAppearance = CreatorLimits.limit(look)
	assert_eq(look.encode(), stored, "the look itself is never rewritten")
	assert_lte(CreatorLimits.load_of(shown), CreatorLimits.budget() + CreatorLimits.EPSILON)
	assert_gt(CreatorLimits.load_of(shown), CreatorLimits.budget() * 0.8, "shrunk to the budget, not to nothing")
	assert_eq(CreatorLimits.limit(shown).encode(), shown.encode(), "idempotent")
	assert_eq(CharacterAppearance.decode(shown.encode()).encode(), shown.encode(), "on the stored grid: shown as stored")
	var flame: int = _id("FLAME_Identity_03")
	look.modifiers[flame] = 76.0 / 127.0  # on the stored grid
	assert_eq(CreatorLimits.limit(look).modifiers[flame], 76.0 / 127.0, "FLAME's sliders are left alone")


func test_strength_zero_lifts_the_limits() -> void:
	var look: CharacterAppearance = _pushed()
	CreatorLimits.strength = 0.0
	assert_eq(CreatorLimits.budget(), INF)
	assert_eq(CreatorLimits.limit(look).encode(), look.encode())
	CreatorLimits.strength = 0.5
	assert_almost_eq(CreatorLimits.budget(), 2.0 * CreatorLimits._budget, 1e-6, "half the strength, twice the budget")


func test_a_slider_stops_where_the_budget_ends() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(9)
	var mouth: int = _id("Mouth_Lips_Height")
	var reach: float = CreatorLimits.max_move(look, mouth, 1.0)
	assert_between(reach, 0.3, 0.99, "one mouth slider alone stops short of its end")
	assert_almost_eq(reach, sqrt(CreatorLimits.budget()), 1.0 / 127.0)
	assert_eq(CreatorLimits.max_move(look, mouth, -1.0), -reach, "both ways")
	assert_eq(CreatorLimits.max_move(look, mouth, 0.1), 0.1, "within the budget: as asked")
	look.modifiers[mouth] = reach
	var other: int = _id("Mouth_Lips_LowerAngle")
	assert_lt(absf(CreatorLimits.max_move(look, other, -1.0)), 0.1, "the mouth's budget spent: the next one barely moves")
	assert_eq(CreatorLimits.max_move(look, _id("FLAME_Identity_01"), 1.0), 1.0, "a FLAME slider is free")


func test_a_look_past_the_limits_may_always_come_back() -> void:
	var look: CharacterAppearance = _pushed()
	var mouth: int = _id("Mouth_Lips_Height")
	assert_eq(CreatorLimits.max_move(look, mouth, 0.4), 0.4, "towards 0: allowed")
	assert_eq(CreatorLimits.max_move(look, mouth, 1.0), 1.0, "staying where it was: allowed")
	assert_eq(CreatorLimits.max_move(look, mouth, -0.5), 0.0, "past 0 the other way: no room left")
