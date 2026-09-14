extends GutTest
## Suite for [RailwayTrack] — where the rail modules go and what stands in
## for their collision.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_railway_track.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const MPD := RADIUS * PI / 180.0


func _road(length_m: float, tracks: int) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		cl.append(Vector2(LON0 + d / (MPD * clat), LAT))
		cum.append(d)
	return {"feature_id": 3, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": tracks}


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	return (lon - LON0) * MPD * cos(deg_to_rad(LAT))


func _flat(_dir: Vector3) -> float:
	return 100.0


func _north() -> Vector3:
	return Vector3(-sin(deg_to_rad(LAT)) * cos(deg_to_rad(LON0)),
			cos(deg_to_rad(LAT)), -sin(deg_to_rad(LAT)) * sin(deg_to_rad(LON0)))


func test_modules_every_pitch_two_halves_per_track() -> void:
	var road := _road(100.0, 1)
	var prof := GradeProfile.compute(road, _flat)
	var xf := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	var L := RailwaySettings.MODULE_LEN_M
	var expect := GradeGeom.module_range(0.0, 100.0, L)
	assert_eq(xf.size(), 2 * (expect.y - expect.x))
	for i in range(0, xf.size(), 2):
		var a: Transform3D = xf[i]["xform"]
		var b: Transform3D = xf[i + 1]["xform"]
		assert_gt(a.basis.determinant(), 0.0, "half A is right-handed")
		assert_gt(b.basis.determinant(), 0.0, "half B is right-handed")
		assert_almost_eq(a.origin.distance_to(b.origin), 0.0, 1e-6, "same centre")
		assert_lt(a.basis.x.dot(b.basis.x), -0.999, "half B is half A turned about up")
		assert_gt(a.basis.y.dot(b.basis.y), 0.999)
		assert_almost_eq(a.origin.length(), RADIUS + 100.0 + RoadTerrain.SURFACE_THICKNESS_M, 1e-3)
	# Consecutive modules are one pitch apart.
	var p0: Vector3 = (xf[0]["xform"] as Transform3D).origin
	var p1: Vector3 = (xf[2]["xform"] as Transform3D).origin
	assert_almost_eq(p0.distance_to(p1), L, 1e-3)
	assert_almost_eq(float(xf[0]["along"]), 0.5 * L, 1e-9)


func test_rail_head_lands_on_standard_gauge() -> void:
	var road := _road(100.0, 1)
	var prof := GradeProfile.compute(road, _flat)
	var xf := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	var a: Transform3D = xf[0]["xform"]
	var b: Transform3D = xf[1]["xform"]
	# The rail sits at +RAIL_CENTRE_M along the module's own X.
	var rail_a: Vector3 = a * Vector3(RailwaySettings.RAIL_CENTRE_M, 0.0, 0.0)
	var rail_b: Vector3 = b * Vector3(RailwaySettings.RAIL_CENTRE_M, 0.0, 0.0)
	assert_almost_eq(rail_a.distance_to(rail_b), 2.0 * RailwaySettings.RAIL_CENTRE_M, 1e-6)
	# Half A's rail is on the left (north) of an eastbound track.
	assert_gt((rail_a - a.origin).dot(_north()), 0.7)
	# The module's +Z runs along the track (backwards for half A).
	assert_almost_eq(absf(a.basis.z.dot(_north())), 0.0, 1e-3)


func test_two_tracks_are_a_pitch_apart() -> void:
	var road := _road(100.0, 2)
	var prof := GradeProfile.compute(road, _flat)
	var xf := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	assert_eq(xf.size() % 4, 0, "two halves × two tracks per module")
	var t0: Transform3D = xf[0]["xform"]
	var t1: Transform3D = xf[2]["xform"]
	assert_eq(int(xf[0]["track"]), 0)
	assert_eq(int(xf[2]["track"]), 1)
	assert_almost_eq(t0.origin.distance_to(t1.origin), RailwaySettings.TRACK_PITCH_M, 1e-6)
	assert_almost_eq((t1.origin - t0.origin).dot(_north()), RailwaySettings.TRACK_PITCH_M, 1e-3,
			"track 1 is north of track 0")


func test_adjacent_pieces_never_share_a_module() -> void:
	var road := _road(200.0, 1)
	var prof := GradeProfile.compute(road, _flat)
	var cl: PackedVector2Array = road["centerline"]
	var cum: PackedFloat64Array = road["_cum_lengths"]
	var a := {"centerline": cl.slice(0, 6), "_cum_lengths": cum.slice(0, 6), "feature_id": 3}
	var b := {"centerline": cl.slice(5), "_cum_lengths": cum.slice(5), "feature_id": 3}
	var xa := RailwayTrack.piece_module_transforms(a, prof, RADIUS, Vector3.ZERO)
	var xb := RailwayTrack.piece_module_transforms(b, prof, RADIUS, Vector3.ZERO)
	var whole := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	assert_eq(xa.size() + xb.size(), whole.size())
	var seen := {}
	for m in xa + xb:
		var k := "%.3f_%d" % [float(m["along"]), int(m["track"])]
		seen[k] = int(seen.get(k, 0)) + 1
	for k in seen:
		assert_eq(int(seen[k]), 2, "exactly the two halves at %s" % k)


func test_collision_boxes_cover_the_piece() -> void:
	var road := _road(100.0, 2)
	var prof := GradeProfile.compute(road, _flat)
	var boxes := RailwayTrack.piece_collision_boxes(road, prof, RADIUS, Vector3.ZERO)
	# 5 straight segments × 2 tracks.
	assert_eq(boxes.size(), 10)
	var covered := 0.0
	for b in boxes:
		if int(b["track"]) == 0:
			covered += float(b["along_hi"]) - float(b["along_lo"])
		var size: Vector3 = b["size"]
		assert_almost_eq(size.x, RailwaySettings.TRACK_W_M, 1e-9)
		assert_almost_eq(size.y, RailwaySettings.MODULE_H_M, 1e-9)
		# The box is as long as the run REALLY is — at the track's altitude,
		# 100 m above the radius the along-metres were measured at.
		assert_almost_eq(size.z, 20.0 * (RADIUS + 100.0) / RADIUS, 1e-3)
		var xf: Transform3D = b["xform"]
		assert_gt(xf.basis.determinant(), 0.0)
		# Box bottom at the sleeper's underside, top at the rail head.
		var bottom: Vector3 = xf * Vector3(0.0, -0.5 * size.y, 0.0)
		var top: Vector3 = xf * Vector3(0.0, 0.5 * size.y, 0.0)
		assert_almost_eq(bottom.length() - RADIUS,
				100.0 + RoadTerrain.SURFACE_THICKNESS_M - RailwaySettings.MODULE_BELOW_M, 1e-3)
		assert_almost_eq(top.length() - RADIUS,
				100.0 + RoadTerrain.SURFACE_THICKNESS_M - RailwaySettings.MODULE_BELOW_M
				+ RailwaySettings.MODULE_H_M, 1e-3)
	assert_almost_eq(covered, 100.0, 1e-6)
	# Every module centre falls inside a box of its track.
	for m in RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO):
		var c: Vector3 = (m["xform"] as Transform3D).origin
		var inside := false
		for b in boxes:
			if int(b["track"]) != int(m["track"]):
				continue
			var local: Vector3 = (b["xform"] as Transform3D).affine_inverse() * c
			var half: Vector3 = (b["size"] as Vector3) * 0.5
			if absf(local.x) <= half.x + 1e-3 and absf(local.z) <= half.z + 1e-3 \
					and local.y >= -half.y - 1e-3 and local.y <= half.y + 1e-3:
				inside = true
				break
		assert_true(inside, "module at %.2f m on track %d has a box" % [float(m["along"]), int(m["track"])])


func test_boxes_split_at_profile_knots() -> void:
	# A climb the track follows: the 200 m knot cuts the segment holding it.
	var slope := func(dir: Vector3) -> float:
		return 100.0 + 0.02 * _east_m(dir)
	var road := _road(400.0, 1)
	var prof := GradeProfile.compute(road, slope)
	var boxes := RailwayTrack.piece_collision_boxes(road, prof, RADIUS, Vector3.ZERO)
	# 20 segments of 20 m; 200 m is a segment boundary already, so no extra cut.
	assert_eq(boxes.size(), 20)
	var road2 := _road(400.0, 1)
	var cum: PackedFloat64Array = road2["_cum_lengths"]
	var cl: PackedVector2Array = road2["centerline"]
	# Coarser polyline (60 m segments) whose vertices straddle the 200 m knot.
	var cl2 := PackedVector2Array()
	var cum2 := PackedFloat64Array()
	for i in range(0, cl.size(), 3):
		cl2.append(cl[i])
		cum2.append(cum[i])
	var road3 := {"centerline": cl2, "_cum_lengths": cum2, "feature_id": 3, "tracks": 1}
	var boxes3 := RailwayTrack.piece_collision_boxes(road3, prof, RADIUS, Vector3.ZERO)
	assert_eq(boxes3.size(), cl2.size() - 1 + 1, "one segment is split by the 200 m knot")


func test_multimesh_groups_by_stretch() -> void:
	var road := _road(200.0, 1)
	var prof := GradeProfile.compute(road, _flat)
	var xf := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	var groups := RailwayTrack.build_multimeshes(xf, 0)
	if RailwayTrack.module_meshes().is_empty():
		assert_eq(groups.size(), 0, "no asset, no group")
		return
	assert_eq(groups.size(), int(ceil(200.0 / RailwaySettings.RAIL_MMI_GROUP_M)))
	var total := 0
	for g in groups:
		var mm: MultiMesh = g["mm"]
		total += mm.instance_count
		# Instances are relative to the group's centre: small numbers.
		assert_lt(mm.get_instance_transform(0).origin.length(), RailwaySettings.RAIL_MMI_GROUP_M)
	assert_eq(total, xf.size())


func test_module_asset_has_three_tiers_at_the_expected_size() -> void:
	# The asset contract RailwaySettings' constants describe: three LOD nodes
	# with the scale applied, coarser as the tier rises.
	var meshes := RailwayTrack.module_meshes()
	assert_eq(meshes.size(), 3, "railroad LOD0/1/2")
	var prev := 1000000
	for m in meshes:
		var tris := 0
		for si in m.get_surface_count():
			@warning_ignore("integer_division")
			tris += m.surface_get_array_index_len(si) / 3
		assert_lt(tris, prev, "each tier is lighter than the previous")
		prev = tris
		var aabb := m.get_aabb()
		assert_almost_eq(aabb.size.x, RailwaySettings.MODULE_HALF_W_M, 0.02)
		assert_almost_eq(aabb.size.z, RailwaySettings.MODULE_LEN_M, 0.02)
		assert_almost_eq(aabb.position.y, -RailwaySettings.MODULE_BELOW_M, 0.02)
	assert_lt(prev, 100, "the far tier is a few boxes")


## The exporter's along-metres are whatever it measured with (tarsis_3's
## road part came out 7.6 % short of the elevation's radius): modules laid
## every MODULE_LEN_M of along are stretched by the true metres per
## along-metre, so the rails still meet — and the collision boxes still
## cover the run — with a metric 10 % short.
func test_modules_meet_whatever_the_along_metric() -> void:
	var road := _road(100.0, 1)
	var cum: PackedFloat64Array = road["_cum_lengths"]
	for i in cum.size():
		cum[i] *= 0.9
	road["_cum_lengths"] = cum
	var prof := GradeProfile.compute(road, _flat)
	var mods := RailwayTrack.piece_module_transforms(road, prof, RADIUS, Vector3.ZERO)
	# Half A of every module: appended first, so the even entries.
	var end_a := Vector3(RailwaySettings.RAIL_CENTRE_M, 0.2, -0.5 * RailwaySettings.MODULE_LEN_M)
	var start_b := Vector3(RailwaySettings.RAIL_CENTRE_M, 0.2, 0.5 * RailwaySettings.MODULE_LEN_M)
	var worst := 0.0
	var pairs := 0
	for i in range(2, mods.size(), 2):
		var prev: Transform3D = mods[i - 2]["xform"]
		var cur: Transform3D = mods[i]["xform"]
		worst = maxf(worst, (prev * end_a).distance_to(cur * start_b))
		pairs += 1
	assert_gt(pairs, 50)
	assert_lt(worst, 1.0e-3, "consecutive rail modules must meet end to end")
	# The stretch is the true metres per along-metre: 1/0.9 at the altitude.
	var xf: Transform3D = mods[0]["xform"]
	assert_almost_eq(xf.basis.z.length(), (RADIUS + 100.0) / RADIUS / 0.9, 1e-4)
	assert_almost_eq(xf.basis.x.length(), 1.0, 1e-9, "no stretch across the track")
	var boxes := RailwayTrack.piece_collision_boxes(road, prof, RADIUS, Vector3.ZERO)
	var covered := 0.0
	for b in boxes:
		covered += (b["size"] as Vector3).z
	assert_almost_eq(covered, 100.0 * (RADIUS + 100.0) / RADIUS, 1e-3,
			"the boxes cover the run's TRUE length")
