extends GutTest
## Suite for [RoadCut] — taking the road ribbon out from under a bridge.
##
## Two properties are defended, and both are about a failure you can drive into:
##
##   · the strip is SPLIT, not thinned. PlanetChunk builds the ribbon as one
##     contiguous quad strip and joins consecutive vertex pairs, so merely
##     dropping the vertices over a gorge would join the pair before the gap to
##     the pair after it and stretch a single quad straight across — the very
##     thing the bridge exists to replace. Each surviving stretch has to come
##     back as its own piece.
##   · the along-road distances stay ABSOLUTE. They are the ribbon's U
##     coordinate, so a piece that restarted at zero would make the asphalt jump
##     at every bridge. A vertex inserted at a cut boundary must carry that
##     boundary's exact distance.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_cut.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6

var _cl: PackedVector2Array
var _cum: PackedFloat64Array


func before_each() -> void:
	# 1 km of road, a point every 20 m.
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(LAT))
	_cl = PackedVector2Array()
	_cum = PackedFloat64Array()
	for i in 51:
		var d := float(i) * 20.0
		_cl.append(Vector2(LON0 + d / (mpd * clat), LAT))
		_cum.append(d)


# ── Merging ────────────────────────────────────────────────────────────

func test_disjoint_intervals_are_left_alone() -> void:
	var m := RoadCut.merge_intervals([Vector2(0, 10), Vector2(30, 40)])
	assert_eq(m.size(), 2)


func test_overlapping_intervals_are_merged() -> void:
	# Two gorges close enough for their approach ramps to meet: leaving them
	# separate would strand a sliver of ribbon between two decks.
	var m := RoadCut.merge_intervals(
			[Vector2(30, 40), Vector2(0, 10), Vector2(5, 20)])
	assert_eq(m.size(), 2, "the first two collapse into one")
	assert_almost_eq((m[0] as Vector2).x, 0.0, 1e-9)
	assert_almost_eq((m[0] as Vector2).y, 20.0, 1e-9)
	assert_almost_eq((m[1] as Vector2).x, 30.0, 1e-9)


func test_touching_intervals_are_merged() -> void:
	var m := RoadCut.merge_intervals([Vector2(0, 10), Vector2(10, 20)])
	assert_eq(m.size(), 1)
	assert_almost_eq((m[0] as Vector2).y, 20.0, 1e-9)


# ── Splitting ──────────────────────────────────────────────────────────

func test_no_exclusion_returns_the_road_whole() -> void:
	var pieces := RoadCut.split(_cl, _cum, [])
	assert_eq(pieces.size(), 1)
	assert_eq((pieces[0][0] as PackedVector2Array).size(), _cl.size())


func test_one_exclusion_yields_two_pieces() -> void:
	var pieces := RoadCut.split(_cl, _cum, [Vector2(400.0, 600.0)])
	assert_eq(pieces.size(), 2, "the strip is split, not thinned")
	var a: PackedFloat64Array = pieces[0][1]
	var b: PackedFloat64Array = pieces[1][1]
	assert_almost_eq(a[a.size() - 1], 400.0, 1e-6,
			"the first piece stops exactly at the cut")
	assert_almost_eq(b[0], 600.0, 1e-6, "the second starts exactly at it")


func test_boundary_vertices_are_interpolated_not_snapped() -> void:
	# 410 and 590 fall between stored points; the piece must end AT them, not at
	# the nearest vertex, or the ribbon would poke out from under the ramp.
	var pieces := RoadCut.split(_cl, _cum, [Vector2(410.0, 590.0)])
	var a: PackedFloat64Array = pieces[0][1]
	var b: PackedFloat64Array = pieces[1][1]
	assert_almost_eq(a[a.size() - 1], 410.0, 1e-6)
	assert_almost_eq(b[0], 590.0, 1e-6)
	# And the inserted point really lies on the road, between its neighbours.
	var acl: PackedVector2Array = pieces[0][0]
	var want := RoadBridge.lonlat_at(_cl, _cum, 410.0)
	assert_almost_eq(acl[acl.size() - 1].x, want.x, 1e-9)
	assert_almost_eq(acl[acl.size() - 1].y, want.y, 1e-9)


func test_distances_stay_absolute_across_a_cut() -> void:
	# The ribbon's U is this distance over the tile size. Restarting at zero on
	# the far side of a bridge would make the asphalt jump.
	var pieces := RoadCut.split(_cl, _cum, [Vector2(400.0, 600.0)])
	var b: PackedFloat64Array = pieces[1][1]
	assert_gt(b[0], 0.0, "the second piece does not restart at zero")
	assert_almost_eq(b[b.size() - 1], 1000.0, 1e-6,
			"and still ends at the road's true end")


func test_every_piece_has_matching_arrays() -> void:
	# PlanetChunk keys its "do I have absolute distances?" test on this
	# equality; a mismatch silently falls back to per-piece distances and the
	# texture jumps.
	var pieces := RoadCut.split(_cl, _cum,
			[Vector2(100.0, 200.0), Vector2(500.0, 505.0)])
	for p in pieces:
		assert_eq((p[0] as PackedVector2Array).size(),
				(p[1] as PackedFloat64Array).size())
		assert_gte((p[0] as PackedVector2Array).size(), 2)


func test_pieces_are_ordered_and_disjoint() -> void:
	var pieces := RoadCut.split(_cl, _cum,
			[Vector2(100.0, 200.0), Vector2(500.0, 600.0)])
	assert_eq(pieces.size(), 3)
	var prev := -INF
	for p in pieces:
		var c: PackedFloat64Array = p[1]
		assert_gte(c[0], prev)
		prev = c[c.size() - 1]


func test_an_exclusion_covering_the_road_leaves_nothing() -> void:
	assert_eq(RoadCut.split(_cl, _cum, [Vector2(-50.0, 1050.0)]).size(), 0)


func test_an_exclusion_past_the_ends_is_clipped() -> void:
	# A ramp can run past the road's own end; the cut must clamp rather than
	# produce a piece with negative distances.
	var pieces := RoadCut.split(_cl, _cum, [Vector2(-100.0, 300.0)])
	assert_eq(pieces.size(), 1)
	var c: PackedFloat64Array = pieces[0][1]
	assert_almost_eq(c[0], 300.0, 1e-6)
	assert_almost_eq(c[c.size() - 1], 1000.0, 1e-6)


func test_a_boundary_on_an_existing_vertex_makes_no_duplicate() -> void:
	# A zero-length segment has no defined perpendicular, and the ribbon
	# extrudes along exactly that.
	var pieces := RoadCut.split(_cl, _cum, [Vector2(400.0, 600.0)])
	for p in pieces:
		var c: PackedFloat64Array = p[1]
		for i in range(1, c.size()):
			assert_gt(c[i] - c[i - 1], 1e-9, "no repeated station")


func test_a_sliver_between_two_cuts_is_dropped() -> void:
	# 10 cm of ribbon between two decks is not worth a draw call, and is exactly
	# the kind of shard that shows as a flickering speck.
	var pieces := RoadCut.split(_cl, _cum,
			[Vector2(400.0, 500.0), Vector2(500.1, 600.0)])
	for p in pieces:
		var c: PackedFloat64Array = p[1]
		assert_gte(c[c.size() - 1] - c[0], RoadCut.MIN_PIECE_M)
