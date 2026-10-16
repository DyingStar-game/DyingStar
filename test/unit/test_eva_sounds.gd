extends GutTest
## EVA thrusters' hiss (EvaThrusterSound, PlayerServer.eva_thrusting) and the player's clothes rustle.

const SERVER := preload("res://scenes/player/player_server.gd")
const PLAYER_SCENE := "res://scenes/player/player.tscn"


func test_a_move_key_fires_the_thrusters() -> void:
	assert_true(SERVER.eva_thrusting(Vector2(0, -1), 0.0, false, false, 0.0))


func test_the_vertical_axis_fires_the_thrusters() -> void:
	assert_true(SERVER.eva_thrusting(Vector2.ZERO, 1.0, false, false, 0.0))


func test_a_roll_key_fires_the_thrusters() -> void:
	assert_true(SERVER.eva_thrusting(Vector2.ZERO, 0.0, true, false, 0.0), "A / E roll the body with thrusters")


func test_no_key_no_thrust() -> void:
	assert_false(SERVER.eva_thrusting(Vector2.ZERO, 0.0, false, false, 3.0), "drifting is silent")


func test_the_brake_fires_only_while_there_is_motion_to_cancel() -> void:
	assert_true(SERVER.eva_thrusting(Vector2.ZERO, 0.0, false, true, 1.0), "braking a drift")
	assert_false(SERVER.eva_thrusting(Vector2.ZERO, 0.0, false, true, 0.0), "held at rest: nothing to push against")


func test_the_hiss_opens_fast_and_dies_slowly() -> void:
	var opened: float = EvaThrusterSound.next_level(0.0, true, EvaThrusterSound.ATTACK_S)
	assert_almost_eq(opened, 1.0, 0.0001, "full after the attack")
	var after_attack_time: float = EvaThrusterSound.next_level(1.0, false, EvaThrusterSound.ATTACK_S)
	assert_gt(after_attack_time, 0.5, "still audible when the attack would be over: a tail, not a cut")
	assert_almost_eq(EvaThrusterSound.next_level(1.0, false, EvaThrusterSound.RELEASE_S), 0.0, 0.0001,
			"silent after the release")


func test_thrusting_is_whitelisted_for_horizon() -> void:
	var def: String = FileAccess.get_file_as_string("res://items_def/player_def.json")
	assert_true(def.contains('"thrusting"'), "player_def.json lets `thrusting` through Horizon")


func test_the_player_has_both_sounds() -> void:
	var scene: String = FileAccess.get_file_as_string(PLAYER_SCENE)
	assert_true(scene.contains("\nsfx_eva_thrust = ExtResource("), "the EVA thrusters' hiss is set on the player")
	assert_true(scene.contains("\nsfx_clothes_short = Array[AudioStream]([ExtResource("), "short rustles set")
	assert_true(scene.contains("\nsfx_clothes_long = Array[AudioStream]([ExtResource("), "long rustles set")
	for path: String in ["eva-thrust-loop.ogg", "clothes-short-1.ogg", "clothes-short-2.ogg", "clothes-long-1.ogg",
			"clothes-long-2.ogg", "clothes-long-3.ogg", "clothes-long-4.ogg"]:
		assert_true(ResourceLoader.exists("res://assets/_universe/audio/sfx/characters/" + path), path)


func test_a_rustle_is_never_the_same_twice_running() -> void:
	var a := AudioStreamWAV.new()
	var b := AudioStreamWAV.new()
	for _i in 20:
		assert_eq(SurfaceSounds.pick_from([a, b], a), b, "two takes: the other one, every time")
	assert_null(SurfaceSounds.pick_from([], null), "no take: silence")
