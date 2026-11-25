extends GutTest
## The volcano's near sounds: the class and take of a stone's impact, its level by speed, and the ash
## fall's level (volcano_impact_sounds.gd, volcano_ash_fall.gd).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_volcano_impact_sounds.gd

const IMPACTS := preload("res://scenes/audio/volcano/volcano_impact_sounds.gd")
const ASH := preload("res://scenes/audio/volcano/volcano_ash_fall.gd")


func test_size_classes() -> void:
	assert_eq(IMPACTS.size_class(0.1, 0.35, 1.2), 0, "a shard is small")
	assert_eq(IMPACTS.size_class(0.35, 0.35, 1.2), 0, "up to the small limit")
	assert_eq(IMPACTS.size_class(0.6, 0.35, 1.2), 1, "a ball-sized bomb is medium")
	assert_eq(IMPACTS.size_class(1.2, 0.35, 1.2), 2, "a block is large")


func test_slow_impacts_are_quieter() -> void:
	assert_eq(IMPACTS.speed_db(30.0, 30.0), 0.0, "full level at the full speed")
	assert_eq(IMPACTS.speed_db(80.0, 30.0), 0.0, "never louder above it")
	assert_almost_eq(IMPACTS.speed_db(7.5, 30.0), linear_to_db(0.5), 0.01, "a quarter of the speed, half the level")


func test_take_is_the_same_for_the_same_stone() -> void:
	var takes: Array = [AudioStreamGenerator.new(), AudioStreamGenerator.new(), AudioStreamGenerator.new()]
	var seen := {}
	for i in 60:
		var born := 1000.0 + i * 0.37
		var take := IMPACTS.pick(takes, born, 0.5, false)
		assert_eq(take, IMPACTS.pick(takes, born, 0.5, false), "same stone, same take")
		seen[take] = true
	assert_eq(seen.size(), takes.size(), "every take comes up")
	assert_null(IMPACTS.pick([], 1000.0, 0.5, false), "no take, no sound")


func test_ash_level() -> void:
	assert_eq(ASH.ash_level(0.0, 2.0), 0.0, "no ash, silence")
	assert_almost_eq(ASH.ash_level(1.0, 2.0), 0.5, 0.001, "half the full ash, half the level")
	assert_eq(ASH.ash_level(9.0, 2.0), 1.0, "never over full")
