extends GutTest
## VehicleSuspensionShocks: a knock is detected from the wheel heights the server simulates, travels as
## a per-wheel shot counter, and is heard once by every client -- never replayed on arrival.

const DT: float = 1.0 / 60.0


## Two wheels; wheel 0 moves up at each of [param speeds] (m/s) for one tick, wheel 1 stays put.
## Returns every shot fired along the way.
func _ride(part: VehicleSuspensionShocks, speeds: Array) -> Array[Vector2i]:
	var fired: Array[Vector2i] = []
	var h := PackedFloat32Array([0.0, 0.0])
	part.track(h, DT)  # first tick: the starting heights, no stroke
	for s in speeds:
		h[0] += float(s) * DT
		fired.append_array(part.track(h, DT))
	return fired


func _part() -> VehicleSuspensionShocks:
	var part := VehicleSuspensionShocks.new()
	part.min_speed = 0.5
	part.full_speed = 3.0
	part.cooldown_s = 0.25
	return part


func test_one_bump_is_one_shot_at_its_peak() -> void:
	var fired := _ride(_part(), [0.2, 1.0, 2.0, 1.5, 0.5, 0.1, 0.0])
	assert_eq(fired.size(), 1, "a single sound however many ticks the stroke lasts")
	assert_eq(fired[0], Vector2i(0, 60), "wheel 0, strength of the 2 m/s peak: (2 - 0.5) / 2.5")


func test_the_suspension_following_the_ground_is_silent() -> void:
	assert_eq(_ride(_part(), [0.3, 0.4, 0.3, -0.4, -0.3, 0.2]).size(), 0)


func test_a_wheel_dropping_away_is_not_a_knock() -> void:
	assert_eq(_ride(_part(), [-1.0, -3.0, -4.0, -2.0, 0.0]).size(), 0, "only a compression is heard")


func test_a_rattle_is_held_back_by_the_cooldown() -> void:
	# Two strokes 4 ticks apart (0.07 s): inside the 0.25 s cooldown, the second is dropped.
	assert_eq(_ride(_part(), [2.0, 1.0, 0.0, 0.0, 2.0, 1.0, 0.0]).size(), 1)
	# The same two strokes 0.5 s apart: two knocks.
	var calm: Array = [2.0, 1.0]
	for i in 30:
		calm.append(0.0)
	calm.append_array([2.0, 1.0])
	assert_eq(_ride(_part(), calm).size(), 2)


func test_a_rebuilt_wheel_set_is_no_knock() -> void:
	var part := _part()
	part.track(PackedFloat32Array([0.0, 0.0]), DT)
	assert_eq(part.track(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), DT).size(), 0, "new wheel count")
	assert_eq(part.track(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]), DT).size(), 0, "a 1 m jump in a tick")
	assert_eq(part.track(PackedFloat32Array([0.9, 0.0, 0.0, 0.0]), DT).size(), 0)


func test_strength_runs_from_the_threshold_to_full() -> void:
	assert_eq(VehicleSuspensionShocks.strength(0.5, 0.5, 3.0), 0.0)
	assert_eq(VehicleSuspensionShocks.strength(3.0, 0.5, 3.0), 1.0)
	assert_eq(VehicleSuspensionShocks.strength(9.0, 0.5, 3.0), 1.0, "a landing is not louder than full")


func test_a_harder_knock_picks_a_harder_sample() -> void:
	for roll in [0.0, 0.5, 0.99]:
		assert_lte(VehicleSuspensionShocks.pick_sample(0.0, 6, -1, roll), 1, "softest end of the list")
		assert_gte(VehicleSuspensionShocks.pick_sample(1.0, 6, -1, roll), 4, "hardest end of the list")


func test_the_same_sample_never_plays_twice_in_a_row() -> void:
	for last in 6:
		for roll in [0.0, 0.5, 0.99]:
			assert_ne(VehicleSuspensionShocks.pick_sample(float(last) / 5.0, 6, last, roll), last)
	assert_eq(VehicleSuspensionShocks.pick_sample(0.7, 1, 0, 0.5), 0, "a single sample is still played")


func test_shots_cross_the_wire_and_are_heard_once() -> void:
	var server := _part()
	var client := _part()
	server.track(PackedFloat32Array([0.0, 0.0]), DT)
	var data: Dictionary = {}
	server.write_changes(data)
	client.read(_through_json(data))
	assert_eq(client.take_heard().size(), 0, "the first counters are the starting point, not shocks")

	_ride_on(server, [1.0, 2.0, 1.0])
	data = {}
	server.write_changes(data)
	assert_true(data.has(VehicleSuspensionShocks.KEY), "a shot is sent")
	client.read(_through_json(data))
	assert_eq(client.take_heard(), [Vector2i(0, 60)] as Array[Vector2i])
	assert_eq(client.take_heard().size(), 0, "played once")

	client.read(_through_json(data))
	assert_eq(client.take_heard().size(), 0, "the same counters sent again (a resend) are no new shot")
	data = {}
	server.write_changes(data)
	assert_false(data.has(VehicleSuspensionShocks.KEY), "nothing new, nothing sent")


func test_a_vehicle_coming_into_view_replays_nothing() -> void:
	var late := _part()
	late.read({VehicleSuspensionShocks.KEY: [[57.0, 80.0], [12.0, 30.0]]})
	assert_eq(late.take_heard().size(), 0)


func test_the_server_carries_on_counting_from_the_database() -> void:
	var server := _part()
	server.read({VehicleSuspensionShocks.KEY: [[57.0, 80.0], [12.0, 30.0]]})
	server.take_heard()
	server.track(PackedFloat32Array([0.0, 0.0]), DT)
	_ride_on(server, [2.0, 1.0])
	var data: Dictionary = {}
	server.write_changes(data)
	assert_eq(int(data[VehicleSuspensionShocks.KEY][0][0]), 58, "a counter going back would be a shot")


func _ride_on(part: VehicleSuspensionShocks, speeds: Array) -> void:
	var h := PackedFloat32Array([0.0, 0.0])
	for s in speeds:
		h[0] += float(s) * DT
		part.track(h, DT)


## What Horizon hands back: JSON, ints turned to floats.
func _through_json(data: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(data))


func test_the_key_is_whitelisted_by_horizon() -> void:
	# A truck that has not run yet has no counters to send, so test_vehicle_state cannot see this key.
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://items_def/vehicle_def.json"))
	var allowed: Array = []
	for channel in def["channels"]:
		allowed.append_array(channel["properties"])
	assert_has(allowed, VehicleSuspensionShocks.KEY, "or Horizon drops it in silence")
