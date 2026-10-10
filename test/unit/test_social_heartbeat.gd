extends GutTest
## The service-social heartbeat's payload shapes and its name bounds, unit-tested without a scene
## tree: what GameServer.social_presence_location builds (through [method
## SocialHeartbeat.build_location]) and the [code]displayName[/code] service-social enforces (2..32
## characters).
##
## Those two are the whole failure surface of "presence doesn't work":
##   • a displayName outside the bounds is REJECTED outright, so the profile upsert must skip rather
##     than fail once per join — and an id social never saw comes back "unknown" in the batch answer,
##     with the player staying offline forever;
##   • the location shape is pinned so a field renamed in the openapi shows up HERE, not as a 400
##     once a minute on a live server.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_social_heartbeat.gd -gexit

const SOCIAL_HEARTBEAT := preload("res://server/social_heartbeat.gd")


func test_location_on_a_planet_carries_system_scene_and_true_position() -> void:
	var location: Dictionary = SOCIAL_HEARTBEAT.build_location(
			"tarsis", "tarsis_3", Vector3(1.5, -2.0, 3.25))
	assert_eq(location["system"], "tarsis")
	assert_eq(location["scene"], "tarsis_3")
	var position: Dictionary = location["position"]
	assert_eq(position["x"], 1.5)
	assert_eq(position["y"], -2.0)
	assert_eq(position["z"], 3.25)


func test_location_in_open_space_is_empty_system_and_space_scene() -> void:
	var location: Dictionary = SOCIAL_HEARTBEAT.build_location("", "space", Vector3.ZERO)
	assert_eq(location["system"], "")
	assert_eq(location["scene"], "space")
	assert_eq(location["position"], {"x": 0.0, "y": 0.0, "z": 0.0})


func test_a_non_finite_coordinate_becomes_zero() -> void:
	# A body mid-transfer or not yet placed can still carry INF (the resend marker in server.gd).
	# JSON has no INF — it would serialise as null and make social reject the whole batch, taking
	# every OTHER player's presence with it.
	var location: Dictionary = SOCIAL_HEARTBEAT.build_location("tarsis", "tarsis_3",
			Vector3(INF, -INF, 1.0))
	assert_eq(location["position"], {"x": 0.0, "y": 0.0, "z": 1.0})


func test_a_nan_coordinate_becomes_zero() -> void:
	var location: Dictionary = SOCIAL_HEARTBEAT.build_location("", "space",
			Vector3(NAN, NAN, NAN))
	assert_eq(location["position"], {"x": 0.0, "y": 0.0, "z": 0.0})


func test_a_planet_wide_position_is_kept_whole() -> void:
	# Astronomic coordinates are NOT an overflow: SandBox sits ~9.5e10 m out, so the payload must
	# pass these through untouched rather than clamping what is a perfectly good distance.
	var location: Dictionary = SOCIAL_HEARTBEAT.build_location("tarsis", "tarsis_3",
			Vector3(2.87715075e10, -1.41729725e10, 7.66766425e10))
	assert_almost_eq(location["position"]["x"], 2.87715075e10, 1.0)
	assert_almost_eq(location["position"]["z"], 7.66766425e10, 1.0)


func test_display_name_is_trimmed() -> void:
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("  Bob  "), "Bob")
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("Bob"), "Bob")


func test_display_name_is_cut_to_thirty_two_characters() -> void:
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("a".repeat(40)).length(), 32)
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("a".repeat(32)).length(), 32)


func test_display_name_too_short_is_dropped() -> void:
	# "" tells the caller to skip the profile upsert entirely — a rejected name would fail on
	# every join, forever.
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name(""), "")
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("  "), "")
	assert_eq(SOCIAL_HEARTBEAT.sanitize_display_name("A"), "")


func test_unknown_ids_of_a_batch_answer() -> void:
	# The silent killer: 200 OK, but ids the service does not know — nobody ever shows online.
	assert_eq(SOCIAL_HEARTBEAT._unknown_ids_of(
			{"data": {"unknown": ["b", "a"]}}), "a, b")
	assert_eq(SOCIAL_HEARTBEAT._unknown_ids_of({"data": {"unknown": []}}), "")
	assert_eq(SOCIAL_HEARTBEAT._unknown_ids_of({"data": {"accepted": ["a"]}}), "")
	assert_eq(SOCIAL_HEARTBEAT._unknown_ids_of({"data": null}), "")
	assert_eq(SOCIAL_HEARTBEAT._unknown_ids_of(null), "")
