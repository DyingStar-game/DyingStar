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
	assert_eq(DevReadouts.server_lines(_cache)[0], "- TPS", "unknown until the server says")
	NetworkOrchestrator.set_gameserver_server_tps.emit(24)
	NetworkOrchestrator.set_gameserver_number_players.emit(9)
	var lines : PackedStringArray = DevReadouts.server_lines(_cache)
	assert_string_contains(lines[0], "24", "TPS")
	assert_string_contains(lines[0], SettingsStyle.ALERT_COLOR.to_html(false), "red under 30")
	assert_eq(lines[1], "9 players", "players")


func test_the_zone_list_is_capped() -> void:
	var zones : Array = []
	for i in 10:
		zones.append(_zone("P%d" % i, false))
	NetworkOrchestrator.set_gameserver_zones.emit(zones)
	var lines : PackedStringArray = DevReadouts.box_lines(_cache, 4)
	assert_eq(lines.size(), 1 + 4 + 1, "name, four zones, then the rest counted")
	assert_string_contains(lines[-1], "6", "+6 more")


func test_a_bounded_zone_fits_one_line() -> void:
	var line : String = DevReadouts.zone_line(_zone("Tarsis3", true))
	assert_false(line.contains("\n"), "one line, not four")
	assert_string_contains(line, "X -1..1", "bounds inline")
	assert_eq(DevReadouts.zone_line(_zone("Gaea", false)), "planet Gaea (whole)", "a whole world")


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
