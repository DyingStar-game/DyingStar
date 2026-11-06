extends GutTest
## The fixes of the village-ground code review (2026-11-04), one test each:
##   · a village bed's corner chunks are handed its ground (PadBed.reach_m from the half-diagonal);
##   · a pad measure persisted under another talus rule is not reused (PadSettings.talus_rule);
##   · the pad constants and LEVEL_RULE really make a cache key (PadSettings.signature);
##   · a chunk a village's ground or roads reach stays out of the disk cache;
##   · re-registering a village's roads compares them whole, and marks stale every pixel their band
##     reaches, not only their vertices' pixels.
##
## Run: godot --headless --path . -s addons/gut/gut_cmdln.gd
##          -gtest=res://test/unit/test_village_ground_review.gd -gexit

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0
const FINEST := 1 << 14


## A bare planet: no relief data (flat), the same depth as the other village tests.
func _data() -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	return data


## The lon/lat [param east_m] east and [param north_m] north of (0, 0), near the equator.
func _at(east_m: float, north_m: float) -> Vector2:
	return Vector2(east_m / MPD, north_m / MPD)


# ── 1. The corners of a village bed ──────────────────────────────────────

func test_the_reach_covers_the_corner_of_a_bed() -> void:
	var bed := VillageBed.record("village:big", 0.0, 0.0, 0.0, 150.0, 150.0)
	assert_gte(PadBed.reach_m(bed), Vector2(150.0, 150.0).length() + PadBed.talus_cap(bed),
			"past a corner, the band reaches |(hx, hy)| + its width from the centre")


func test_the_corner_chunk_of_a_300_m_bed_is_handed_its_ground() -> void:
	var data := _data()
	data.register_village_bed(VillageBed.record("village:big", 0.0, 0.0, 0.0, 150.0, 150.0))
	# 80 m past the north-east corner, on the diagonal: 113 m off the footprint, inside the band.
	var corner := _at(230.0, 230.0)
	var nside := 1 << 18  # ~25 m chunks: the half diagonal no longer hides the missing corner
	var ip := HEALPix.vec2pix_nest(nside, HEALPix.lonlat2vec(corner.x, corner.y))
	var beds := data.village_beds_for_chunk(nside, ip)
	assert_eq(beds.size(), 1, "the corner chunk gets the bed")
	if beds.size() == 1:
		var plane := VillageBed.plane_at(beds[0], Vector2(150.0, 150.0))
		var h := plane - 100.0
		assert_ne(VillageBed.apply(h, corner, beds, MPD), h, "and the bed does move that ground")


# ── 2. The talus rule of a persisted measure ─────────────────────────────

func test_a_measure_taken_under_another_talus_rule_is_not_reused() -> void:
	var rec := PadBed.record("prop:b1", 0.0, 0.0, 0.0, 10.0, 10.0, 8.0, 0.0)
	var entry := PadBed.settled_entry(rec, {"z": 12.0, "span": 1.0, "talus_m": 6.0})
	assert_eq(str(entry["rule"]), PadSettings.talus_rule(), "the entry carries the rule it was measured under")
	assert_false(PadBed.settled_stats(rec, entry).is_empty(), "same rule: reused")
	var other := entry.duplicate()
	other["rule"] = "0.500_1.00_L%d" % (PadSettings.LEVEL_RULE - 1)
	assert_true(PadBed.settled_stats(rec, other).is_empty(), "another rule: measured again")
	var legacy := entry.duplicate()
	legacy.erase("rule")
	assert_true(PadBed.settled_stats(rec, legacy).is_empty(), "an entry from before the rule: measured again")


func test_the_rule_survives_json() -> void:
	var rec := PadBed.record("prop:b1", 0.0, 0.0, 0.0, 10.0, 10.0, 8.0, 0.0)
	var entry := PadBed.settled_entry(rec, {"z": 12.0, "span": 1.0, "talus_m": 6.0})
	var back: Dictionary = JSON.parse_string(JSON.stringify(entry))
	assert_false(PadBed.settled_stats(rec, back).is_empty(), "the way Horizon hands it back")


# ── 3. The cache key ─────────────────────────────────────────────────────

func test_the_pad_signature_formats_and_carries_the_level_rule() -> void:
	var sig := PadSettings.signature()
	assert_false(sig.is_empty())
	assert_true(sig.ends_with("_L%d" % PadSettings.LEVEL_RULE), "LEVEL_RULE re-keys the chunk cache: " + sig)
	assert_false(sig.contains("%"), "every placeholder was filled")
	assert_true(sig.contains("%.2f" % PadSettings.TALUS_SPREAD), "and so does the talus spread")


# ── 4. The disk cache ────────────────────────────────────────────────────

func test_a_chunk_a_village_bed_reaches_is_not_cached() -> void:
	var data := _data()
	data.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	var near_ip := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(0.0, 0.0))
	var far_ip := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(90.0, 30.0))
	assert_true(data.chunk_cache_ineligible(FINEST, near_ip), "under the village: never cached")
	assert_true(data.chunk_cache_ineligible(FINEST >> 3, near_ip >> 6), "nor the coarser chunks over it")
	assert_false(data.chunk_cache_ineligible(FINEST, far_ip), "far away: cached as before")


func test_a_chunk_a_village_road_reaches_is_not_cached() -> void:
	var data := _data()
	var cl := PackedVector2Array([_at(0.0, 0.0), _at(40.0, 0.0)])
	data.register_village_roads("village:r", [_zone(cl)])
	var near_ip := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(cl[0].x, cl[0].y))
	assert_true(data.chunk_cache_ineligible(FINEST, near_ip), "under the road: never cached")


func test_a_fence_post_stands_on_the_same_road_with_and_without_the_memo() -> void:
	var data := _data()
	var cl := PackedVector2Array([_at(0.0, 0.0), _at(40.0, 0.0)])
	data.register_village_bed(VillageBed.record("village:r", cl[0].x, cl[0].y, 0.0, 100.0, 100.0))
	data.register_village_roads("village:r", [_zone(cl, 0.5)])
	var memo := {}
	for t: float in [0.0, 5.0, 20.0, 39.0, 60.0]:
		var ll := _at(t, 0.0)
		var dir := HEALPix.lonlat2vec(ll.x, ll.y)
		assert_eq(data.carved_surface_dist(dir, memo), data.carved_surface_dist(dir), "%d m along" % t)


# ── 14. Re-registering a village's roads ─────────────────────────────────

## A village road zone (LayoutRoads.to_zones' format) of the bed "village:r" along [param cl].
func _zone(cl: PackedVector2Array, sink: float = 0.0, fid: int = LayoutRoads.FEATURE_ID_BASE - 1) -> Dictionary:
	var cum := PackedFloat64Array()
	var along := 0.0
	for i in cl.size():
		if i > 0:
			along += (cl[i] - cl[i - 1]).length() * MPD
		cum.append(along)
	return {"road_type": "road", "width": 4.0, "centerline": cl, "_cum_lengths": cum, "village": true,
			"bed": "village:r", "feature_id": fid, "_sink_m": sink}


func test_the_same_roads_again_change_nothing() -> void:
	var data := _data()
	var cl := PackedVector2Array([_at(0.0, 0.0), _at(40.0, 0.0)])
	assert_false(data.register_village_roads("village:r", [_zone(cl)]).is_empty(), "the first time")
	assert_true(data.register_village_roads("village:r", [_zone(cl)]).is_empty(), "the same roads again")


func test_a_road_that_now_gives_way_is_registered_again() -> void:
	var data := _data()
	var cl := PackedVector2Array([_at(0.0, 0.0), _at(40.0, 0.0)])
	data.register_village_roads("village:r", [_zone(cl)])
	assert_false(data.register_village_roads("village:r", [_zone(cl, LayoutRoads.SINK_M)]).is_empty(),
			"a new sink is a new ribbon height")
	assert_false(data.register_village_roads("village:r",
			[_zone(cl, LayoutRoads.SINK_M, LayoutRoads.FEATURE_ID_BASE - 2)]).is_empty(), "a new feature id too")


func test_the_pixels_the_band_reaches_are_marked_stale() -> void:
	# Walk north from a point until a pixel boundary at least 10 m away, then lay a short road 4 m south
	# of it: both its vertices in one pixel, its band (2 m + kerb + 6 m) reaching into the next.
	var x := 0.013
	var y0 := 0.011
	var ip0 := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(x, y0))
	var run_start := 0
	var k := 0
	var boundary := -1
	while k < 5000 and boundary < 0:
		k += 1
		var ip := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(x, y0 + float(k) / MPD))
		if ip != ip0:
			if k - run_start >= 10:
				boundary = k
			else:
				ip0 = ip
				run_start = k
	assert_gt(boundary, 0, "a pixel boundary was found")
	var y := y0 + float(boundary - 4) / MPD
	var cl := PackedVector2Array([Vector2(x - 0.01 / MPD, y), Vector2(x + 0.01 / MPD, y)])
	for p: Vector2 in cl:
		assert_eq(HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(p.x, p.y)), ip0, "both vertices in one pixel")
	var beyond := HEALPix.vec2pix_nest(FINEST, HEALPix.lonlat2vec(x, y0 + float(boundary) / MPD))
	var dirty := _data().register_village_roads("village:r", [_zone(cl)])
	assert_true(dirty.has(ip0), "the road's own pixel")
	assert_true(dirty.has(beyond), "and the pixel its band reaches, 4 m north")
