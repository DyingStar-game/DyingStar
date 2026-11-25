extends GutTest
## WeatherField: the atmosphere model's near-ground grid as Horizon relays it (contract `weather_field`):
## decoding, the grid's lon/lat convention, bilinear sampling, time interpolation, and ClimateWeather
## taking it as the background while it is fresh.

const SCENE := "res://scenes/_universe/environment/weather/weather_field.tscn"
const DEF := "res://items_def/weather_field_def.json"
const W := 128
const H := 64
const QUANTITIES := ["wind_east", "wind_north", "dust_tau", "t_air", "p_sea"]
## [offset, scale] of each quantity in the frames built here.
const SCALES := [[-60.0, 0.01], [-60.0, 0.01], [0.0, 0.001], [150.0, 0.01], [60000.0, 1.0]]


## The u16 of [param value] for quantity [param q] under SCALES (the test's own encoder).
static func _u(q: int, value: float) -> int:
	return clampi(roundi((value - float(SCALES[q][0])) / float(SCALES[q][1])), 0, 65535)


## A frame's `fields` (base64 of u16 LE, quantity-major then row-major), each value from
## [param value_of].call(q, i, j).
static func _fields(value_of: Callable, scales: Array = SCALES) -> String:
	var raw := PackedByteArray()
	raw.resize(QUANTITIES.size() * W * H * 2)
	for q in QUANTITIES.size():
		for j in H:
			for i in W:
				var v := float(value_of.call(q, i, j))
				var u := clampi(roundi((v - float(scales[q][0])) / float(scales[q][1])), 0, 65535)
				raw.encode_u16(((q * H + j) * W + i) * 2, u)
	return Marshalls.raw_to_base64(raw)


## Every quantity flat at [param values][q].
static func _flat(values: Array) -> String:
	return _fields(func(q: int, _i: int, _j: int) -> float: return float(values[q]))


## The whole object as the service creates it.
static func _data(fields: String, valid_at: float) -> Dictionary:
	return {"name": "tarsis_3", "grid_w": W, "grid_h": H, "quantities": QUANTITIES, "scales": SCALES,
		"valid_at": valid_at, "model_day": 12.5, "fields": fields}


static func _lon(i: float) -> float:
	return -180.0 + (i + 0.5) * 360.0 / W


static func _lat(j: float) -> float:
	return 90.0 - (j + 0.5) * 180.0 / H


func _field() -> WeatherField:
	var node: WeatherField = load(SCENE).instantiate()
	add_child_autofree(node)
	return node


func test_the_scene_carries_a_prop_sync_of_the_right_type() -> void:
	var node := _field()
	var net: PropSync = PropSync.of(node)
	assert_not_null(net, "a PropSync child")
	assert_eq(net.type_name, "weather_field")
	assert_true(node.is_in_group(WeatherField.GROUP))
	assert_eq(node.frames().size(), 0, "no frame before any data")
	assert_eq(node.sample(0.0, 0.0, 0.0), {})
	assert_false(node.is_fresh(0.0))


func test_the_values_come_back_through_the_scales() -> void:
	var node := _field()
	var value_of := func(q: int, i: int, j: int) -> float:
		return [-12.34, 7.5, 1.234, 210.0 + i * 0.5, 61000.0 + j * 10.0][q]
	node.apply_prop_data(_data(_fields(value_of), 1000.0))
	var frames := node.frames()
	assert_eq(frames.size(), 1)
	var frame: Dictionary = frames[0]
	var values: PackedFloat32Array = frame["values"]
	assert_eq(values.size(), 5 * W * H)
	assert_eq(frame["index"], {"wind_east": 0, "wind_north": 1, "dust_tau": 2, "t_air": 3, "p_sea": 4})
	for q in 5:
		for cell: Vector2i in [Vector2i(0, 0), Vector2i(77, 31), Vector2i(W - 1, H - 1)]:
			var expected := float(SCALES[q][0]) + float(SCALES[q][1]) * _u(q, value_of.call(q, cell.x, cell.y))
			assert_almost_eq(values[(q * H + cell.y) * W + cell.x], expected, 1e-3,
					"%s at %s" % [QUANTITIES[q], cell])
	assert_almost_eq(node.model_day, 12.5, 1e-9)


func test_a_cell_sits_at_the_contract_s_longitude_and_latitude() -> void:
	# Cell (37, 11) of t_air alone is warm: sampled at its centre it reads whole; at the next cell's
	# centre, east and south, it is gone (row 0 is north, columns run eastward from -180°).
	var node := _field()
	node.apply_prop_data(_data(_fields(func(q: int, i: int, j: int) -> float:
		return 250.0 if q == 3 and i == 37 and j == 11 else [0.0, 0.0, 0.0, 200.0, 61000.0][q]), 1000.0))
	assert_almost_eq(float(node.sample(_lon(37), _lat(11), 0.0)["t_air"]), 250.0, 1e-3, "the cell's centre")
	assert_almost_eq(float(node.sample(_lon(38), _lat(11), 0.0)["t_air"]), 200.0, 1e-3, "one cell east")
	assert_almost_eq(float(node.sample(_lon(37), _lat(12), 0.0)["t_air"]), 200.0, 1e-3, "one cell south")
	assert_almost_eq(_lon(37), -74.53125, 1e-9)
	assert_almost_eq(_lat(11), 57.65625, 1e-9)


func test_sampling_is_bilinear_wraps_in_longitude_and_clamps_in_latitude() -> void:
	# wind_east = the column, wind_north = the row.
	var node := _field()
	node.apply_prop_data(_data(_fields(func(q: int, i: int, j: int) -> float:
		return [float(i) * 0.1, float(j) * 0.1, 0.0, 200.0, 61000.0][q]), 1000.0))
	var mid := node.sample(_lon(10.5), _lat(20.25), 0.0)
	assert_almost_eq(float(mid["wind_east"]), 1.05, 1e-3, "halfway between columns 10 and 11")
	assert_almost_eq(float(mid["wind_north"]), 2.025, 1e-3, "a quarter of the way from row 20 to 21")
	assert_almost_eq(float(node.sample(180.0, 0.0, 0.0)["wind_east"]), (12.7 + 0.0) / 2.0, 1e-3,
			"at 180° between the last column and the first")
	assert_almost_eq(float(node.sample(-180.0, 0.0, 0.0)["wind_east"]), 6.35, 1e-3, "same place from the west")
	assert_almost_eq(float(node.sample(0.0, 90.0, 0.0)["wind_north"]), 0.0, 1e-3, "the pole reads row 0")
	assert_almost_eq(float(node.sample(0.0, -90.0, 0.0)["wind_north"]), 6.3, 1e-3, "the south pole the last row")


func test_time_goes_from_the_previous_frame_to_the_newest_and_holds() -> void:
	var node := _field()
	node.apply_prop_data(_data(_flat([10.0, 0.0, 0.0, 200.0, 61000.0]), 1000.0))
	assert_almost_eq(float(node.sample(0.0, 0.0, 5000.0)["wind_east"]), 10.0, 1e-3, "one frame: used as it is")
	node.apply_prop_data({"valid_at": 2000.0, "model_day": 12.6,
			"fields": _flat([20.0, 0.0, 0.0, 220.0, 62000.0])})
	assert_eq(node.frames().size(), 2)
	var half := node.sample(0.0, 0.0, 1500.0)
	assert_almost_eq(float(half["wind_east"]), 15.0, 1e-3, "halfway between the frames")
	assert_almost_eq(float(half["t_air"]), 210.0, 1e-3)
	assert_almost_eq(float(half["p_sea"]), 61500.0, 1e-3)
	assert_almost_eq(float(node.sample(0.0, 0.0, 2500.0)["wind_east"]), 20.0, 1e-3, "past the newest: held")
	assert_almost_eq(float(node.sample(0.0, 0.0, 500.0)["wind_east"]), 10.0, 1e-3, "before the previous: it")
	node.apply_prop_data({"valid_at": 3000.0, "fields": _flat([40.0, 0.0, 0.0, 200.0, 61000.0])})
	assert_almost_eq(float(node.sample(0.0, 0.0, 2500.0)["wind_east"]), 30.0, 1e-3, "the oldest frame dropped")
	node.apply_prop_data({"valid_at": 100.0, "fields": _flat([5.0, 0.0, 0.0, 200.0, 61000.0])})
	assert_eq(node.frames().size(), 1, "time went back: nothing to interpolate from")


func test_a_malformed_frame_is_ignored() -> void:
	var node := _field()
	node.apply_prop_data(_data(_flat([10.0, 0.0, 0.0, 200.0, 61000.0]), 1000.0))
	node.apply_prop_data({"valid_at": 2000.0, "fields": Marshalls.raw_to_base64(PackedByteArray([1, 2, 3, 4]))})
	node.apply_prop_data({"valid_at": 2000.0, "fields": 42})
	assert_eq(node.frames().size(), 1, "the bad frames are not kept")
	assert_almost_eq(float(node.sample(0.0, 0.0, 1500.0)["wind_east"]), 10.0, 1e-3, "the good one still stands")
	assert_true(WeatherField.decode_frame(PackedByteArray(), W, H, QUANTITIES, SCALES, 0.0).has("error"))
	var raw := Marshalls.base64_to_raw(_flat([0.0, 0.0, 0.0, 200.0, 61000.0]))
	assert_true(WeatherField.decode_frame(raw, W, H, QUANTITIES, SCALES.slice(0, 4), 0.0).has("error"), "a scale missing")
	assert_true(WeatherField.decode_frame(raw, 0, H, QUANTITIES, SCALES, 0.0).has("error"), "no grid")
	assert_false(WeatherField.decode_frame(raw, W, H, QUANTITIES, SCALES, 0.0).has("error"))


func test_scales_that_come_apart_from_their_fields_are_paired_with_them() -> void:
	# Zone 0 (scales) and zone 1 (fields) are separate channels: either may arrive first.
	var other := [[-30.0, 0.02], [-60.0, 0.01], [0.0, 0.001], [150.0, 0.01], [60000.0, 1.0]]
	var node := _field()
	node.apply_prop_data(_data(_flat([10.0, 0.0, 0.0, 200.0, 61000.0]), 1000.0))
	# Fields first, then their scales.
	node.apply_prop_data({"valid_at": 2000.0, "fields": _fields(func(q: int, _i: int, _j: int) -> float:
		return [30.0, 0.0, 0.0, 200.0, 61000.0][q], other)})
	node.apply_prop_data({"scales": other})
	assert_almost_eq(float(node.sample(0.0, 0.0, 2000.0)["wind_east"]), 30.0, 1e-3, "re-decoded with its scales")
	assert_almost_eq(float(node.sample(0.0, 0.0, 1000.0)["wind_east"]), 10.0, 1e-3, "the previous frame untouched")
	# Scales first, then their fields.
	node.apply_prop_data({"scales": SCALES})
	assert_almost_eq(float(node.sample(0.0, 0.0, 2000.0)["wind_east"]), 30.0, 1e-3, "the newest is not re-decoded")
	node.apply_prop_data({"valid_at": 3000.0, "fields": _flat([5.0, 0.0, 0.0, 200.0, 61000.0])})
	assert_almost_eq(float(node.sample(0.0, 0.0, 3000.0)["wind_east"]), 5.0, 1e-3, "decoded with the scales ahead")


func test_freshness_follows_the_newest_frame() -> void:
	var node := _field()
	node.apply_prop_data(_data(_flat([10.0, 0.0, 0.0, 200.0, 61000.0]), 1000.0))
	assert_true(node.is_fresh(500.0))
	assert_true(node.is_fresh(1000.0 + WeatherField.FRESH_FOR_S - 1.0))
	assert_false(node.is_fresh(1000.0 + WeatherField.FRESH_FOR_S + 1.0), "a silent service: stale")


func test_climate_weather_takes_a_fresh_field_and_falls_back_without_one() -> void:
	var t := ClimateWeather.now()
	var planet := Planet.new()
	add_child_autofree(planet)
	var storm := WeatherSystem.new()  # a storm of the profile's weather, where we look
	planet.add_child(storm)
	storm.position = HEALPix.lonlat2vec(-39.5, 20.0) * 6356000.0
	storm.apply_prop_data({"kind": "dust_storm", "radius_m": 600000.0, "intensity": 1.0, "pressure_anomaly_pa": -900.0,
			"params": {"wind_peak_ms": 25.0, "dust_tau": 5.0}})
	var field := WeatherField.new()
	planet.add_child(field)
	field.apply_prop_data(_data(_flat([3.0, -4.0, 0.25, 230.0, 70000.0]), t + 3600.0))
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	var held := weather.fresh_field(planet, t)
	assert_eq(held.size(), 1, "the planet's field is read")
	var got := weather.sample_at(-39.5, 20.0, 0.0, 0.0, 0.0, weather.systems(planet), held, t)
	assert_true(got["weather_field"])
	assert_almost_eq(float(got["wind_east_m_s"]), 3.0, 1e-3)
	assert_almost_eq(float(got["wind_north_m_s"]), -4.0, 1e-3)
	assert_almost_eq(float(got["wind_speed_m_s"]), 5.0, 1e-3)
	assert_almost_eq(float(got["dust_tau"]), 0.25, 1e-3, "the field's dust, not the storm's")
	assert_almost_eq(float(got["temperature_k"]), 230.0, 1e-3)
	assert_almost_eq(float(got["pressure_pa"]), 70000.0, 1e-3)
	assert_almost_eq(float(got["pressure_anomaly_pa"]), 70000.0 - weather.profile.pressure_pa, 1e-3)
	assert_eq((got["systems"] as Array).size(), 0, "the systems are not counted over the field")
	for key: String in ["wind_from_deg", "lift_threshold_m_s", "air_density_kg_m3", "visibility_m", "band"]:
		assert_true(got.has(key), "a field sample still has %s" % key)
	var air := weather.air_at(-39.5, 20.0, weather.systems(planet), held, t)
	assert_almost_eq(float(air["wind_east_m_s"]), 3.0, 1e-3, "the devils and walls read the field's air too")
	assert_almost_eq(float(air["dust_tau"]), 0.25, 1e-3)
	# Stale: the profile and the storm again.
	var old := WeatherField.new()
	planet.remove_child(field)
	field.free()
	planet.add_child(old)
	old.apply_prop_data(_data(_flat([3.0, -4.0, 0.25, 230.0, 70000.0]), t - WeatherField.FRESH_FOR_S - 60.0))
	weather.feed([])  # read the planet's nodes again now
	assert_eq(weather.fresh_field(planet, t).size(), 0, "a stale field is not used")
	var back := weather.sample_at(-39.5, 20.0, 0.0, 0.0, 0.0, weather.systems(planet), weather.fresh_field(planet, t), t)
	assert_false(back["weather_field"])
	assert_gt(float(back["dust_tau"]), 1.0, "the storm's dust is back")


func test_the_hook_reads_a_fed_field_through_sample() -> void:
	var t := ClimateWeather.now()
	var node := _field()
	node.apply_prop_data(_data(_flat([-6.0, 8.0, 0.5, 240.0, 71000.0]), t + 3600.0))
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	var before := weather.sample(null, HEALPix.lonlat2vec(-39.5, 45.0))
	assert_gt(float(before.wind_east_m_s), 0.0, "the westerlies without a field")
	weather.feed_field(node.frames())
	var got := weather.sample(null, HEALPix.lonlat2vec(-39.5, 45.0))
	assert_almost_eq(float(got.wind_east_m_s), -6.0, 1e-3, "the field's wind through the hook")
	assert_almost_eq(float(got.wind_north_m_s), 8.0, 1e-3)
	assert_almost_eq(float(got.temperature_k), 240.0, 1e-3)
	weather.feed_field([])
	assert_gt(float(weather.sample(null, HEALPix.lonlat2vec(-39.5, 45.0)).wind_east_m_s), 0.0, "taken away: the profile")


func test_the_def_lists_the_contract_s_channels() -> void:
	var def: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DEF))
	var zones := {}
	for channel: Dictionary in def["channels"]:
		zones[int(channel["zone"])] = channel
	assert_eq(zones.keys(), [0, 1, 6])
	assert_eq(zones[0]["properties"], ["name", "parent_id", "position", "rotation", "grid_w", "grid_h", "quantities", "scales"])
	assert_eq(zones[1]["properties"], ["valid_at", "model_day", "fields"])
	assert_eq(zones[6]["properties"], ["scenename"], "zone 6 carries the deletion")
	assert_almost_eq(float(zones[0]["frequency"]), 1.0, 1e-9)
	assert_almost_eq(float(zones[1]["frequency"]), 0.2, 1e-9)
	assert_almost_eq(float(zones[6]["distance"]), 20000001.0, 1e-6)
	for channel: Dictionary in def["channels"]:
		assert_almost_eq(float(channel["distance"]), 20000000.0, 1.0)
		for key in channel["properties"]:
			assert_false(key in ["type", "uuid"], "an envelope key is never a property")
	# Every key the object receives from the wire is listed.
	var listed: Array = []
	for channel: Dictionary in def["channels"]:
		listed.append_array(channel["properties"])
	for key: String in _data("", 0.0):
		assert_has(listed, key, "'%s' must be in weather_field_def.json" % key)
	assert_has(GameServer.STREAM_ALWAYS_TYPES, "weather_field", "the server keeps the field awake")
