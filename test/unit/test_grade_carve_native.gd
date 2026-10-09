extends GutTest
## GradeCarveNative (C#) must carve exactly what GradeBed.apply's GDScript
## carves — the nearest piece, the cutting / channel rule and the coarse
## shave — bit for bit, for a graded road and for a lava flow (varying width,
## sunk floor, crust overlap), on points around and away from the lines.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_grade_carve_native.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
var _mpd := RADIUS * PI / 180.0


func after_all() -> void:
	GradeBed.use_native = true


func _line(length_m: float, fid: int, north_m: float, over: Dictionary) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		# A gentle bend so the nearest segment changes along the line.
		var y := north_m + 40.0 * sin(d / 300.0)
		cl.append(Vector2(LON0 + d / (_mpd * clat), LAT + y / _mpd))
		cum.append(d)
	var z := {"feature_id": fid, "centerline": cl, "_cum_lengths": cum}
	z.merge(over, true)
	return z


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(-dir.z, dir.x))
	return (lon - LON0) * (RADIUS * PI / 180.0) * cos(deg_to_rad(LAT))


func _terrain(dir: Vector3) -> float:
	var s := _east_m(dir)
	var h := 500.0 - 0.04 * s
	if s >= 600.0 and s <= 900.0:
		h += 35.0 * sin(PI * (s - 600.0) / 300.0)
	return h


## Pieces cut every 150 m, as a chunk's partitioned records are.
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


func test_native_carve_is_bit_identical() -> void:
	assert_true(GradeBed.native_available(), "the C# assembly must be built")
	var sampler := func(d: Vector3) -> float: return _terrain(d)
	var road := _line(1500.0, 9, 0.0, {"road_type": "road", "max_slope_degrees": 4,
			"width_m": 6.0, "half_width_m": 3.0})
	var lava := _line(1500.0, (1 << 30) + 1, 250.0, {"road_type": LavaSettings.LAVA_TYPE,
			"state": "active", "width_start_m": 10.0, "width_end_m": 40.0, "width": 40.0,
			"width_m": 40.0, "half_width_m": 20.0, "depth_m": 3.0})
	var profiles := {9: GradeProfile.compute(road, sampler),
			(1 << 30) + 1: GradeProfile.compute(lava, sampler)}
	assert_true(profiles[9]["ok"] and profiles[(1 << 30) + 1]["ok"])
	var pieces := _pieces_of(road) + _pieces_of(lava)
	var native := GradeBed.make_native(pieces, profiles)
	assert_true(native != null, "native built")
	var mismatches := 0
	var moved := 0
	for i in 6000:
		var e := fmod(i * 7.919, 1600.0) - 50.0
		var nth := fmod(i * 13.37, 500.0) - 125.0
		var ll := Vector2(LON0 + e / (_mpd * cos(deg_to_rad(LAT))), LAT + nth / _mpd)
		var h := 480.0 + fmod(i * 3.1, 80.0)
		for mode in 2:
			var ctx := {"pieces": pieces, "profiles": profiles, "pads": [], "m_per_deg": _mpd}
			if mode == 0:
				ctx["floor_margin"] = 3.4
			else:
				ctx["coarse_band_m"] = 37.0
			var gd := GradeBed.apply(h, ll, ctx)
			ctx["native"] = native
			var cs := GradeBed.apply(h, ll, ctx)
			if gd != cs:
				mismatches += 1
			if gd != h:
				moved += 1
	assert_gt(moved, 1500, "the points hit cuttings, channels and shaves")
	assert_eq(mismatches, 0, "C# and GDScript carve differently")
