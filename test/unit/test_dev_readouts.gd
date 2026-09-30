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


func test_every_zone_is_listed() -> void:
	var zones : Array = []
	for i in 10:
		zones.append(_zone("P%d" % i, false))
	NetworkOrchestrator.set_gameserver_zones.emit(zones)
	var lines : PackedStringArray = DevReadouts.box_lines(_cache)
	assert_eq(lines.size(), 1 + 10, "the name, then all ten zones: the section scrolls, nothing is cut")
	assert_string_contains(lines[-1], "P9", "down to the last one")


func test_a_bounded_zone_is_a_table_of_its_bounds() -> void:
	var zone : Dictionary = {"world": "planet", "planet_name": "Tarsis3", "bounds": {
		"min_x": -4450658.9, "max_x": 1234567.0, "min_y": -2.0, "max_y": 999.0, "min_z": 0.4, "max_z": 1000.0}}
	var block : String = DevReadouts.zone_block(zone)
	assert_string_contains(block, "[color=%s]planet Tarsis3[/color]" % DevReadouts.ZONE_NAME_COLOR, "the name first")
	assert_string_contains(block, "[table=3]", "then a table")
	assert_eq(block.count("[/cell]"), 9, "three axes, each with its min and max")
	assert_string_contains(block, "-4" + ReadoutFormat.THOUSANDS + "450" + ReadoutFormat.THOUSANDS + "659",
		"thousands apart, rounded")
	assert_string_contains(block, "1" + ReadoutFormat.THOUSANDS + "000", "a max on the Z row")


func test_a_whole_world_says_so() -> void:
	assert_eq(DevReadouts.zone_block(_zone("Gaea", false)),
		"[color=%s]planet Gaea[/color] (whole)" % DevReadouts.ZONE_NAME_COLOR, "no table for a whole world")


func test_a_zone_name_is_not_read_as_bbcode() -> void:
	var block : String = DevReadouts.zone_block({"world": "space [test]"})
	assert_string_contains(block, "space [lb]test]", "the bracket is escaped")


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
