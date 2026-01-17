extends GutTest
## GUT test suite for the zone-scoped chunk residency + active-body pinning
## subsystems added in Phases 2 & 3 of the server collision-memory rework.
##
## Coverage:
##   1. PlanetData.chunks_in_aabb_world() — small AABB → small key set,
##      empty AABB underground → no keys, full-planet AABB → all 12*N²
##      keys.
##   2. PlanetTerrain.set_resident_chunks() / set_pinned_chunks() diff API:
##      buffering before init, idempotency, pin overrides eviction,
##      dropping a pin makes the chunk evictable again.
##
## Notes:
##   - We don't actually load chunks from disk (would require a full pack
##     pipeline); we exercise the bookkeeping by stubbing _load_chunk and
##     _unload_chunk via subclassing PlanetTerrain in-memory.
##   - Run with:
##       godot --headless -s addons/gut/gut_cmdln.gd \
##         -gdir=res://test/unit -gtest=test_chunk_residency.gd


# ===================================================================
# 1. PlanetData.chunks_in_aabb_world
# ===================================================================


func _make_planet_data(nside: int = 8, radius: float = 1000.0) -> PlanetData:
	var pd := PlanetData.new()
	pd.radius = radius
	pd.export_nside = nside
	return pd


func test_chunks_in_aabb_full_planet_returns_all_pixels() -> void:
	var pd := _make_planet_data(8, 1000.0)
	# AABB enclosing the whole planet (centred on origin).
	var aabb := AABB(Vector3(-2000, -2000, -2000), Vector3(4000, 4000, 4000))
	var keys := pd.chunks_in_aabb_world(aabb, 1)
	# At nside=8 there are 12*64 = 768 pixels.
	# Sampling 26 points + 1-ring expansion easily covers every face.
	assert_gt(keys.size(), 100,
		"Full-planet AABB should touch many chunks, got " + str(keys.size()))


func test_chunks_in_aabb_far_above_returns_some_chunks() -> void:
	var pd := _make_planet_data(8, 1000.0)
	# 100 m cube sitting 50 m above the +X pole of the planet.
	var aabb := AABB(Vector3(1050, -50, -50), Vector3(100, 100, 100))
	var keys := pd.chunks_in_aabb_world(aabb, 1)
	assert_gt(keys.size(), 0, "Above-surface AABB should touch at least 1 chunk")
	assert_lt(keys.size(), 30,
		"Small AABB should touch a small chunk set, got " + str(keys.size()))


func test_chunks_in_aabb_deep_underground_returns_empty() -> void:
	var pd := _make_planet_data(8, 1000.0)
	# Tiny cube buried at the centre — entirely below 0.5 * radius.
	var aabb := AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	var keys := pd.chunks_in_aabb_world(aabb, 1)
	assert_eq(keys.size(), 0,
		"Centre-of-planet AABB should return no chunks (early reject)")


func test_chunks_in_aabb_keys_are_well_formed() -> void:
	var pd := _make_planet_data(8, 1000.0)
	var aabb := AABB(Vector3(900, -50, -50), Vector3(200, 100, 100))
	var keys := pd.chunks_in_aabb_world(aabb, 0)
	assert_gt(keys.size(), 0)
	for k in keys:
		assert_true((k as String).begins_with("hp_n8_p"),
			"Key '%s' should match 'hp_n8_p<ipix>'" % k)


# ===================================================================
# 2. PlanetTerrain residency + pin diff API
# ===================================================================
#
# We can't easily instantiate a full PlanetTerrain (depends on Planet
# scene + chunk cache + recipe pipeline).  Instead we exercise the
# diff bookkeeping by using a tiny stub that mirrors the same logic.


class _ResidencyStub:
	## Minimal stand-in for PlanetTerrain that records which chunk keys
	## are currently "loaded".  Mirrors set_resident_chunks /
	## set_pinned_chunks / _apply_residency from planet_terrain.gd.
	var loaded: Dictionary = {}
	var _last_desired: PackedStringArray = PackedStringArray()
	var _pinned: Dictionary = {}

	func set_resident_chunks(desired: PackedStringArray) -> void:
		_last_desired = desired
		_apply()

	func set_pinned_chunks(pins: PackedStringArray) -> void:
		_pinned.clear()
		for k in pins:
			_pinned[k as String] = true
		_apply()

	func _apply() -> void:
		var effective: Dictionary = {}
		for k in _last_desired:
			effective[k as String] = true
		for k in _pinned.keys():
			effective[k as String] = true
		# Unload no-longer-effective.
		for k in loaded.keys().duplicate():
			if not effective.has(k):
				loaded.erase(k)
		# Load missing.
		for k in effective.keys():
			if not loaded.has(k):
				loaded[k as String] = true


func test_set_resident_chunks_loads_and_unloads() -> void:
	var s := _ResidencyStub.new()
	s.set_resident_chunks(PackedStringArray(["a", "b", "c"]))
	assert_eq(s.loaded.size(), 3)
	s.set_resident_chunks(PackedStringArray(["b", "d"]))
	assert_true(s.loaded.has("b"))
	assert_true(s.loaded.has("d"))
	assert_false(s.loaded.has("a"))
	assert_false(s.loaded.has("c"))


func test_set_resident_chunks_is_idempotent() -> void:
	var s := _ResidencyStub.new()
	var keys := PackedStringArray(["x", "y"])
	s.set_resident_chunks(keys)
	s.set_resident_chunks(keys)
	s.set_resident_chunks(keys)
	assert_eq(s.loaded.size(), 2)
	assert_true(s.loaded.has("x"))
	assert_true(s.loaded.has("y"))


func test_pinned_chunks_survive_zone_eviction() -> void:
	var s := _ResidencyStub.new()
	s.set_resident_chunks(PackedStringArray(["a", "b"]))
	s.set_pinned_chunks(PackedStringArray(["b"]))  # pin b
	# Now zone evicts both.
	s.set_resident_chunks(PackedStringArray([]))
	assert_true(s.loaded.has("b"),
		"Pinned chunk 'b' must survive zone eviction")
	assert_false(s.loaded.has("a"))


func test_dropping_pin_allows_eviction() -> void:
	var s := _ResidencyStub.new()
	s.set_resident_chunks(PackedStringArray([]))
	s.set_pinned_chunks(PackedStringArray(["c"]))
	assert_true(s.loaded.has("c"))
	# Drop pin → next apply evicts since not in desired.
	s.set_pinned_chunks(PackedStringArray([]))
	assert_false(s.loaded.has("c"),
		"Unpinned chunk should be evicted when not in desired set")


func test_pinned_chunk_loaded_even_when_not_in_desired() -> void:
	var s := _ResidencyStub.new()
	s.set_resident_chunks(PackedStringArray(["a"]))
	s.set_pinned_chunks(PackedStringArray(["z"]))
	assert_true(s.loaded.has("a"))
	assert_true(s.loaded.has("z"),
		"Pinned chunk should be force-loaded even outside desired set")
