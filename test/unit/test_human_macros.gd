extends GutTest
## HumanMacros: which targets the macro sliders of a body turn on. The Vitruvian body has one shape key
## per trait, so this is a small table -- but a wrong sign here makes every woman a man.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_human_macros.gd -gexit

const CONFIG := {"female": "Gender_Female", "male": "Gender_Male", "old": "Age_Old", "origins": ["A", "B", "C"]}


func _stack(macros: Dictionary, origins: Array = [0.0, 0.0, 0.0]) -> Dictionary:
	var out: Dictionary = {}
	for pair: Array in HumanMacros.target_stack(CONFIG, macros, PackedFloat32Array(origins)):
		out[pair[0]] = pair[1]
	return out


func test_gender_goes_from_woman_through_neutral_to_man() -> void:
	assert_almost_eq(float(_stack({"gender": 0.0})["Gender_Female"]), 1.0, 1e-6)
	assert_false(_stack({"gender": 0.0}).has("Gender_Male"))
	assert_false(_stack({"gender": 0.5}).has("Gender_Female"), "the neutral body")
	assert_false(_stack({"gender": 0.5}).has("Gender_Male"))
	assert_almost_eq(float(_stack({"gender": 0.75})["Gender_Male"]), 0.5, 1e-6)


func test_age_is_adult_and_old_age_comes_late() -> void:
	assert_almost_eq(HumanMacros.years_of(0.0), 18.0, 1e-6, "the youngest body is an adult")
	assert_almost_eq(HumanMacros.years_of(HumanMacros.age_of(47.0)), 47.0, 1e-4)
	assert_false(_stack({"age": HumanMacros.age_of(25.0)}).has("Age_Old"))
	assert_almost_eq(float(_stack({"age": HumanMacros.age_of(85.0)})["Age_Old"]), 1.0, 1e-4)


func test_origins_never_add_up_past_one() -> void:
	var mixed: Dictionary = _stack({}, [1.0, 1.0, 0.0])
	assert_almost_eq(float(mixed["A"]) + float(mixed["B"]), 1.0, 1e-6, "two full origins share the body")
	assert_almost_eq(float(_stack({}, [0.3, 0.0, 0.0])["A"]), 0.3, 1e-6, "a light touch stays light")


func test_every_macro_target_is_in_the_bank() -> void:
	var bank := load(HumanBank.PATH) as HumanBank
	var origins := PackedFloat32Array()
	origins.resize(CharacterAppearance.ORIGINS)
	origins.fill(0.5)
	for gender in [0.0, 1.0]:
		for pair: Array in HumanMacros.target_stack(bank.macro_config, {"gender": gender, "age": 1.0}, origins):
			assert_ne(bank.target_index(pair[0]), -1, "%s is in the bank" % pair[0])
	assert_eq((bank.macro_config["origins"] as Array).size(), CharacterAppearance.ORIGINS)


func test_an_origin_brings_its_features() -> void:
	var config: Dictionary = (load(HumanBank.PATH) as HumanBank).macro_config
	var names: Array = config["origins"]
	var origins := PackedFloat32Array()
	origins.resize(names.size())
	origins[CharacterAppearance.ORIGIN_AFRICAN] = 1.0
	var stack: Dictionary = {}
	for pair: Array in HumanMacros.target_stack(config, {}, origins):
		stack[pair[0]] = pair[1]
	assert_eq(names[CharacterAppearance.ORIGIN_AFRICAN], "Race_African")
	assert_almost_eq(float(stack["Race_African"]), 1.0, 1e-6, "the base model's own key")
	assert_gt(float(stack["Mouth_Lips_Height"]), 1.0, "and feature sliders, past their own range")
	assert_lt(float(stack["Nose_BridgeProminence"]), 0.0)
	# Half an origin, half its features; and every feature is a target the bank holds.
	origins[CharacterAppearance.ORIGIN_AFRICAN] = 0.5
	for pair: Array in HumanMacros.target_stack(config, {}, origins):
		if pair[0] == "Mouth_Lips_Height":
			assert_almost_eq(float(pair[1]), float(stack["Mouth_Lips_Height"]) * 0.5, 1e-6)
	var bank := load(HumanBank.PATH) as HumanBank
	for origin: String in HumanMacros.ORIGIN_FEATURES:
		assert_true(names.has(origin), "%s is an origin of the catalogue" % origin)
		for key: String in HumanMacros.ORIGIN_FEATURES[origin]:
			assert_ne(bank.target_index(key), -1, "%s: %s is a target of the bank" % [origin, key])


func test_real_faces_widen_some_sliders() -> void:
	var stats: Dictionary = CharacterAppearance.face_stats()
	assert_gt(stats.size(), 5, "the survey's sliders are known")
	for key: String in stats:
		var entry: Dictionary = stats[key]
		assert_ne(CharacterAppearance.modifier_id(key), -1, "%s is a creator slider" % key)
		assert_between(float(entry["range"]), 1.0, 2.0, "%s: its reach" % key)
		assert_between(float(entry["sd"]), 0.0, 1.0)
	var key: String = stats.keys()[0]
	var a := CharacterAppearance.new()
	a.modifiers[CharacterAppearance.modifier_id(key)] = 1.0
	a.canonicalise()
	var weight: float = 0.0
	for pair: Array in a.modifier_stack():
		if pair[0] == key:
			weight = pair[1]
	assert_almost_eq(weight, CharacterAppearance.slider_range(key), 1e-6, "a slider at full travel reaches its range")
	assert_almost_eq(CharacterAppearance.slider_range("Nose_NostrilSize"), 1.0, 1e-6, "an unmeasured slider is as it was")
