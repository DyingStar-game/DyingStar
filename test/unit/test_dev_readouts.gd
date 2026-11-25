extends GutTest
## DevReadouts / ClientReadout / EventRate: what the debug panel's sections say, from plain data.

var _saved_offset : float = 0.0
var _cache : ServerInfoCache


func before_each() -> void:
	_saved_offset = Globals.debug_time_offset
	_cache = ServerInfoCache.new()
	add_child_autofree(_cache)


func after_each() -> void:
	Globals.debug_time_offset = _saved_offset


func _zone(planet: String, bounded: bool) -> Dictionary:
	var zone : Dictionary = {"world": "planet", "planet_name": planet}
	if bounded:
		zone["bounds"] = {"min_x": -1.0, "max_x": 1.0, "min_y": -2.0, "max_y": 2.0, "min_z": -3.0, "max_z": 3.0}
	return zone


func test_the_clock_alert_speaks_only_while_the_clock_is_shifted() -> void:
	assert_eq(DevReadouts.clock_alert_text(0.0), "", "nothing to say at the server's time")
	var text : String = DevReadouts.clock_alert_text(12.0 * 3600.0)
	assert_string_contains(text, "+12.0", "the offset is in it")
	assert_false(text.begins_with("%%"), "translated, not the raw key")
	Globals.debug_time_offset = -3.0 * 3600.0
	assert_true(DevReadouts.clock_alert_active(), "active while shifted")
	Globals.debug_time_offset = 0.0
	assert_false(DevReadouts.clock_alert_active(), "and gone once back")


func test_server_values_come_from_the_signals() -> void:
	assert_eq(DevReadouts.server_lines(_cache)[1], "- TPS", "unknown until the server says")
	NetworkOrchestrator.set_gameserver_server_tps.emit(24)
	NetworkOrchestrator.set_gameserver_number_players.emit(9)
	var lines : PackedStringArray = DevReadouts.server_lines(_cache)
	assert_string_contains(lines[1], "24", "TPS")
	assert_string_contains(lines[1], SettingsStyle.ALERT_COLOR.to_html(false), "red under 30")
	assert_eq(lines[2], "9 players", "players")


func test_universe_counts_are_whole_numbers() -> void:
	assert_eq(DevReadouts.universe_lines(null, _cache)[0], "- servers", "unknown until the server says")
	# JSON hands every number over as a float.
	NetworkOrchestrator.set_universe_servers.emit(3.0)
	NetworkOrchestrator.set_universe_players.emit(12.0)
	var lines : PackedStringArray = DevReadouts.universe_lines(null, _cache)
	assert_eq(lines[0], "3 servers", "servers")
	assert_eq(lines[1], "12 players", "players")


func test_the_server_section_names_it_and_ends_on_its_border() -> void:
	var zones : Array = []
	for i in 10:
		zones.append(_zone("P%d" % i, false))
	NetworkOrchestrator.set_gameserver_zones.emit(zones)
	var lines : PackedStringArray = DevReadouts.server_lines(_cache)
	assert_string_contains(lines[0], "server name: ", "its name first")
	assert_eq(lines.size(), 7, "name, TPS, players, objects, scenes, active scenes, border: no zone list")
	assert_eq(lines[-1], "frontière : --", "no body, no camera: no border to measure")


func _box(min_x: float, max_x: float) -> Dictionary:
	return {"world": "planet", "planet_uuid": "T3", "bounds": {
		"min_x": min_x, "max_x": max_x, "min_y": -100.0, "max_y": 100.0, "min_z": -100.0, "max_z": 100.0}}


func test_the_border_is_measured_along_the_camera() -> void:
	var zones : Array = [_box(-100.0, 12.345)]
	var d : float = DevReadouts.border_distance(zones, "T3", Vector3.ZERO, Vector3.RIGHT)
	assert_almost_eq(d, 12.345, 1e-6, "straight to the max X face")
	assert_eq(DevReadouts.border_text(d), "frontière : 12.35 mètres", "two decimals")
	var diagonal : Vector3 = Vector3(1.0, 0.0, 1.0).normalized()
	assert_almost_eq(DevReadouts.border_distance(zones, "T3", Vector3.ZERO, diagonal), 12.345 * sqrt(2.0), 1e-6,
		"the nearest face crossed, not the nearest face")
	assert_almost_eq(DevReadouts.border_distance(zones, "T3", Vector3.ZERO, Vector3.LEFT), 100.0, 1e-6,
		"the other way, the other face")


func test_a_zone_of_the_same_server_is_no_border() -> void:
	var zones : Array = [_box(-10.0, 10.0), _box(10.0, 40.0)]
	assert_almost_eq(DevReadouts.border_distance(zones, "T3", Vector3.ZERO, Vector3.RIGHT), 40.0, 0.1,
		"walked on through the neighbouring zone")


func test_far_whole_or_elsewhere() -> void:
	assert_eq(DevReadouts.border_text(DevReadouts.border_distance([_box(-10.0, 90000.0)], "T3", Vector3.ZERO,
		Vector3.RIGHT)), "frontière : > 30000 mètres", "far away")
	var whole : Dictionary = {"world": "planet", "planet_uuid": "T3"}
	assert_eq(DevReadouts.border_text(DevReadouts.border_distance([whole], "T3", Vector3.ZERO, Vector3.UP)),
		"frontière : > 30000 mètres", "a whole world has no border")
	assert_eq(DevReadouts.border_text(DevReadouts.border_distance([_box(-10.0, 10.0)], "G1", Vector3.ZERO,
		Vector3.UP)), "frontière : hors zone", "another planet's zone is not ours")
	assert_eq(DevReadouts.border_text(DevReadouts.border_distance([_box(-10.0, 10.0)], "T3", Vector3(50, 0, 0),
		Vector3.UP)), "frontière : hors zone", "outside every zone")
	assert_true(is_nan(DevReadouts.border_distance([_box(-10.0, 10.0)], "", Vector3.ZERO, Vector3.UP)),
		"in space, a planet zone does not hold us")


func test_numbers_are_grouped_by_thousands() -> void:
	var sep : String = ReadoutFormat.THOUSANDS
	assert_eq(ReadoutFormat.grouped(0.0), "0", "zero")
	assert_eq(ReadoutFormat.grouped(999.0), "999", "under a thousand, no separator")
	assert_eq(ReadoutFormat.grouped(1000.0), "1" + sep + "000", "a thousand")
	assert_eq(ReadoutFormat.grouped(-1234567.0), "-1" + sep + "234" + sep + "567", "negative millions")
	assert_eq(ReadoutFormat.grouped(-0.4), "0", "no sign on a value that rounds to zero")
	assert_eq(ReadoutFormat.grouped(12.6), "13", "rounded, not cut")


func test_the_ground_readout_escapes_its_brackets() -> void:
	var lines : PackedStringArray = DevReadouts.surface_lines(
		{"family": "sand", "source": "objet", "detail": "mat [from meta]"}, null)
	assert_eq(lines[0], "surface: sand", "the family")
	assert_string_contains(lines[1], "[lb]from meta]", "a bracket in a name is not read as bbcode")
	assert_eq(DevReadouts.surface_lines({}, null)[0], "surface --", "no sample yet")


func test_an_event_rate_is_measured_by_its_own_reader() -> void:
	var rate := EventRate.new()
	assert_eq(rate.per_second(100, 1000), 0.0, "nothing to compare with yet")
	assert_almost_eq(rate.per_second(160, 1500), 120.0, 0.01, "60 events in half a second")
	var other := EventRate.new()
	other.per_second(160, 1500)
	assert_almost_eq(rate.per_second(220, 2000), 120.0, 0.01, "another reader steals nothing")


func test_the_client_readout_without_a_session() -> void:
	var body := Node3D.new()
	add_child_autofree(body)
	var lines : PackedStringArray = ClientReadout.new().lines(body)
	assert_has(lines, "x: 0.00", "coordinates")
	assert_has(lines, "- chunks", "no planet, no chunks")
	assert_has(lines, "- ms ping", "no session, no ping")


func test_the_ping_is_graded_lower_is_better() -> void:
	assert_eq(ClientReadout.ping_text(0.0), "- ms ping", "no sample yet")
	assert_string_contains(ClientReadout.ping_text(40.0), SettingsStyle.GOOD_COLOR.to_html(false), "green")
	assert_string_contains(ClientReadout.ping_text(120.0), SettingsStyle.FAIR_COLOR.to_html(false), "orange")
	assert_string_contains(ClientReadout.ping_text(300.0), SettingsStyle.ALERT_COLOR.to_html(false), "red")
	assert_string_contains(ClientReadout.ping_text(42.4), "]42[/color] ms ping", "whole milliseconds")


func test_the_music_readout_names_the_track_and_the_rule_that_chose_it() -> void:
	var lines : PackedStringArray = DevReadouts.music_lines({
		"track": "tin_can.ogg", "position_s": 75.0, "length_s": 154.0, "playlist": "space.tres",
		"gap_left_s": -1.0, "why": "rule 2: EVA", "where": "weightless", "pending": "capital.tres"})
	assert_eq(lines[0], "track: tin_can.ogg  1:15 / 2:34", "what plays, and how far in")
	assert_eq(lines[1], "playlist: space.tres", "where it comes from")
	assert_eq(lines[2], "case: rule 2: EVA", "the line of the table that won")
	assert_eq(lines[3], "where: weightless", "what the rules had to match")
	assert_eq(lines[4], "next: capital.tres", "and what is about to take over")


func test_the_music_readout_tells_a_pause_from_a_chosen_silence() -> void:
	var pause : Dictionary = {"track": "", "playlist": "wild.tres", "gap_left_s": 41.2, "why": "rule 4: WILD", "where": "wild"}
	assert_eq(DevReadouts.music_lines(pause)[0], "track: (silence, next track in 42 s)", "between two tracks")
	var silence : Dictionary = {"track": "", "playlist": "", "gap_left_s": -1.0, "why": "rule 4: WILD", "where": "wild"}
	var lines : PackedStringArray = DevReadouts.music_lines(silence)
	assert_eq(lines[0], "track: (silence)", "nothing due")
	assert_eq(lines[1], "playlist: (none)", "the rule has no playlist")
	assert_eq(lines.size(), 4, "nothing pending, no fifth line")
	assert_eq(DevReadouts.music_lines({})[0], "music --", "before the director started")


func test_the_weather_readout_gives_the_wind_in_both_units_and_where_it_blows_from() -> void:
	var lines : PackedStringArray = DevReadouts.weather_lines_of({
		"wind_east_m_s": -17.68, "wind_north_m_s": -17.68, "wind_speed_m_s": 25.0, "wind_from_deg": 45.0,
		"lift_threshold_m_s": 6.0, "temperature_k": 290.0, "pressure_pa": 101800.0, "pressure_anomaly_pa": -200.0,
		"dust_tau": 0.42, "visibility_m": 7200.0, "air_density_kg_m3": 1.256, "band": &"trades",
		"phenomena": [&"dust_devil", &"haze"]})
	assert_eq(lines[0], "wind 25.0 m/s (90 km/h) from NE (045°)", "both units, and where it comes FROM")
	assert_eq(lines[1], "sand lifts over 6.0 m/s: lifting", "over the grains' threshold")
	assert_eq(lines[2], "temperature 16.9 °C (290.0 K)", "both scales")
	assert_eq(lines[3], "pressure 1018 hPa (-2.0)", "with what the systems take")
	assert_eq(lines[4], "dust tau 0.42  visibility 7.2 km")
	assert_eq(lines[5], "air 1.256 kg/m³")
	assert_eq(lines[6], "band: trades")
	assert_eq(lines[7], "here: dust_devil, haze", "the local phenomena felt on the spot")


func test_the_weather_readout_keeps_to_what_the_source_gives() -> void:
	# A uniform wind knows no temperature and no pressure: no line is invented for them.
	var lines : PackedStringArray = DevReadouts.weather_lines_of({
		"wind_east_m_s": 3.0, "wind_north_m_s": 4.0, "dust_tau": 0.0, "lift_threshold_m_s": 6.0, "air_density_kg_m3": 1.2})
	assert_eq(lines[0], "wind 5.0 m/s (18 km/h) from SW (217°)", "the speed and the bearing worked out from east and north")
	assert_eq(lines[1], "sand lifts over 6.0 m/s: not lifting")
	assert_eq(lines.size(), 4, "wind, sand, dust, air: nothing else")
	assert_eq(DevReadouts.weather_lines_of({"wind_speed_m_s": 0.0})[0], "wind calm", "no direction in calm air")
	assert_eq(DevReadouts.weather_lines_of({})[0], "weather: no air", "an airless body")
	assert_eq(DevReadouts.weather_lines(null)[0], "weather: space", "no planet under us")
	assert_eq(DevReadouts.compass(350.0), "N", "the bearing wraps round north")
	assert_eq(DevReadouts.compass(130.0), "SE")
	assert_eq(DevReadouts.compass(112.0), "E", "112 degrees is nearer east (90) than south-east (135)")


func test_the_compass_bearing_is_read_on_the_ground_clockwise_from_north() -> void:
	# On the ground at local +Z, Planet.local_axes gives north +Y and east +X.
	var up := Vector3(0.0, 0.0, 1.0)
	assert_almost_eq(DevReadouts.heading_of(up, Vector3(0.0, 1.0, 0.0)), 0.0, 1e-6, "north")
	assert_almost_eq(DevReadouts.heading_of(up, Vector3(1.0, 0.0, 0.0)), 90.0, 1e-6, "east")
	assert_almost_eq(DevReadouts.heading_of(up, Vector3(-1.0, -1.0, 0.0)), 225.0, 1e-6, "south-west")
	assert_almost_eq(DevReadouts.heading_of(up, Vector3(0.0, 1.0, 0.7)), 0.0, 1e-6, "looking up a slope changes nothing")
	assert_eq(DevReadouts.heading_of(up, Vector3(0.0, 0.0, -1.0)), -1.0, "straight down: no bearing")
	assert_eq(DevReadouts.facing_text(44.6), "facing NE (045°)")
	assert_eq(DevReadouts.facing_text(-1.0), "facing straight up or down")


func test_the_compass_dial_turns_with_the_view() -> void:
	var centre := Vector2(100.0, 100.0)
	assert_almost_eq(WeatherCompass.dial_point(centre, 10.0, 0.0, 0.0), Vector2(100.0, 90.0), Vector2.ONE * 1e-4,
			"looking north: north at the top")
	assert_almost_eq(WeatherCompass.dial_point(centre, 10.0, 90.0, 0.0), Vector2(110.0, 100.0), Vector2.ONE * 1e-4,
			"east on the right")
	assert_almost_eq(WeatherCompass.dial_point(centre, 10.0, 90.0, 90.0), Vector2(100.0, 90.0), Vector2.ONE * 1e-4,
			"looking east: east at the top")
	assert_almost_eq(WeatherCompass.dial_point(centre, 10.0, 0.0, 90.0), Vector2(90.0, 100.0), Vector2.ONE * 1e-4,
			"and north on the left")
	assert_eq(DevReadouts.compass_state(null), {}, "nothing to draw off a planet")


func test_the_daylight_line_reads_in_lux_against_the_photocell_thresholds() -> void:
	var text: String = DevReadouts.daylight_text(0.011)
	assert_string_contains(text, "1100 lux", "a daylight of 0.011 is about 1100 lux")
	assert_string_contains(text, "on < %.0f lux" % Photocell.DEFAULT_TUNING.on_below_lux, "the shared tuning, in lux")
	assert_eq(DevReadouts.daylight_line(null), "light: --", "no body: nothing to read")
