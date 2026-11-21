## Writes res://xr/openxr_action_map.tres, the OpenXR action map: one action set, "dyingstar", whose actions
## are the controls of a hand (trigger, squeeze, stick, face buttons, poses), bound on EVERY controller profile
## Godot 4.7 knows (Steam Frame, Index, Vive, Touch, Pico, Windows MR, Cosmos, Focus 3, generic...). The
## runtime picks the profile of the controllers in the user's hands and the game reads the same actions
## whatever the headset: that is how VR stays headset-agnostic. Godot's own default map binds 4 profiles.
##
## The inputs each profile has come from tools/xr/openxr_profile_inputs.json, taken from Godot's
## OpenXRInteractionProfileMetadata registrations. Each action takes, on each hand, the FIRST of its
## candidate inputs the profile has (a Vive wand has a trackpad where others have a thumbstick).
##
## Usage (from the project root), after changing the rules or the table:
##   $GODOT --headless --script tools/xr/build_action_map.gd
@tool
extends SceneTree

const OUT_PATH := "res://xr/openxr_action_map.tres"
const TABLE_PATH := "res://tools/xr/openxr_profile_inputs.json"
const HANDS: Array[String] = ["/user/hand/left", "/user/hand/right"]
## ACTION_HAPTIC: in the engine's enum (after POSE) but not bound to scripts in 4.7.
const ACTION_HAPTIC := 4

## [action name, OpenXRAction type, candidates (input paths, first one present wins)]. A candidate given
## as "left=a|right=b" differs per hand. Bool inputs may feed float actions and the reverse: OpenXR
## converts (a float is "pressed" past the runtime's threshold).
const RULES: Array = [
	["aim_pose", OpenXRAction.OPENXR_ACTION_POSE, ["/input/aim/pose"]],
	["grip_pose", OpenXRAction.OPENXR_ACTION_POSE, ["/input/grip/pose"]],
	["palm_pose", OpenXRAction.OPENXR_ACTION_POSE, ["/input/grip_surface/pose"]],
	["haptic", ACTION_HAPTIC, ["/output/haptic"]],
	["trigger", OpenXRAction.OPENXR_ACTION_FLOAT,
			["/input/trigger/value", "/input/pinch_ext/value", "/input/select/click"]],
	["trigger_click", OpenXRAction.OPENXR_ACTION_BOOL,
			["/input/trigger/click", "/input/trigger/value", "/input/pinch_ext/value", "/input/select/click"]],
	["trigger_touch", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/trigger/touch"]],
	# "squeeze", not "grip": Godot names the grip_pose action "grip" on the tracker, and a second "grip"
	# in the set is dropped (OpenXRInterface.create_action), with every binding of it.
	["squeeze", OpenXRAction.OPENXR_ACTION_FLOAT,
			["/input/squeeze/value", "/input/squeeze/click", "/input/grasp_ext/value"]],
	["squeeze_click", OpenXRAction.OPENXR_ACTION_BOOL,
			["/input/squeeze/click", "/input/squeeze/value", "/input/grasp_ext/value"]],
	["primary", OpenXRAction.OPENXR_ACTION_VECTOR2, ["/input/thumbstick", "/input/trackpad"]],
	["primary_click", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/thumbstick/click", "/input/trackpad/click"]],
	["primary_touch", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/thumbstick/touch", "/input/trackpad/touch"]],
	# Lower face button: A on the right hand, X on the left (Touch, Pico, Windows MR...), A on both (Index).
	["ax_button", OpenXRAction.OPENXR_ACTION_BOOL,
			["left=/input/x/click|right=/input/a/click", "/input/a/click", "/input/primary/click"]],
	["ax_touch", OpenXRAction.OPENXR_ACTION_BOOL, ["left=/input/x/touch|right=/input/a/touch", "/input/a/touch"]],
	["by_button", OpenXRAction.OPENXR_ACTION_BOOL,
			["left=/input/y/click|right=/input/b/click", "/input/b/click", "/input/secondary/click"]],
	["by_touch", OpenXRAction.OPENXR_ACTION_BOOL, ["left=/input/y/touch|right=/input/b/touch", "/input/b/touch"]],
	# The Steam Frame's right controller carries all four face buttons, A B X Y, like a gamepad.
	["x_button", OpenXRAction.OPENXR_ACTION_BOOL, ["right=/input/x/click"]],
	["y_button", OpenXRAction.OPENXR_ACTION_BOOL, ["right=/input/y/click"]],
	["menu_button", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/menu/click"]],
	# Back / view: the Steam Frame's left View button, the simple controller has none beyond select.
	["select_button", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/view/click"]],
	["bumper", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/bumper/click", "/input/shoulder/click"]],
	# The Steam Frame's left controller has a real d-pad.
	["dpad_up", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/dpad_up/click"]],
	["dpad_down", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/dpad_down/click"]],
	["dpad_left", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/dpad_left/click"]],
	["dpad_right", OpenXRAction.OPENXR_ACTION_BOOL, ["/input/dpad_right/click"]],
	# A second pad beside the stick (Index, Windows MR): free for later.
	["secondary", OpenXRAction.OPENXR_ACTION_VECTOR2, ["/input/trackpad"], "/input/thumbstick"],
]


func _init() -> void:
	var table: Dictionary = _load_table()
	if table.is_empty():
		quit(1)
		return
	var map := build(table)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_PATH.get_base_dir()))
	var err := ResourceSaver.save(map, OUT_PATH)
	if err != OK:
		printerr("build_action_map: cannot save %s (%s)" % [OUT_PATH, error_string(err)])
		quit(1)
		return
	print("build_action_map: %d profiles -> %s" % [map.interaction_profiles.size(), OUT_PATH])
	quit(0)


## The action map for [param table] (profile path -> {"left": [inputs], "right": [inputs]}).
static func build(table: Dictionary) -> OpenXRActionMap:
	var map := OpenXRActionMap.new()
	var action_set := OpenXRActionSet.new()
	action_set.resource_name = "dyingstar"
	action_set.localized_name = "DyingStar"
	action_set.priority = 0
	var actions: Dictionary = {}
	for rule: Array in RULES:
		var action := OpenXRAction.new()
		action.resource_name = rule[0]
		action.localized_name = String(rule[0]).capitalize()
		action.action_type = rule[1]
		action.toplevel_paths = PackedStringArray(HANDS)
		action_set.add_action(action)
		actions[rule[0]] = action
	map.add_action_set(action_set)
	var profile_paths: Array = table.keys()
	profile_paths.sort()
	for profile_path: String in profile_paths:
		var bindings: Array = []
		for rule: Array in RULES:
			for path: String in bind_paths(rule, table[profile_path]):
				var binding := OpenXRIPBinding.new()
				binding.action = actions[rule[0]]
				binding.binding_path = path
				bindings.append(binding)
		if bindings.is_empty():
			continue
		var profile := OpenXRInteractionProfile.new()
		profile.interaction_profile_path = profile_path
		profile.bindings = bindings
		map.add_interaction_profile(profile)
	return map


## The full input paths [param rule] binds on a profile whose inputs per hand are [param inputs]: on each
## hand, its first candidate the hand has. A rule with a 4th element binds only when the hand ALSO has
## that input (the trackpad is "secondary" only beside a thumbstick).
static func bind_paths(rule: Array, inputs: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for hand: String in HANDS:
		var side: String = hand.get_file()
		var has: Array = inputs.get(side, [])
		if rule.size() > 3 and not has.has(rule[3]):
			continue
		for candidate: String in rule[2]:
			var path := _for_side(candidate, side)
			if path != "" and has.has(path):
				out.append(hand + path)
				break
	return out


## [param candidate] for one hand: "left=a|right=b" gives a or b ("" when the hand is not named).
static func _for_side(candidate: String, side: String) -> String:
	if not candidate.contains("="):
		return candidate
	for part: String in candidate.split("|"):
		if part.begins_with(side + "="):
			return part.trim_prefix(side + "=")
	return ""


static func _load_table() -> Dictionary:
	var text := FileAccess.get_file_as_string(TABLE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary or not (parsed as Dictionary).has("profiles"):
		printerr("build_action_map: cannot read %s" % TABLE_PATH)
		return {}
	return (parsed as Dictionary)["profiles"]
