extends GutTest

const STAR_MAP := preload("res://scenes/ui/star_map/star_map.gd")
const STAR_KEY := "__star__"
const PLAYER_KEY := "__player__"

## StarMapPoi.service_entry: a point of interest of the SERVICE, on the chart beside the level
## design's towns. The two live in different frames — the export writes lon/lat on a unit sphere, the
## service writes an offset from the body's own centre in metres — so the conversion is where the
## whole merge can go wrong, and it is pure, so nothing stops it being checked here.

## A POI of the service, as [method PlayerServices.poi_list] hands one over.
func _poi(overrides: Dictionary = {}) -> Dictionary:
	var poi := {
		"id": "8f2c1a00-0000-4000-8000-000000000001",
		"name": "Livraison Alpha — tarsis_3",
		"description": "Le dépôt du nord",
		"system": "tarsis",
		"scene": "tarsis_3",
		"x": 120.0,
		"y": 6000000.0,
		"z": -35.0,
		"radiusM": 50.0,
		"ownerType": "mission",
		"visibility": "public",
	}
	for key: Variant in overrides:
		poi[key] = overrides[key]
	return poi


## Every key the chart's info card reads DIRECTLY (not with .get): a record missing one of them is
## not a thin record, it is a crash on the first click.
func test_a_converted_poi_answers_every_key_the_info_card_reads() -> void:
	var entry := StarMapPoi.service_entry(_poi(), "tarsis_3")
	for key: String in ["label", "name", "kind", "population", "radius_m", "description",
			"lon", "lat"]:
		assert_true(entry.has(key), "the info card reads poi[\"%s\"] directly" % key)


func test_a_poi_of_the_right_body_is_drawn_at_the_spot_it_names() -> void:
	var entry := StarMapPoi.service_entry(_poi(), "tarsis_3")
	assert_eq(entry["service_id"], "8f2c1a00-0000-4000-8000-000000000001",
			"a click has to be able to name the POI back to the service")
	assert_eq(entry["label"], "Livraison Alpha — tarsis_3",
			"a name a player wrote is shown as written, not through pretty_name")
	assert_eq(entry["kind"], "mission", "the icon table tints by owner")
	assert_eq(entry["owner_type"], "mission")
	assert_eq(entry["radius_m"], 50.0)
	assert_eq(entry["population"], 0)
	# The offset is direction: the chart draws on a sphere, and a direction is what a marker needs.
	assert_almost_eq((entry["dir"] as Vector3).length(), 1.0, 1.0e-6)
	# And lon/lat are the SAME direction, read the other way round: the card prints them.
	var back := HEALPix.lonlat2vec(entry["lon"], entry["lat"])
	assert_almost_eq(back.dot(entry["dir"]), 1.0, 1.0e-5,
			"lon/lat must name the same spot as the offset, or the card lies about the position")


func test_a_poi_of_another_body_is_not_drawn_here() -> void:
	# The frame rule. `tarsis_1` and `tarsis_10` are two planets that happen to share a prefix, and
	# reading them as one is the bug service-inventory reports as POI_SCENE_SYSTEM_MISMATCH.
	assert_true(StarMapPoi.service_entry(_poi(), "tarsis_1").is_empty())
	assert_true(StarMapPoi.service_entry(_poi(), "tarsis_10").is_empty())
	# Off-world has no body to stand on, and this layer draws on bodies only.
	assert_true(StarMapPoi.service_entry(_poi({"scene": ""}), "tarsis_3").is_empty())


func test_a_poi_at_the_centre_is_not_drawn_anywhere() -> void:
	# A zero offset has no direction, and the origin is a spot the star occupies: not "somewhere on
	# the body", which is what a naive normalise would answer with.
	var at_origin := _poi({"x": 0.0, "y": 0.0, "z": 0.0})
	assert_true(StarMapPoi.service_entry(at_origin, "tarsis_3").is_empty())


func test_a_null_field_is_read_as_absent_and_never_as_a_crash() -> void:
	# The service serialises SQL NULL as JSON null, and Dictionary's default only applies to an
	# ABSENT key: poi.get("radiusM", 0.0) returns null for a POI that HAS the key with no radius.
	var blank := _poi({"name": null, "description": null, "radiusM": null, "id": null})
	var entry := StarMapPoi.service_entry(blank, "tarsis_3")
	assert_eq(entry["radius_m"], 0.0, "a null radius is a point")
	assert_eq(entry["description"], "")
	assert_eq(entry["service_id"], "")


func test_an_unnamed_poi_says_so_in_the_player_language_rather_than_showing_an_id() -> void:
	# An uuid is never a label: the same mistake as showing a translation key, which reads as a bug
	# even when nothing is wrong.
	var entry := StarMapPoi.service_entry(_poi({"name": "  "}), "tarsis_3")
	assert_ne(entry["label"], "8f2c1a00-0000-4000-8000-000000000001")
	assert_ne(entry["label"], "")
	assert_eq(entry["label"], TranslationServer.translate("%%SVC_POI_UNNAMED"))


func test_the_export_and_the_service_come_back_as_one_list() -> void:
	# Both sources in ONE list, because the chart's search index stores positions in it: if the
	# export were read alone by one and merged by the other, a result would frame the wrong marker.
	var service := [_poi(), _poi({"scene": "tarsis_1", "id": "other"})]
	var merged := StarMapPoi.merged_for("tarsis_3", service)
	var export_count := StarMapPoi.load_for("tarsis_3").size()
	assert_eq(merged.size(), export_count + 1, "the export's towns, then the one service POI here")
	assert_eq(merged[export_count]["service_id"], "8f2c1a00-0000-4000-8000-000000000001")
	assert_eq(merged[0]["service_id"] if merged[0].has("service_id") else "", "",
			"a town of the export has no service id to give back")


func test_a_search_result_and_a_drawn_list_agree_on_which_marker_is_which() -> void:
	# The one property the merge exists for: an index into the list the chart draws must be the
	# index into the list the search was built from.
	var merged := StarMapPoi.merged_for("tarsis_3", [_poi()])
	for index: int in range(merged.size()):
		var entry: Dictionary = merged[index]
		assert_true(entry.has("label"), "entry %d is drawable and nameable" % index)
		assert_true(entry.has("dir"), "entry %d is placeable" % index)


# ── What a click may put a point on ─────────────────────────────────────────────────────────────

## The chart, never in the tree: these questions are pure, and building the chart's viewport just to
## ask which bodies carry a surface is what the file it lives in avoids doing too.
func _chart() -> StarMap:
	return autofree(STAR_MAP.new()) as StarMap


func test_a_click_may_only_land_on_a_body_that_has_a_surface() -> void:
	# Your own marker and a station are drawn at a fixed size on screen and stand on nothing, and the
	# star is the star. They were all reachable by the placement's ray, and the marker is the one a
	# click near you ALWAYS finds — which answered "point at a planet" while the planet filled the
	# screen underneath it.
	var chart := _chart()
	var planet := {"key": "tarsis_3", "radius_m": 6356000.0}
	assert_true(chart._bears_places(planet), "a planet carries a surface")
	assert_false(chart._bears_places({"key": "tarsis_3", "radius_m": 0.0}),
			"a body with no radius is not a place to put anything")
	assert_false(chart._bears_places({"key": "tarsis_3", "radius_m": 6356000.0, "station": {}}),
			"nor is a station, which hangs above one")
	assert_false(chart._bears_places({"key": STAR_KEY, "radius_m": 1.0e6}), "nor is the star")
	assert_false(chart._bears_places({"key": PLAYER_KEY, "radius_m": 0.0}), "nor is your own marker")


func test_a_chart_with_nobody_to_show_says_no_rather_than_hanging() -> void:
	# A false, never a silent one: the console tells the player the place is not on the chart, and
	# the alternative — an open chart showing nothing — is indistinguishable from a broken one.
	var chart := _chart()
	# `await` on both: focus_service_poi travels and waits for the layer, so it is a coroutine, and
	# a coroutine handed straight to an assertion is an OBJECT — always true — and every one of
	# these would pass while proving nothing.
	#
	# Both take the guard at the top, which is the part a chart out of a tree can answer: an id
	# nobody asked for, and a chart with no camera because it was never in a tree. The travel and
	# the wait need a viewport, so that path is the game's and not this file's.
	assert_false(await chart.focus_service_poi(""))
	assert_false(await chart.focus_service_poi("not-in-this-session"))


func test_a_point_the_chart_has_no_record_of_is_not_an_entry() -> void:
	# The lookup on its own — pure, no camera, no service, no coroutine. It answers {} for a point
	# this session has never held, which is the answer that makes [method focus_service_poi] go and
	# FETCH one rather than telling the player it does not exist.
	var chart := _chart()
	assert_true(chart._service_poi_entry("not-in-this-session").is_empty())
	assert_true(chart._service_poi_entry("").is_empty())


# ── One gesture, one switch ─────────────────────────────────────────────────────────────────────

func test_arming_to_choose_also_arms_placing_and_one_end_takes_both() -> void:
	# The mission builder asks to be able to CHOOSE a point that already exists, and the chart still
	# needs to place one when the click lands on bare ground: the same gesture, the same question
	# ("where"), so the two answers share a switch. The points of interest form asks only to place,
	# which is why the two are separate flags under one end.
	var chart := _chart()
	assert_false(chart.is_placing_poi(), "disarmed until somebody asks")
	assert_false(chart.is_picking_poi())
	chart.begin_poi_pick(50.0)
	assert_true(chart.is_picking_poi(), "pointing at an existing POI is now an answer")
	assert_true(chart.is_placing_poi(), "and placing one still is")
	chart.end_poi_place()
	assert_false(chart.is_picking_poi(), "whoever asked came for a place; either answer ends it")
	assert_false(chart.is_placing_poi())

	chart.begin_poi_place(0.0)
	assert_true(chart.is_placing_poi())
	assert_false(chart.is_picking_poi(), "the points of interest form places, it does not choose")
	chart.end_poi_place()
