extends GutTest
## The chat finds its Player body by walking the tree, never by asking `owner`.
##
## The bug this pins: DirectChat is an `instance=` of its own scene inside player.tscn, and
## `Player.instantiate()` does not propagate `owner` down the tree — server/client.gd only sets it on
## the Player body itself (`spawned_entity_instance.owner = get_tree().current_scene`). So for every
## child of the Player, `owner` is the SCENE ROOT, and `_is_local()`'s `owner is Player` was
## permanently false: the chat was never wired to ChatNetwork, `ensure_connected()` never ran, and
## F12 did nothing at all. The project already knew `owner` was unreliable here (see the note on
## _screen_owner_of), the chat simply never adopted the walk.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_local_body.gd -gexit

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const DIRECT_CHAT_SCENE := "res://ui/direct_chat/direct_chat.tscn"


## F12 opens the chat — the binding the fix makes reachable again.
func test_f12_is_the_chat_key() -> void:
	assert_true(InputMap.has_action("toggle_chat"))
	var events: Array[InputEvent] = InputMap.action_get_events("toggle_chat")
	assert_eq(events.size(), 1, "toggle_chat has exactly one key")
	if events.size() == 1:
		assert_eq((events[0] as InputEventKey).physical_keycode, KEY_F12)


## The premise of the fix, straight from the scene files: NO child of the Player declares an owner,
## so `owner` cannot identify the body for a node sitting under it. Read from the scene, nothing
## instantiated: a Player brings a whole client with it (same constraint as test_audio_keys).
func test_no_child_of_the_player_scene_declares_an_owner() -> void:
	var state: SceneState = (load(PLAYER_SCENE) as PackedScene).get_state()
	assert_gt(state.get_node_count(), 0, "the player scene has nodes")
	for node: int in range(state.get_node_count()):
		var declared := false
		for property: int in range(state.get_node_property_count(node)):
			if state.get_node_property_name(node, property) == &"owner":
				declared = true
		assert_false(declared, "%s declares no owner: it is found by walking, not by asking"
				% state.get_node_path(node))


## The chat really does sit UNDER a Player in that scene — the walk has something to find, and the
## old `owner is Player` had nothing, which is precisely the difference.
func test_the_chat_is_a_child_of_the_player_scene() -> void:
	var state: SceneState = (load(PLAYER_SCENE) as PackedScene).get_state()
	var found := false
	for node: int in range(state.get_node_count()):
		if state.get_node_name(node) == &"DirectChat":
			found = true
			var path := str(state.get_node_path(node))
			assert_true(path.contains("UserInterface"),
					"DirectChat sits under UserInterface, not at the root: %s" % path)
	assert_true(found, "DirectChat is part of the player scene")


## Player.of() is the walker the fix relies on, exercised through a Player that never enters the
## tree: Player._ready() reads its capsule, interact_ray and mining_tool, so a Player added to the
## test tree would explode for reasons that have nothing to do with the walk. Outside the tree
## _ready never runs, and the walk only needs get_parent(), which works on a parented node.
func test_player_of_walks_up_to_the_body() -> void:
	var body := Player.new()
	body.name = "StandInBody"
	var middle := Control.new()
	var leaf := Control.new()
	body.add_child(middle)
	middle.add_child(leaf)

	assert_eq(Player.of(leaf), body, "found from the deepest child")
	assert_eq(Player.of(middle), body, "found from the middle")
	assert_eq(Player.of(body), body, "the body answers for itself")

	body.free()


func test_player_of_returns_null_under_no_player() -> void:
	var root := Node.new()
	var orphan := Control.new()
	root.add_child(orphan)
	assert_null(Player.of(orphan), "no Player above it: null, never a wrong body")
	assert_null(Player.of(root), "and none for the root either")

	root.free()