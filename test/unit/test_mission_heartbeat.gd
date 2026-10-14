extends GutTest
## The service-mission player-state heartbeat's payload, unit-tested without a scene tree.
##
## The whole surface is the shape of one `PlayerStateEntry`: service-mission measures every physical
## objective from it (`visit`, `deliver_material`, `transport`, `transport_passenger`) AND matches
## each mission's availability zones against it, so a wrong field is not a cosmetic 400 — it is a
## mission that never matches, or a player who cannot see the contract they accepted.
##
## The invariant worth the most here is `test_the_seat_flags_are_never_re_read_off_the_body`:
## the flags are stored once and only flipped by the explicit seat hooks, because
## `GameServer._unseat_for_transfer` nulls the very same seat on a zone crossing. Re-reading it
## while building a payload would complete every passenger transport at every border.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_mission_heartbeat.gd -gexit

const MISSION_HEARTBEAT := preload("res://server/mission_heartbeat.gd")


## A seat that answers like VehicleSeat, so `seat_state_of` can be exercised without a vehicle.
## It is a Node because the real VehicleSeat is one and `seat_state_of` insists on it: a RefCounted
## standing in would read as "on foot" and the driver/passenger tests would pass for the wrong reason.
class SeatDouble extends Node:
	var driver: bool = false

	func is_driver_seat() -> bool:
		return driver


## A body carrying the `_seat_node` property the game reads it off.
class SeatedBody extends Node3D:
	var _seat_node: Variant = null


func _body(seat: Variant) -> SeatedBody:
	var body := SeatedBody.new()
	body._seat_node = seat
	if seat is Node:
		add_child_autofree(seat as Node)
	add_child_autofree(body)
	return body


func _place(system: String, scene: String, position: Vector3) -> Dictionary:
	return MISSION_HEARTBEAT.build_place(
		{"system": system, "scene": scene, "position": {"x": position.x, "y": position.y,
			"z": position.z}})


# ── Place: the mission schema's Place is FLAT, Social's is not ──────────────────────────────────

func test_place_is_flat_system_scene_xyz() -> void:
	# The coordinates are the very ones SocialHeartbeat.build_location sends, but the mission
	# schema's Place has x/y/z at the top level — forwarding the nested {position:{x,y,z}} as-is
	# would silently store a place at the origin.
	var place: Dictionary = MISSION_HEARTBEAT.build_place(
		{"system": "tarsis", "scene": "tarsis_3", "position": {"x": 1.5, "y": -2.0, "z": 3.25}})
	assert_eq(place, {"system": "tarsis", "scene": "tarsis_3", "x": 1.5, "y": -2.0, "z": 3.25})


func test_place_off_world_is_empty_system_and_space_scene() -> void:
	assert_eq(_place("", "space", Vector3.ZERO),
		{"system": "", "scene": "space", "x": 0.0, "y": 0.0, "z": 0.0})


func test_place_keeps_an_astronomic_coordinate_whole() -> void:
	# SandBox sits ~9.5e10 m out: not an overflow, and clamping it would put a planet in the wrong
	# system entirely.
	var place: Dictionary = _place("tarsis", "tarsis_3", Vector3(2.87715075e10, 0.0, 7.66766425e10))
	assert_almost_eq(place["x"], 2.87715075e10, 1.0)
	assert_almost_eq(place["z"], 7.66766425e10, 1.0)


func test_place_without_a_position_is_empty_rather_than_the_origin() -> void:
	# An answer with no position is "not known". Returning {x:0,y:0,z:0} here would put the player
	# on the origin, which is a real place some POI could sit on.
	assert_eq(MISSION_HEARTBEAT.build_place({"system": "tarsis", "scene": "tarsis_3"}), {})


# ── Entry: exactly what PlayerStateEntry accepts ───────────────────────────────────────────────

func test_entry_has_exactly_the_five_schema_keys() -> void:
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("player-1", _place("", "space", Vector3.ONE),
			{"onFoot": true, "passenger": false}, {"ore.iron": 40})
	assert_eq(entry.keys().size(), 5)
	assert_eq(entry["playerId"], "player-1")
	assert_eq(entry["onFoot"], true)
	assert_eq(entry["passenger"], false)
	assert_eq(entry["carried"], {"ore.iron": 40})
	assert_eq((entry["place"] as Dictionary)["scene"], "space")


func test_entry_defaults_to_on_foot_and_not_a_passenger() -> void:
	# An entry with no stored seat state must read as a player on foot, never as a seated one:
	# defaulting the other way would end a passenger transport before it starts.
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("player-1", null, {}, {})
	assert_eq(entry["onFoot"], true)
	assert_eq(entry["passenger"], false)


func test_entry_carries_a_null_place_as_null() -> void:
	# null is "outside every zone". A zeroed coordinate would instead read as the origin and could
	# satisfy a `visit` aimed at a POI sitting there.
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("player-1", null, {}, {})
	assert_null(entry["place"])


func test_entry_carries_only_the_carried_keys_and_keeps_them_whole() -> void:
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("player-1", null, {},
			{"ore.gold": 10, "ore.iron": 40})
	assert_eq(entry["carried"], {"ore.gold": 10, "ore.iron": 40})


# ── The seat flags: read once, then only flipped by the hooks ───────────────────────────────────

func test_seat_state_of_a_body_with_no_seat_is_on_foot() -> void:
	assert_eq(MISSION_HEARTBEAT.seat_state_of(_body(null)), {"onFoot": true, "passenger": false})


func test_seat_state_of_a_driver_seat_is_not_a_passenger() -> void:
	var seat := SeatDouble.new()
	seat.driver = true
	assert_eq(MISSION_HEARTBEAT.seat_state_of(_body(seat)), {"onFoot": false, "passenger": false})


func test_seat_state_of_a_crew_seat_is_a_passenger() -> void:
	assert_eq(MISSION_HEARTBEAT.seat_state_of(_body(SeatDouble.new())),
		{"onFoot": false, "passenger": true})


func test_the_seat_flags_are_never_re_read_off_the_body() -> void:
	# THE regression this file exists for. GameServer._unseat_for_transfer nulls _seat_node on a
	# zone crossing — a hand-over, not a player stepping out. If building an entry read the seat,
	# every passenger transport would complete at the first border crossed.
	var seated := _body(SeatDouble.new())
	var stored := {"onFoot": false, "passenger": true}
	var before: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, stored, {})
	seated._seat_node = null  # what the transfer does
	var after: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, stored, {})
	assert_eq(after, before)
	assert_eq(after["onFoot"], false)
	assert_eq(after["passenger"], true)


# ── Carried: a snapshot of what is physically with the player ───────────────────────────────────

func test_carried_drops_empty_quantities() -> void:
	# A zero would make every push differ from the last and wake the 10 s flush for nothing.
	assert_eq(MISSION_HEARTBEAT.sanitize_carried({"ore.gold": 10, "ore.iron": 0}), {"ore.gold": 10})


func test_carried_drops_negative_quantities() -> void:
	assert_eq(MISSION_HEARTBEAT.sanitize_carried({"ore.gold": -5, "ore.iron": 3}), {"ore.iron": 3})


func test_carried_keeps_any_good_type_it_is_given() -> void:
	# The vocabulary belongs to the service: an unknown goodType is its business to reject, not ours
	# to second-guess here. The mining minerals are ore.<mineral_id> and the catalog grows.
	assert_eq(MISSION_HEARTBEAT.sanitize_carried({"ore.cryptonite": 7}), {"ore.cryptonite": 7})
	assert_eq(MISSION_HEARTBEAT.sanitize_carried({"ore.not_mined_yet": 1}), {"ore.not_mined_yet": 1})


# ── Change detection: what is worth a push ─────────────────────────────────────────────────────

func test_place_moved_is_false_for_the_same_place() -> void:
	var place := _place("tarsis", "tarsis_3", Vector3(10.0, 20.0, 30.0))
	assert_false(MISSION_HEARTBEAT.place_moved(place, place.duplicate()))


func test_place_moved_is_false_inside_the_epsilon() -> void:
	# Physics jitter: re-pushing a body that has not really gone anywhere is pure noise.
	var before := _place("tarsis", "tarsis_3", Vector3(10.0, 20.0, 30.0))
	var after := _place("tarsis", "tarsis_3", Vector3(10.0, 20.0, 30.5))
	assert_false(MISSION_HEARTBEAT.place_moved(before, after))


func test_place_moved_is_true_past_the_epsilon() -> void:
	var before := _place("tarsis", "tarsis_3", Vector3(10.0, 20.0, 30.0))
	var after := _place("tarsis", "tarsis_3", Vector3(10.0, 20.0, 40.0))
	assert_true(MISSION_HEARTBEAT.place_moved(before, after))


func test_place_moved_is_true_across_scenes() -> void:
	# Short hop, but the body changed world: a planet's own coordinate frame is a different place.
	var before := _place("tarsis", "tarsis_3", Vector3.ZERO)
	var after := _place("tarsis", "tarsis_4", Vector3.ZERO)
	assert_true(MISSION_HEARTBEAT.place_moved(before, after))


func test_place_moved_is_true_when_a_place_appears_or_disappears() -> void:
	var place := _place("tarsis", "tarsis_3", Vector3.ZERO)
	assert_true(MISSION_HEARTBEAT.place_moved(null, place))
	assert_true(MISSION_HEARTBEAT.place_moved(place, null))


func test_needs_push_is_true_the_first_time() -> void:
	# Nothing has been accepted yet, so even a sitting-still player must go out once.
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, {}, {})
	assert_true(MISSION_HEARTBEAT._needs_push({}, entry))


func test_needs_push_is_false_for_an_identical_entry() -> void:
	var entry: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, {}, {"ore.iron": 4})
	assert_false(MISSION_HEARTBEAT._needs_push(entry, entry.duplicate()))


func test_needs_push_is_true_when_the_carried_snapshot_moved() -> void:
	var before: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, {}, {"ore.iron": 4})
	var after: Dictionary = MISSION_HEARTBEAT.build_entry("p", null, {}, {"ore.iron": 40})
	assert_true(MISSION_HEARTBEAT._needs_push(before, after))


func test_needs_push_is_true_when_the_player_got_out() -> void:
	var before: Dictionary = MISSION_HEARTBEAT.build_entry("p", null,
			{"onFoot": false, "passenger": true}, {})
	var after: Dictionary = MISSION_HEARTBEAT.build_entry("p", null,
			{"onFoot": true, "passenger": false}, {})
	assert_true(MISSION_HEARTBEAT._needs_push(before, after))


func test_needs_push_is_true_when_the_player_became_a_passenger() -> void:
	# The driver is not a passenger: a boarding player flips this even though nothing else changed,
	# and it is the flip that starts (or refuses) a transport_passenger objective.
	var before: Dictionary = MISSION_HEARTBEAT.build_entry("p", null,
			{"onFoot": false, "passenger": false}, {})
	var after: Dictionary = MISSION_HEARTBEAT.build_entry("p", null,
			{"onFoot": false, "passenger": true}, {})
	assert_true(MISSION_HEARTBEAT._needs_push(before, after))

# ── The goods vocabulary: minerals become inventory goods, volumes become whole units ─────────────

func test_a_mineral_becomes_an_ore_good_type() -> void:
	# service-inventory's catalogue: ore.gold / ore.iron / ore.cryptonite, keyed off the mineral id
	# the mining zone replicates.
	assert_eq(MISSION_HEARTBEAT.good_type_for_mineral("gold"), "ore.gold")
	assert_eq(MISSION_HEARTBEAT.good_type_for_mineral("iron"), "ore.iron")
	assert_eq(MISSION_HEARTBEAT.good_type_for_mineral("cryptonite"), "ore.cryptonite")


func test_an_empty_mineral_credits_nothing() -> void:
	# "" would build the goodType "ore." and credit it — the caller checks, so it must be empty.
	assert_eq(MISSION_HEARTBEAT.good_type_for_mineral(""), "")
	assert_eq(MISSION_HEARTBEAT.good_type_for_mineral("   "), "")


func test_one_haul_box_is_not_zero_units() -> void:
	# The crate collision box is 0.395 x 0.411 x 0.404 m, so a crate holds ≈0.0657 m3. In WHOLE
	# METRES that rounds to 0, and every extract would mint nothing at all — the reason goods are
	# counted in litres.
	var crate_m3: float = 0.3953384826854745 * 0.4112716205195284 * 0.4039184679659229
	assert_eq(MISSION_HEARTBEAT.units_of_volume(crate_m3), 66)


func test_units_of_volume_round_to_the_nearest_litre() -> void:
	assert_eq(MISSION_HEARTBEAT.units_of_volume(1.0), 1000)
	assert_eq(MISSION_HEARTBEAT.units_of_volume(0.0657), 66)
	assert_eq(MISSION_HEARTBEAT.units_of_volume(0.0), 0)


func test_units_of_volume_never_goes_negative() -> void:
	# A depot that rounded a sub-litre remainder the wrong way would send a negative delta, which
	# service-inventory reads as a drop-off.
	assert_eq(MISSION_HEARTBEAT.units_of_volume(-0.0004), 0)


func test_carried_of_reads_the_service_view() -> void:
	# The write answers a Stack, which carries no `carried`; the figure is read back from a
	# StackView instead, so this is the one number the payload's `carried` rests on.
	assert_eq(MISSION_HEARTBEAT.carried_of({"carried": 132}), 132)
	assert_eq(MISSION_HEARTBEAT.carried_of({"carried": 0}), 0)


func test_carried_of_an_unreadable_answer_is_zero() -> void:
	# Zero is the safe direction: the player owns less than they should, never more.
	assert_eq(MISSION_HEARTBEAT.carried_of({}), 0)
	assert_eq(MISSION_HEARTBEAT.carried_of(null), 0)
	assert_eq(MISSION_HEARTBEAT.carried_of("not a view"), 0)
