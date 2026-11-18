extends GutTest
## Full-coverage inheritance of the populate zones (export/planet/biomes.py "full_inherit"): a zone is
## written FULL only on the coarsest tile it entirely covers, so a tile's zones are its own plus its
## ancestors' FULL ones, re-sorted by rank. Without it tarsis_3's biome part was 1.2 GB.


## One POPULATE record: [param rank] in the u16 slot after vertex_count, no props, no geometry for a
## FULL one and a unit square for a PARTIAL one.
func _record(biome_index: int, coverage: int, rank: int) -> PackedByteArray:
	var b := PackedByteArray()
	var verts: int = 4 if coverage == ModifierPack.COVERAGE_PARTIAL else 0
	b.resize(12 + verts * 8)
	b.encode_u16(0, ModifierPack.SID_NONE)
	b.encode_u8(2, coverage)
	b.encode_u8(3, 0)
	b.encode_s32(4, biome_index)
	b.encode_u16(8, verts)
	b.encode_u16(10, rank)
	var square: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i: int in range(verts):
		b.encode_s32(12 + i * 8, int(square[i].x * 1.0e7))
		b.encode_s32(16 + i * 8, int(square[i].y * 1.0e7))
	return b


func _zone(biome_index: int, coverage: String, rank: int) -> Dictionary:
	return {"biome_index": biome_index, "coverage": coverage, "_rank": rank}


func _indices(zones: Array) -> Array[int]:
	var out: Array[int] = []
	for zone: Dictionary in zones:
		out.append(int(zone["biome_index"]))
	return out


func test_rank_is_decoded_from_the_record() -> void:
	var pack := ModifierPack.new()
	var bytes := _record(7, ModifierPack.COVERAGE_FULL, 41)
	bytes.append_array(_record(8, ModifierPack.COVERAGE_PARTIAL, 3))
	var zones: Array = pack._decode_populate(bytes, 0, 2)
	assert_eq(zones.size(), 2)
	assert_eq(int(zones[0]["_rank"]), 41)
	assert_eq(str(zones[0]["coverage"]), "full")
	assert_eq(int(zones[1]["_rank"]), 3)
	assert_eq((zones[1]["polygon"] as PackedVector2Array).size(), 4)


func test_no_ancestor_zone_returns_the_tile_s_own_list() -> void:
	var own: Array = [_zone(1, "partial", 2)]
	assert_same(ModifierPack.merge_inherited_zones(own, [[], []]), own)


func test_ancestors_full_zones_merge_in_rank_order() -> void:
	var own: Array = [_zone(10, "partial", 1), _zone(30, "partial", 5)]
	var parent: Array = [_zone(20, "full", 3), _zone(99, "partial", 0)]
	var grand: Array = [_zone(40, "full", 0)]
	var merged: Array = ModifierPack.merge_inherited_zones(own, [parent, grand])
	assert_eq(_indices(merged), [40, 10, 20, 30] as Array[int],
			"rank order; an ancestor's PARTIAL zone is its own edge, not this tile's")


func test_inherits_flag_comes_from_the_populate_part() -> void:
	var pack := ModifierPack.new()
	assert_false(pack.populate_inherits(), "no manifest, no inheritance")
	pack._manifest = {"parts": {"populate": {"full_inherit": true}}}
	assert_true(pack.populate_inherits())
	pack._manifest = {"parts": {"populate": {}}}
	assert_false(pack.populate_inherits(), "an older pack keeps its own list per tile")
