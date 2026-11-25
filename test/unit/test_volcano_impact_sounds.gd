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


func test_ash_level_is_smoothed_whatever_the_frame_rate() -> void:
	var fast := 0.0
	for i in 120:
		fast = ASH.smooth_toward(fast, 1.0, 1.0 / 120.0, 3.0)
	var slow := 0.0
	for i in 10:
		slow = ASH.smooth_toward(slow, 1.0, 0.1, 3.0)
	assert_almost_eq(fast, slow, 0.001, "same level after 1 s at 120 or 10 fps")
	assert_almost_eq(fast, 1.0 - exp(-1.0 / 3.0), 0.001, "a first-order lag of 3 s")


func test_ash_fades_in_and_out_without_a_corner() -> void:
	var env := 0.0
	env = ASH.step_envelope(env, true, 1.0, 4.0, 8.0)
	assert_almost_eq(env, 0.25, 0.001, "a quarter in after 1 s of a 4 s fade in")
	env = ASH.step_envelope(env, true, 10.0, 4.0, 8.0)
	assert_eq(env, 1.0, "in")
	env = ASH.step_envelope(env, false, 2.0, 4.0, 8.0)
	assert_almost_eq(env, 0.75, 0.001, "a quarter out after 2 s of an 8 s fade out")
	assert_eq(ASH.envelope_gain(0.0), 0.0, "silent at the start")
	assert_eq(ASH.envelope_gain(1.0), 1.0, "full at the end")
	assert_lt(ASH.envelope_gain(0.05), 0.05, "starts gently")
	assert_gt(ASH.envelope_gain(0.95), 0.95, "ends gently")


func test_ash_lands_downwind_not_upwind() -> void:
	# A puff 8 km up over the vent, 3 km wide; wind 10 m/s toward +x; ash falling at 4 m/s.
	var puff := Vector4(0.0, 8000.0, 0.0, 3000.0)
	var wind := Vector2(10.0, 0.0)
	var downwind := VolcanoPlume.fallout_weight(puff, Vector3(10000.0, 0.0, 0.0), wind, 4.0)
	var upwind := VolcanoPlume.fallout_weight(puff, Vector3(-5000.0, 0.0, 0.0), wind, 4.0)
	assert_gt(downwind, 0.5, "the ash lands downwind")
	assert_eq(upwind, 0.0, "nothing upwind of the volcano")
	assert_eq(VolcanoPlume.fallout_weight(puff, Vector3(0.0, 9000.0, 0.0), wind, 4.0), 0.0, "none from a puff below")
	assert_gt(VolcanoPlume.fallout_weight(puff, Vector3.ZERO, Vector2.ZERO, 4.0), 0.9, "straight down without wind")
