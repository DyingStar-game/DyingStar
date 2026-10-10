extends GutTest
## A dev tool is refused where it RUNS: the game server turns down the action of a switched-off tool,
## whatever the client sends. The client only hides the key, so an old build, or a modified one, could
## otherwise still delete props from the database or spawn trucks on a production server.

const GATED_ACTIONS: Array[String] = ["delete_prop", "spawn_prop", "god_mode", "god_mode_speed", "god_mode_land"]
const SERVER_BUILDS: Array[String] = [
	"res://.github/workflows/build-server-preprod.yaml",
	"res://.github/workflows/build-server-prod.yaml",
]

var _build_loop := RegEx.create_from_string("for tool in ([a-z_ ]+); do")


func test_a_switched_off_tool_is_refused() -> void:
	for action: String in GATED_ACTIONS:
		assert_false(PlayerServer.is_action_allowed(action, _off), "%s ran with its dev tool off" % action)


func test_a_switched_on_tool_runs() -> void:
	for action: String in GATED_ACTIONS:
		assert_true(PlayerServer.is_action_allowed(action, _on), "%s refused with its dev tool on" % action)


func test_an_ordinary_action_never_asks_a_dev_tool() -> void:
	for action: String in ["jump", "sprint", "enter_vehicle", "kiosk_spawn", "screen_state", ""]:
		assert_true(PlayerServer.is_action_allowed(action, _off), "'%s' was gated as a dev tool" % action)


## The dispatcher passes Globals.is_dev_tool_enabled itself: if that reference were wrong, EVERY player
## action (jump, sprint...) would fail at the gate, not just the dev tools.
func test_the_game_switch_answers_through_the_gate() -> void:
	assert_true(PlayerServer.is_action_allowed("jump", Globals.is_dev_tool_enabled))
	for action: String in GATED_ACTIONS:
		var tool: StringName = PlayerServer.DEV_TOOL_OF_ACTION[action]
		assert_eq(PlayerServer.is_action_allowed(action, Globals.is_dev_tool_enabled),
				Globals.is_dev_tool_enabled(tool), "%s does not follow the %s switch" % [action, tool])


func test_every_gated_action_is_listed() -> void:
	assert_eq(PlayerServer.DEV_TOOL_OF_ACTION.keys().size(), GATED_ACTIONS.size())
	for action: String in GATED_ACTIONS:
		assert_true(PlayerServer.DEV_TOOL_OF_ACTION.has(action), "%s is not gated" % action)


## A tool name missing from Globals.ENABLED_DEV_TOOLS counts as OFF for ever: a typo in the table would
## refuse the action everywhere, the editor included, without a word.
func test_every_gated_tool_is_a_real_switch() -> void:
	for tool: StringName in PlayerServer.DEV_TOOL_OF_ACTION.values():
		assert_true(Globals.ENABLED_DEV_TOOLS.has(String(tool)), "%s is not in ENABLED_DEV_TOOLS" % tool)


## The gate only protects production if the server builds switch the tool off (the repository ships it
## on, for developers). A tool added to the table must be added to their `sed` loop too.
func test_the_server_builds_switch_every_gated_tool_off() -> void:
	for path: String in SERVER_BUILDS:
		var found: RegExMatch = _build_loop.search(FileAccess.get_file_as_string(path))
		assert_not_null(found, "%s has no dev-tool loop" % path)
		if found == null:
			continue
		var switched_off: PackedStringArray = found.get_string(1).split(" ", false)
		for tool: StringName in PlayerServer.DEV_TOOL_OF_ACTION.values():
			assert_true(String(tool) in switched_off, "%s leaves %s on" % [path.get_file(), tool])


func _off(_tool: StringName) -> bool:
	return false


func _on(_tool: StringName) -> bool:
	return true
