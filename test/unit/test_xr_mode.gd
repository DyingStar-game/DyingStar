extends GutTest
## VR is turned on by `--xr-mode on` alone, and its controls must work on every headset: the action map
## binds the game's actions on every controller profile Godot knows, and the file in the project is the
## one tools/xr/build_action_map.gd writes (run it after changing its rules).

const ACTION_MAP_PATH := "res://xr/openxr_action_map.tres"
const BUILDER_PATH := "res://tools/xr/build_action_map.gd"
## Profiles of the headsets most played on PC, which must never drop out of the map.
const MUST_HAVE: Array[String] = [
	"/interaction_profiles/valve/frame_controller_valve",
	"/interaction_profiles/valve/index_controller",
	"/interaction_profiles/htc/vive_controller",
	"/interaction_profiles/oculus/touch_controller",
	"/interaction_profiles/bytedance/pico4_controller",
	"/interaction_profiles/hp/mixed_reality_controller",
	"/interaction_profiles/microsoft/motion_controller",
	"/interaction_profiles/khr/simple_controller",
]


func test_flat_screen_by_default() -> void:
	assert_false(XRMode.is_active(), "the tests run without --xr-mode on")
	assert_false(ProjectSettings.get_setting("xr/openxr/enabled", false),
			"OpenXR must not start without --xr-mode on: it would wake a VR runtime for every player")
	assert_false(ProjectSettings.get_setting("xr/shaders/enabled", false),
			"--xr-mode on compiles the stereo shaders by itself; on for all, every player compiles them")
	assert_true(ProjectSettings.get_setting("xr/openxr/startup_alert", true),
			"the only word a player gets when --xr-mode on finds no headset")
	assert_eq(ProjectSettings.get_setting("xr/openxr/default_action_map"), ACTION_MAP_PATH)


func test_the_action_map_binds_every_main_headset() -> void:
	var map: OpenXRActionMap = load(ACTION_MAP_PATH)
	assert_not_null(map)
	for path in MUST_HAVE:
		assert_not_null(map.find_interaction_profile(path), "no bindings for " + path)


func test_every_controller_can_aim_and_trigger_with_both_hands() -> void:
	var map: OpenXRActionMap = load(ACTION_MAP_PATH)
	for i in map.get_interaction_profile_count():
		var profile: OpenXRInteractionProfile = map.get_interaction_profile(i)
		var bound: Dictionary = {}
		for j in profile.get_binding_count():
			var binding: OpenXRIPBinding = profile.get_binding(j)
			bound[binding.action.resource_name + ":" + binding.binding_path.split("/")[3]] = true
		for action in ["aim_pose", "trigger"]:
			for hand in ["left", "right"]:
				assert_true(bound.has(action + ":" + hand),
						"%s: no %s on the %s hand" % [profile.interaction_profile_path, action, hand])


func test_the_steam_frame_is_bound_like_a_gamepad() -> void:
	var map: OpenXRActionMap = load(ACTION_MAP_PATH)
	var bound := _bindings(map.find_interaction_profile("/interaction_profiles/valve/frame_controller_valve"))
	assert_has(bound, "ax_button=/user/hand/right/input/a/click")
	assert_has(bound, "x_button=/user/hand/right/input/x/click")
	assert_has(bound, "dpad_up=/user/hand/left/input/dpad_up/click")
	assert_has(bound, "select_button=/user/hand/left/input/view/click")
	assert_has(bound, "menu_button=/user/hand/right/input/menu/click")


func test_a_vive_wand_moves_with_its_trackpad() -> void:
	var map: OpenXRActionMap = load(ACTION_MAP_PATH)
	var bound := _bindings(map.find_interaction_profile("/interaction_profiles/htc/vive_controller"))
	assert_has(bound, "primary=/user/hand/left/input/trackpad")


func test_the_action_map_is_the_builders() -> void:
	var builder: GDScript = load(BUILDER_PATH)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(builder.TABLE_PATH))
	var built: OpenXRActionMap = builder.build(parsed["profiles"])
	var saved: OpenXRActionMap = load(ACTION_MAP_PATH)
	assert_eq(saved.get_interaction_profile_count(), built.get_interaction_profile_count())
	for i in built.get_interaction_profile_count():
		var want: OpenXRInteractionProfile = built.get_interaction_profile(i)
		var have := saved.find_interaction_profile(want.interaction_profile_path)
		assert_not_null(have, "missing " + want.interaction_profile_path)
		if have != null:
			assert_eq(_bindings(have), _bindings(want),
					"%s is stale: run tools/xr/build_action_map.gd" % want.interaction_profile_path)


## "action=path" of every binding of [param profile], sorted.
func _bindings(profile: OpenXRInteractionProfile) -> Array[String]:
	var out: Array[String] = []
	if profile == null:
		return out
	for j in profile.get_binding_count():
		var binding: OpenXRIPBinding = profile.get_binding(j)
		out.append(binding.action.resource_name + "=" + binding.binding_path)
	out.sort()
	return out
