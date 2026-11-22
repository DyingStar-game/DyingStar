extends GutTest
## The spawn watchdog (client.gd _watch_own_player_spawn) tells a lost parent from a slow zone build.
##
## Preprod 2026-11-20: "the parent object df4b19a2 never arrived from the server" on a first connection,
## the same player spawned on a reconnect one second later and the server had the building all along.
## The watchdog only counted the time since the last zone entry built: it did not look at the zone
## entries still waiting in the backlog, nor at where the parent itself was (half-received, waiting
## for its own parent), so every case read "never arrived".
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_spawn_watchdog.gd

const CLIENT := preload("res://server/client.gd")
const BUILDING := "df4b19a2-12ab-5ff8-a65e-ab7582e13ce5"
const PLANET := "c0379c08-1d5b-4ca2-8876-230908141b68"


func _zone_entry(object_id: String) -> Dictionary:
	return {"type": "gorc_zone_enter", "object_id": object_id, "channel": 0, "zone_data": {}}


func _pending_object(object_id: String, parent_id: String) -> Dictionary:
	return {"object_id": object_id, "object_type": "spawnbuilding",
			"object_data": {"scenename": "spawnbuilding", "parent_id": parent_id}}


func test_a_zone_entry_still_waiting_holds_the_watchdog() -> void:
	var backlog := NetBacklog.new()
	backlog.push({"object_type": "player", "object_id": "someone", "event": "move"})
	assert_false(backlog.any_waiting(CLIENT.is_zone_build_event), "moves alone: nothing of the zone is coming")
	backlog.push(_zone_entry(BUILDING))
	assert_true(backlog.any_waiting(CLIENT.is_zone_build_event), "a zone entry behind the moves: the zone is coming")


func test_an_object_unblocked_by_its_parent_counts_as_the_zone_coming() -> void:
	var backlog := NetBacklog.new()
	backlog.push({"type": CLIENT.PENDING_OBJECT, "event": {}})
	assert_true(backlog.any_waiting(CLIENT.is_zone_build_event))


func test_handled_events_are_no_longer_waiting() -> void:
	var backlog := NetBacklog.new()
	backlog.push(_zone_entry(BUILDING))
	backlog.drain(func(_e: Dictionary) -> bool: return true, 100000)
	assert_false(backlog.any_waiting(CLIENT.is_zone_build_event))


func test_a_parent_in_the_backlog_is_on_its_way() -> void:
	var backlog := NetBacklog.new()
	backlog.push(_zone_entry(BUILDING))
	assert_eq(CLIENT.object_whereabouts(BUILDING, backlog, {}, []), {"state": "backlog"})


func test_a_parent_half_received_names_what_it_misses() -> void:
	var pre := {BUILDING: {"type": "spawnbuilding", "channels": {1: {"parent_id": PLANET}}}}
	var where: Dictionary = CLIENT.object_whereabouts(BUILDING, NetBacklog.new(), pre, [])
	assert_eq(where["state"], "incomplete")
	assert_eq(where["missing"], ["scenename"])
	var text: String = CLIENT.spawn_failure_message("me", BUILDING, where)
	assert_string_contains(text, BUILDING)
	assert_string_contains(text, "scenename")


func test_a_parent_waiting_for_its_own_parent_names_the_missing_ancestor() -> void:
	var pending := [_pending_object(BUILDING, PLANET)]
	var where: Dictionary = CLIENT.object_whereabouts(BUILDING, NetBacklog.new(), {}, pending)
	assert_eq(where["state"], "orphan")
	assert_eq(where["parent_id"], PLANET)
	assert_eq(where["parent"], {"state": "never"})
	var text: String = CLIENT.spawn_failure_message("me", BUILDING, where)
	assert_string_contains(text, BUILDING)
	assert_string_contains(text, PLANET)


func test_a_chain_of_waiting_parents_names_its_end() -> void:
	var pending := [_pending_object(BUILDING, "pad"), _pending_object("pad", PLANET)]
	var where: Dictionary = CLIENT.object_whereabouts(BUILDING, NetBacklog.new(), {}, pending)
	assert_string_contains(CLIENT.spawn_failure_message("me", BUILDING, where), PLANET,
			"the ancestor really missing, not the one in between")


func test_a_cycle_of_parents_does_not_hang() -> void:
	var pending := [_pending_object("a", "b"), _pending_object("b", "a")]
	var where: Dictionary = CLIENT.object_whereabouts("a", NetBacklog.new(), {}, pending)
	assert_eq(where["state"], "orphan")
	assert_ne(CLIENT.spawn_failure_message("me", "a", where), "")


func test_a_parent_never_received_keeps_its_wording() -> void:
	var where: Dictionary = CLIENT.object_whereabouts(BUILDING, NetBacklog.new(), {}, [])
	assert_eq(where, {"state": "never"})
	assert_eq(CLIENT.spawn_failure_message("me", BUILDING, where),
			TranslationServer.translate("%%ERR_NO_PARENT") % BUILDING)


func test_no_creation_of_our_own_player_says_so() -> void:
	assert_eq(CLIENT.spawn_failure_message("me", "", {}), TranslationServer.translate("%%ERR_NO_PLAYER") % "me")


func test_a_client_too_slow_is_told_so() -> void:
	var text: String = CLIENT.spawn_too_slow_message(187, 4321)
	assert_string_contains(text, "187")
	assert_string_contains(text, "4321")
