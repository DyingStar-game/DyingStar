extends GutTest
## PadBed.road_exclusion skips the walk of road segments that cannot reach the footprint. That is a
## speed-up only: every case here compares it, interval for interval and bit for bit, with the plain
## walk it replaced (kept below as the reference), on roads that cross, graze, miss, run along the pad
## over several segments, stop inside it, and cross the longitude wrap.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_pad_road_exclusion_reject.gd

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = 20261016


## The walk before the rejection, verbatim: the answer the fast one must give.
static func _reference(rec: Dictionary, cl: PackedVector2Array, cum: PackedFloat64Array,
		m_per_deg: float, half_width_m: float = 0.0) -> Array:
	var out: Array = []
	var n := cl.size()
	if n < 2 or cum.size() != n or m_per_deg <= 0.0 or PadBed.is_notch(rec):
		return out
	var limit: float = PadSettings.ROAD_CUT_MARGIN_M + maxf(half_width_m, 0.0)
	var step: float = PadSettings.ROAD_CUT_STEP_M
	var half := 0.5 * step
	var run_lo := INF
	var prev := INF
	for i in n - 1:
		var a: float = cum[i]
		var b: float = cum[i + 1]
		if b - a <= 1e-9:
			continue
		var s := a
		while s <= b:
			var t := (s - a) / (b - a)
			var p := cl[i].lerp(cl[i + 1], t)
			var inside := PadBed.sdf_m(rec, p, m_per_deg) <= limit
			if inside and run_lo == INF:
				run_lo = s - half
			elif not inside and run_lo != INF:
				out.append(Vector2(run_lo, prev + half))
				run_lo = INF
			prev = s
			s += step
	if run_lo != INF:
		out.append(Vector2(run_lo, prev + half))
	return out


func _pad(lon: float, lat: float, hx: float, hy: float, yaw: float) -> Dictionary:
	return {"uuid": "prop:test", "lon": lon, "lat": lat, "yaw": yaw, "hx": hx, "hy": hy,
		"apron_m": 8.0, "z_off": 0.0}


## A polyline through [param pts_m] (east, north metres on the tangent plane at lon0/lat0), with its
## cumulative lengths — the shape a road record carries.
static func _road(lon0: float, lat0: float, pts_m: Array) -> Array:
	var ls := cos(deg_to_rad(lat0))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var along := 0.0
	for i in pts_m.size():
		var p: Vector2 = pts_m[i]
		if i > 0:
			along += (p - (pts_m[i - 1] as Vector2)).length()
		cl.append(Vector2(lon0 + p.x / (MPD * ls), lat0 + p.y / MPD))
		cum.append(along)
	return [cl, cum]


func _assert_same(rec: Dictionary, road: Array, half_width: float, why: String) -> void:
	var fast: Array = PadBed.road_exclusion(rec, road[0], road[1], MPD, half_width)
	var slow: Array = _reference(rec, road[0], road[1], MPD, half_width)
	assert_eq(fast, slow, why)


func test_random_roads_give_the_same_intervals() -> void:
	var cut: int = 0
	for k in 300:
		var lat: float = _rng.randf_range(-80.0, 80.0)
		var lon: float = _rng.randf_range(-179.0, 179.0)
		var rec := _pad(lon, lat, _rng.randf_range(0.2, 50.0), _rng.randf_range(0.2, 50.0), _rng.randf_range(-PI, PI))
		# A wandering road, offset so that about half of them come close to the pad.
		var start := Vector2(_rng.randf_range(-400.0, -150.0), _rng.randf_range(-80.0, 80.0))
		var heading: float = _rng.randf_range(-0.6, 0.6)
		var pts: Array = [start]
		for i in _rng.randi_range(2, 60):
			heading += _rng.randf_range(-0.3, 0.3)
			var seg: float = _rng.randf_range(0.0, 40.0) if _rng.randf() < 0.9 else 0.0  # some zero-length
			pts.append((pts[-1] as Vector2) + Vector2(cos(heading), sin(heading)) * seg)
		var road := _road(lon, lat, pts)
		var hw: float = _rng.randf_range(0.0, 4.0)
		if not _reference(rec, road[0], road[1], MPD, hw).is_empty():
			cut += 1
		_assert_same(rec, road, hw, "random road %d" % k)
	assert_gt(cut, 30, "enough of the random roads actually cross a pad for the comparison to mean something")


func test_a_run_spanning_many_short_segments() -> void:
	# Vertices every 1.3 m straight through a 40 m pad: the cut opens in one segment and closes
	# thirty segments later, and segments next to the open run must never be skipped.
	var rec := _pad(10.0, 45.0, 20.0, 6.0, 0.3)
	var pts: Array = []
	var x := -300.0
	while x <= 300.0:
		pts.append(Vector2(x, 2.0))
		x += 1.3
	_assert_same(rec, _road(10.0, 45.0, pts), 1.5, "run over many segments")


func test_a_road_ending_inside_the_footprint() -> void:
	var rec := _pad(-70.0, 12.0, 15.0, 15.0, 0.0)
	_assert_same(rec, _road(-70.0, 12.0, [Vector2(-2000.0, 0.0), Vector2(-500.0, 3.0), Vector2(0.0, 0.0)]), 2.0,
			"the open run is closed at the end of the road")


func test_a_long_road_through_the_pad_and_its_cost() -> void:
	# A 20 km piece at 25 m vertex spacing crossing the pad once: the case that cost 7 ms a road.
	var rec := _pad(30.0, -20.0, 10.0, 48.0, 1.1)
	var pts: Array = []
	for i in 801:
		pts.append(Vector2(-10000.0 + 25.0 * i, 0.01 * i))
	var road := _road(30.0, -20.0, pts)
	var t0: int = Time.get_ticks_usec()
	var fast: Array = PadBed.road_exclusion(rec, road[0], road[1], MPD, 2.0)
	var t_fast: int = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var slow: Array = _reference(rec, road[0], road[1], MPD, 2.0)
	var t_slow: int = Time.get_ticks_usec() - t0
	assert_eq(fast, slow)
	assert_eq(fast.size(), 1, "one crossing")
	gut.p("20 km road: %.2f ms walked whole, %.2f ms with the rejection" % [t_slow / 1000.0, t_fast / 1000.0])
	assert_lt(t_fast * 10, t_slow, "the rejection skips nearly all of the walk")


func test_across_the_longitude_wrap() -> void:
	# The pad straddles the antimeridian; the road's longitudes jump from +179.99x to -179.99x.
	var rec := _pad(179.9999, 5.0, 12.0, 12.0, 0.2)
	var ls := cos(deg_to_rad(5.0))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	for i in 41:
		var e: float = -200.0 + 10.0 * i  # metres east of the pad
		var lon: float = wrapf(179.9999 + e / (MPD * ls), -180.0, 180.0)
		cl.append(Vector2(lon, 5.0 + 1.0 / MPD))
		cum.append(10.0 * i)
	_assert_same(rec, [cl, cum], 1.0, "across the wrap")


func test_near_the_pole() -> void:
	var rec := _pad(42.0, 89.3, 25.0, 9.0, -0.7)
	var pts: Array = []
	for i in 120:
		pts.append(Vector2(-600.0 + 10.0 * i, 30.0 * sin(0.05 * i)))
	_assert_same(rec, _road(42.0, 89.3, pts), 3.0, "high latitude")
