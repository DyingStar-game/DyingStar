extends GutTest
## The roads drawn inside a layout (VillageRoad): their ends snap onto the RoadSnaps and onto each
## other, they land on the planet through the village bed's own frame (LayoutRoads.to_zones), and
## the terrain draws each stretch in exactly one chunk (PlanetData.get_roads_for_chunk).

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0


func _road(points: Array, kind: VillageRoad.Kind = VillageRoad.Kind.ROAD) -> VillageRoad:
	var r := VillageRoad.new()
	r.kind = kind
	r.curve = Curve3D.new()
	for p: Vector3 in points:
		r.curve.add_point(p)
	return r


func test_an_end_near_a_snap_of_its_kind_lands_on_it() -> void:
	var root := Node3D.new()
	var snap := RoadSnap.new()
	snap.position = Vector3(100.0, 0.0, -28.0)
	root.add_child(snap)
	var path_snap := RoadSnap.new()
	path_snap.kind = RoadSnap.Kind.PATH
	path_snap.position = Vector3(-50.0, 0.0, 0.0)
	root.add_child(path_snap)
	var road := _road([Vector3(-48.0, 0.0, 1.0), Vector3(96.0, 0.0, -25.0)])
	root.add_child(road)
	assert_eq(road.snap_ends(root), 1, "the far end only: the near snap is a path's")
	assert_eq(road.curve.get_point_position(1), Vector3(100.0, 0.0, -28.0))
	assert_eq(road.curve.get_point_position(0), Vector3(-48.0, 0.0, 1.0), "out of the road's kind")
	root.free()


func test_an_end_near_another_road_joins_it() -> void:
	var root := Node3D.new()
	var avenue := _road([Vector3(0.0, 0.0, 0.0), Vector3(200.0, 0.0, 0.0)])
	root.add_child(avenue)
	var alley := _road([Vector3(50.0, 0.0, 80.0), Vector3(203.0, 0.0, 2.0)], VillageRoad.Kind.PATH)
	root.add_child(alley)
	assert_eq(alley.snap_ends(root), 1)
	assert_eq(alley.curve.get_point_position(1), Vector3(200.0, 0.0, 0.0), "on the avenue's end")
	root.free()


func test_an_end_meets_another_road_anywhere_along_it() -> void:
	var root := Node3D.new()
	var avenue := _road([Vector3(-200.0, 0.0, -28.0), Vector3(300.0, 0.0, -28.0)])
	root.add_child(avenue)
	var alley := _road([Vector3(124.7, 0.0, -30.7), Vector3(90.0, 0.0, -113.0)], VillageRoad.Kind.PATH)
	root.add_child(alley)
	assert_eq(alley.snap_ends(root), 1)
	assert_almost_eq(alley.curve.get_point_position(0), Vector3(124.7, 0.0, -28.0), Vector3.ONE * 0.01,
			"on the avenue's axis, mid-way")
	root.free()


## Only X and Z count: a road drawn rising (its points at different heights) still offers the point
## straight beside the end, not the one a 3-D search finds along its slope (10 m away here).
func test_the_nearest_point_is_searched_in_x_and_z_only() -> void:
	var root := Node3D.new()
	var ramp := _road([Vector3(0.0, 0.0, -20.0), Vector3(0.0, 40.0, 20.0)])
	root.add_child(ramp)
	var alley := _road([Vector3(3.0, 0.0, 0.0), Vector3(60.0, 0.0, 0.0)], VillageRoad.Kind.PATH)
	root.add_child(alley)
	assert_eq(alley.snap_ends(root), 1, "the ramp passes 3 m away in X and Z")
	assert_almost_eq(alley.curve.get_point_position(0), Vector3(0.0, 0.0, 0.0), Vector3.ONE * 0.01,
			"beside the end, at the end's own height")
	root.free()


## A road changed in the editor redraws the fences too, from the same roads: the fence it crosses
## shows its gap at once.
func test_redrawing_the_roads_redraws_the_fences() -> void:
	var root := Node3D.new()
	var fence := VillageFence.new()
	fence.curve = Curve3D.new()
	fence.curve.add_point(Vector3(0.0, 0.0, 0.0))
	fence.curve.add_point(Vector3(30.0, 0.0, 0.0))
	root.add_child(fence)
	var whole := (fence.preview_geometry(root, LayoutRoads.of_layout(root))["boxes"] as Array).size()
	root.add_child(_road([Vector3(15.0, 0.0, -40.0), Vector3(15.0, 0.0, 40.0)]))
	VillageRoad.redraw_previews(root)
	assert_not_null(fence.get_node_or_null(VillageFence.PREVIEW_NAME), "the fence is drawn again")
	var opened := (fence.preview_geometry(root, LayoutRoads.of_layout(root))["boxes"] as Array).size()
	assert_lt(opened, whole, "with a gap where the road crosses")
	root.free()


func test_the_polyline_is_in_the_layout_frame() -> void:
	var root := Node3D.new()
	var road := _road([Vector3(0.0, 5.0, 0.0), Vector3(40.0, 5.0, 0.0)])
	road.position = Vector3(10.0, 0.0, -28.0)
	root.add_child(road)
	var pts := road.polyline_in(root)
	assert_gt(pts.size(), 5, "a point every few metres")
	assert_almost_eq(pts[0], Vector2(10.0, -28.0), Vector2.ONE * 0.01)
	assert_almost_eq(pts[pts.size() - 1], Vector2(50.0, -28.0), Vector2.ONE * 0.01)
	root.free()


func test_zones_go_through_the_bed_frame() -> void:
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.3, 300.0, 200.0)
	var centre := Vector2(20.0, -10.0)
	var roads := [{"road_type": "road", "width": 12.0,
			"points": PackedVector2Array([centre, centre + Vector2(100.0, 0.0), centre + Vector2(100.0, -50.0)])}]
	var zones := LayoutRoads.to_zones(roads, bed, centre, MPD)
	assert_eq(zones.size(), 1)
	var z: Dictionary = zones[0]
	var cl: PackedVector2Array = z["centerline"]
	assert_almost_eq(cl[0], Vector2(10.0, 45.0), Vector2.ONE * 1e-6, "the footprint centre is the bed's")
	# layout +X is the bed's +X; layout -Z its +Y
	var p1 := PadBed.local_m(bed, cl[1], MPD)
	assert_almost_eq(p1, Vector2(100.0, 0.0), Vector2.ONE * 0.05)
	var p2 := PadBed.local_m(bed, cl[2], MPD)
	assert_almost_eq(p2, Vector2(100.0, 50.0), Vector2.ONE * 0.05)
	assert_eq(z["_cum_lengths"], PackedFloat64Array([0.0, 100.0, 150.0]), "metres along the road")
	assert_true(bool(z["village"]))
	assert_lt(int(z["feature_id"]), LayoutRoads.FEATURE_ID_BASE + 1, "never a QGIS feature's id")


func test_each_stretch_is_drawn_by_exactly_one_chunk() -> void:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 13
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.0, 400.0, 400.0)
	var pts := PackedVector2Array()
	for i in 301:
		pts.append(Vector2(-1500.0 + 10.0 * float(i), 0.0))  # 3 km: across several chunks
	var zones := LayoutRoads.to_zones([{"road_type": "road", "width": 12.0, "points": pts}], bed, Vector2.ZERO, MPD)
	var dirty := data.register_village_roads("village:v", zones)
	assert_gt(dirty.size(), 1, "the chunks along the road are stale")
	assert_eq(data.register_village_roads("village:v", zones), {}, "the same roads again change nothing")
	var nside := 1 << 13
	var along: Array = []
	for ip: int in dirty:
		for piece: Dictionary in data.get_roads_for_chunk(nside, ip):
			var cum: PackedFloat64Array = piece["_cum_lengths"]
			along.append(Vector2(cum[0], cum[cum.size() - 1]))
	along.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	assert_eq((along[0] as Vector2).x, 0.0, "from the start")
	assert_eq((along[along.size() - 1] as Vector2).y, 3000.0, "to the end")
	for i in range(1, along.size()):
		assert_eq((along[i] as Vector2).x, (along[i - 1] as Vector2).y, "end to end, no gap, no overlap")
	assert_true(data.has_roads(), "a planet with village roads has roads")


## The road's ground (VillageRoadBed): the village's plane across its width and kerb, whatever the
## pads left there; an S back to the pads' ground over the band; untouched past it.
func test_the_road_takes_its_width_back_from_the_pads() -> void:
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.0, 300.0, 300.0)
	bed["z0"] = 100.0
	bed["gx"] = 0.1  # a slope along +X
	var pts := PackedVector2Array([Vector2(-200.0, 0.0), Vector2(200.0, 0.0)])
	var zone: Dictionary = LayoutRoads.to_zones([{"road_type": "road", "width": 12.0, "points": pts}],
			bed, Vector2.ZERO, MPD)[0]
	zone["_bbox"] = VillageRoadBed.bbox_of(zone, MPD)
	var at := func(x: float, y: float) -> Vector2:
		return HEALPix.vec2lonlat(PadBed.dir_at(bed, x, y, MPD))
	var pad_left := 104.0  # a platform 4 m above the plane at x = 50
	var on_road: float = VillageRoadBed.apply(pad_left, at.call(50.0, 3.0), [zone], [bed], MPD)
	assert_almost_eq(on_road, 105.0, 0.01, "the plane under the road, not the platform")
	var kerb: float = VillageRoadBed.apply(pad_left, at.call(50.0, 6.9), [zone], [bed], MPD)
	assert_almost_eq(kerb, 105.0, 0.01, "and on its kerb")
	var mid: float = VillageRoadBed.apply(pad_left, at.call(50.0, 10.0), [zone], [bed], MPD)
	assert_between(mid, 104.0, 105.0, "an S back to the platform across the band")
	var past: float = VillageRoadBed.apply(pad_left, at.call(50.0, 14.0), [zone], [bed], MPD)
	assert_eq(past, pad_left, "the platform past the band")


func test_off_the_village_the_road_rule_leaves_the_ground() -> void:
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.0, 50.0, 50.0)
	var pts := PackedVector2Array([Vector2(-200.0, 0.0), Vector2(200.0, 0.0)])
	var zone: Dictionary = LayoutRoads.to_zones([{"road_type": "road", "width": 12.0, "points": pts}],
			bed, Vector2.ZERO, MPD)[0]
	zone["_bbox"] = VillageRoadBed.bbox_of(zone, MPD)
	var far := HEALPix.vec2lonlat(PadBed.dir_at(bed, 150.0, 0.0, MPD))
	assert_eq(VillageRoadBed.apply(42.0, far, [zone], [bed], MPD), 42.0, "no village ground there")


## Where two roads overlap the larger keeps its ribbon and the other stops at its edge: two ribbons
## at the same height flickered at the avenue / alley junction.
func test_the_alley_stops_at_the_avenue_s_edge() -> void:
	var roads := [
		{"road_type": "road", "width": 12.0, "points": PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)])},
		{"road_type": "path", "width": 4.5, "points": PackedVector2Array([Vector2(20.0, 0.0), Vector2(20.0, 50.0)])},
	]
	assert_true(LayoutRoads.wins_over(roads, 0, 1), "a road wins over a path")
	var avenue := LayoutRoads.visible_runs(roads, 0)
	assert_eq(avenue.size(), 1, "the avenue keeps its whole ribbon")
	var alley := LayoutRoads.visible_runs(roads, 1)
	assert_eq(alley.size(), 1)
	var first: Vector2 = (alley[0][0] as PackedVector2Array)[0]
	assert_almost_eq(first.y, 6.0 - LayoutRoads.TUCK_M, 0.005, "the alley starts at the avenue's edge, tucked under it")
	assert_almost_eq((alley[0][1] as PackedFloat64Array)[0], 6.0 - LayoutRoads.TUCK_M, 0.005,
			"its texture keeps its distance from the road's start")


func test_between_equals_the_branch_gives_way() -> void:
	var roads := [
		{"road_type": "path", "width": 4.0, "points": PackedVector2Array([Vector2(0.0, 30.0), Vector2(0.0, 0.0)])},
		{"road_type": "path", "width": 4.0, "points": PackedVector2Array([Vector2(-50.0, 0.0), Vector2(50.0, 0.0)])},
	]
	assert_false(LayoutRoads.wins_over(roads, 0, 1), "the first one ends on the second: it is the branch")
	assert_true(LayoutRoads.wins_over(roads, 1, 0))
	assert_eq(LayoutRoads.visible_runs(roads, 1).size(), 1, "the carrying-on path is whole")


func test_the_editor_preview_strip_follows_the_line() -> void:
	var pts := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(20.0, 0.0)])
	var arr := VillageRoad.strip(pts, PackedFloat64Array([0.0, 10.0, 20.0]), 6.0, 6.0, Transform3D.IDENTITY, 0.03)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	assert_eq(v.size(), 6, "two edges per point")
	assert_almost_eq(absf(v[0].z), 6.0, 0.001, "half the width each side")
	assert_almost_eq(v[0].y, 0.03, 0.001, "just above the layout's ground")
	assert_eq(VillageRoad.strip(PackedVector2Array([Vector2.ZERO]), PackedFloat64Array([0.0]), 6.0, 6.0,
			Transform3D.IDENTITY, 0.0), [], "nothing under two points")


func test_each_road_knows_its_node_for_the_preview() -> void:
	var root := Node3D.new()
	var road := _road([Vector3(0.0, 0.0, 0.0), Vector3(40.0, 0.0, 0.0)])
	road.name = "Avenue"
	root.add_child(road)
	var roads := LayoutRoads.of_layout(root)
	assert_eq(str(roads[0]["path"]), "Avenue")
	root.free()


## A path crossing the avenue at 45°: cut on its centreline, a corner of its end lay ON the avenue.
## It is cut where its whole width is under the avenue, and drawn a little lower to pass under it.
func test_a_path_crossing_at_an_angle_hides_under_the_road() -> void:
	var roads := [
		{"road_type": "road", "width": 12.0, "points": PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)])},
		{"road_type": "path", "width": 4.0, "points": PackedVector2Array([Vector2(-30.0, -30.0), Vector2(30.0, 30.0)])},
	]
	var runs := LayoutRoads.visible_runs(roads, 1)
	assert_eq(runs.size(), 2, "one stretch each side of the avenue")
	var end_in: Vector2 = (runs[0][0] as PackedVector2Array)[(runs[0][0] as PackedVector2Array).size() - 1]
	var dir := Vector2(1.0, 1.0).normalized()
	var side := Vector2(-dir.y, dir.x) * 2.0
	for corner: Vector2 in [end_in + side, end_in - side]:
		assert_lt(absf(corner.y), 6.0 + 0.01, "both corners of its end are under the avenue")
	var zones := LayoutRoads.to_zones(LayoutRoads.of_layout_data(roads), VillageBed.record("village:v", 10.0, 45.0, 0.0, 300.0, 300.0),
			Vector2.ZERO, MPD)
	var path_sinks := zones.filter(func(z: Dictionary) -> bool: return z["road_type"] == "path").map(
			func(z: Dictionary) -> float: return float(z["_sink_m"]))
	assert_eq(path_sinks, [LayoutRoads.SINK_M, LayoutRoads.SINK_M], "the path passes under")
	var road_sinks := zones.filter(func(z: Dictionary) -> bool: return z["road_type"] == "road").map(
			func(z: Dictionary) -> float: return float(z["_sink_m"]))
	assert_eq(road_sinks, [0.0], "the avenue stays on top")


## Under a road the layout's own areas (LayoutPads) are kept, the buildings' pads are not: the road
## crosses the mine's yard on the yard, and runs past a building on the village's plane.
func test_under_the_road_the_areas_count_the_buildings_do_not() -> void:
	var bed := VillageBed.record("village:v", 10.0, 45.0, 0.0, 300.0, 300.0)
	bed["z0"] = 100.0
	var pts := PackedVector2Array([Vector2(-200.0, 0.0), Vector2(200.0, 0.0)])
	var zone: Dictionary = LayoutRoads.to_zones([{"road_type": "path", "width": 4.0, "points": pts}],
			bed, Vector2.ZERO, MPD)[0]
	zone["_bbox"] = VillageRoadBed.bbox_of(zone, MPD)
	var at := func(x: float, y: float) -> Vector2:
		return HEALPix.vec2lonlat(PadBed.dir_at(bed, x, y, MPD))
	var here: Vector2 = at.call(0.0, 0.0)
	var building := PadBed.record("prop:garage", here.x, here.y, 0.0, 5.0, 5.0, 8.0, 0.0)
	building["z"] = 104.0
	building["talus_m"] = 5.0
	assert_almost_eq(VillageRoadBed.apply(0.0, here, [zone], [bed], MPD, [building]), 100.0, 0.01,
			"a building's pad does not lift the road")
	var yard := PadBed.record("village:v%syard" % LayoutPads.UUID_TAG, here.x, here.y, 0.0, 50.0, 50.0, 2.0, 0.0)
	yard["z"] = 103.0
	yard["talus_m"] = 5.0
	assert_almost_eq(VillageRoadBed.apply(0.0, here, [zone], [bed], MPD, [building, yard]), 103.0, 0.01,
			"a layout area does")
