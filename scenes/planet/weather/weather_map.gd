class_name WeatherMap
extends RefCounted
## A picture of a body's weather at one instant, longitude/latitude (west → east, north → south, as
## NovaAtlas's map): the air temperature as colours, the dust as an ochre veil, the pressure as isobars,
## the wind as arrows, the systems as rings. What the weather is checked on by eye: the circulation cells
## (trades converging on the equator, westerlies, polar easterlies), the day and night sides, the storms.
##
## Pure: a ClimateWeather and its systems in, an Image out. Seconds of script: call it from a worker.

## The grid the weather is sampled on (the picture is this grid, smoothed).
const GRID := Vector2i(240, 120)
## Isobars every this many pascals.
const ISOBAR_PA := 300.0
## An arrow every this many pixels, and its length per m/s of wind (capped).
const ARROW_EVERY_PX := 40
const ARROW_PX_PER_MS := 2.4
const ARROW_MAX_PX := 34.0
## Dust optical depth that hides the ground entirely under the veil.
const DUST_FULL_TAU := 3.0

const COLOR_DUST := Color(0.72, 0.52, 0.28)
const COLOR_ISOBAR := Color(0.08, 0.08, 0.1)
## The wind's arrows: over the dust threshold (it lifts the sand), and under it.
const COLOR_WIND_LIFTING := Color(1.0, 1.0, 1.0)
const COLOR_WIND := Color(0.12, 0.12, 0.14)
const COLOR_LOW := Color(0.85, 0.1, 0.1)
const COLOR_HIGH := Color(0.1, 0.25, 0.9)
const COLOR_STORM := Color(0.45, 0.25, 0.05)

## Air temperature → colour, kelvins.
const TEMPERATURES := [[213.0, Color(0.25, 0.1, 0.5)], [243.0, Color(0.15, 0.35, 0.85)],
		[263.0, Color(0.35, 0.8, 0.9)], [278.0, Color(0.55, 0.85, 0.5)], [288.0, Color(0.95, 0.9, 0.4)],
		[298.0, Color(0.95, 0.6, 0.2)], [313.0, Color(0.8, 0.15, 0.1)]]


## The colour of an air temperature.
static func temperature_color(kelvin: float) -> Color:
	for i in range(1, TEMPERATURES.size()):
		if kelvin <= float(TEMPERATURES[i][0]) or i == TEMPERATURES.size() - 1:
			var low: Array = TEMPERATURES[i - 1]
			var high: Array = TEMPERATURES[i]
			return (low[1] as Color).lerp(high[1], clampf((kelvin - float(low[0])) / (float(high[0]) - float(low[0])), 0.0, 1.0))
	return TEMPERATURES[0][1]


## The weather of [param weather]'s body under [param live] systems (ClimateWeather.systems), as {image (RGB8,
## [param width] wide, half as high),
## t_min_k, t_max_k, wind_max_m_s, systems: {kind: count}}. [param decl_deg] and
## [param substellar_lon_deg]: where the star stands overhead.
static func render(weather: ClimateWeather, live: Array, decl_deg: float, substellar_lon_deg: float,
		width := 1440) -> Dictionary:
	var size := Vector2i(width, width / 2)
	var colors := Image.create(GRID.x, GRID.y, false, Image.FORMAT_RGB8)
	var pressure := Image.create(GRID.x, GRID.y, false, Image.FORMAT_RF)
	var east := PackedFloat32Array()
	var north := PackedFloat32Array()
	east.resize(GRID.x * GRID.y)
	north.resize(GRID.x * GRID.y)
	var t_min := INF
	var t_max := -INF
	var wind_max := 0.0
	for y in GRID.y:
		var lat := 90.0 - (y + 0.5) * 180.0 / GRID.y
		for x in GRID.x:
			var lon := -180.0 + (x + 0.5) * 360.0 / GRID.x
			var s := weather.sample_at(lon, lat, 0.0, decl_deg, substellar_lon_deg, live)
			var kelvin := float(s["temperature_k"])
			t_min = minf(t_min, kelvin)
			t_max = maxf(t_max, kelvin)
			wind_max = maxf(wind_max, float(s["wind_speed_m_s"]))
			colors.set_pixel(x, y, temperature_color(kelvin).lerp(COLOR_DUST,
					clampf(float(s["dust_tau"]) / DUST_FULL_TAU, 0.0, 1.0) * 0.85))
			pressure.set_pixel(x, y, Color(float(s["pressure_anomaly_pa"]), 0.0, 0.0))
			east[y * GRID.x + x] = s["wind_east_m_s"]
			north[y * GRID.x + x] = s["wind_north_m_s"]
	colors.resize(size.x, size.y, Image.INTERPOLATE_CUBIC)
	pressure.resize(size.x, size.y, Image.INTERPOLATE_CUBIC)
	_draw_isobars(colors, pressure.get_data().to_float32_array())
	var counts := {}
	for system: Dictionary in live:
		counts[system["kind"]] = int(counts.get(system["kind"], 0)) + 1
		_draw_system(colors, system, weather.profile.radius_m)
	var threshold := weather.profile.v10_threshold_m_s
	@warning_ignore("integer_division")
	for py in range(ARROW_EVERY_PX / 2, size.y, ARROW_EVERY_PX):
		@warning_ignore("integer_division")
		for px in range(ARROW_EVERY_PX / 2, size.x, ARROW_EVERY_PX):
			var cell := (py * GRID.y / size.y) * GRID.x + px * GRID.x / size.x
			var wind := Vector2(east[cell], -north[cell])  # the picture's y runs south
			var speed := wind.length()
			if speed < 0.3:
				continue
			_draw_arrow(colors, Vector2(px, py), wind / speed * minf(speed * ARROW_PX_PER_MS, ARROW_MAX_PX),
					COLOR_WIND_LIFTING if speed >= threshold else COLOR_WIND)
	return {"image": colors, "t_min_k": t_min, "t_max_k": t_max, "wind_max_m_s": wind_max, "systems": counts}


## A dark pixel wherever the pressure anomaly crosses an isobar to the right or below.
static func _draw_isobars(image: Image, anomaly: PackedFloat32Array) -> void:
	var w := image.get_width()
	var h := image.get_height()
	for y in h - 1:
		for x in w - 1:
			var here := _isobar(anomaly[y * w + x])
			if here != _isobar(anomaly[y * w + x + 1]) or here != _isobar(anomaly[(y + 1) * w + x]):
				image.set_pixel(x, y, image.get_pixel(x, y).lerp(COLOR_ISOBAR, 0.55))


## Which band between two isobars a pressure anomaly lies in. The bands are centred on 0, so calm air (an
## anomaly wandering around nothing) draws no line.
static func _isobar(anomaly_pa: float) -> float:
	return floorf(anomaly_pa / ISOBAR_PA + 0.5)


## A ring one σ around a system's centre (wider toward the poles, as the ground is on this picture), by
## its kind, and a dot at the centre.
static func _draw_system(image: Image, system: Dictionary, radius_m: float) -> void:
	var w := image.get_width()
	var h := image.get_height()
	var color := COLOR_HIGH
	if system["kind"] == WeatherSampler.KIND_DUST_STORM:
		color = COLOR_STORM
	elif system["kind"] != WeatherSampler.KIND_ANTICYCLONE:
		color = COLOR_LOW
	var centre := Vector2((float(system["lon"]) + 180.0) / 360.0 * w, (90.0 - float(system["lat"])) / 180.0 * h)
	var ry := rad_to_deg(float(system["sigma_m"]) / radius_m) / 180.0 * h
	var rx := ry / maxf(cos(deg_to_rad(float(system["lat"]))), 0.15)
	for k in 360:
		var a := deg_to_rad(float(k))
		for thick in 2:
			_plot(image, centre + Vector2(cos(a) * (rx + thick), sin(a) * (ry + thick)), color)
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			_plot(image, centre + Vector2(dx, dy), color)


## An arrow from [param from] along [param along] (pixels), two pixels thick, with its head.
static func _draw_arrow(image: Image, from: Vector2, along: Vector2, color: Color) -> void:
	var to := from + along
	_draw_line(image, from, to, color)
	var back := -along.normalized() * minf(along.length() * 0.45, 9.0)
	_draw_line(image, to, to + back.rotated(0.5), color)
	_draw_line(image, to, to + back.rotated(-0.5), color)


static func _draw_line(image: Image, from: Vector2, to: Vector2, color: Color) -> void:
	var steps := maxi(ceili(from.distance_to(to)), 1)
	for k in steps + 1:
		var p := from.lerp(to, float(k) / steps)
		_plot(image, p, color)
		_plot(image, p + Vector2(1, 0), color)
		_plot(image, p + Vector2(0, 1), color)


## One pixel, the longitude wrapping round the picture.
static func _plot(image: Image, at: Vector2, color: Color) -> void:
	var y := int(at.y)
	if y >= 0 and y < image.get_height():
		image.set_pixel(posmod(int(at.x), image.get_width()), y, color)
