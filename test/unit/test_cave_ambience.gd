extends GutTest

## The air of a cave (CaveAmbience): louder the deeper the player stands, silent outside.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_cave_ambience.gd


func test_how_deep_is_how_far_from_the_nearest_way_out() -> void:
	var mouths := PackedVector3Array([Vector3.ZERO, Vector3(100.0, 0.0, 0.0)])
	assert_eq(CaveAmbience.depth_from(mouths, Vector3(10.0, 0.0, 0.0)), 10.0)
	assert_eq(CaveAmbience.depth_from(mouths, Vector3(90.0, 0.0, 0.0)), 10.0, "the other mouth is nearer")
	assert_eq(CaveAmbience.depth_from(PackedVector3Array(), Vector3.ZERO), -1.0, "no opening")


func test_it_rises_as_the_player_goes_in() -> void:
	assert_eq(CaveAmbience.level_at(-1.0), 0.0, "outside")
	assert_eq(CaveAmbience.level_at(0.0), 0.0, "at the mouth")
	var shallow := CaveAmbience.level_at(CaveAmbience.FULL_DEPTH_M * 0.25)
	var half := CaveAmbience.level_at(CaveAmbience.FULL_DEPTH_M * 0.5)
	assert_gt(shallow, 0.0)
	assert_gt(half, shallow, "deeper, louder")
	assert_eq(CaveAmbience.level_at(CaveAmbience.FULL_DEPTH_M), 1.0)
	assert_eq(CaveAmbience.level_at(CaveAmbience.FULL_DEPTH_M * 3.0), 1.0, "never more than its full level")


func test_it_fades_in_and_dies_away() -> void:
	var air := CaveAmbience.new()
	add_child_autofree(air)
	assert_false(air.playing)
	air.hear(CaveAmbience.FULL_DEPTH_M)
	air._process(CaveAmbience.FADE_S * 0.5)
	assert_true(air.playing)
	assert_lt(air.volume_db, CaveAmbience.FULL_DB, "on its way up")
	air._process(CaveAmbience.FADE_S)
	assert_almost_eq(air.volume_db, CaveAmbience.FULL_DB, 0.01)
	air.hear(-1.0)
	air._process(CaveAmbience.FADE_S * 2.0)
	assert_false(air.playing, "out of the cave: silent, and stopped")


func test_the_sound_loops_and_has_its_credit() -> void:
	var stream := CaveAmbience.STREAM as AudioStreamOggVorbis
	assert_not_null(stream)
	assert_true(stream.loop)
	assert_true(FileAccess.file_exists("res://assets/_universe/audio/sfx/environment/cave-ambience.txt"))
