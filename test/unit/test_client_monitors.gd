extends GutTest
## The client's network monitors are lambdas of this script, held by the engine's Performance: left there
## when the game quits, they outlived the scripting and Performance freed them last, through a destroyed
## lock -- the game crashed on quit (playtest 2026-10-21). Leaving the tree, however it leaves it, takes
## them out.

const CLIENT := "res://server/client.gd"
const MONITORS: Array[StringName] = [&"network/events_received", &"network/events_sent"]


func test_leaving_the_tree_takes_the_monitors_out() -> void:
	var client: Node = (load(CLIENT) as GDScript).new()
	add_child(client)
	for monitor in MONITORS:
		assert_true(Performance.has_custom_monitor(monitor), "%s while it plays" % monitor)
	remove_child(client)  # what quitting does to every node, without shutdown()
	for monitor in MONITORS:
		assert_false(Performance.has_custom_monitor(monitor), "%s gone with it" % monitor)
	client.free()
