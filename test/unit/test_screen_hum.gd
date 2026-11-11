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


func test_the_sound_loops_and_has_its_credit() -> void:
	var stream := ScreenHum.STREAM as AudioStreamOggVorbis
	assert_not_null(stream, "an Ogg: an MP3 loop ticks at every turn")
	assert_true(stream.loop, "a hum that stops after one turn is no hum")
	assert_true(FileAccess.file_exists("res://assets/_universe/audio/sfx/ui/screen-fan-hum.txt"))
