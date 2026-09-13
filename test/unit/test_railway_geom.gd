extends GutTest
## Suite for [GradeGeom] — where a point is relative to the track and how
## rail modules are laid along it.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_railway_geom.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const MPD := RADIUS * PI / 180.0


## Straight piece from [param a] to [param b] metres along, east-west or
## north-south, as a decoded record.
func _piece(a: float, b: float, north: bool = false, fid: int = 5) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int((b - a) / 10.0) + 1
	for i in n:
		var d := a + float(i) * 10.0
		if north:
			cl.append(Vector2(LON0, LAT + d / MPD))
		else:
			cl.append(Vector2(LON0 + d / (MPD * clat), LAT))
		cum.append(d)
	return {"feature_id": fid, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway"}


## A point [param along] metres down an east-west track and [param left_m] to
## its left (north).
func _east_point(along: float, left_m: float) -> Vector2:
	var clat := cos(deg_to_rad(LAT))
	return Vector2(LON0 + along / (MPD * clat), LAT + left_m / MPD)


func test_nearest_lateral_offset_is_metric_east_west() -> void:
	var pieces := [_piece(0.0, 100.0)]
	for off in [0.7175, -0.7175, 3.44, -3.44]:
		var q := GradeGeom.nearest_on_pieces(pieces, _east_point(40.0, off), MPD)
		assert_true(q["hit"])
		assert_almost_eq(float(q["lat_m"]), off, 0.01, "offset %.4f" % off)
		assert_almost_eq(float(q["along"]), 40.0, 0.01)
		assert_almost_eq(float(q["dist_m"]), absf(off), 0.01)
		assert_eq(int(q["fid"]), 5)


func test_nearest_lateral_offset_is_metric_north_south() -> void:
	# Northbound track: "left" is west, i.e. -lon. A degree of longitude is
	# cos(lat) short, which is exactly what the scaling must undo.
	var pieces := [_piece(0.0, 100.0, true)]
	var clat := cos(deg_to_rad(LAT))
	for off in [0.7175, -3.44]:
		var p := Vector2(LON0 - off / (MPD * clat), LAT + 40.0 / MPD)
		var q := GradeGeom.nearest_on_pieces(pieces, p, MPD)
		assert_almost_eq(float(q["lat_m"]), off, 0.01, "offset %.4f" % off)
		assert_almost_eq(float(q["along"]), 40.0, 0.01)


func test_left_matches_perp_deg() -> void:
	var pieces := [_piece(0.0, 100.0)]
	var cl: PackedVector2Array = pieces[0]["centerline"]
	var perp := RoadTerrain.perp_deg(cl[0], cl[1])
	var p := cl[2] + perp * (2.0 / MPD)
	var q := GradeGeom.nearest_on_pieces(pieces, p, MPD)
	assert_gt(float(q["lat_m"]), 1.9, "+perp is the positive (left) side")


func test_along_is_continuous_across_a_piece_joint() -> void:
	var pieces := [_piece(0.0, 100.0), _piece(100.0, 200.0)]
	var q := GradeGeom.nearest_on_pieces(pieces, _east_point(100.0, 0.5), MPD)
	assert_almost_eq(float(q["along"]), 100.0, 0.01)
	q = GradeGeom.nearest_on_pieces(pieces, _east_point(150.0, -0.5), MPD)
	assert_almost_eq(float(q["along"]), 150.0, 0.01)
	assert_eq(int(q["piece"]), 1)


func test_no_pieces_means_no_hit() -> void:
	assert_false(GradeGeom.nearest_on_pieces([], Vector2.ZERO, MPD)["hit"])
	assert_false(GradeGeom.nearest_on_pieces([{"centerline": PackedVector2Array()}],
			Vector2.ZERO, MPD)["hit"])


func test_frame_is_right_handed_and_follows_the_grade() -> void:
	var piece := _piece(0.0, 100.0)
	var cl: PackedVector2Array = piece["centerline"]
	var cum: PackedFloat64Array = piece["_cum_lengths"]
	var z_at := func(along: float) -> float:
		return 100.0 + 0.04 * along
	var f := GradeGeom.frame_at(cl, cum, 50.0, z_at, RADIUS)
	var t: Vector3 = f["t"]
	var up: Vector3 = f["up"]
	var n: Vector3 = f["n"]
	assert_almost_eq(t.length(), 1.0, 1e-9)
	assert_almost_eq(up.length(), 1.0, 1e-9)
	assert_almost_eq(t.dot(up), 0.0, 1e-9)
	assert_almost_eq(n.dot(t), 0.0, 1e-9)
	assert_gt(Basis(n, up, -t).determinant(), 0.0, "module half A basis is right-handed")
	assert_gt(Basis(-n, up, t).determinant(), 0.0, "module half B basis is right-handed")
	# Eastbound: the tangent climbs 4 % against the radial.
	var radial: Vector3 = (f["pos"] as Vector3).normalized()
	assert_almost_eq(t.dot(radial), 0.04 / sqrt(1.0 + 0.04 * 0.04), 1e-4)
	# n points north (left of eastward travel).
	var north := Vector3(-sin(deg_to_rad(LAT)) * cos(deg_to_rad(LON0)),
			cos(deg_to_rad(LAT)), -sin(deg_to_rad(LAT)) * sin(deg_to_rad(LON0)))
	assert_gt(n.dot(north), 0.99)
	assert_almost_eq((f["pos"] as Vector3).length(), RADIUS + 102.0, 1e-3)


func test_module_range_partitions_the_line() -> void:
	var L := RailwaySettings.MODULE_LEN_M
	var a := GradeGeom.module_range(0.0, 10.0, L)
	var b := GradeGeom.module_range(10.0, 20.0, L)
	assert_eq(a.y, b.x, "adjacent pieces hand over at the same index")
	assert_eq(a.x, 0)
	# Every module centre in [0, 20) is covered exactly once.
	var seen := {}
	for i in range(a.x, a.y):
		seen[i] = true
	for i in range(b.x, b.y):
		assert_false(seen.has(i), "module %d instanced twice" % i)
		seen[i] = true
	var i := 0
	while (i + 0.5) * L < 20.0:
		assert_true(seen.has(i), "module %d skipped" % i)
		i += 1
	assert_eq(seen.size(), i)
	assert_eq(GradeGeom.module_range(5.0, 5.0, L), Vector2i(0, 0))
