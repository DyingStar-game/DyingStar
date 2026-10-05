extends GutTest
## A station as a teleporter destination: it travels by uuid (it has no ground and does not stay above
## one), round-trips the wire, and the catalog offers it first.


func _site() -> StationSite:
	var site := StationSite.new()
	site.id = "tarsis_3/test"
	site.body_key = "tarsis_3"
	site.proper_name = "Test"
	return site


func test_a_station_destination_round_trips_the_wire() -> void:
	var dest := TeleportDestination.to_station(_site(), "tarsis_3")
	var back := TeleportDestination.from_payload(dest.to_payload())
	assert_true(back.is_station(), "still a station on the other side")
	assert_eq(back.station_uuid, _site().uuid(), "same uuid")
	assert_eq(back.kind, TeleportDestination.Kind.STATION, "kind rebuilt from the uuid")
	assert_true(back.is_valid(), "no lon/lat to validate — the server checks the uuid")


func test_a_ground_destination_is_not_a_station() -> void:
	var dest := TeleportDestination.new("x", "tarsis_3", 10.0, 20.0, 2.0)
	var back := TeleportDestination.from_payload(dest.to_payload())
	assert_false(back.is_station(), "an empty uuid is a ground trip")
	assert_true(back.is_valid())


func test_an_old_payload_without_station_still_reads() -> void:
	var back := TeleportDestination.from_payload({"planet": "tarsis_3", "lon": 1.0, "lat": 2.0})
	assert_false(back.is_station(), "a client from before stations sends no uuid")
	assert_true(back.is_valid())


func test_the_catalog_describes_the_sandbox_station() -> void:
	# Sandbox's figures, not its scene: loading tarsis_3.tscn drags in every dependency and their load
	# errors, which GUT counts against the test.
	var sandbox := {"map_radius_km": 6356.0, "orbit_mass_earths": 0.788, "rotation_period_hours": 25.0,
			"axial_tilt_deg": 15.0}
	var sites: Array[StationSite] = StationSites.for_body("tarsis", "tarsis_3")
	assert_eq(sites.size(), 1, "the Palaka-Pital station")
	var dest := TeleportCatalog.station_destination(sites[0], "tarsis_3", sandbox)
	assert_true(dest.is_station())
	assert_eq(dest.station_uuid, sites[0].uuid())
	assert_string_contains(dest.detail, "400 km", "its orbit is described")


## A station nobody is near sleeps in the server's registry: the trip wakes it rather than refusing it
## ("not on this server" was every trip to the station from the planet).
func test_a_sleeping_station_is_woken_for_the_trip() -> void:
	var station := OrbitalStation.new()
	var asleep := _server_holding(null, station)
	assert_same(Teleporter.find_station(asleep, "s"), station, "woken from the registry")
	assert_eq(asleep.get("woken"), ["s"])
	var live := _server_holding(station, null)
	assert_same(Teleporter.find_station(live, "s"), station, "already live: nothing to wake")
	assert_eq(live.get("woken"), [])
	assert_null(Teleporter.find_station(_server_holding(null, null), "s"), "unknown here: refused")
	assert_null(Teleporter.find_station(null, "s"), "no server")
	station.free()


## A stand-in for the game server: [param live] is what its scene holds, [param sleeping] what waking
## the uuid gives.
func _server_holding(live: Node, sleeping: Node) -> Object:
	var script := GDScript.new()
	script.source_code = "\n".join([
		"extends RefCounted",
		"var live: Node",
		"var sleeping: Node",
		"var woken: Array = []",
		"func _search_parent_node(_uuid: String) -> Node:",
		"\treturn live",
		"func wake_prop(uuid: String) -> Node:",
		"\twoken.append(uuid)",
		"\treturn sleeping",
	])
	script.reload()
	var server: RefCounted = script.new()
	server.set("live", live)
	server.set("sleeping", sleeping)
	return server
