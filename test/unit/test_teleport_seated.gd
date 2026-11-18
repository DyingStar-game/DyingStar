extends GutTest
## Teleporting from a seat. The server takes the traveller out of the seat before it moves them (a body
## moved with its seat still held left its owner unable to walk or look around, playtest 2026-11-17),
## gives the seat back once the vehicle has landed, and the owner's client sits where the server's STATE
## has it seated -- never on a seat that left the game.

const SEAT_KEY := "seat_driver"


## A bare vehicle with one driver's seat, in the tree -- or out of it ([param in_tree] false) to hang a
## bare Player from it: a Player entering the tree wants its whole scene.
func _truck(in_tree: bool = true) -> Vehicle:
	var truck := Vehicle.new()
	var seat := VehicleSeat.new()
	seat.name = "SeatDriver"
	seat.role = VehicleSeat.Role.DRIVER
	truck.add_child(seat)
	if in_tree:
		add_child_autofree(truck)
	else:
		autofree(truck)
	return truck


## A server-side body named [param uuid], out of the tree like test_player_spawn_state's.
func _traveller(uuid: String) -> Player:
	var player := Player.new()
	player.client_uuid = uuid
	var role := PlayerServer.new()
	role.player = player
	player._role = role
	autofree(role)
	autofree(player)
	return player


func _seat(truck: Vehicle, player: Player) -> VehicleSeat:
	truck.server_enter(player, SEAT_KEY, true)
	return truck.find_seat(SEAT_KEY) as VehicleSeat


func test_taken_out_of_the_seat_where_it_is_the_seat_is_free_and_everyone_is_told() -> void:
	var truck := _truck()
	var player := _traveller("p1")
	var seat := _seat(truck, player)
	assert_eq(seat.occupant_uuid, "p1", "seated")
	watch_signals(player)
	var kept: Dictionary = player.server_unseat_in_place()
	assert_true(seat.is_free(), "the seat is released")
	assert_null(player._seat_node, "the body rides nothing: the server no longer glues it to the cab")
	assert_false(player.piloting)
	assert_eq(kept.get("vehicle"), truck, "what gives the seat back names the vehicle")
	assert_eq(kept.get("seat"), SEAT_KEY, "and the seat")
	assert_signal_emitted(player, "hs_server_player_update", "the owner's client and the others are told")
	var told: Dictionary = get_signal_parameters(player, "hs_server_player_update")[1]
	assert_true(str(told.get("action", "")).begins_with("unseat:"), "the event that stands the owner up")
	assert_eq(told.get("seat"), "", "and the state a later arrival reads")


func test_on_foot_there_is_nothing_to_take_out() -> void:
	var player := _traveller("p1")
	watch_signals(player)
	assert_eq(player.server_unseat_in_place(), {})
	assert_signal_not_emitted(player, "hs_server_player_update")


## A seat that will be given back leaves the body as the seat had it: its vehicle lands on the spot it
## waits at. A ride that is over makes it solid again.
func test_the_body_is_solid_again_only_when_the_ride_is_over() -> void:
	var truck := _truck()
	var player := _traveller("p1")
	player.collision_layer = 4
	player.collision_mask = 5
	_seat(truck, player)
	assert_eq(player.collision_layer, 0, "seated: out of the cab's way")
	player.server_unseat_in_place(false)
	assert_eq(player.collision_layer, 0, "the seat is kept for the arrival: still not solid")
	_seat(truck, player)
	player.server_unseat_in_place(true)
	assert_eq(player.collision_layer, 4, "the ride is over: solid")
	assert_eq(player.collision_mask, 5)


func test_the_seat_is_given_back_whatever_its_door_and_everyone_is_told() -> void:
	var truck := _truck()
	var player := _traveller("p1")
	var seat := _seat(truck, player)
	var kept: Dictionary = player.server_unseat_in_place(false)
	watch_signals(player)
	assert_true(player.server_reseat(kept), "back at the wheel")
	assert_eq(seat.occupant_uuid, "p1")
	assert_eq(player._seat_node, seat, "the server rides the seat again")
	assert_true(player.piloting)
	assert_eq(truck.pilot_uuid, "p1", "and drives")
	var told: Dictionary = get_signal_parameters(player, "hs_server_player_update")[1]
	assert_true(str(told.get("action", "")).begins_with("seat:driver:"), "the event: seated by the server")
	assert_eq(told.get("seat"), "driver", "with the state, in one message")
	assert_false(player.server_reseat(kept), "already seated: nothing to give back twice")


func test_a_seat_taken_meanwhile_is_not_given_back_and_the_body_is_solid() -> void:
	var truck := _truck()
	var player := _traveller("p1")
	player.collision_layer = 4
	_seat(truck, player)
	var kept: Dictionary = player.server_unseat_in_place(false)
	(truck.find_seat(SEAT_KEY) as VehicleSeat).occupant_uuid = "someone else"
	assert_false(player.server_reseat(kept), "the seat went to another")
	assert_null(player._seat_node)
	assert_eq(player.collision_layer, 4, "standing: solid again")


func test_a_vehicle_gone_meanwhile_gives_no_seat_back() -> void:
	var truck := _truck()
	var player := _traveller("p1")
	_seat(truck, player)
	var kept: Dictionary = player.server_unseat_in_place(false)
	truck.free()
	assert_false(player.server_reseat(kept))


## The teleporter's own reading of who is seated where.
func test_the_teleporter_finds_the_seated_in_a_vehicle() -> void:
	var truck := _truck(false)
	var player := _traveller("p1")
	assert_null(Teleporter._vehicle_of(player), "on foot")
	_seat(truck, player)
	assert_eq(Teleporter._vehicle_of(player), truck, "the vehicle of the seat it rides")
	truck.add_child(player)  # the server hangs a seated body from its vehicle
	var walker := _traveller("p2")
	truck.add_child(walker)  # standing in the bed: not seated
	assert_eq(Teleporter._seated_in(truck), [player] as Array[Player])
	truck.remove_child(player)
	truck.remove_child(walker)


# -- the owner's client -------------------------------------------------------------------------

## The client's body under [param truck], whose replicated seat map has it at the wheel.
func _client_body_in(truck: Vehicle, uuid: String) -> Player:
	var body := Player.new()
	body.client_uuid = uuid
	autofree(body)
	truck._net_seats = {SEAT_KEY: uuid}
	return body


func test_the_client_sits_where_the_server_s_state_has_it() -> void:
	var truck := _truck(false)
	var body := _client_body_in(truck, "p1")
	assert_null(PlayerClient.seat_given(body, 0, 10000), "its frame is no vehicle: on foot")
	truck.add_child(body)
	assert_eq(PlayerClient.seat_given(body, 0, 10000), truck.find_seat(SEAT_KEY),
			"its frame is the truck and the seat map names it: that seat")
	truck._net_seats = {SEAT_KEY: ""}
	assert_null(PlayerClient.seat_given(body, 0, 10000), "the map names nobody: standing in the cab")
	body.client_uuid = ""
	assert_null(PlayerClient.seat_given(body, 0, 10000), "a body with no name is not given the free seats")
	truck.remove_child(body)


func test_the_state_is_not_believed_just_after_the_server_said_unseat() -> void:
	var truck := _truck(false)
	var body := _client_body_in(truck, "p1")
	truck.add_child(body)
	var said: int = 50000
	assert_null(PlayerClient.seat_given(body, said, said + PlayerClient.UNSEAT_SETTLE_MS - 1),
			"the seat map and the frame lag the word: not seated again from them")
	assert_not_null(PlayerClient.seat_given(body, said, said + PlayerClient.UNSEAT_SETTLE_MS),
			"still seated in the state long after: the server kept us there")
	truck.remove_child(body)


func test_a_seat_that_left_the_game_is_not_ridden() -> void:
	var truck := _truck()
	var seat: Node = truck.find_seat(SEAT_KEY)
	assert_true(PlayerClient.seat_is_live(seat), "in the game")
	truck.process_mode = Node.PROCESS_MODE_DISABLED  # NetworkAgent._retire: out of our zone
	assert_false(PlayerClient.seat_is_live(seat), "its vehicle retired")
	truck.process_mode = Node.PROCESS_MODE_INHERIT
	var freed := Node3D.new()
	freed.free()
	assert_false(PlayerClient.seat_is_live(freed), "freed")
	assert_false(PlayerClient.seat_is_live(null), "none")
