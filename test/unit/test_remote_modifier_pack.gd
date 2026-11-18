extends GutTest
## RemoteModifierPack: the terrain-modifier pack read from the tile service (body <planet>.mod)
## instead of a shipped terrainmodifier.pack. The transport is injected (RemoteTileSource.fetcher),
## so the tree publish_tiles.py writes is served from a Dictionary — no network.

const CACHE := "user://test_remote_modifier_pack/"
const BASE := "http://modtest/dist"
const BODY := "modplanet.mod"
const VERSION := "v0001"

var _served: Dictionary = {}
var _hits: Dictionary = {}


func before_each() -> void:
	_served.clear()
	_hits.clear()
	RemoteTileSource._remove_tree(CACHE)


func after_all() -> void:
	RemoteTileSource._remove_tree(CACHE)


func _fake_fetch(url: String) -> Array:
	_hits[url] = int(_hits.get(url, 0)) + 1
	if _served.has(url):
		return [200, _served[url]]
	return [404, PackedByteArray()]


## publish_tiles.tile_blob(payload, compress=False): "DSTL", CRC32, flags 0, payload.
func _envelope(payload: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(12)
	b.encode_u32(0, RemoteTileSource.TILE_MAGIC)
	b.encode_u32(4, RemoteTileSource._crc32(payload))
	b.encode_u32(8, 0)
	b.append_array(payload)
	return b


## A one-kind DSMP tile holding a single POPULATE FULL record of [param biome_index].
func _populate_tile(biome_index: int, rank: int) -> PackedByteArray:
	var rec := PackedByteArray()
	rec.resize(12)
	rec.encode_u16(0, 0)   # biome_type sid 0 -> strings[0]
	rec.encode_u8(2, ModifierPack.COVERAGE_FULL)
	rec.encode_u8(3, 0)
	rec.encode_s32(4, biome_index)
	rec.encode_u16(8, 0)
	rec.encode_u16(10, rank)
	var t := PackedByteArray()
	t.resize(12)
	t.encode_u16(0, 1)     # tile_version
	t.encode_u16(2, 1)     # kind_count
	t.encode_u8(4, ModifierPack.KIND_POPULATE)
	t.encode_u8(5, 0)
	t.encode_u16(6, 1)     # record_count
	t.encode_u32(8, rec.size())
	t.append_array(rec)
	return t


## publish_tiles.floor_bundle: "DSFL", version, count, {nside, ipix, abs offset, length}, blobs.
func _floor(entries: Array) -> PackedByteArray:
	var head := PackedByteArray()
	head.resize(12 + entries.size() * 16)
	head.encode_u32(0, RemoteTileSource.FLOOR_MAGIC)
	head.encode_u32(4, 1)
	head.encode_u32(8, entries.size())
	var blobs := PackedByteArray()
	for k: int in range(entries.size()):
		var blob: PackedByteArray = _envelope(entries[k][2])
		head.encode_u32(12 + k * 16, int(entries[k][0]))
		head.encode_u32(16 + k * 16, int(entries[k][1]))
		head.encode_u32(20 + k * 16, head.size() + blobs.size())
		head.encode_u32(24 + k * 16, blob.size())
		blobs.append_array(blob)
	head.append_array(blobs)
	return head


## The tree publish_tiles.py writes for a pack with a floor tile (1, 3), a fine tile (64, 100)
## and nothing else.
func _publish(dataset: String = "modifiers", with_manifest: bool = true) -> void:
	var root := "%s/%s/%s" % [BASE, BODY, VERSION]
	_served["%s/%s/latest.json" % [BASE, BODY]] = JSON.stringify({
		"data_version": VERSION, "nside_min": 1, "nside_max": 64, "shard_tiles": 4096,
		"floor_nside_max": 16, "dataset": dataset}).to_utf8_buffer()
	if with_manifest:
		_served[root + "/manifest.json"] = JSON.stringify({
			"levels": [1, 16, 64], "strings": ["outcrop-plateau"],
			"parts": {"populate": {"full_inherit": true}}}).to_utf8_buffer()
	_served[root + "/floor.bin"] = _floor([[1, 3, _populate_tile(7, 0)]])
	var bits := PackedByteArray()
	bits.resize(512)
	bits[100 >> 3] = 1 << (100 & 7)
	_served[root + "/n64/f0/present.bin"] = bits
	_served[root + "/n64/f0/f100.bin"] = _envelope(_populate_tile(9, 1))


func _source() -> RemoteTileSource:
	var s := RemoteTileSource.new()
	s.cache_root = CACHE
	s.fetcher = _fake_fetch
	return s


func _open() -> RemoteModifierPack:
	var src := _source()
	assert_true(src.open_planet(BASE, BODY), "a modifiers body opens without a tile_res")
	var pack := RemoteModifierPack.new()
	assert_true(pack.open_source(src))
	return pack


func test_opens_on_the_manifest_and_the_floor() -> void:
	_publish()
	var pack := _open()
	assert_true(pack.is_open())
	assert_true(pack.is_streamed())
	assert_eq(Array(pack.get_levels()), [1, 16, 64])
	assert_true(pack.populate_inherits(), "the part flags come from the published manifest")
	assert_eq(Array(pack.get_tile_ipix(1)), [3], "the floor levels are enumerable")


func test_floor_tiles_are_ready_or_absent_without_a_request() -> void:
	_publish()
	var pack := _open()
	var before := _hits.duplicate()
	assert_eq(pack.tile_state(1, 3), ModifierPack.TILE_READY)
	assert_eq(pack.tile_state(1, 4), ModifierPack.TILE_ABSENT, "not in the floor = nothing there")
	assert_true(pack.read_tile(1, 4).is_empty())
	assert_eq(_hits, before, "a floor level never asks the service again")
	var zones: Array = pack.decode_tile(pack.read_tile(1, 3))["populate_zones"]
	assert_eq(int(zones[0]["biome_index"]), 7)
	assert_eq(str(zones[0]["biome_type"]), "outcrop-plateau", "string table from the manifest")


func test_a_fine_tile_is_pending_until_downloaded() -> void:
	_publish()
	var pack := _open()
	assert_eq(pack.tile_state(64, 100), ModifierPack.TILE_PENDING, "presence map not known yet")
	pack.source.has_tile(64, 100)   # what the download thread does with the queued presence job
	assert_eq(pack.tile_state(64, 100), ModifierPack.TILE_PENDING, "published, not on disk yet")
	assert_true(pack.read_tile(64, 100).is_empty(), "never read from the network on the hot path")
	assert_true(pack.source.fetch_now(64, 100))
	assert_eq(pack.tile_state(64, 100), ModifierPack.TILE_READY)
	var zones: Array = pack.decode_tile(pack.read_tile(64, 100))["populate_zones"]
	assert_eq(int(zones[0]["biome_index"]), 9)
	assert_eq(int(zones[0]["_rank"]), 1)


func test_an_unpublished_tile_is_absent_once_its_map_is_known() -> void:
	_publish()
	var pack := _open()
	pack.source.has_tile(64, 101)
	assert_eq(pack.tile_state(64, 101), ModifierPack.TILE_ABSENT, "bit clear in present.bin")
	pack.source.has_tile(64, 5000)
	assert_eq(pack.tile_state(64, 5000), ModifierPack.TILE_ABSENT,
			"a shard with no tile is not published at all: its 404 means empty")
	assert_eq(pack.tile_state(32, 0), ModifierPack.TILE_ABSENT, "a level the pack has not")


func test_no_manifest_no_pack() -> void:
	_publish("modifiers", false)
	var src := _source()
	assert_true(src.open_planet(BASE, BODY))
	assert_false(RemoteModifierPack.new().open_source(src))


func test_an_elevation_body_is_not_a_modifier_pack() -> void:
	_publish("")
	var src := _source()
	assert_false(src.open_planet(BASE, BODY), "no tile_res and not a modifiers body")
	assert_false(RemoteModifierPack.new().open_source(src))
