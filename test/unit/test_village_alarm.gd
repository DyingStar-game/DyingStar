extends GutTest
## VillageAlarm: the storm siren of a village — when it warns, sounds and stops (the server's state machine),
## where the siren is in its sample on every client, and the dust wall an admin calls in to set it off
## (ForcedDustWall, WeatherRelief.forced_wall).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_village_alarm.gd

const WALL_SCENE := "res://scenes/_universe/environment/weather/forced_dust_wall.tscn"
const WALL_DEF := "res://items_def/dust_wall_def.json"
const VILLAGE_DEF := "res://items_def/poi_village_def.json"
const RADIUS_M := 6356000.0
const TARGET := Vector2(12.0, -8.0)


## Every property a def's channels list.
static func _listed(def_path: String) -> Array:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(def_path))
	var listed := []
	for channel: Dictionary in def["channels"]:
		listed.append_array(channel["properties"])
	return listed


## A called-in wall aimed at TARGET, born at [param t], running east, as the server spawns it.
static func _forced(t: float) -> Dictionary:
	var data := ForcedDustWall.spawn_data("planet", "wall", Vector3.ZERO, TARGET, Vector2(3.0, 0.0), t, RADIUS_M)
	data["id"] = 7
	return data


func test_the_forecast_calls_for_a_state() -> void:
	assert_eq(VillageAlarm.wanted_for(-1.0), VillageAlarm.OFF, "nothing in sight")
	assert_eq(VillageAlarm.wanted_for(0.0), VillageAlarm.DURING, "there now")
	assert_eq(VillageAlarm.wanted_for(VillageAlarm.LOOKAHEAD_S), VillageAlarm.WARNING, "within the lookahead")
	assert_eq(VillageAlarm.wanted_for(VillageAlarm.LOOKAHEAD_S + 1.0), VillageAlarm.OFF, "past it")


func test_the_eta_is_the_first_dangerous_step() -> void:
	assert_eq(VillageAlarm.eta(func(offset: float) -> bool: return offset >= 100.0), 120.0, "the first step from 100 s")
	assert_eq(VillageAlarm.eta(func(_offset: float) -> bool: return true), 0.0, "there now")
	assert_eq(VillageAlarm.eta(func(_offset: float) -> bool: return false), -1.0, "never")


func test_the_alarm_climbs_at_once_and_comes_down_after_the_hold() -> void:
	var alarm := VillageAlarm.new()
	assert_true(alarm.step(100.0, 300.0), "an arrival in 5 min: warning")
	assert_eq(alarm.state, VillageAlarm.WARNING)
	assert_eq(alarm.since, 100.0, "the rhythm counts from the change")
	assert_false(alarm.step(110.0, 290.0), "still warning: nothing to replicate")
	assert_true(alarm.step(400.0, 0.0), "there: the siren at once")
	assert_eq(alarm.state, VillageAlarm.DURING)
	assert_false(alarm.step(500.0, -1.0), "gone, but held")
	assert_false(alarm.step(500.0 + VillageAlarm.CLEAR_HOLD_S - 1.0, -1.0), "still held")
	assert_true(alarm.step(500.0 + VillageAlarm.CLEAR_HOLD_S, -1.0), "all clear once the hold has run")
	assert_eq(alarm.state, VillageAlarm.OFF)


func test_a_flickering_forecast_does_not_flicker_the_siren() -> void:
	var alarm := VillageAlarm.new()
	alarm.step(0.0, 0.0)
	alarm.step(10.0, -1.0)
	assert_false(alarm.step(20.0, 0.0), "back before the hold ran out: no change")
	assert_false(alarm.step(30.0, -1.0), "the hold starts again")
	assert_false(alarm.step(30.0 + VillageAlarm.CLEAR_HOLD_S - 1.0, -1.0))
	assert_eq(alarm.state, VillageAlarm.DURING)


func test_the_drill_warns_sounds_then_ends_without_a_hold() -> void:
	var alarm := VillageAlarm.new()
	alarm.drill(1000.0)
	assert_true(alarm.step(1000.0, -1.0))
	assert_eq(alarm.state, VillageAlarm.WARNING, "the drill warns first, whatever the weather")
	assert_true(alarm.step(1000.0 + VillageAlarm.DRILL_WARNING_S, -1.0))
	assert_eq(alarm.state, VillageAlarm.DURING)
	assert_true(alarm.step(1000.0 + VillageAlarm.DRILL_WARNING_S + VillageAlarm.DRILL_DURING_S, -1.0),
			"off at once when it ends: it was no weather")
	assert_eq(alarm.state, VillageAlarm.OFF)


func test_the_siren_is_in_step_on_every_machine() -> void:
	var length := 8.0
	assert_almost_eq(VillageAlarm.siren_position(VillageAlarm.DURING, 100.0, 119.0, length), 3.0, 1e-9,
			"the loop, joined where the others hear it")
	assert_almost_eq(VillageAlarm.siren_position(VillageAlarm.WARNING, 100.0, 100.0, length), 0.0, 1e-9,
			"a warning's sounding starts at the head of the sound")
	assert_almost_eq(VillageAlarm.siren_position(VillageAlarm.WARNING, 100.0, 102.0, length), 2.0, 1e-9,
			"a late client joins it mid-way, without waiting")
	assert_eq(VillageAlarm.siren_position(VillageAlarm.WARNING, 100.0, 130.0, length), -1.0, "then is silent")
	assert_almost_eq(VillageAlarm.siren_position(VillageAlarm.WARNING, 100.0, 100.0 + VillageAlarm.WARNING_PERIOD_S,
			length), 0.0, 1e-9, "and sounds again a period later, from its head")
	assert_eq(VillageAlarm.siren_position(VillageAlarm.OFF, 100.0, 101.0, length), -1.0)


func test_a_storm_is_a_storm_from_the_wall_veil() -> void:
	assert_false(VillageAlarm.storm_danger(VillageAlarm.STORM_DANGER_TAU - 0.01))
	assert_true(VillageAlarm.storm_danger(VillageAlarm.STORM_DANGER_TAU))
	assert_eq(VillageAlarm.STORM_DANGER_TAU, WeatherRelief.WALL_VEIL_TAU[0], "where a storm's air stops the walls")


func test_a_called_in_wall_reaches_the_village_after_its_lead() -> void:
	var t := 5000.0
	var forced := _forced(t)
	assert_eq(WeatherRelief.forced_wall(forced, t - 1.0, RADIUS_M), {}, "not before it is called")
	assert_eq(WeatherRelief.forced_wall(forced, float(forced["dies_at"]), RADIUS_M), {}, "gone at its end")
	var born := WeatherRelief.forced_wall(forced, t, RADIUS_M)
	assert_almost_eq(WeatherRelief.offset_m(Vector2(born["lon"], born["lat"]), TARGET, RADIUS_M).x,
			ForcedDustWall.upwind_m(), 1.0, "placed upwind by speed x lead and its drawn front's lead")
	assert_gt(ForcedDustWall.upwind_m(), ForcedDustWall.SPEED_M_S * ForcedDustWall.LEAD_S, "the drawn front leads its middle")
	assert_almost_eq(WeatherRelief.wall_behind_m(WeatherRelief.forced_wall(forced, t + ForcedDustWall.LEAD_S, RADIUS_M),
			TARGET, RADIUS_M), 0.0, 1.0, "the front as drawn reaches the village after its lead")
	assert_almost_eq(float(born["east"]), 1.0, 1e-9, "running with the wind given")
	assert_eq(float(born["grown"]), 1.0, "born risen: called in to be seen")
	var danger := func(offset: float) -> bool:
		var wall := WeatherRelief.forced_wall(forced, t + offset, RADIUS_M)
		return VillageAlarm.wall_danger([] if wall.is_empty() else [wall], TARGET, RADIUS_M)
	var eta := VillageAlarm.eta(danger)
	assert_between(eta, ForcedDustWall.LEAD_S, ForcedDustWall.LEAD_S + VillageAlarm.STEP_S,
			"the alarm sees it coming within its lead: a warning first")
	assert_true(danger.call(ForcedDustWall.LEAD_S + 20.0), "its dusty air at the village")
	assert_false(danger.call(float(forced["dies_at"]) - t - WeatherRelief.FORCED_FADE_S),
			"gone past the village before it fades out")


func test_a_called_in_wall_ends_only_once_its_tail_has_left_the_village() -> void:
	var t := 5000.0
	var forced := _forced(t)
	var end: float = float(forced["dies_at"]) - t
	var danger_from := -1.0
	var danger_until := -1.0
	var dust_until := -1.0
	var offset := 0.0
	while offset < end:
		var wall := WeatherRelief.forced_wall(forced, t + offset, RADIUS_M)
		var tau: float = VillageAlarm.walls_tau([] if wall.is_empty() else [wall], TARGET, RADIUS_M)
		if tau >= VillageAlarm.WALL_DANGER_TAU:
			danger_until = offset
			if danger_from < 0.0:
				danger_from = offset
		if tau > 0.0:
			dust_until = offset
		offset += 5.0
	gut.p("Called-in wall over the village: danger (tau >= %.1f) from %.0f s to %.0f s, dust until %.0f s, ends at %.0f s"
			% [VillageAlarm.WALL_DANGER_TAU, danger_from, danger_until, dust_until, end])
	assert_between(danger_from, ForcedDustWall.LEAD_S - 5.0, ForcedDustWall.LEAD_S + 10.0, "its front arrives after its lead")
	assert_gt(danger_until - danger_from, 180.0, "its dusty tail keeps the siren going minutes after the front")
	assert_gt(dust_until, danger_until, "the thin end of the tail follows")
	assert_lt(dust_until, end - WeatherRelief.FORCED_FADE_S, "the tail has left before the wall fades out and is deleted")


func test_the_called_in_wall_is_a_networked_prop_its_def_whitelists() -> void:
	var node: ForcedDustWall = load(WALL_SCENE).instantiate()
	add_child_autofree(node)
	assert_eq(PropSync.of(node).type_name, ForcedDustWall.TYPE_NAME)
	assert_true(node.is_in_group(ForcedDustWall.GROUP))
	var listed := _listed(WALL_DEF)
	for key: String in _forced(0.0):
		if key != "type" and key != "uuid" and key != "id":
			assert_has(listed, key, "'%s' must be in dust_wall_def.json" % key)
	assert_does_not_have(listed, "type", "never a property named like an envelope key")
	assert_has(GameServer.STREAM_ALWAYS_TYPES, ForcedDustWall.TYPE_NAME, "the server keeps it awake to end it")


func test_the_wall_reads_horizon_s_whole_numbers_as_floats() -> void:
	var node: ForcedDustWall = load(WALL_SCENE).instantiate()
	add_child_autofree(node)
	node.apply_prop_data({"born_at": 1200, "speed_m_s": 15, "origin_lat": -8})
	assert_eq(typeof(node.born_at), TYPE_FLOAT)
	assert_eq(node.data()["born_at"], 1200.0)
	assert_eq(node.data()["origin_lat"], -8.0)


func test_the_village_replicates_its_alarm() -> void:
	var listed := _listed(VILLAGE_DEF)
	assert_has(listed, "alarm")
	assert_has(listed, "alarm_since")
	assert_has(listed, "dust_light", "the dust's share of the daylight the photocells read")


func test_a_wall_over_the_village_dims_its_daylight() -> void:
	var t := 5000.0
	var forced := _forced(t)
	var wall := WeatherRelief.forced_wall(forced, t + ForcedDustWall.LEAD_S + 20.0, RADIUS_M)
	var tau := VillageAlarm.walls_tau([wall], TARGET, RADIUS_M)
	assert_between(tau, VillageAlarm.WALL_DANGER_TAU, WeatherRelief.WALL_TAU, "its dusty air at the village")
	assert_almost_eq(tau, float(WeatherRelief.wall_effect(wall, TARGET, RADIUS_M)[1]), 1e-9, "one wall: its own dust")
	assert_almost_eq(VillageAlarm.walls_tau([wall, wall], TARGET, RADIUS_M), 2.0 * tau, 1e-9,
			"walls add their dust, as WeatherRelief.apply adds it")
	assert_eq(VillageAlarm.walls_tau([], TARGET, RADIUS_M), 0.0)
	assert_eq(VillageAlarm.dust_light(0.0), 1.0, "no dust: the clear daylight")
	assert_almost_eq(VillageAlarm.dust_light(WeatherRelief.WALL_TAU), 0.07, 1e-6, "a whole wall: 7 % of it")
	assert_lt(VillageAlarm.dust_light(10.0), 0.05, "a thick storm: night-dark enough for the lamps")
	assert_almost_eq(VillageAlarm.dust_light(1.234), snappedf(VillageAlarm.dust_light(1.234), VillageAlarm.DUST_LIGHT_STEP),
			1e-9, "replicated in steps")
