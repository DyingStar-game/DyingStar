extends GutTest
## Anti-regression suite for the bug that started all of this: the same road
## rendered twice, the upper copy floating ~2 m above the lower one.
##
## The cause was that a road was stored ONCE, globally, and
## PlanetChunk.generate_mesh() walked its entire centerline in EVERY chunk whose
## bounding box touched it. Neighbouring chunks at different LODs sample terrain
## height at different pyramid levels (sample_nside_for() clamps hp_nside to
## [export_nside_min, export_nside]), so the duplicate ribbons landed at
## different altitudes.
##
## terrainmodifier.pack fixes it at the data level: at every pyramid level a road
## is PARTITIONED across tiles, so each chunk owns a disjoint stretch and no two
## chunks can extrude the same metre of asphalt. These tests assert exactly that,
## on the real exported pack.
##
## The export directory is gitignored (assets ship as a tarball), so every test
## skips cleanly when the pack is absent — the partition maths itself is covered
## without any asset by test/unit/test_modifier_pack_py.py.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_no_double_render.gd

const ModifierPackScript := preload("res://scenes/planet/modifier_pack.gd")
const PACK_PATH := "res://assets/qgis/export/tarsis_4_chunks/terrainmodifier.pack"

## Along-road distances are float32 in the pack; 1 mm is far below anything
## visible and well above the representation error at 40 km.
const SPAN_EPS_M := 0.05

var _pack = null
var _m_per_deg: float = 0.0


func before_all() -> void:
	if not FileAccess.file_exists(PACK_PATH):
		return
	_pack = ModifierPackScript.new()
	if not _pack.open(PACK_PATH):
		_pack = null
		return
	_m_per_deg = float(_pack.get_manifest().get("radius", 6356000.0)) * PI / 180.0


func after_all() -> void:
	if _pack != null:
		_pack.close()


## True when the exported pack is unavailable; the caller should return.
func _skip_without_pack() -> bool:
	if _pack != null:
		return false
	pass_test("skipped: %s not present (export assets are gitignored)" % PACK_PATH)
	return true


## {feature_id: [[along_start, along_end], …]} for every road piece at [nside].
func _spans_by_feature(nside: int) -> Dictionary:
	var out: Dictionary = {}
	for ipix in _pack.get_tile_ipix(nside):
		var raw: PackedByteArray = _pack.read_tile(nside, int(ipix))
		if raw.is_empty():
			continue
		var t: Dictionary = _pack.decode_tile(
			raw, _m_per_deg, ModifierPackScript.MASK_ROAD)
		for r in t["roads"]:
			var cum: PackedFloat64Array = r["_cum_lengths"]
			if cum.size() < 2:
				continue
			var fid := int(r["feature_id"])
			if not out.has(fid):
				out[fid] = []
			out[fid].append([cum[0], cum[cum.size() - 1]])
	return out


func _total_span(spans: Dictionary) -> float:
	var total := 0.0
	for fid in spans:
		for s in spans[fid]:
			total += float(s[1]) - float(s[0])
	return total


# ── The core invariant ─────────────────────────────────────────────────

func test_total_road_length_is_identical_at_every_level() -> void:
	# Partitioning REDISTRIBUTES a road across more tiles as levels get finer.
	# It must never lengthen it: a longer total means some stretch is stored —
	# and would be drawn — more than once.
	if _skip_without_pack():
		return
	var levels: PackedInt64Array = _pack.get_levels()
	assert_gt(levels.size(), 1, "the pack has several levels")
	var reference := -1.0
	var ref_nside := 0
	for nside_v in levels:
		var nside := int(nside_v)
		if nside > 1024:
			break   # enough evidence; deeper levels cost a lot of tile reads
		var total := _total_span(_spans_by_feature(nside))
		if reference < 0.0:
			reference = total
			ref_nside = nside
			assert_gt(total, 0.0, "n%d actually holds roads" % nside)
			continue
		assert_almost_eq(total, reference, SPAN_EPS_M,
				"n%d total road length must equal n%d's" % [nside, ref_nside])


func test_pieces_of_one_road_never_overlap_within_a_level() -> void:
	# The direct statement of "not duplicated": at a given level, two tiles may
	# not both contain the same stretch of the same road.
	if _skip_without_pack():
		return
	for nside_v in _pack.get_levels():
		var nside := int(nside_v)
		if nside > 1024:
			break
		var spans := _spans_by_feature(nside)
		for fid in spans:
			var ranges: Array = spans[fid].duplicate()
			ranges.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			for i in range(1, ranges.size()):
				var prev_end := float(ranges[i - 1][1])
				var cur_start := float(ranges[i][0])
				assert_gt(cur_start, prev_end - SPAN_EPS_M,
						"n%d feature %d: piece starting at %.3f overlaps the "
						% [nside, fid, cur_start]
						+ "previous one ending at %.3f" % prev_end)


func test_children_partition_their_parent() -> void:
	# The chunk-level statement: a parent tile's road length is exactly shared
	# out among its four quadtree children, never duplicated into them.
	if _skip_without_pack():
		return
	var levels: PackedInt64Array = _pack.get_levels()
	var parent_nside := 0
	for nside_v in levels:
		var nside := int(nside_v)
		if nside >= 64 and nside <= 256:
			parent_nside = nside
			break
	if parent_nside == 0:
		pass_test("no suitable level pair in this pack")
		return
	var child_nside := parent_nside * 2
	if not _pack.get_levels().has(child_nside):
		pass_test("n%d not baked" % child_nside)
		return

	for parent_ipix in _pack.get_tile_ipix(parent_nside):
		var praw: PackedByteArray = _pack.read_tile(parent_nside, int(parent_ipix))
		if praw.is_empty():
			continue
		var pt: Dictionary = _pack.decode_tile(
			praw, _m_per_deg, ModifierPackScript.MASK_ROAD)
		var parent_span := 0.0
		for r in pt["roads"]:
			var cum: PackedFloat64Array = r["_cum_lengths"]
			parent_span += cum[cum.size() - 1] - cum[0]

		var child_span := 0.0
		for c in 4:
			var child_ipix: int = int(parent_ipix) * 4 + c
			var craw: PackedByteArray = _pack.read_tile(child_nside, child_ipix)
			if craw.is_empty():
				continue
			var ct: Dictionary = _pack.decode_tile(
				craw, _m_per_deg, ModifierPackScript.MASK_ROAD)
			for r in ct["roads"]:
				var cum: PackedFloat64Array = r["_cum_lengths"]
				child_span += cum[cum.size() - 1] - cum[0]

		assert_almost_eq(child_span, parent_span, SPAN_EPS_M,
				"n%d p%d: its 4 children hold %.3f m of road, the parent %.3f m"
				% [parent_nside, int(parent_ipix), child_span, parent_span])


func test_roads_are_baked_to_the_quadtree_depth() -> void:
	# If the deepest baked road level were shallower than the quadtree, chunks
	# below it would share an ancestor tile — and a shared tile is precisely how
	# two chunks ended up drawing the same road.
	if _skip_without_pack():
		return
	var cap: int = _pack.max_nside_for_kind(ModifierPackScript.KIND_ROAD)
	var quadtree_nside := 1 << 13    # tarsis_4.tscn: max_quadtree_depth = 13
	assert_true(cap >= quadtree_nside,
			"roads baked to n%d but the quadtree reaches n%d" % [cap, quadtree_nside])


func test_pieces_carry_absolute_along_distances() -> void:
	# UV continuity across a chunk seam depends on this: a piece must report its
	# offset within the WHOLE road, not restart at zero.
	if _skip_without_pack():
		return
	var found_offset_piece := false
	for ipix in _pack.get_tile_ipix(1024):
		var raw: PackedByteArray = _pack.read_tile(1024, int(ipix))
		if raw.is_empty():
			continue
		var t: Dictionary = _pack.decode_tile(
			raw, _m_per_deg, ModifierPackScript.MASK_ROAD)
		for r in t["roads"]:
			var cum: PackedFloat64Array = r["_cum_lengths"]
			assert_true(cum[cum.size() - 1] <= float(r["_total_length"]) + SPAN_EPS_M,
					"a piece cannot run past the end of its parent road")
			if cum[0] > SPAN_EPS_M:
				found_offset_piece = true
	assert_true(found_offset_piece,
			"at n1024 at least one piece must start partway along its road")
