extends GutTest
## MusicTable / MusicRule / MusicPlaylist / MusicPoi / MusicZone: which playlist goes with where the
## player is, decided from plain values — no world, no audio.

const DIRECTOR := preload("res://scenes/audio/music/music_director.gd")

var _menu: MusicPlaylist = null
var _space: MusicPlaylist = null
var _city: MusicPlaylist = null
var _table: MusicTable = null


func before_each() -> void:
	_menu = MusicPlaylist.new()
	_space = MusicPlaylist.new()
	_city = MusicPlaylist.new()
	_table = MusicTable.new()
	_table.rules = [
		_rule(MusicRule.Situation.MENU, "", _menu),
		_rule(MusicRule.Situation.ZONE, "capital", _city),
		_rule(MusicRule.Situation.EVA, "", _space),
		_rule(MusicRule.Situation.STATION, "", _space),
		_rule(MusicRule.Situation.POI, "city", _city),
		_rule(MusicRule.Situation.WILD, "", null),
	]


func _rule(situation: MusicRule.Situation, only: String, playlist: MusicPlaylist) -> MusicRule:
	var rule: MusicRule = MusicRule.new()
	rule.situation = situation
	rule.only = only
	rule.playlist = playlist
	return rule


func _on_ground(poi: Dictionary = {}) -> MusicContext:
	var context: MusicContext = MusicContext.new()
	context.on_ground = true
	context.poi = poi
	return context


## The table the game ships, as MusicDirector loads it.
func _shipped() -> MusicTable:
	return load("res://scenes/audio/music/music_table.tres") as MusicTable


func test_without_a_player_it_is_the_menu() -> void:
	var context: MusicContext = MusicContext.new()
	context.in_menu = true
	context.floating = true
	assert_eq(_table.playlist_for(context), _menu, "the menu rule is the only one that fits the menu")


func test_the_menu_rule_does_not_follow_the_player_into_the_world() -> void:
	assert_null(_table.playlist_for(_on_ground()), "in the wild the table says silence")


func test_weightless_plays_the_space_playlist() -> void:
	var context: MusicContext = MusicContext.new()
	context.floating = true
	assert_eq(_table.playlist_for(context), _space, "EVA")


func test_a_station_and_an_eva_share_one_playlist() -> void:
	var aboard: MusicContext = MusicContext.new()
	aboard.station_id = "tarsis_3/palaka_pital"
	var outside: MusicContext = MusicContext.new()
	outside.station_id = "tarsis_3/palaka_pital"
	outside.floating = true
	assert_same(_table.playlist_for(aboard), _table.playlist_for(outside), "stepping out restarts nothing")


func test_a_poi_is_matched_by_its_type() -> void:
	var context: MusicContext = _on_ground({"name": "whatever_01", "kind": "City", "radius_m": 1000.0})
	assert_eq(_table.playlist_for(context), _city, "poi_type, case ignored")


func test_a_poi_is_matched_by_the_start_of_its_name() -> void:
	_table.rules[4].only = "major_railway_city_"
	var context: MusicContext = _on_ground({"name": "major_railway_city_08", "kind": "", "radius_m": 1000.0})
	assert_eq(_table.playlist_for(context), _city, "the records with an empty poi_type are told by name")


func test_a_poi_no_rule_names_falls_through_to_nothing() -> void:
	var context: MusicContext = _on_ground({"name": "mining_village_02", "kind": "mining village"})
	assert_null(_table.playlist_for(context), "not a city, and WILD does not cover a POI")


func test_the_first_rule_that_fits_wins() -> void:
	var context: MusicContext = _on_ground({"name": "c", "kind": "city"})
	context.zone_tag = &"Capital"
	_table.rules[1].playlist = _space
	assert_eq(_table.playlist_for(context), _space, "the zone rule stands above the POI rule")


func test_a_zone_with_another_tag_is_not_the_capital() -> void:
	var context: MusicContext = _on_ground()
	context.zone_tag = &"bar"
	assert_null(_table.playlist_for(context), "falls through to WILD")


func test_a_playlist_on_the_zone_itself_wins_over_the_table() -> void:
	var own: MusicPlaylist = MusicPlaylist.new()
	var context: MusicContext = MusicContext.new()
	context.floating = true
	context.zone_playlist = own
	assert_eq(_table.playlist_for(context), own, "the scene's exception")


func test_a_rule_without_playlist_is_a_chosen_silence() -> void:
	_table.rules.append(_rule(MusicRule.Situation.ANYWHERE, "", _space))
	assert_null(_table.playlist_for(_on_ground()), "WILD wins with nothing to play, the catch-all is not reached")


func test_shuffle_never_repeats_a_track() -> void:
	var a: AudioStream = AudioStreamWAV.new()
	var b: AudioStream = AudioStreamWAV.new()
	_menu.tracks = [a, b]
	var previous: AudioStream = null
	for i in 20:
		var track: AudioStream = _menu.next_after(previous)
		assert_ne(track, previous, "draw %d" % i)
		previous = track


func test_in_order_goes_round_the_list() -> void:
	var a: AudioStream = AudioStreamWAV.new()
	var b: AudioStream = AudioStreamWAV.new()
	_menu.tracks = [a, null, b]
	_menu.shuffle = false
	assert_eq(_menu.next_after(null), a, "starts at the top")
	assert_eq(_menu.next_after(a), b, "an empty slot is skipped")
	assert_eq(_menu.next_after(b), a, "and back to the top")


func test_a_single_track_plays_again_and_an_empty_playlist_plays_nothing() -> void:
	var a: AudioStream = AudioStreamWAV.new()
	_menu.tracks = [a]
	assert_eq(_menu.next_after(a), a, "one track")
	assert_null(_space.next_after(null), "no track")


func test_the_gap_stays_between_its_bounds_in_either_order() -> void:
	_menu.gap_min_s = 90.0
	_menu.gap_max_s = 30.0
	for i in 20:
		assert_between(_menu.draw_gap(), 30.0, 90.0, "draw %d" % i)


func test_the_smallest_influence_sphere_holding_the_player_wins() -> void:
	var here: Vector3 = Vector3(0.0, 0.0, 1.0)
	var pois: Array[Dictionary] = [
		{"name": "city", "radius_m": 25000.0, "dir": here},
		{"name": "village", "radius_m": 1000.0, "dir": here},
		{"name": "far", "radius_m": 1000.0, "dir": Vector3(1.0, 0.0, 0.0)},
	]
	assert_eq(MusicPoi.containing(pois, here, 6356000.0)["name"], "village", "nested spheres")
	# 2 km along the ground from the centre: out of the village, still in the city.
	var aside: Vector3 = here.rotated(Vector3.UP, 2000.0 / 6356000.0)
	assert_eq(MusicPoi.containing(pois, aside, 6356000.0)["name"], "city", "outside the small one")
	assert_true(MusicPoi.containing(pois, Vector3(0.0, 1.0, 0.0), 6356000.0).is_empty(), "the wild")


func test_the_shipped_table_loads_and_has_music_for_the_menu() -> void:
	var shipped: MusicTable = _shipped()
	assert_not_null(shipped, "music_table.tres is a MusicTable")
	var context: MusicContext = MusicContext.new()
	context.in_menu = true
	var playlist: MusicPlaylist = shipped.playlist_for(context)
	assert_not_null(playlist, "the menu has a playlist")
	assert_not_null(playlist.next_after(null), "with a track that loads")


## The places with music of their own in the shipped table: a zone tagged shop, corpo_hall, combat or
## ship (a MusicZone a level designer puts in a scene), and the mining and factory villages.
func test_the_shipped_table_has_music_for_zones_and_villages() -> void:
	var shipped: MusicTable = _shipped()
	var by_tag: Dictionary = {}
	for tag: String in ["shop", "corpo_hall", "combat", "ship"]:
		var zone: MusicContext = _on_ground()
		zone.zone_tag = StringName(tag)
		by_tag[tag] = shipped.playlist_for(zone)
		assert_not_null(by_tag[tag], "a '%s' zone has its playlist" % tag)
		if by_tag[tag] != null:
			assert_not_null((by_tag[tag] as MusicPlaylist).next_after(null), "with a track that loads")
	assert_same(by_tag.shop, by_tag.corpo_hall, "shops and corporate halls share one playlist")
	for poi_name: String in ["mining_village_02", "factory_village_01"]:
		var village: MusicContext = _on_ground({"name": poi_name, "kind": "", "radius_m": 1000.0})
		var playlist: MusicPlaylist = shipped.playlist_for(village)
		assert_not_null(playlist, "%s is no longer a chosen silence" % poi_name)
		if playlist != null:
			assert_not_null(playlist.next_after(null), "with a track that loads")


## The tarsis_3 export names its villages M0042, F0001: only their poi_type says what they are, so the
## QGIS types have to be in the shipped table on their own, not just as name prefixes.
func test_the_shipped_table_knows_the_qgis_poi_types() -> void:
	var shipped: MusicTable = _shipped()
	for kind: String in ["mining village", "factory village"]:
		var village: MusicContext = _on_ground({"name": "M0042", "kind": kind, "radius_m": 1000.0})
		assert_not_null(shipped.playlist_for(village), "a '%s' plays the village music" % kind)
	for kind: String in ["city", "railway city"]:
		var town: MusicContext = _on_ground({"name": "X0001", "kind": kind, "radius_m": 1000.0})
		assert_null(shipped.playlist_for(town), "a '%s' is a chosen silence" % kind)


func test_overlapping_zones_are_settled_by_priority() -> void:
	var building: MusicZone = add_child_autofree(MusicZone.new())
	var room: MusicZone = add_child_autofree(MusicZone.new())
	room.priority = 1
	assert_eq(MusicZone.strongest([building, room, autofree(Area3D.new())]), room, "the room inside the building")
	assert_null(MusicZone.strongest([]), "no zone")
	assert_false(building.monitoring, "passive: the player's detector does the looking")
	assert_true(building.is_in_group(MusicZone.GROUP), "tagged for whoever lists them")


func test_the_director_starts_on_the_menu_playlist_and_on_the_menu_music_bus() -> void:
	_menu.tracks = [AudioStreamWAV.new()]
	var director: Node = add_child_autofree(DIRECTOR.new())
	director.table = _table
	director.start()
	var voices: Array[Node] = director.get_children()
	assert_eq(voices.size(), 1, "one voice")
	var voice: AudioStreamPlayer = voices[0] as AudioStreamPlayer
	assert_eq(voice.stream, _menu.tracks[0], "no player to follow: the menu")
	assert_eq(voice.bus, &"MenuMusic", "the Menu music slider drives it, and the Music one through its send")


func test_the_table_says_which_rule_won_and_the_context_what_it_saw() -> void:
	var context: MusicContext = _on_ground({"name": "major_railway_city_08", "kind": "city"})
	assert_eq(_table.why(context), "rule 4: POI 'city'", "numbered as the Inspector lists them")
	assert_eq(context.describe(), "POI major_railway_city_08 (city)", "what the rules had to match")
	context.zone_tag = &"bar"
	context.zone_playlist = _space
	assert_eq(_table.why(context), "the zone's own playlist", "the scene's exception says so")
	assert_eq(MusicContext.new().describe(), "in space", "nothing at all is still a place")
	_table.rules.clear()
	assert_eq(_table.why(_on_ground()), "no rule fits", "and silence has a reason too")


func test_a_rule_names_itself_from_what_it_holds() -> void:
	var rule: MusicRule = MusicRule.new()
	assert_eq(rule.resource_name, "ANYWHERE → silence", "named from the start")
	rule.situation = MusicRule.Situation.POI
	rule.only = "village mining"
	assert_eq(rule.resource_name, "POI village mining → silence", "and again at each change")
	var shipped: MusicTable = _shipped()
	assert_eq(shipped.rules[0].resource_name, "MENU → menu", "the playlist is named by its file")


## Arriving in a town freezes the client a few hundred milliseconds at a time: a Tween counted those
## frames in full, and the 4 s crossfade went by in a handful of them — the track cut off dead
## (preprod, 2026-10-05). A long frame now only delays the fade.
func test_a_frozen_frame_delays_the_crossfade_instead_of_skipping_it() -> void:
	_menu.tracks = [AudioStreamWAV.new()]
	_city.tracks = [AudioStreamWAV.new()]
	var director: Node = add_child_autofree(DIRECTOR.new())
	director.table = _table
	director.start()
	var old: AudioStreamPlayer = director.get_children()[0] as AudioStreamPlayer
	for i in 200:
		director._step_fades(0.05)  # the menu track fully faded in
	assert_almost_eq(old.volume_linear, 1.0, 0.001)
	director.set_override(_city)
	director._step_fades(3.0)  # a three-second freeze
	assert_gt(old.volume_linear, 0.95, "the old track barely moved: the freeze is not counted")
	assert_false(old.is_queued_for_deletion(), "still fading out")
	for i in 100:
		director._step_fades(0.05)  # five seconds of normal frames
	assert_true(old.is_queued_for_deletion(), "faded out to the end, then freed")
