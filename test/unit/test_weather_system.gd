extends GutTest
## WeatherSystem: the networked prop a weather system arrives as. It reads partial channel data,
## walks its keyframes on the shared clock, and reports its state for the sampler.

const SCENE := "res://scenes/_universe/environment/weather/weather_system.tscn"


func _system() -> WeatherSystem:
	var node : WeatherSystem = load(SCENE).instantiate()
	add_child_autofree(node)
	return node


func test_the_scene_carries_a_prop_sync_of_the_right_type() -> void:
	var node := _system()
	var net : PropSync = PropSync.of(node)
	assert_not_null(net, "a PropSync child")
	assert_eq(net.type_name, "weather_system")
	assert_true(node.is_in_group(WeatherSystem.GROUP))


func test_partial_data_only_touches_what_it_carries() -> void:
	var node := _system()
	node.apply_prop_data({"kind": "dust_storm", "radius_m": 400000.0, "intensity": 0.7,
		"params": {"wind_peak_ms": 25.0, "dust_tau": 4.0}})
	assert_eq(node.kind, &"dust_storm")
	assert_almost_eq(node.radius_m, 400000.0, 1e-6)
	assert_almost_eq(node.wind_peak_ms, 25.0, 1e-9)
	node.apply_prop_data({"intensity": 0.2})
	assert_almost_eq(node.intensity, 0.2, 1e-9)
	assert_eq(node.kind, &"dust_storm", "untouched by a partial update")
	assert_almost_eq(node.wind_peak_ms, 25.0, 1e-9, "untouched by a partial update")


func test_keyframes_move_the_centre_on_the_shared_clock() -> void:
	var node := _system()
	node.apply_prop_data({
		"from_timestamp": 1000.0, "keyframe_dt_s": 100.0,
		"track": [{"x": 0.0, "y": 0.0, "z": 0.0}, {"x": 1000.0, "y": 0.0, "z": 0.0}, {"x": 2000.0, "y": 0.0, "z": 0.0}],
		"intensity_track": [0.0, 1.0, 0.0],
	})
	node._walk_keyframes(1050.0)
	assert_almost_eq(node.position.x, 500.0, 1e-6, "halfway to the second keyframe")
	assert_almost_eq(node.intensity, 0.5, 1e-9)
	node._walk_keyframes(1200.0)
	assert_almost_eq(node.position.x, 2000.0, 1e-6, "parked on the last keyframe")
	assert_almost_eq(node.intensity, 0.0, 1e-9, "dead at the end of its track")
	node._walk_keyframes(900.0)
	assert_almost_eq(node.position.x, 0.0, 1e-6, "before the track: the first keyframe")


func test_state_reports_the_centre_as_longitude_and_latitude() -> void:
	var node := _system()
	node.position = HEALPix.lonlat2vec(-39.5, 24.7) * 6356000.0
	node.apply_prop_data({"radius_m": 600000.0, "intensity": 0.4, "kind": "depression",
		"pressure_anomaly_pa": -1500.0, "params": {"wind_peak_ms": 12.0}})
	var s : Dictionary = node.state()
	assert_almost_eq(s["lon"], -39.5, 1e-6)
	assert_almost_eq(s["lat"], 24.7, 1e-6)
	assert_almost_eq(s["sigma_m"], 300000.0, 1e-6, "sigma is half the radius")
	assert_eq(s["kind"], &"depression")
	assert_almost_eq(s["wind_peak"], 12.0, 1e-9)
