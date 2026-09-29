extends GutTest
## A profiled line round a planet has 200 k knots and thousands of segments:
## the per-chunk builders read it through binary searches and through a
## profile SLICED to the chunk's stretch (GradeProfile.open_range /
## segment_range / slice, GradeBed.slice_profiles). They must answer exactly
## what a walk over the whole profile answered — bit for bit.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_grade_profile_slice.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const LENGTH_M := 30000.0
const Kind := GradeSettings.Kind
var _mpd := RADIUS * PI / 180.0
var _road: Dictionary
var _prof: Dictionary


func before_all() -> void:
	_road = _line(LENGTH_M, 7)
	_prof = GradeProfile.compute(_road, func(d: Vector3) -> float: return _terrain(d))


func after_all() -> void:
	GradeBed.use_native = true


## A railway with a gentle bend, points every 20 m.
func _line(length_m: float, fid: int) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		var y := 40.0 * sin(d / 300.0)
		cl.append(Vector2(LON0 + d / (_mpd * clat), LAT + y / _mpd))
		cum.append(d)
	return {"feature_id": fid, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": 2}


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	return (lon - LON0) * (RADIUS * PI / 180.0) * cos(deg_to_rad(LAT))


## Hills and valleys every few km, bumps every few hundred metres: every
## kind of run, many times over.
func _terrain(dir: Vector3) -> float:
	var s := _east_m(dir)
	return 800.0 + 120.0 * sin(s / 900.0) + 25.0 * sin(s / 97.0) + 0.001 * s


## Pieces cut every 160 m, as a chunk's partitioned records are.
func _pieces_of(line: Dictionary) -> Array:
	var out: Array = []
	var cl: PackedVector2Array = line["centerline"]
	var cum: PackedFloat64Array = line["_cum_lengths"]
	var i := 0
	while i < cl.size() - 1:
		var j := mini(i + 8, cl.size() - 1)
		var piece := line.duplicate()
		piece["centerline"] = cl.slice(i, j + 1)
		piece["_cum_lengths"] = cum.slice(i, j + 1)
		out.append(piece)
		i = j
	return out


func test_the_line_has_every_kind_of_run() -> void:
	assert_true(_prof["ok"])
	var seen := {}
	for seg in _prof["segments"]:
		seen[int(seg["kind"])] = true
	assert_true(seen.has(Kind.TUNNEL) and seen.has(Kind.BRIDGE) and seen.has(Kind.GROUND),
			"the synthetic relief must exercise tunnels, viaducts and ground: %s" % [seen.keys()])
	assert_gt((_prof["segments"] as Array).size(), 20)


func test_open_range_is_the_strict_filter() -> void:
	var ka: PackedFloat64Array = _prof["knots_along"]
	for i in 400:
		var lo := fmod(i * 173.3, LENGTH_M + 400.0) - 200.0
		var hi := lo + fmod(i * 37.1, 900.0)
		# Exactly on a knot, now and then.
		if i % 5 == 0:
			lo = ka[(i * 13) % ka.size()]
		if i % 7 == 0:
			hi = ka[(i * 17) % ka.size()]
		var want := PackedFloat64Array()
		for k in ka:
			if k > lo and k < hi:
				want.append(k)
		var r := GradeProfile.open_range(ka, lo, hi)
		assert_eq(ka.slice(r.x, r.y), want, "open_range(%f, %f)" % [lo, hi])


func test_segment_range_covers_every_overlapping_segment() -> void:
	var segs: Array = _prof["segments"]
	for i in 400:
		var lo := fmod(i * 211.7, LENGTH_M + 400.0) - 200.0
		var hi := lo + fmod(i * 53.3, 1200.0)
		if i % 4 == 0:
			lo = float(segs[(i * 3) % segs.size()]["hi"])
		var r := GradeProfile.segment_range(_prof, lo, hi)
		for si in segs.size():
			var s: Dictionary = segs[si]
			if float(s["hi"]) >= lo and float(s["lo"]) <= hi:
				assert_true(si >= r.x and si < r.y,
						"segment %d [%f, %f] overlaps [%f, %f] but is outside %s"
						% [si, s["lo"], s["hi"], lo, hi, r])


func test_a_slice_answers_like_the_whole_profile() -> void:
	var m := GradeProfile.SLICE_MARGIN_M
	var bad := 0
	for w in 60:
		var lo := fmod(w * 1543.1, LENGTH_M) - 100.0
		var hi := lo + 150.0 + fmod(w * 97.3, 600.0)
		var sl := GradeProfile.slice(_prof, lo - m, hi + m)
		assert_false(sl.has("stations_along"), "a slice carries no stations")
		assert_lt((sl["knots_along"] as PackedFloat64Array).size(),
				(_prof["knots_along"] as PackedFloat64Array).size())
		for i in 200:
			var a := lo + (hi - lo) * float(i) / 199.0
			if GradeProfile.z_track_at(sl, a) != GradeProfile.z_track_at(_prof, a):
				bad += 1
			if GradeProfile.segment_at(sl, a) != GradeProfile.segment_at(_prof, a):
				bad += 1
			if GradeProfile.hw_at(sl, a) != GradeProfile.hw_at(_prof, a):
				bad += 1
			for z_off in [1.0, 3.0, 12.0]:
				var z: float = GradeProfile.z_track_at(_prof, a) + z_off
				if GradeTunnel.inside_bore(sl, a, 1.0, z) != GradeTunnel.inside_bore(_prof, a, 1.0, z):
					bad += 1
	assert_eq(bad, 0, "sliced answers differ from the whole profile's")


func test_bore_triangle_test_matches_every_tunnel_box() -> void:
	# The along prefilter must never drop a tunnel box the triangle meets.
	var bw := GradeTunnel.bore_half_width(float(_prof["hw_m"]))
	var hood := GradeSettings.PORTAL_HOOD_M
	var z_lo := 0.3
	var z_hi := GradeSettings.BORE_H_M + GradeSettings.TUNNEL_WALL_M
	var hits := 0
	for i in 3000:
		var a := fmod(i * 11.37, LENGTH_M)
		var l0 := Vector3(a, fmod(i * 1.7, 12.0) - 6.0, fmod(i * 0.9, 9.0) - 1.0)
		var l1 := l0 + Vector3(fmod(i * 3.3, 30.0) - 15.0, 2.0, 1.5)
		var l2 := l0 + Vector3(4.0, -3.0, fmod(i * 0.7, 6.0) - 3.0)
		var brute := false
		for seg in GradeTunnel.profile_tunnels(_prof):
			var a_lo: float = float(seg["lo"]) - hood
			var a_hi: float = float(seg["hi"]) + hood
			var c := Vector3(0.5 * (a_lo + a_hi), 0.0, 0.5 * (z_lo + z_hi))
			var h := Vector3(0.5 * (a_hi - a_lo), bw, 0.5 * (z_hi - z_lo))
			if GradeTunnel._tri_box(l0 - c, l1 - c, l2 - c, h):
				brute = true
				break
		if brute:
			hits += 1
		assert_eq(GradeTunnel.tri_hits_bore_local(_prof, l0, l1, l2), brute, "triangle %d" % i)
	assert_gt(hits, 20, "some triangles must cross a bore")


func test_bed_stations_are_those_of_the_full_walk() -> void:
	var ka: PackedFloat64Array = _prof["knots_along"]
	var seg_lo: PackedFloat64Array = _prof["seg_lo"]
	for i in 300:
		var a0 := fmod(i * 97.1, LENGTH_M)
		var a1 := a0 + 5.0 + fmod(i * 31.3, 400.0)
		if i % 6 == 0:
			a0 = ka[(i * 7) % ka.size()]
		var got := GradeBed._stations(a0, a1, 4.0, ka, seg_lo, i % 2 == 0)
		# The walk this replaced.
		var n_sub := maxi(1, ceili((a1 - a0) / 4.0))
		var out := PackedFloat64Array()
		for j in n_sub:
			out.append(a0 + (a1 - a0) * float(j) / float(n_sub))
		for k in ka:
			if k > a0 + 1e-6 and k < a1 - 1e-6:
				out.append(k)
		for s in seg_lo:
			if s > a0 + 1e-6 and s < a1 - 1e-6:
				out.append(s)
		if i % 2 == 0:
			out.append(a1)
		out.sort()
		var want := PackedFloat64Array()
		for v in out:
			if want.is_empty() or v - want[want.size() - 1] > 1e-3:
				want.append(v)
		assert_eq(got, want, "stations of [%f, %f]" % [a0, a1])


func test_rail_collision_boxes_unchanged_by_the_search() -> void:
	# A piece's boxes from the whole profile and from its slice: the knot
	# cuts come from a binary search, the lookups from the slice.
	var pieces := _pieces_of(_road)
	for pi in range(0, pieces.size(), 17):
		var piece: Dictionary = pieces[pi]
		var sl: Dictionary = GradeBed.slice_profiles([piece], {7: _prof})[7]
		var full := RailwayTrack.piece_collision_boxes(piece, _prof, RADIUS, Vector3.ZERO)
		var cut := RailwayTrack.piece_collision_boxes(piece, sl, RADIUS, Vector3.ZERO)
		assert_eq(str(cut), str(full), "piece %d" % pi)


func test_carve_on_a_sliced_context_is_bit_identical() -> void:
	var pieces_all := _pieces_of(_road)
	var mismatches := 0
	var moved := 0
	for c in range(0, pieces_all.size() - 3, 23):
		# A chunk's candidate set: three consecutive pieces.
		var pieces := pieces_all.slice(c, c + 3)
		var full := {7: _prof}
		var sliced := GradeBed.slice_profiles(pieces, full)
		var cum0: float = (pieces[0]["_cum_lengths"] as PackedFloat64Array)[0]
		for use_native in [false, true]:
			if use_native and not GradeBed.native_available():
				continue
			GradeBed.use_native = use_native
			var ctx_f := {"pieces": pieces, "profiles": full, "pads": [], "m_per_deg": _mpd,
					"floor_margin": 3.4, "native": GradeBed.make_native(pieces, full)}
			var ctx_s := {"pieces": pieces, "profiles": sliced, "pads": [], "m_per_deg": _mpd,
					"floor_margin": 3.4, "native": GradeBed.make_native(pieces, sliced)}
			for i in 300:
				var e := cum0 + fmod(i * 7.919, 520.0) - 20.0
				var nth := fmod(i * 13.37, 50.0) - 25.0
				var ll := Vector2(LON0 + e / (_mpd * cos(deg_to_rad(LAT))), LAT + nth / _mpd)
				var h := 950.0 + fmod(i * 3.1, 300.0)
				var hf := GradeBed.apply(h, ll, ctx_f)
				if hf != GradeBed.apply(h, ll, ctx_s):
					mismatches += 1
				if hf != h:
					moved += 1
	GradeBed.use_native = true
	assert_gt(moved, 100, "the points hit cuttings")
	assert_eq(mismatches, 0, "a sliced context carves differently")
