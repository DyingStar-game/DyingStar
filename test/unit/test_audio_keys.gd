extends GutTest
## The speaker and the microphone keys. They were shortcuts set on the two HUD buttons, N and M written
## into the player's scene: a shortcut is served before the control that has the keyboard, so neither
## letter could be typed in the controls page's own search box, and neither key could be changed or
## even found in that page.

const PLAYER_SCENE: String = "res://scenes/player/player.tscn"
const KEYS: Dictionary = {&"toggle_speaker": KEY_N, &"toggle_microphone": KEY_M}


func test_the_two_keys_are_actions() -> void:
	for action: StringName in KEYS:
		assert_true(InputMap.has_action(action), "%s is an action" % action)
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_eq(events.size(), 1, "%s has its key" % action)
		if events.size() == 1:
			assert_eq((events[0] as InputEventKey).keycode, KEYS[action],
				"bound by the letter on the key, as before: M is M on every layout")


func test_no_button_of_the_hud_keeps_a_key_of_its_own() -> void:
	# From the scene FILE, nothing instantiated: a player brings a whole client with it.
	var state: SceneState = (load(PLAYER_SCENE) as PackedScene).get_state()
	for node: int in range(state.get_node_count()):
		for property: int in range(state.get_node_property_count(node)):
			assert_ne(state.get_node_property_name(node, property), &"shortcut",
				"%s: a shortcut takes its key before a text field does" % state.get_node_path(node))


func test_they_are_listed_in_the_controls_page_under_general() -> void:
	var general: Dictionary = MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"]
	for action: StringName in KEYS:
		assert_true(general.has(String(action)), "%s can be found and rebound" % action)


func test_a_key_bound_by_its_letter_has_a_name() -> void:
	assert_eq(InputLabel.for_action(&"toggle_speaker"), "N")
	assert_eq(InputLabel.for_action(&"toggle_microphone"), "M")
	var with_ctrl := InputEventKey.new()
	with_ctrl.keycode = KEY_M
	with_ctrl.ctrl_pressed = true
	assert_eq(InputLabel.for_event(with_ctrl), "Ctrl + M", "its modifiers named as for any other key")
