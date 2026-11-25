extends RefCounted
## The pure parts of the star map's weather layer (star_map_weather.gd): the lon/lat grid the weather is
## sampled on, the isobars traced through it, the pressure centres found in it, the lattice the wind's
## arrows stand on at a given zoom, and the line the cursor readout writes. No node, no tree: a worker can
## run any of it, and the tests call it directly.
##
## The grid's convention, everywhere in this file: cell centres, longitude -180 → +180 from the left
## column, latitude +90 → -90 from the top row (HEALPix.vec2lonlat's degrees). Loaded by path (preload),
## never by a class name.

## The grid the weather is sampled on: 4° cells, 4 050 samples (a few hundred ms of script on a worker).
const COARSE_W: int = 90
const COARSE_H: int = 45
## How much finer the grid the isobars are traced on is (Catmull-Rom between the samples): 4° / 3.
const UPSAMPLE: int = 3
## One isobar every 2 hPa.
const ISOBAR_PA: float = 200.0
## A pressure centre found in the grid (when no system is known) stands this many cells above or below
## everything around it...
const EXTREMUM_REACH: int = 3
## ...and at least this much (Pa) above the lowest / below the highest of them: a flat field has none.
const EXTREMUM_MIN_PA: float = 200.0
## The arrows: about this many pixels apart on screen, on a lattice whose step is ARROW_BASE_DEG halved
## as often as the zoom asks (ARROW_LEVELS times at most), ARROW_HALF steps either side of the view's centre.
const ARROW_PX: float = 56.0
const ARROW_BASE_DEG: float = 16.0
const ARROW_LEVELS: int = 12
const ARROW_HALF: int = 24
## Under this wind (m/s) the readout says calm and names no direction.
const CALM_M_S: float = 0.3


## Longitude of the centre of column [param x] of a grid [param w] wide.
static func cell_lon(x: float, w: int) -> float:
	return -180.0 + (x + 0.5) * 360.0 / float(w)


## Latitude of the centre of row [param y] of a grid [param h] high.
static func cell_lat(y: float, h: int) -> float:
	return 90.0 - (y + 0.5) * 180.0 / float(h)


## The weather on a [param w] × [param h] grid: [param sample] is called (longitude, latitude in degrees)
## once per cell and answers WeatherSource's keys. Returns {w, h, pressure (Pa), east, north (m/s): one
## float per cell, row after row; has_pressure: whether the source gave a pressure at all}. A key the
## source leaves out reads 0.
static func sample_grid(sample: Callable, w: int, h: int) -> Dictionary:
	var pressure := PackedFloat32Array()
	var east := PackedFloat32Array()
	var north := PackedFloat32Array()
	pressure.resize(w * h)
	east.resize(w * h)
	north.resize(w * h)
	var has_pressure: bool = false
	for y in h:
		var lat: float = cell_lat(y, h)
		for x in w:
			var s: Dictionary = sample.call(cell_lon(x, w), lat)
			var i: int = y * w + x
			if s.has("pressure_pa"):
				has_pressure = true
				pressure[i] = float(s["pressure_pa"])
			east[i] = float(s.get("wind_east_m_s", 0.0))
			north[i] = float(s.get("wind_north_m_s", 0.0))
	return {"w": w, "h": h, "pressure": pressure, "east": east, "north": north, "has_pressure": has_pressure}


## [param values] (a [param w] × [param h] grid) at a longitude and latitude, bilinear between the four
## cells around it: the longitude wraps, the latitude stops at the first and last rows.
static func bilinear(values: PackedFloat32Array, w: int, h: int, lon: float, lat: float) -> float:
	var gx: float = (lon + 180.0) / 360.0 * float(w) - 0.5
	var gy: float = clampf((90.0 - lat) / 180.0 * float(h) - 0.5, 0.0, float(h - 1))
	var x0: int = floori(gx)
	var fx: float = gx - float(x0)
	var y0: int = mini(floori(gy), maxi(h - 2, 0))
	var fy: float = gy - float(y0)
	var y1: int = mini(y0 + 1, h - 1)
	var xa: int = posmod(x0, w)
	var xb: int = posmod(x0 + 1, w)
	var top: float = lerpf(values[y0 * w + xa], values[y0 * w + xb], fx)
	var bottom: float = lerpf(values[y1 * w + xa], values[y1 * w + xb], fx)
	return lerpf(top, bottom, fy)


## [param values] on a grid [param factor] times finer both ways, Catmull-Rom through the samples
## (separable: rows, then columns), the longitude wrapping and the latitude held at its edges. A finer
## cell's centre maps to (u + 0.5) / factor - 0.5 coarse cells, so both grids keep the convention above.
static func upsample(values: PackedFloat32Array, w: int, h: int, factor: int) -> PackedFloat32Array:
	var fw: int = w * factor
	var fh: int = h * factor
	var rows := PackedFloat32Array()
	rows.resize(fw * h)
	for y in h:
		var base: int = y * w
		for u in fw:
			var g: float = (float(u) + 0.5) / float(factor) - 0.5
			var i: int = floori(g)
			rows[y * fw + u] = _catmull(values[base + posmod(i - 1, w)], values[base + posmod(i, w)],
					values[base + posmod(i + 1, w)], values[base + posmod(i + 2, w)], g - float(i))
	var out := PackedFloat32Array()
	out.resize(fw * fh)
	for v in fh:
		var g: float = (float(v) + 0.5) / float(factor) - 0.5
		var j: int = floori(g)
		var t: float = g - float(j)
		var r0: int = clampi(j - 1, 0, h - 1) * fw
		var r1: int = clampi(j, 0, h - 1) * fw
		var r2: int = clampi(j + 1, 0, h - 1) * fw
		var r3: int = clampi(j + 2, 0, h - 1) * fw
		for u in fw:
			out[v * fw + u] = _catmull(rows[r0 + u], rows[r1 + u], rows[r2 + u], rows[r3 + u], t)
	return out


static func _catmull(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)))


## The isobars of [param values] (a [param w] × [param h] grid, Pa) every [param step] Pa, by marching
## squares between the cell centres (the longitude wraps): segments as pairs of (longitude, latitude)
## points, [a0, b0, a1, b1, ...]. A saddle is resolved by the mean of its four corners.
static func isobars(values: PackedFloat32Array, w: int, h: int, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if step <= 0.0:
		return out
	for y in h - 1:
		for x in w:
			var x1: int = (x + 1) % w
			var tl: float = values[y * w + x]
			var tr: float = values[y * w + x1]
			var br: float = values[(y + 1) * w + x1]
			var bl: float = values[(y + 1) * w + x]
			var lo: float = minf(minf(tl, tr), minf(br, bl))
			var hi: float = maxf(maxf(tl, tr), maxf(br, bl))
			for k in range(ceili(lo / step), floori(hi / step) + 1):
				_cell_isobar(out, float(k) * step, x, y, w, h, tl, tr, br, bl)
	return out


## The segments of the isobar [param level] across the cell whose top-left corner is (x, y).
static func _cell_isobar(out: PackedVector2Array, level: float, x: int, y: int, w: int, h: int,
		tl: float, tr: float, br: float, bl: float) -> void:
	var in_tl: bool = tl >= level
	var in_tr: bool = tr >= level
	var in_br: bool = br >= level
	var in_bl: bool = bl >= level
	# The crossings on the top, right, bottom and left edges, in grid cells (NAN: none).
	var none := Vector2(NAN, NAN)
	var top: Vector2 = _cross(Vector2(x, y), Vector2(x + 1, y), tl, tr, level) if in_tl != in_tr else none
	var right: Vector2 = _cross(Vector2(x + 1, y), Vector2(x + 1, y + 1), tr, br, level) if in_tr != in_br else none
	var bottom: Vector2 = _cross(Vector2(x, y + 1), Vector2(x + 1, y + 1), bl, br, level) if in_bl != in_br else none
	var left: Vector2 = _cross(Vector2(x, y), Vector2(x, y + 1), tl, bl, level) if in_tl != in_bl else none
	var found: Array[Vector2] = []
	for p: Vector2 in [top, right, bottom, left]:
		if not is_nan(p.x):
			found.append(p)
	if found.size() == 2:
		_emit(out, found[0], found[1], w, h)
	elif found.size() == 4:
		# A saddle: two inside corners face each other. The mean says whether they meet through the middle
		# (the outside corners are cut off) or not (the inside ones are).
		var centre_in: bool = (tl + tr + br + bl) * 0.25 >= level
		if centre_in != in_tl:
			_emit(out, left, top, w, h)
			_emit(out, right, bottom, w, h)
		else:
			_emit(out, top, right, w, h)
			_emit(out, bottom, left, w, h)


static func _cross(a: Vector2, b: Vector2, va: float, vb: float, level: float) -> Vector2:
	var t: float = 0.5 if is_equal_approx(va, vb) else clampf((level - va) / (vb - va), 0.0, 1.0)
	return a.lerp(b, t)


static func _emit(out: PackedVector2Array, a: Vector2, b: Vector2, w: int, h: int) -> void:
	out.append(Vector2(cell_lon(a.x, w), cell_lat(a.y, h)))
	out.append(Vector2(cell_lon(b.x, w), cell_lat(b.y, h)))


## The pressure centres of [param values] (a [param w] × [param h] grid, Pa): the cells at least as high
## (or as low) as every cell within EXTREMUM_REACH, standing EXTREMUM_MIN_PA clear of the other end of that
## neighbourhood. [{lon, lat, high: bool, pressure_pa}]. What marks the highs and lows when the weather
## comes from a field with no system named in it.
static func extrema(values: PackedFloat32Array, w: int, h: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for y in range(EXTREMUM_REACH, h - EXTREMUM_REACH):
		for x in w:
			var v: float = values[y * w + x]
			var is_max: bool = true
			var is_min: bool = true
			var lowest: float = v
			var highest: float = v
			for dy in range(-EXTREMUM_REACH, EXTREMUM_REACH + 1):
				for dx in range(-EXTREMUM_REACH, EXTREMUM_REACH + 1):
					if dx == 0 and dy == 0:
						continue
					var n: float = values[(y + dy) * w + posmod(x + dx, w)]
					# Ties: only the first cell of a plateau (in reading order) is kept.
					var earlier: bool = dy < 0 or (dy == 0 and dx < 0)
					if n > v or (earlier and n == v):
						is_max = false
					if n < v or (earlier and n == v):
						is_min = false
					lowest = minf(lowest, n)
					highest = maxf(highest, n)
			if is_max and v - lowest >= EXTREMUM_MIN_PA:
				out.append({"lon": cell_lon(x, w), "lat": cell_lat(y, h), "high": true, "pressure_pa": v})
			elif is_min and highest - v >= EXTREMUM_MIN_PA:
				out.append({"lon": cell_lon(x, w), "lat": cell_lat(y, h), "high": false, "pressure_pa": v})
	return out


## The step (degrees) of the arrows' lattice for a pixel covering [param metres_per_pixel] on a body
## [param radius_m] across: ARROW_BASE_DEG halved until the arrows stand about ARROW_PX apart.
static func arrow_step_deg(metres_per_pixel: float, radius_m: float) -> float:
	var step: float = ARROW_BASE_DEG
	if metres_per_pixel <= 0.0 or radius_m <= 0.0:
		return step
	var wanted: float = rad_to_deg(metres_per_pixel * ARROW_PX / radius_m)
	for i in ARROW_LEVELS:
		if step * 0.5 < wanted:
			break
		step *= 0.5
	return step


## Where the arrows stand around ([param lon], [param lat]) for a lattice [param step] degrees: multiples
## of the step, ARROW_HALF of them either side, rows wider apart in longitude toward the poles (by powers
## of two, so they stay on the lattice) and the whole circle when it is that close.
static func arrow_lattice(lon: float, lat: float, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var row0: int = roundi(lat / step)
	for j in range(-ARROW_HALF, ARROW_HALF + 1):
		var row_lat: float = float(row0 + j) * step
		if absf(row_lat) >= 90.0 - step * 0.25:
			continue
		var widen: float = pow(2.0, maxf(roundf(log(1.0 / cos(deg_to_rad(row_lat))) / log(2.0)), 0.0))
		var lon_step: float = step * widen
		if lon_step * float(ARROW_HALF * 2 + 1) >= 360.0:
			var count: int = maxi(floori(360.0 / lon_step), 1)
			for i in count:
				out.append(Vector2(-180.0 + float(i) * 360.0 / float(count), row_lat))
		else:
			var col0: int = roundi(lon / lon_step)
			for i in range(-ARROW_HALF, ARROW_HALF + 1):
				out.append(Vector2(wrapf(float(col0 + i) * lon_step, -180.0, 180.0), row_lat))
	return out


## The eight winds' name for a direction [param from_deg] (clockwise from north), from the letters
## [param n], [param e], [param s], [param w] ("N", "E", "S", "O" in French): NE, SO...
static func compass(from_deg: float, n: String, e: String, s: String, w: String) -> String:
	var names: Array[String] = [n, n + e, e, s + e, s, s + w, w, n + w]
	return names[posmod(roundi(fposmod(from_deg, 360.0) / 45.0), 8)]


## What the cursor readout adds for the weather [param sample] (WeatherSource's keys and ClimateWeather's):
## the wind in km/h and where it blows from, the pressure in hPa with what the systems add, the air's
## temperature, the dust's optical depth — a part only for the keys the source gives. [param tr_fn] turns a
## translation key into its text (the node's tr), so this stays pure.
static func readout_text(sample: Dictionary, tr_fn: Callable) -> String:
	if sample.is_empty():
		return ""
	var parts: PackedStringArray = []
	var east: float = float(sample.get("wind_east_m_s", 0.0))
	var north: float = float(sample.get("wind_north_m_s", 0.0))
	var speed: float = float(sample.get("wind_speed_m_s", sqrt(east * east + north * north)))
	if speed < CALM_M_S:
		parts.append(str(tr_fn.call("%%HUD_MAP_WEATHER_CALM")))
	else:
		var from: float = float(sample.get("wind_from_deg", rad_to_deg(atan2(-east, -north))))
		var heading: String = compass(from, tr_fn.call("%%COMPASS_N"), tr_fn.call("%%COMPASS_E"),
				tr_fn.call("%%COMPASS_S"), tr_fn.call("%%COMPASS_W"))
		parts.append(str(tr_fn.call("%%HUD_MAP_WEATHER_WIND")) % ["%.0f" % (speed * 3.6), heading])
	if sample.has("pressure_pa"):
		parts.append(str(tr_fn.call("%%HUD_MAP_WEATHER_PRESSURE")) % ["%.0f" % (float(sample["pressure_pa"]) / 100.0),
				"%+.0f" % (float(sample.get("pressure_anomaly_pa", 0.0)) / 100.0)])
	if sample.has("temperature_k"):
		parts.append(str(tr_fn.call("%%HUD_MAP_WEATHER_TEMPERATURE")) % ("%.0f" % (float(sample["temperature_k"]) - 273.15)))
	if sample.has("dust_tau"):
		parts.append(str(tr_fn.call("%%HUD_MAP_WEATHER_DUST")) % ("%.1f" % float(sample["dust_tau"])))
	return "   ".join(parts)
