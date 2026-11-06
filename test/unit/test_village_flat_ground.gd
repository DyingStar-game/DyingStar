extends GutTest
## A city's chunks without their 78 s: the pads a sub-vertex asks about (PadBed.cells_of), no sub-grid for
## a village's plane (VillageBed.on_plane, GradeRefine), and on the server the ground kept and built in
## the right order while they are rebuilt (PlanetTerrain).

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0
const DEPTH := 13
const NSIDE := 1 << DEPTH
const RES := 32
const LON := -39.53
const LAT := 24.69
const BED := "village:test"


func _pad(uuid: String, east_m: float, north_m: float, hx: float, hy: float, apron: float, z: float,
		talus: float = 6.0, lon0: float = LON) -> Dictionary:
	var rec := PadBed.record(uuid, lon0 + east_m / (MPD * cos(deg_to_rad(LAT))), LAT + north_m / MPD,
			0.3, hx, hy, apron, 0.0)
	rec["z"] = z
	rec["talus_m"] = talus
	return rec


## Pads of all sizes, some sharing their ground, a yard, a notch.
func _district(lon0: float = LON) -> Array:
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		out.append(_pad("prop:%d" % i, rng.randf_range(-300.0, 300.0), rng.randf_range(-300.0, 300.0),
				rng.randf_range(1.0, 30.0), rng.randf_range(1.0, 30.0), rng.randf_range(0.0, 8.0),
				100.0 + rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 40.0), lon0))
	out.append(_pad("yard%sa" % LayoutPads.UUID_TAG, 40.0, 60.0, 60.0, 40.0, 4.0, 102.0, 10.0, lon0))
	var notch := PadBed.notch_record("notch|prop:lift", lon0, LAT, 0.0, 6.0, 6.0, 90.0)
	out.append(notch)
	return out


func _bed(hx: float = 1200.0, hy: float = 1200.0) -> Dictionary:
	var bed := VillageBed.record(BED, LON, LAT, 0.2, hx, hy)
	bed["z0"] = 100.0
	bed["gx"] = -0.00113
	bed["gy"] = -0.00058
	return bed


## The chosen cells give the bits every pad gives, wherever the point falls.
func _assert_same_ground(pads: Array, lon0: float, spread_m: float, extra: Dictionary = {}) -> void:
	var full := {"pads": pads, "m_per_deg": MPD}
	full.merge(extra)
	var indexed := full.duplicate()
	indexed["pad_cells"] = PadBed.cells_of(pads, MPD)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var moved := 0
	var different := 0
	for i in 4000:
		var ll := Vector2(wrapf(lon0 + rng.randf_range(-spread_m, spread_m) / (MPD * cos(deg_to_rad(LAT))), -180.0, 180.0),
				LAT + rng.randf_range(-spread_m, spread_m) / MPD)
		var h := 100.0 + rng.randf_range(-6.0, 6.0)
		var expected := GradeBed.apply(h, ll, full)
		if expected != h:
			moved += 1
		if GradeBed.apply(h, ll, indexed) != expected:
			different += 1
	assert_eq(different, 0, "the same bits")
	assert_gt(moved, 100, "and the pads do move the ground there")


func test_a_cell_gives_the_ground_of_all_the_pads() -> void:
	_assert_same_ground(_district(), LON, 500.0)


func test_a_cell_gives_the_ground_of_all_the_pads_across_the_longitude_wrap() -> void:
	_assert_same_ground(_district(179.999), 179.999, 500.0)
	_assert_same_ground(_district(-179.999), -179.999, 500.0)


func test_a_cell_gives_the_ground_under_the_roads_of_a_village_too() -> void:
	var zone := {"width": 8.0, "centerline": PackedVector2Array([Vector2(LON - 0.002, LAT), Vector2(LON + 0.002, LAT)])}
	zone["_bbox"] = VillageRoadBed.bbox_of(zone, MPD)
	_assert_same_ground(_district(), LON, 500.0, {"villages": [_bed()], "village_roads": [zone]})


func test_a_cell_holds_only_the_pads_near_it() -> void:
	var cells := PadBed.cells_of(_district(), MPD)
	var biggest := 0
	var total := 0
	for cell: Vector2i in cells:
		biggest = maxi(biggest, (cells[cell] as Array).size())
		total += (cells[cell] as Array).size()
	assert_lt(float(total) / float(cells.size()), 8.0, "of the 42 pads of the district")
	assert_true(PadBed.cell_of(Vector2(LON + 1.0, LAT), MPD) not in cells, "and none a degree away")


func test_the_plane_is_flat_within_the_tolerance_and_inside_its_footprint() -> void:
	var beds := [_bed(100.0, 100.0)]
	var inside := Vector2(LON, LAT)
	var plane := VillageBed.floor_at(inside, beds, MPD)
	assert_true(VillageBed.on_plane(plane + 0.05, inside, beds, MPD))
	assert_true(VillageBed.on_plane(plane - 0.05, inside, beds, MPD))
	assert_false(VillageBed.on_plane(plane + 0.5, inside, beds, MPD))
	var out_of_it := Vector2(LON + 1.0, LAT)
	assert_false(VillageBed.on_plane(plane, out_of_it, beds, MPD), "off its footprint no height is on it")
	assert_false(VillageBed.on_plane(plane, inside, [], MPD), "without a bed neither")


func test_a_pad_lies_on_the_plane_as_a_whole() -> void:
	var beds := [_bed()]
	var at := func(east: float, north: float, half: float, off: float) -> Dictionary:
		var rec := _pad("p", east, north, half, half, 4.0, 0.0)
		rec["z"] = VillageBed.floor_at(Vector2(rec["lon"], rec["lat"]), beds, MPD) + off
		return rec
	assert_true(VillageBed.pad_on_plane(at.call(10.0, 0.0, 8.0, 0.02), beds, MPD))
	assert_false(VillageBed.pad_on_plane(at.call(10.0, 0.0, 8.0, 0.5), beds, MPD), "half a metre above it")
	assert_false(VillageBed.pad_on_plane(at.call(1190.0, 0.0, 30.0, 0.0), beds, MPD), "reaching over its edge")
	assert_false(VillageBed.pad_on_plane(at.call(10.0, 0.0, 8.0, 0.0), [], MPD), "no bed")
	var notch := PadBed.notch_record("n", LON, LAT, 0.0, 6.0, 6.0, 90.0)
	assert_false(VillageBed.pad_on_plane(notch, beds, MPD), "a notch digs")


## The refinement of a chunk at (LON, LAT) under [param ctx], its corners [param off_at] (func(xi, yi))
## off the plane of [param bed], all moved.
func _refine(pd: PlanetData, ctx: Dictionary, bed: Dictionary, off_at: Callable) -> Dictionary:
	var ipix := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(LON, LAT))
	var grid_dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, RES)
	var n := (RES + 1) * (RES + 1)
	var grid_h := PackedFloat64Array()
	var band := PackedByteArray()
	grid_h.resize(n)
	band.resize(n)
	band.fill(1)
	for yi in RES + 1:
		for xi in RES + 1:
			var ll := HEALPix.vec2lonlat(grid_dirs[yi][xi])
			grid_h[yi * (RES + 1) + xi] = VillageBed.floor_at(ll, [bed], MPD) + float(off_at.call(xi, yi))
	var sampler := func(_d: Vector3) -> float: return 100.0
	return GradeRefine.build(pd, NSIDE, ipix, RES, grid_dirs, grid_h, band, ctx, PackedByteArray(), sampler, true)


func _refined_cells(patch: Dictionary) -> int:
	var count := 0
	for q in (patch.get("quads", PackedByteArray()) as PackedByteArray):
		count += q
	return count


func _plain_data() -> PlanetData:
	var pd := PlanetData.new()
	pd.radius = RADIUS
	return pd


func test_a_city_on_its_plane_needs_no_sub_grid() -> void:
	var bed := _bed(20000.0, 20000.0)
	var ctx := {"pieces": [], "profiles": {}, "pads": [], "refine_pads": [], "villages": [bed], "m_per_deg": MPD}
	var flat := func(_x: int, _y: int) -> float: return 0.05
	assert_eq(_refine(_plain_data(), ctx, bed, flat), {}, "every corner moved, none refined")


func test_a_corner_off_the_plane_refines_its_cells() -> void:
	var bed := _bed(20000.0, 20000.0)
	var ctx := {"pieces": [], "profiles": {}, "pads": [], "refine_pads": [], "villages": [bed], "m_per_deg": MPD}
	var off := func(xi: int, yi: int) -> float: return 1.0 if xi == 16 and yi == 16 else 0.0
	assert_eq(_refined_cells(_refine(_plain_data(), ctx, bed, off)), 4)


func test_a_corner_moved_outside_a_village_refines_as_ever() -> void:
	var bed := _bed(20000.0, 20000.0)
	var ctx := {"pieces": [], "profiles": {}, "pads": [], "refine_pads": [], "villages": [], "m_per_deg": MPD}
	var flat := func(_x: int, _y: int) -> float: return 0.0
	assert_eq(_refined_cells(_refine(_plain_data(), ctx, bed, flat)), RES * RES)


func test_only_the_pads_off_the_plane_ask_for_a_sub_grid() -> void:
	var bed := _bed(20000.0, 20000.0)
	var ipix := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(LON, LAT))
	var centre: Vector3 = HEALPix.get_pixel_grid(NSIDE, ipix, RES)[16][16]
	var ll := HEALPix.vec2lonlat(centre)
	var pad := PadBed.record("flat", ll.x, ll.y, 0.0, 3.0, 3.0, 2.0, 0.0)
	pad["z"] = VillageBed.floor_at(ll, [bed], MPD) + 0.02
	pad["talus_m"] = 4.0
	var flat := func(_x: int, _y: int) -> float: return 0.0
	var ctx := {"pieces": [], "profiles": {}, "pads": [pad], "refine_pads": [], "villages": [bed], "m_per_deg": MPD}
	assert_eq(_refine(_plain_data(), ctx, bed, flat), {}, "on the plane: drawn by the grid")
	ctx["refine_pads"] = [pad]
	assert_gt(_refined_cells(_refine(_plain_data(), ctx, bed, flat)), 0, "off it: as ever")
	ctx.erase("refine_pads")
	assert_gt(_refined_cells(_refine(_plain_data(), ctx, bed, flat)), 0, "a context that does not say: every pad")


func test_the_chunk_context_tells_which_pads_stand_on_the_plane() -> void:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = DEPTH
	data.relief_signature = "relief-test"
	data.register_village_bed(VillageBed.record(BED, LON, LAT, 0.0, 1000.0, 1000.0))
	var on_it := PadBed.record("prop:on", LON, LAT, 0.0, 6.0, 6.0, 4.0, 0.0)
	var pit := PadBed.notch_record("notch|prop:pit", LON + 0.001, LAT, 0.0, 6.0, 6.0, -50.0)
	data.register_pads([on_it, pit])
	var ipix := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(LON, LAT))
	var ctx := GradeBed.make_ctx(data, NSIDE, ipix, 2.0)
	var uuids := func(recs: Array) -> Array: return recs.map(func(r: Dictionary) -> String: return r["uuid"])
	assert_eq((uuids.call(ctx["pads"]) as Array).size(), 2)
	assert_eq(uuids.call(ctx["refine_pads"]), ["notch|prop:pit"])
	assert_false((ctx["pad_cells"] as Dictionary).is_empty())
	var coarse := GradeBed.make_coarse_ctx(data, NSIDE / 2, ipix >> 2, 40.0)
	assert_false(coarse.has("pad_cells"), "the coarse rule is another one: all its pads")


func _server_terrain() -> PlanetTerrain:
	var t: PlanetTerrain = PlanetTerrain.new()
	t.planet_data = _plain_data()
	t.planet_data.max_quadtree_depth = DEPTH
	t.is_server = true
	add_child_autofree(t)
	return t


func _resident(t: PlanetTerrain, key: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	t.add_child(body)
	t._server_collision_chunks[key] = body
	return body


func test_a_chunk_being_rebuilt_keeps_its_ground_until_the_new_one_is_there() -> void:
	var t := _server_terrain()
	var key := "hp_n%d_p%d" % [NSIDE, 1000]
	var old := _resident(t, key)
	var feature := Node3D.new()
	t.add_child(feature)
	t._server_feature_nodes[key] = [feature]
	t._keep_chunk_until_rebuilt(key)
	assert_false(t._server_collision_chunks.has(key), "the residency sees it missing and loads it")
	assert_true(is_instance_valid(old) and not old.is_queued_for_deletion(), "while it stands")
	assert_false(feature.is_queued_for_deletion())
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD]))
	t._server_assemble_chunk(key, NSIDE, 1000, shape)
	assert_true(t._server_collision_chunks.has(key))
	assert_ne(t._server_collision_chunks[key], old)
	assert_true(old.is_queued_for_deletion(), "the old ground goes with the new one in place")
	assert_true(feature.is_queued_for_deletion())
	assert_false(t._server_stale_chunks.has(key))


func test_a_chunk_nobody_wants_any_more_does_not_keep_its_old_ground() -> void:
	var t := _server_terrain()
	var key := "hp_n%d_p%d" % [NSIDE, 1000]
	var old := _resident(t, key)
	t._keep_chunk_until_rebuilt(key)
	t._server_collision_loaded = true
	t.set_pinned_chunks(PackedStringArray())
	assert_true(old.is_queued_for_deletion())
	assert_false(t._server_stale_chunks.has(key))


func test_an_unloaded_chunk_drops_its_old_ground() -> void:
	var t := _server_terrain()
	var key := "hp_n%d_p%d" % [NSIDE, 1000]
	var old := _resident(t, key)
	t._keep_chunk_until_rebuilt(key)
	t._unload_chunk(key)
	assert_true(old.is_queued_for_deletion())


func test_the_chunk_nearest_a_body_is_built_first() -> void:
	var t := _server_terrain()
	for key: String in ["far", "ring", "under", "other", "far2"]:
		t._server_chunk_queue.append({"key": key})
	t.set_pinned_chunks(PackedStringArray(["ring", "under"]), PackedInt32Array([9, 0]))
	var order: Array = []
	while not t._server_chunk_queue.is_empty():
		order.append(t._server_chunk_queue.pop_at(t._next_queued_chunk())["key"])
	assert_eq(order, ["under", "ring", "far", "other", "far2"], "then in order of arrival")


func test_a_pin_without_a_rank_comes_first() -> void:
	var t := _server_terrain()
	t._server_chunk_queue.append({"key": "far"})
	t._server_chunk_queue.append({"key": "pin"})
	t.set_pinned_chunks(PackedStringArray(["pin"]))
	assert_eq(t._next_queued_chunk(), 1)


func test_the_pins_of_a_tile_start_with_the_tile_then_its_nearest_ring() -> void:
	var server: Node = autofree(load("res://server/server.gd").new())
	autofree(server.discoveries)
	var keys: PackedStringArray = server._pin_keys_for_tile(NSIDE, 5000, true)
	assert_eq(keys[0], "hp_n%d_p5000" % NSIDE)
	var ring: Array = []
	for nb in HEALPix.get_neighbors_nest(NSIDE, 5000).values():
		ring.append("hp_n%d_p%d" % [NSIDE, int(nb)])
	var first_ring := keys.slice(1, 1 + ring.size())
	for key: String in first_ring:
		assert_true(ring.has(key), key)
