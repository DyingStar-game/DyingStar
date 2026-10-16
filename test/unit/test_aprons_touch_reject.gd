extends GutTest
## PadBed.aprons_touch skips the separating-axis test for pads whose circumscribed circles are apart.
## A speed-up only: every pair here gets the same answer as the plain test it replaced (kept below as
## the reference), and so does the level every pad of a village settles on (PadLevels.settle).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_aprons_touch_reject.gd

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = 20261016


## The test before the rejection, verbatim.
static func _reference(a: Dictionary, b: Dictionary, m_per_deg: float) -> bool:
	if PadBed.is_notch(a) or PadBed.is_notch(b):
		return false
	var lat0: float = float(a["lat"])
	var ls := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6)
	var t := Vector2(wrapf(float(b["lon"]) - float(a["lon"]), -180.0, 180.0) * ls * m_per_deg,
			(float(b["lat"]) - lat0) * m_per_deg)
	var ya: float = float(a["yaw"])
	var yb: float = float(b["yaw"])
	var axes := [Vector2(cos(ya), sin(ya)), Vector2(-sin(ya), cos(ya)),
			Vector2(cos(yb), sin(yb)), Vector2(-sin(yb), cos(yb))]
	var ea := Vector2(float(a["hx"]), float(a["hy"])) + Vector2.ONE * float(a["apron_m"])
	var eb := Vector2(float(b["hx"]), float(b["hy"])) + Vector2.ONE * float(b["apron_m"])
	for l: Vector2 in axes:
		var ra: float = ea.x * absf((axes[0] as Vector2).dot(l)) + ea.y * absf((axes[1] as Vector2).dot(l))
		var rb: float = eb.x * absf((axes[2] as Vector2).dot(l)) + eb.y * absf((axes[3] as Vector2).dot(l))
		if absf(t.dot(l)) > ra + rb:
			return false
	return true


func _pad(uuid: String, lon: float, lat: float) -> Dictionary:
	return {"uuid": uuid, "lon": lon, "lat": lat, "yaw": _rng.randf_range(-PI, PI),
		"hx": _rng.randf_range(0.2, 50.0), "hy": _rng.randf_range(0.2, 50.0),
		"apron_m": _rng.randf_range(0.0, 10.0), "z_off": 0.0, "z": _rng.randf_range(0.0, 50.0), "talus_m": 5.0}


## [param b] at [param dist_m] from [param a] in a random direction, on a's tangent plane.
func _pad_at(a: Dictionary, uuid: String, dist_m: float) -> Dictionary:
	var h: float = _rng.randf_range(-PI, PI)
	var ls := cos(deg_to_rad(float(a["lat"])))
	return _pad(uuid, float(a["lon"]) + cos(h) * dist_m / (MPD * ls), float(a["lat"]) + sin(h) * dist_m / MPD)


func test_random_pairs_get_the_same_answer() -> void:
	var touching: int = 0
	var rejected: int = 0
	for k in 20000:
		var a := _pad("a", _rng.randf_range(-179.0, 179.0), _rng.randf_range(-85.0, 85.0))
		var b := _pad_at(a, "b", 0.0)
		var ea := Vector2(float(a["hx"]), float(a["hy"])) + Vector2.ONE * float(a["apron_m"])
		var eb := Vector2(float(b["hx"]), float(b["hy"])) + Vector2.ONE * float(b["apron_m"])
		var bound: float = ea.length() + eb.length()
		# Around the circle bound and around the boxes' own reach, where the two tests could disagree.
		var dist: float = bound * _rng.randf_range(0.0, 1.3) if k % 2 == 0 else bound + _rng.randf_range(-3.0, 3.0)
		b = _pad_at(a, "b", dist)
		var want: bool = _reference(a, b, MPD)
		assert_eq(PadBed.aprons_touch(a, b, MPD), want, "pair %d at %.3f m (bound %.3f)" % [k, dist, bound])
		if want:
			touching += 1
		if dist > bound + 1.5:
			rejected += 1
	assert_gt(touching, 2000, "enough pairs touch for the comparison to mean something")
	assert_gt(rejected, 2000, "and enough are rejected by the bound")


func test_a_village_settles_on_the_same_levels() -> void:
	# 120 pads 15-60 m apart on one slope: the levels with the rejection are the reference's levels.
	var finest: int = 8192
	var idx := PadIndex.new(finest)
	idx.set_radius(RADIUS)
	var own := {}
	var recs: Array = []
	for i in 120:
		var r := _pad("p%03d" % i, 10.0 + float(i % 12) * 30.0 / MPD, 45.0 + float(i / 12) * 35.0 / MPD)
		recs.append(r)
		own[r["uuid"]] = {"z": float(r["z"]), "talus_m": 5.0}
		idx.register(r)
	var memo := {}
	for r: Dictionary in recs:
		var got := PadLevels.level(idx, str(r["uuid"]), own, memo, finest, MPD)
		var want := _reference_level(idx, str(r["uuid"]), own, {}, finest, recs)
		assert_eq(got, want, "level of %s" % r["uuid"])


func test_settling_pad_by_pad_lands_on_the_reference_levels() -> void:
	# What an ingest does: one settle per registered pad, into a clone of the published index. The
	# levels reached are the ones the plain pairwise walk gives for the final set, in any order.
	var finest: int = 8192
	var idx := PadIndex.new(finest)
	idx.set_radius(RADIUS)
	var own := {}
	var recs: Array = []
	for i in 120:
		var r := _pad("p%03d" % i, 10.0 + float(i % 12) * 30.0 / MPD, 45.0 + float(i / 12) * 35.0 / MPD)
		recs.append(r)
		own[r["uuid"]] = {"z": float(r["z"]), "talus_m": 5.0}
	var order: Array = recs.duplicate()
	order.shuffle()
	for r: Dictionary in order:
		var next := idx.clone()
		next.register(r)
		PadLevels.settle(next, idx, [{}, r], own, finest, MPD)
		idx = next
	var memo := {}
	for r: Dictionary in recs:
		var u := str(r["uuid"])
		var want := _reference_level(idx, u, own, memo, finest, recs)
		var got: Dictionary = idx.get_rec(u)
		assert_eq([float(got["z"]), float(got["talus_m"])], want, "level of %s" % u)


## PadLevels.level over the reference test: the plain pairwise walk, no index, no rejection.
func _reference_level(idx: PadIndex, u: String, own: Dictionary, memo: Dictionary, finest: int, recs: Array) -> Array:
	if memo.has(u):
		return memo[u]
	var rec: Dictionary = idx.get_rec(u)
	var mine: Dictionary = own[u]
	var area := float(rec["hx"]) * float(rec["hy"])
	var best: Dictionary = {}
	for c: Dictionary in recs:
		if str(c["uuid"]) == u or not _reference(rec, c, MPD):
			continue
		if float(c["hx"]) * float(c["hy"]) > area and (best.is_empty() or PadBed.outranks(c, best)):
			best = c
	var z := float(mine["z"])
	var talus := float(mine["talus_m"])
	if not best.is_empty():
		var up := _reference_level(idx, str(best["uuid"]), own, memo, finest, recs)
		talus = minf(talus + absf(float(up[0]) - z) / PadSettings.TALUS_SLOPE, PadSettings.TALUS_MAX_M)
		z = float(up[0])
	memo[u] = [z, talus]
	return memo[u]
