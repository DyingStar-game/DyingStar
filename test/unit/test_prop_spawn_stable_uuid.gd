extends GutTest
## Suite for [method PropSpawn.stable_uuid] — the ids of the world infrastructure (villages, depots,
## shelves, mining zones, vehicle bays, stations):
##
##   · the same seed always gives the same uuid;
##   · it is a version 5 uuid (RFC 9562), which the services that check a uuid strictly accept;
##   · it is the standard one: the values below come from Python's `uuid.uuid5` on the same namespace.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_prop_spawn_stable_uuid.gd

## An RFC 9562 uuid of version 5: version digit 5, variant digit 8, 9, a or b.
const V5 := "^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"


func test_same_seed_same_uuid() -> void:
	assert_eq(PropSpawn.stable_uuid("tarsis_3|cliff_lift|1"), PropSpawn.stable_uuid("tarsis_3|cliff_lift|1"))
	assert_ne(PropSpawn.stable_uuid("tarsis_3|cliff_lift|1"), PropSpawn.stable_uuid("tarsis_3|cliff_lift|2"))


func test_is_a_version_5_uuid() -> void:
	var re := RegEx.create_from_string(V5)
	for seed_str: String in ["", "station:ares_orbital", "a|b", "%s|platform" % "x".repeat(300)]:
		var id := PropSpawn.stable_uuid(seed_str)
		assert_not_null(re.search(id), "%s for seed '%s'" % [id, seed_str])


func test_matches_the_standard_uuid5() -> void:
	# python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('a0affe13-815e-4162-b78b-e3988ca71339'), '…'))"
	assert_eq(PropSpawn.stable_uuid("station:ares_orbital"), "360a32dd-e20b-5a72-8bbd-e1c1f79dae2c")
	assert_eq(
		PropSpawn.stable_uuid("f87ab025-db9d-5dad-9a19-09f4b96063c2|hab_01"),
		"48352d7d-6ea4-58dd-b509-d9e307ab2ba6")
	assert_eq(PropSpawn.stable_uuid("é|ü"), "f0d6312a-1a66-52aa-ba97-58fff4149c43", "seed read as UTF-8")
	assert_eq(PropSpawn.stable_uuid(""), "a11e8d02-94b8-511c-85be-b7304d6008e2", "an empty seed")
