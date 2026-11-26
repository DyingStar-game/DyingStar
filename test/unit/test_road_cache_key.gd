extends GutTest
## The road part re-keys the chunk cache (PlanetData.road_fingerprint, folded into PlanetTerrain's
## _cache_version as "_rd…"). Without it, a road re-export served meshes cached before it: the
## new road stopped at the edge of an old chunk, with a hole along its cutting (tarsis_3,
## 39.49 W 24.73 N, 2026-11-26) — and every re-export needed a hand-made vNN bump.


class FakePack:
	var manifest: Dictionary

	func _init(m: Dictionary) -> void:
		manifest = m

	func get_manifest() -> Dictionary:
		return manifest


func _data(parts: Dictionary) -> PlanetData:
	var d := PlanetData.new()
	d.planet_name = "road_key_test"
	d._modifier_pack = FakePack.new({"parts": parts})
	d._modifier_pack_tried = true
	return d


func _road(extra: Dictionary = {}) -> Dictionary:
	var r := {"file": "roads.dsmpart", "generated_at": "2026-11-26T08:34:00",
		"counts": {"features": 132}, "profiled_roads": 129}
	r.merge(extra, true)
	return r


func test_no_road_part_no_key() -> void:
	assert_eq(_data({}).road_fingerprint(), "", "byte-identical key for planets without roads")
	var none := PlanetData.new()
	none._modifier_pack_tried = true
	assert_eq(none.road_fingerprint(), "")


func test_the_exporters_fingerprint_is_used() -> void:
	var fp := _data({"road": _road({"fingerprint": "0123456789abcdef0123"})}).road_fingerprint()
	assert_eq(fp, "0123456789ab")


func test_a_pack_without_fingerprint_still_rekeys_on_export() -> void:
	var a := _data({"road": _road()}).road_fingerprint()
	var again := _data({"road": _road()}).road_fingerprint()
	var later := _data({"road": _road({"generated_at": "2026-11-26T09:00:00"})}).road_fingerprint()
	assert_eq(a.length(), 12)
	assert_eq(a, again, "the same pack keeps its cache")
	assert_ne(a, later, "a road re-export re-keys the cache")


func test_other_parts_do_not_move_it() -> void:
	var a := _data({"road": _road({"fingerprint": "f" + "0".repeat(39)})}).road_fingerprint()
	var b := _data({"road": _road({"fingerprint": "f" + "0".repeat(39)}),
		"mountain": {"fingerprint": "abc"}}).road_fingerprint()
	assert_eq(a, b)
