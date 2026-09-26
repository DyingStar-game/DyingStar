extends GutTest

## The star chart: the contract it owes [code]PlayerClient[/code], the points of interest it reads from
## the level design's export, and the search that makes an unreachable body reachable.
##
## Preloading the chart script is deliberate: it is the only thing in the suite that forces the whole
## screen to compile, and a screen that no longer compiles is a bug nobody sees until F2 is pressed.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map.gd

const STAR_MAP := preload("res://scenes/ui/star_map/star_map.gd")

## A body that certainly carries points of interest. Picked rather than "whatever comes first" so a
## failure names one thing; tarsis_3 is the only populated one today and it is the one you spawn on.
const POI_BODY: String = "tarsis_3"
## A body whose file exists but is an empty shell — the normal case for eighteen of the nineteen.
const EMPTY_POI_BODY: String = "tarsis_8"


# ---------------------------------------------------------------------------
# The contract with PlayerClient
# ---------------------------------------------------------------------------

## PlayerClient builds the chart, toggles it on F2 and asks whether it is open to decide if the game
## keys are locked. Renaming any of these four quietly turns the chart, or the input lock, into a no-op.
func test_the_chart_keeps_the_four_methods_player_client_calls() -> void:
	# Typed as Script, not as the class: calling a non-static method straight on a class_name is a
	# parse error, and preload() of a script carrying one resolves to the class.
	var script: Script = STAR_MAP
	var names: Array = []
	for method: Dictionary in script.get_script_method_list():
		names.append(str(method["name"]))
	for required: String in ["setup", "open", "close", "is_open"]:
		assert_true(names.has(required),
				"PlayerClient calls StarMap.%s(); it has to still exist" % required)


# ---------------------------------------------------------------------------
# Points of interest
# ---------------------------------------------------------------------------

## The chart reads the QGIS export directly, so the towns it marks are the towns the world has. If this
## breaks, it is because the pipeline changed its output — which is exactly what we want to hear about.
func test_points_of_interest_are_read_from_the_level_design_export() -> void:
	var pois: Array[Dictionary] = StarMapPoi.load_for(POI_BODY)
	assert_gt(pois.size(), 0, "%s ships points of interest" % POI_BODY)
	for poi: Dictionary in pois:
		assert_true(poi.has("dir"), "every record resolves to a ground direction")
		assert_almost_eq((poi["dir"] as Vector3).length(), 1.0, 0.0001,
				"and that direction is a unit vector, ready to multiply by a drawn radius")
		assert_true(float(poi["lat"]) >= -90.0 and float(poi["lat"]) <= 90.0,
				"latitude stays in EPSG:4326 range")


## A body with an empty file, and a body with no file at all, are both simply "nothing to draw". Neither
## may raise: the chart shows all nineteen bodies and most of them have nothing to say.
func test_a_body_without_points_of_interest_is_silent() -> void:
	assert_eq(StarMapPoi.load_for(EMPTY_POI_BODY).size(), 0)
	assert_eq(StarMapPoi.load_for("no_such_body").size(), 0)
	assert_eq(StarMapPoi.load_for("").size(), 0)


## The export writes pipeline identifiers, not labels. Showing one raw reads as a bug even when nothing
## is wrong — the same mistake as leaving a translation key on screen.
func test_identifiers_are_turned_into_labels() -> void:
	assert_eq(StarMapPoi.pretty_name("mining_village_02"), "Mining village 02")
	assert_eq(StarMapPoi.pretty_name("factory_village_01"), "Factory village 01")
	assert_eq(StarMapPoi.pretty_name("  spaceport-hq  "), "Spaceport HQ")
	assert_eq(StarMapPoi.pretty_name(""), "", "an unnamed site gets no invented name")


## A sphere is opaque to the eye but not to a billboard drawn without depth testing. Without this test
## the night side's towns read straight through the globe and the chart shows twice as many as exist.
func test_points_on_the_far_side_are_hidden() -> void:
	var camera: Vector3 = Vector3(0.0, 0.0, 10.0)
	var near_side: Vector3 = Vector3(0.0, 0.0, 1.0)
	var far_side: Vector3 = Vector3(0.0, 0.0, -1.0)
	assert_true(StarMapPoi.faces_camera(near_side, near_side, camera))
	assert_false(StarMapPoi.faces_camera(far_side, far_side, camera))


## Every real record on tarsis_3 must land on a picture, and on the RIGHT one. Checked against the names
## the export actually writes rather than against invented ones: the mapping's whole difficulty is that
## twenty-two of the twenty-seven carry a blank poi_type and are identified by name alone.
func test_every_real_site_gets_the_right_picture() -> void:
	var expected: Dictionary = {
		"Palaka-Pital": "capital.png",
		"major_airport_city_03": "spaceport.png",
		"major_railway_city_08": "railway_station.png",
		"mining_village_02": "mining_village.png",
		"factory_village_01": "industrial_village.png",
	}
	for raw_name: String in expected:
		var poi: Dictionary = {"name": raw_name, "kind": ""}
		var icon: Texture2D = StarMapPoiLayer.ICONS.icon_for(poi)
		assert_not_null(icon, "%s must get a picture" % raw_name)
		assert_true(icon.resource_path.ends_with(str(expected[raw_name])),
				"%s should be drawn as %s, not %s" % [raw_name, expected[raw_name],
				icon.resource_path])


## An unforeseen kind of site still gets a picture. A marker that silently fails to draw looks exactly
## like a hole in the export, and would be chased there instead of here.
func test_an_unforeseen_site_still_gets_a_picture() -> void:
	var icon: Texture2D = StarMapPoiLayer.ICONS.icon_for({"name": "brand_new_thing", "kind": ""})
	assert_not_null(icon, "the fallback picture has to be set on the resource")


## The panel has to be able to say WHAT a place is. Reading the export alone it could not: the field is
## blank on twenty-two records, which is most of them.
func test_a_blank_poi_type_still_yields_a_kind() -> void:
	var poi: Dictionary = {"name": "major_railway_city_08", "kind": ""}
	assert_ne(StarMapPoiLayer.ICONS.kind_label(poi), "",
			"the icon table names the kind that the export left empty")


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

## Identifiers and labels have to collapse to the same string, or a player has to guess which spelling
## the chart wants.
func test_identifiers_and_labels_search_alike() -> void:
	assert_eq(StarMapSearch.normalise("mining_village_02"), "mining village 02")
	assert_eq(StarMapSearch.normalise("Mining Village 02"), "mining village 02")


## Accents are folded, so a name can be found without them and a French keyboard is never a handicap.
func test_accents_do_not_hide_a_result() -> void:
	assert_eq(StarMapSearch.normalise("Palaka-Pitál"), "palaka pital")
	assert_ne(StarMapSearch.score("pital", StarMapSearch.normalise("Palaka-Pitál")),
			StarMapSearch.NO_MATCH)


## A player typing "tar" wants Tarsis itself before anything merely containing the letters.
func test_results_are_ordered_best_first() -> void:
	var entries: Array[Dictionary] = [
		{"label": "Outer Tarsis Relay"},
		{"label": "Tarsis"},
		{"label": "Tarsis VIII"},
	]
	var order: Array[int] = StarMapSearch.rank("tarsis", entries)
	assert_eq(order.size(), 3, "all three contain it")
	assert_eq(order[0], 1, "the exact name comes first")
	assert_eq(order[1], 2, "then the one that starts with it")
	assert_eq(order[2], 0, "and the one that merely contains it comes last")


## The underlying key is searchable too. "SandBox - Tarsis III" and "tarsis_3" share not one letter, and
## both are names somebody might type.
func test_the_underlying_key_is_searchable() -> void:
	var entries: Array[Dictionary] = [{"label": "SandBox - Tarsis III", "alt": "tarsis_3"}]
	assert_eq(StarMapSearch.rank("tarsis_3", entries), [0] as Array[int])
	assert_eq(StarMapSearch.rank("sandbox", entries), [0] as Array[int])


## An empty box shows nothing rather than everything: a results list that appears the moment the field
## is focused covers the chart for no reason.
func test_an_empty_query_returns_nothing() -> void:
	assert_eq(StarMapSearch.rank("", [{"label": "Tarsis"}] as Array[Dictionary]).size(), 0)
	assert_eq(StarMapSearch.rank("   ", [{"label": "Tarsis"}] as Array[Dictionary]).size(), 0)


## The list is capped, and the cap has to bite before the panel grows taller than the screen.
func test_the_result_list_is_capped() -> void:
	var entries: Array[Dictionary] = []
	for i: int in range(40):
		entries.append({"label": "Station %02d" % i})
	assert_eq(StarMapSearch.rank("station", entries).size(), StarMapSearch.MAX_RESULTS)


# ---------------------------------------------------------------------------
# Scale bar
# ---------------------------------------------------------------------------

## A scale bar exists to be measured against by eye, and the eye can only do that with numbers it can
## halve and double. "187 km" on a bar is noise.
func test_the_scale_bar_picks_a_speakable_length() -> void:
	assert_eq(StarMapScale.nice_length(187000.0), 100000.0)
	assert_eq(StarMapScale.nice_length(640.0), 500.0)
	assert_eq(StarMapScale.nice_length(2.7), 2.0)
	assert_eq(StarMapScale.nice_length(1.0), 1.0)


## Whatever it rounds to, the bar must stay a usable fraction of the width it was aiming for: never
## longer than asked (it would run off the corner) and never so short it cannot be read.
func test_the_bar_stays_a_usable_length() -> void:
	var asked: float = 1.0
	for _i: int in range(60):
		var got: float = StarMapScale.nice_length(asked)
		assert_lte(got, asked, "never longer than the room it has")
		assert_gt(got, asked * 0.19, "and never a fifth of it either")
		asked *= 1.37


## Degenerate inputs come up for real: the very first frame has no camera distance yet.
func test_a_meaningless_scale_draws_nothing() -> void:
	assert_eq(StarMapScale.nice_length(0.0), 0.0)
	assert_eq(StarMapScale.nice_length(-5.0), 0.0)
	assert_eq(StarMapScale.nice_length(INF), 0.0)


## Metres below a kilometre, kilometres above — and written here rather than pushed through
## Globals.format_distance, which says "million km" in English whatever the language is set to.
func test_the_bar_is_labelled_in_plain_units() -> void:
	assert_eq(StarMapScale.label_for(500.0), "500 m")
	assert_eq(StarMapScale.label_for(1000.0), "1 km")
	assert_eq(StarMapScale.label_for(100000.0), "100 km")
	assert_true(StarMapScale.label_for(2.5e9).ends_with(" km"),
			"even the widest views stay in kilometres, which everyone can picture")


## The badge has to land on the town, and the only way it can miss is a convention mismatch: the export
## writes EPSG:4326 lon/lat, the chart turns that into a direction with HEALPix, and the game turns a
## direction back into lon/lat the same way for its own HUD. A round trip over every real record is
## what says the two agree — a sign or an axis swapped would put a village in the wrong hemisphere and
## look, on screen, merely like odd level design.
func test_every_town_round_trips_through_its_coordinates() -> void:
	var pois: Array[Dictionary] = StarMapPoi.load_for(POI_BODY)
	assert_gt(pois.size(), 0, "%s ships points of interest" % POI_BODY)
	for poi: Dictionary in pois:
		var back: Vector2 = HEALPix.vec2lonlat(poi["dir"])
		assert_almost_eq(back.y, float(poi["lat"]), 0.0001,
				"latitude survives the trip for %s" % poi["name"])
		# Longitude wraps, so compare the angle rather than the number.
		assert_lt(absf(angle_difference(deg_to_rad(back.x), deg_to_rad(float(poi["lon"])))), 0.0001,
				"longitude survives the trip for %s" % poi["name"])


## Every town carries its own ground height, worked out once when the body is loaded. Without it the
## badges sit on the reference sphere while the globe around them rises and falls by up to a hundred
## exaggerated km, so they sink into the hills and float over the basins.
func test_every_town_knows_how_high_its_ground_is() -> void:
	if not StarMapRelief.has_data(POI_BODY):
		pending("aucune tuile en cache pour %s sur cette machine" % POI_BODY)
		return
	var seen: Dictionary = {}
	for poi: Dictionary in StarMapPoi.load_for(POI_BODY):
		var at: float = StarMapRelief.surface_factor(POI_BODY, poi["dir"])
		assert_gt(at, 0.9, "a town stands on a surface, not somewhere else")
		assert_lt(at, 1.1, "and not far above one either")
		seen[snappedf(at, 0.0001)] = true
	assert_gt(seen.size(), 1,
			"the towns are not all at the same altitude, so the lookup is reading real ground")


# ---------------------------------------------------------------------------
# Whose ground
# ---------------------------------------------------------------------------

## Pulling the camera back must not throw the relief away.
##
## The chart elects one body for its LABELS — big enough on screen for its town names to be worth
## drawing — and that election drops to -1 as soon as you zoom past the threshold. The ground used to
## live and die by it, so a zoom out destroyed every tile and a zoom back in rebuilt all of them, for a
## view that had not changed body at all. Measured in game: twelve tiles rebuilt from nothing on a zoom
## out and back, and at a fine level that would be up to StarMapRelief.PATCH_TILES_MAX instead.
##
## Instantiated without ever entering a tree, which is why this can be a unit test: the choice reads two
## plain integers and touches nothing that _ready would have set up.
func test_pulling_back_keeps_the_ground_it_already_has() -> void:
	var chart: CanvasLayer = autofree(STAR_MAP.new()) as CanvasLayer
	chart._ground_body = 3

	chart._blocker = 3
	assert_eq(chart._relief_body(), 3, "the elected body, when there is one")
	chart._blocker = 5
	assert_eq(chart._relief_body(), 5, "another body elected, and the ground follows it")
	chart._blocker = -1
	assert_eq(chart._relief_body(), 3,
			"nothing elected: the ground keeps what it has rather than being thrown away")

	chart._ground_body = -1
	assert_eq(chart._relief_body(), -1, "and with no ground at all, there is nothing to keep")
