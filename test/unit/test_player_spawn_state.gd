extends GutTest
## A player taken by a server is told the posture the server holds, even at its defaults: disconnected
## crouched (in EVA, at the wheel), the next session's client and Horizon still held it, the server
## stood, and the stand-up asked was no change to it — no answer, stuck crouched.

const STANDING := {"stance": 0, "floating": false, "thrusting": false, "seat": ""}


class FakeSeat extends Node3D:
	var driver : bool = true

	func is_driver_seat() -> bool:
		return driver


func _role_of(player: Player) -> PlayerServer:
	var role := PlayerServer.new()
	role.player = player
	player._role = role
	return role


func test_a_new_body_publishes_standing_on_foot() -> void:
	var player := Player.new()
	var role := _role_of(player)
	assert_eq(role.spawn_state(), STANDING, "the defaults are said, not left implied")
	role.free()
	player.free()


func test_the_published_posture_is_the_one_the_server_holds() -> void:
	var player := Player.new()
	var role := _role_of(player)
	role._stance = 2
	player.floating = true
	assert_eq(role.spawn_state(), {"stance": 2, "floating": true, "thrusting": false, "seat": ""},
			"a body handed over keeps its posture")
	role.free()
	player.free()


func test_a_body_re_seated_on_a_hand_over_says_its_seat() -> void:
	var player := Player.new()
	var role := _role_of(player)
	var seat := FakeSeat.new()
	player._seat_node = seat
	assert_eq(role.spawn_state()["seat"], "driver", "back at the wheel")
	seat.driver = false
	assert_eq(role.spawn_state()["seat"], "passenger")
	seat.free()
	role.free()
	player.free()


func test_the_posture_goes_out_on_the_player_update() -> void:
	var player := Player.new()
	var role := _role_of(player)
	player.client_uuid = "p1"
	watch_signals(player)
	player.server_publish_spawn_state()
	assert_signal_emitted_with_parameters(player, "hs_server_player_update", ["p1", STANDING])
	role.free()
	player.free()
