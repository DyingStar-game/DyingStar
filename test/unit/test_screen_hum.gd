extends GutTest

## The fan hum of the world's screens (ScreenHum): every screen but a vehicle's and a player's own.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_screen_hum.gd


func test_a_screen_of_the_world_hums_and_a_vehicles_does_not() -> void:
	var machine := Node3D.new()
	add_child_autofree(machine)
	var screen := Node3D.new()
	machine.add_child(screen)
	assert_true(ScreenHum.hums_on(screen), "a machine's console")
	var cab := Node3D.new()
	cab.add_to_group("vehicle")
	add_child_autofree(cab)
	var dashboard := Node3D.new()
	cab.add_child(dashboard)
	assert_false(ScreenHum.hums_on(dashboard), "a cab has its own sounds")


func test_it_is_heard_from_a_few_metres_only() -> void:
	assert_true(ScreenHum.heard_from(1.0))
	assert_true(ScreenHum.heard_from(ScreenHum.HEAR_M))
	assert_false(ScreenHum.heard_from(ScreenHum.HEAR_M + 0.1), "further, it does not even play")


func test_a_giant_screen_is_heard_from_further() -> void:
	# The town hall's mission board is 16 m wide: its middle is metres away from who stands under it.
	assert_false(ScreenHum.heard_from(12.0), "a console is silent from there")
	assert_true(ScreenHum.heard_from(12.0, 16.0), "the giant board is not")
	assert_gt(ScreenHum.unit_for(16.0), ScreenHum.unit_for(0.0), "and keeps its level further out")
	var board: Node3D = (load("res://scenes/_universe/structures/missions/mission_board.tscn") as PackedScene).instantiate()
	add_child_autofree(board)
	var hum := board.get_node_or_null(NodePath(ScreenHum.NODE_NAME)) as ScreenHum
	assert_not_null(hum, "the town hall's giant board hums")
	assert_gt(hum.size_m, 10.0)


func test_the_sound_loops_and_has_its_credit() -> void:
	var stream := ScreenHum.STREAM as AudioStreamOggVorbis
	assert_not_null(stream, "an Ogg: an MP3 loop ticks at every turn")
	assert_true(stream.loop, "a hum that stops after one turn is no hum")
	assert_true(FileAccess.file_exists("res://assets/_universe/audio/sfx/ui/screen-fan-hum.txt"))
