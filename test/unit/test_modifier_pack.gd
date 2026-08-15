extends GutTest
## GUT test suite for ModifierPack (scenes/planet/modifier_pack.gd) — the sparse
## DSMP v1 terrain-modifier archive reader.
##
## A synthetic pack is generated in user:// with pyramid levels n1…n32. Only
## tiles whose ipix is a multiple of SPARSE_STRIDE are populated, so the binary
## search is exercised on gaps, before the first entry and past the last one.
## Every record carries a marker derived from (nside, ipix) so reads can be
## verified exactly.
##
## _write_pack() below is the REFERENCE WRITER: tools/qgis/export/planet/dsmp.py
## must produce byte-identical output for the same input (see
## test/unit/test_modifier_pack_py.py, which compares both against a shared
## SHA-256).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_modifier_pack.gd

const ModifierPackScript := preload("res://scenes/planet/modifier_pack.gd")

const NSIDE_MIN := 1
const NSIDE_MAX := 32
const SPARSE_STRIDE := 7
const PACK_DIR := "user://test_modifier_pack_chunks"
const PACK_PATH := PACK_DIR + "/terrainmodifier.pack"
const BAD_MAGIC_PATH := PACK_DIR + "/bad_magic.pack"
const BAD_VERSION_PATH := PACK_DIR + "/bad_version.pack"

## Planet radius used for the derived degree fields.
const RADIUS := 6356000.0

## String table. Index 0 is deliberately a real string so a 0 sid is meaningful.
const STRINGS := [
	"maritime_river-river",   # 0  linear type
	"v_shape",                # 1  linear profile
	"spatial-cave",           # 2  radial type
	"bowl",                   # 3  radial profile
	"road",                   # 4  road_type
	"asphalt",                # 5  surface
	"route de test",          # 6  road name
	"meadow_steppe-meadow",   # 7  biome_type
	"density",                # 8  prop key (float)
	"undergrowth",            # 9  prop key (string)
	"fern",                   # 10 prop value (string)
]

const SID_LINEAR_TYPE := 0
const SID_LINEAR_PROFILE := 1
const SID_RADIAL_TYPE := 2
const SID_RADIAL_PROFILE := 3
const SID_ROAD_TYPE := 4
const SID_SURFACE := 5
const SID_ROAD_NAME := 6
const SID_BIOME := 7
const SID_DENSITY := 8
const SID_UNDERGROWTH := 9
const SID_FERN := 10

var _levels: Array[int] = []
var _m_per_deg: float = RADIUS * PI / 180.0


# ── Marker values, all derived from (nside, ipix) ───────────────────────

func _marker(nside: int, ipix: int) -> float:
	return float(nside * 1000 + ipix)


## Longitude of the tile's first point. Kept inside ±180 and away from the
## antimeridian so no wrapping logic is involved.
func _marker_lon(nside: int, ipix: int) -> float:
	return fmod(_marker(nside, ipix) * 0.001, 170.0) - 85.0


func _marker_lat(nside: int, ipix: int) -> float:
	return fmod(_marker(nside, ipix) * 0.0007, 80.0) - 40.0


func _populated(ipix: int) -> bool:
	return ipix % SPARSE_STRIDE == 0


# ── Encoding helpers (the reference writer) ─────────────────────────────

func _e7(deg: float) -> int:
	return int(round(deg * 1.0e7))


func _put_u8(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)


func _put_u16(b: PackedByteArray, v: int) -> void:
	var o := b.size()
	b.resize(o + 2)
	b.encode_u16(o, v)


func _put_u32(b: PackedByteArray, v: int) -> void:
	var o := b.size()
	b.resize(o + 4)
	b.encode_u32(o, v)


func _put_s32(b: PackedByteArray, v: int) -> void:
	var o := b.size()
	b.resize(o + 4)
	b.encode_s32(o, v)


func _put_u64(b: PackedByteArray, v: int) -> void:
	var o := b.size()
	b.resize(o + 8)
	b.encode_u64(o, v)


func _put_f32(b: PackedByteArray, v: float) -> void:
	var o := b.size()
	b.resize(o + 4)
	b.encode_float(o, v)


func _put_point(b: PackedByteArray, lon: float, lat: float, along: float) -> void:
	_put_s32(b, _e7(lon))
	_put_s32(b, _e7(lat))
	_put_f32(b, along)


# ── Per-kind block builders ────────────────────────────────────────────

func _block_crater(nside: int, ipix: int) -> PackedByteArray:
	var b := PackedByteArray()
	_put_s32(b, _e7(_marker_lon(nside, ipix)))
	_put_s32(b, _e7(_marker_lat(nside, ipix)))
	_put_f32(b, _marker(nside, ipix))          # radius_m
	_put_f32(b, _marker(nside, ipix) * 0.1)    # depth_m
	return b


func _block_radial(nside: int, ipix: int) -> PackedByteArray:
	var b := PackedByteArray()
	_put_s32(b, _e7(_marker_lon(nside, ipix) + 0.5))
	_put_s32(b, _e7(_marker_lat(nside, ipix) + 0.5))
	_put_f32(b, _marker(nside, ipix) * 2.0)    # radius_m
	_put_f32(b, _marker(nside, ipix) * 0.2)    # depth_m
	_put_u16(b, SID_RADIAL_TYPE)
	_put_u16(b, SID_RADIAL_PROFILE)
	return b


## 3-point linear feature with a depth_override, so the flags bit is exercised.
func _block_linear(nside: int, ipix: int) -> PackedByteArray:
	var b := PackedByteArray()
	_put_u16(b, SID_LINEAR_TYPE)
	_put_u16(b, SID_LINEAR_PROFILE)
	_put_u8(b, 1)          # flags: has depth_override
	_put_u8(b, 0)          # reserved
	_put_u16(b, 0)         # padding
	_put_f32(b, 40.0)      # width_start_m
	_put_f32(b, 90.0)      # width_end_m
	_put_f32(b, 0.0004)    # half_width_max_deg
	_put_f32(b, 1500.0)    # total_length_m  (of the UNCLIPPED parent)
	_put_f32(b, 7.5)       # depth_override
	_put_u32(b, ipix)      # feature_id
	_put_u32(b, 3)         # point_count
	var lon := _marker_lon(nside, ipix)
	var lat := _marker_lat(nside, ipix)
	# cum_length_m does NOT start at 0: this piece is clipped out of the middle
	# of a longer river, which is exactly what the format has to preserve.
	_put_point(b, lon, lat, 400.0)
	_put_point(b, lon + 0.01, lat + 0.01, 700.0)
	_put_point(b, lon + 0.02, lat + 0.02, 1000.0)
	return b


func _block_road(nside: int, ipix: int) -> PackedByteArray:
	var b := PackedByteArray()
	_put_u16(b, SID_ROAD_TYPE)
	_put_u16(b, SID_SURFACE)
	_put_u16(b, SID_ROAD_NAME)
	_put_u16(b, 2)         # lanes
	_put_f32(b, 6.0)       # width_m (TOTAL)
	_put_f32(b, 2400.0)    # total_length_m
	_put_u32(b, ipix + 1000)
	_put_u32(b, 2)         # point_count
	var lon := _marker_lon(nside, ipix)
	var lat := _marker_lat(nside, ipix)
	_put_point(b, lon, lat, 800.0)
	_put_point(b, lon + 0.005, lat, 1100.0)
	return b


## Partial-coverage zone with 4 vertices and 2 props (one float, one string).
func _block_populate(nside: int, ipix: int) -> PackedByteArray:
	var b := PackedByteArray()
	_put_u16(b, SID_BIOME)
	_put_u8(b, ModifierPackScript.COVERAGE_PARTIAL)
	_put_u8(b, 2)          # prop_count
	_put_s32(b, 3)         # biome_index
	_put_u16(b, 4)         # vertex_count
	_put_u16(b, 0)         # reserved
	# prop 0: density = 0.75 (f32)
	_put_u16(b, SID_DENSITY)
	_put_u8(b, 0)
	_put_u8(b, 0)
	_put_f32(b, 0.75)
	# prop 1: undergrowth = "fern" (string id)
	_put_u16(b, SID_UNDERGROWTH)
	_put_u8(b, 1)
	_put_u8(b, 0)
	_put_u32(b, SID_FERN)
	var lon := _marker_lon(nside, ipix)
	var lat := _marker_lat(nside, ipix)
	for d in [Vector2(0.0, 0.0), Vector2(0.1, 0.0), Vector2(0.1, 0.1), Vector2(0.0, 0.1)]:
		_put_s32(b, _e7(lon + d.x))
		_put_s32(b, _e7(lat + d.y))
	return b


## Assemble one tile payload: header + kind directory + blocks.
func _tile_payload(nside: int, ipix: int) -> PackedByteArray:
	var kinds := [
		[ModifierPackScript.KIND_CRATER, 1, _block_crater(nside, ipix)],
		[ModifierPackScript.KIND_LINEAR, 1, _block_linear(nside, ipix)],
		[ModifierPackScript.KIND_RADIAL, 1, _block_radial(nside, ipix)],
		[ModifierPackScript.KIND_POPULATE, 1, _block_populate(nside, ipix)],
		[ModifierPackScript.KIND_ROAD, 1, _block_road(nside, ipix)],
	]
	var out := PackedByteArray()
	_put_u16(out, 1)              # tile_version
	_put_u16(out, kinds.size())
	for k in kinds:
		_put_u8(out, k[0])
		_put_u8(out, 0)
		_put_u16(out, k[1])
		_put_u32(out, (k[2] as PackedByteArray).size())
	for k in kinds:
		out.append_array(k[2] as PackedByteArray)
	return out


func _manifest_dict() -> Dictionary:
	var caps := {}
	for k in ["crater", "linear", "radial", "populate", "road"]:
		caps[k] = NSIDE_MAX
	return {
		"format": "dsmp_v1",
		"pack_file": "terrainmodifier.pack",
		"planet_name": "testmod",
		"radius": RADIUS,
		"nside_min": NSIDE_MIN,
		"nside_max": NSIDE_MAX,
		"levels": _levels,
		"kind_max_nside": caps,
		"coord_scale": ModifierPackScript.COORD_SCALE,
		"strings": STRINGS,
	}


## Write a valid DSMP v1 pack. This is the reference encoder — dsmp.py must
## match it byte for byte.
func _write_pack(path: String, magic: String = "DSMP", version: int = 1) -> void:
	DirAccess.make_dir_recursive_absolute(PACK_DIR)

	# 1. Per-level tile payloads, ipix ascending.
	var per_level: Array = []      # [ [nside, [[ipix, payload], …]], … ]
	for nside in _levels:
		var npix := 12 * nside * nside
		var tiles: Array = []
		for ipix in npix:
			if _populated(ipix):
				tiles.append([ipix, _tile_payload(nside, ipix)])
		per_level.append([nside, tiles])

	# 2. Blob + index entries.
	var blob := PackedByteArray()
	var index := PackedByteArray()
	var dir_entries: Array = []    # [nside, count, index_offset]
	for lv in per_level:
		var nside: int = lv[0]
		var tiles: Array = lv[1]
		dir_entries.append([nside, tiles.size(), index.size()])
		for t in tiles:
			var payload: PackedByteArray = t[1]
			_put_u32(index, t[0])          # ipix
			_put_u64(index, blob.size())   # offset relative to blob_start
			_put_u32(index, payload.size())
			blob.append_array(payload)

	# 3. Header geometry.
	var manifest := JSON.stringify(_manifest_dict()).to_utf8_buffer()
	@warning_ignore("integer_division")
	var dir_start: int = (32 + manifest.size() + 15) / 16 * 16
	@warning_ignore("integer_division")
	var index_start: int = (dir_start + dir_entries.size() * 16 + 15) / 16 * 16
	@warning_ignore("integer_division")
	var blob_start: int = (index_start + index.size() + 15) / 16 * 16

	var f := FileAccess.open(path, FileAccess.WRITE)
	assert(f != null)
	f.store_buffer(magic.to_ascii_buffer())
	f.store_32(version)
	f.store_32(dir_entries.size())
	f.store_32(0)              # flags
	f.store_32(index_start)
	f.store_32(blob_start)
	f.store_32(manifest.size())
	f.store_32(0)              # reserved
	f.store_buffer(manifest)
	while f.get_position() < dir_start:
		f.store_8(0)
	for d in dir_entries:
		f.store_32(d[0])
		f.store_32(d[1])
		f.store_64(d[2])
	while f.get_position() < index_start:
		f.store_8(0)
	f.store_buffer(index)
	while f.get_position() < blob_start:
		f.store_8(0)
	f.store_buffer(blob)
	f.close()


func before_all() -> void:
	_levels = []
	var ns := NSIDE_MIN
	while ns <= NSIDE_MAX:
		_levels.append(ns)
		ns *= 2
	_write_pack(PACK_PATH)
	_write_pack(BAD_MAGIC_PATH, "XXXX")
	_write_pack(BAD_VERSION_PATH, "DSMP", 99)


func after_all() -> void:
	for p in [PACK_PATH, BAD_MAGIC_PATH, BAD_VERSION_PATH]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Open the shared fixture. [param preload_bytes] < 0 keeps the default budget.
func _open(preload_bytes: int = -1):
	var pack = ModifierPackScript.new()
	if preload_bytes >= 0:
		pack.preload_max_bytes = preload_bytes
	assert_true(pack.open(PACK_PATH), "pack opens")
	return pack


# ── Header / manifest / levels ─────────────────────────────────────────

func test_open_parses_header_manifest_and_levels() -> void:
	var pack = _open()
	assert_true(pack.is_open(), "is_open after open")
	var m: Dictionary = pack.get_manifest()
	assert_eq(m.get("planet_name", ""), "testmod", "manifest round-trips")
	assert_eq(m.get("format", ""), "dsmp_v1", "format tag")
	var levels := pack.get_levels()
	assert_eq(levels.size(), _levels.size(), "level count")
	for i in _levels.size():
		assert_eq(int(levels[i]), _levels[i], "level[%d] ascending" % i)
	pack.close()
	assert_false(pack.is_open(), "closed")


func test_max_nside_for_kind() -> void:
	var pack = _open()
	assert_eq(pack.max_nside_for_kind(ModifierPackScript.KIND_ROAD), NSIDE_MAX,
			"road cap read from manifest")
	assert_eq(pack.max_nside_for_kind(99), 0, "unknown kind → 0")
	pack.close()


func test_open_rejects_bad_magic() -> void:
	var pack = ModifierPackScript.new()
	assert_false(pack.open(BAD_MAGIC_PATH), "bad magic rejected")
	assert_false(pack.is_open(), "not left open")


func test_open_rejects_bad_version() -> void:
	var pack = ModifierPackScript.new()
	assert_false(pack.open(BAD_VERSION_PATH), "bad version rejected")


func test_open_rejects_missing_file() -> void:
	var pack = ModifierPackScript.new()
	assert_false(pack.open(PACK_DIR + "/does_not_exist.pack"), "missing file")


# ── Sparse index lookup ────────────────────────────────────────────────

func test_has_tile_hits_and_misses() -> void:
	var pack = _open()
	for nside in _levels:
		var npix := 12 * nside * nside
		for ipix in mini(npix, 40):
			assert_eq(pack.has_tile(nside, ipix), _populated(ipix),
					"n%d p%d presence" % [nside, ipix])
	pack.close()


func test_lookup_before_first_and_after_last_entry() -> void:
	var pack = _open()
	# ipix 0 IS populated (0 % 7 == 0), so probe the gaps around it and past
	# the last entry of the level.
	assert_true(pack.has_tile(1, 0), "first entry present")
	assert_false(pack.has_tile(1, 1), "gap right after the first entry")
	var npix := 12 * 1 * 1
	assert_false(pack.has_tile(1, npix - 1), "past the last populated ipix")
	assert_false(pack.has_tile(1, npix + 500), "far out of range")
	assert_false(pack.has_tile(1, -1), "negative ipix")
	pack.close()


func test_unbaked_level_returns_nothing() -> void:
	var pack = _open()
	assert_false(pack.has_tile(3, 0), "n3 is not a baked level")
	assert_eq(pack.read_tile(3, 0).size(), 0, "no bytes for an unbaked level")
	assert_eq(pack.read_tile(NSIDE_MAX * 2, 0).size(), 0, "past nside_max")
	pack.close()


func test_read_tile_is_empty_for_gaps() -> void:
	var pack = _open()
	assert_gt(pack.read_tile(8, 0).size(), 0, "populated tile has bytes")
	assert_eq(pack.read_tile(8, 1).size(), 0, "gap tile has no bytes")
	pack.close()


# ── Decoding ───────────────────────────────────────────────────────────

func test_decode_all_five_kinds() -> void:
	var pack = _open()
	var nside := 8
	var ipix := 14
	var t := pack.decode_tile(pack.read_tile(nside, ipix), _m_per_deg)

	assert_eq((t["craters"] as Array).size(), 1, "one crater")
	var cr: Dictionary = t["craters"][0]
	assert_almost_eq(cr["lon"], _marker_lon(nside, ipix), 1e-6, "crater lon")
	assert_almost_eq(cr["lat"], _marker_lat(nside, ipix), 1e-6, "crater lat")
	assert_almost_eq(cr["radius_m"], _marker(nside, ipix), 1e-2, "crater radius")
	assert_almost_eq(cr["depth_m"], _marker(nside, ipix) * 0.1, 1e-2, "crater depth")

	assert_eq((t["radial_features"] as Array).size(), 1, "one radial")
	var rf: Dictionary = t["radial_features"][0]
	assert_eq(rf["type"], "spatial-cave", "radial type from string table")
	assert_eq(rf["profile"], "bowl", "radial profile")
	assert_almost_eq(rf["radius_m"], _marker(nside, ipix) * 2.0, 1e-2, "radial radius")

	assert_eq((t["linear_features"] as Array).size(), 1, "one linear")
	var lf: Dictionary = t["linear_features"][0]
	assert_eq(lf["type"], "maritime_river-river", "linear type")
	assert_eq(lf["profile"], "v_shape", "linear profile")
	assert_almost_eq(lf["width_start_m"], 40.0, 1e-3, "width_start_m")
	assert_almost_eq(lf["width_end_m"], 90.0, 1e-3, "width_end_m")
	assert_almost_eq(lf["depth_override"], 7.5, 1e-3, "depth_override present")
	var cl: PackedVector2Array = lf["centerline"]
	assert_eq(cl.size(), 3, "3 centerline points")
	assert_typeof(cl, TYPE_PACKED_VECTOR2_ARRAY, "centerline is PackedVector2Array")

	assert_eq((t["roads"] as Array).size(), 1, "one road")
	var rd: Dictionary = t["roads"][0]
	assert_eq(rd["road_type"], "road", "road_type")
	assert_eq(rd["surface"], "asphalt", "surface")
	assert_eq(rd["name"], "route de test", "name")
	assert_eq(rd["lanes"], 2, "lanes")
	assert_almost_eq(rd["width_m"], 6.0, 1e-3, "total width")
	assert_almost_eq(rd["half_width_m"], 3.0, 1e-3, "half width in metres")

	assert_eq((t["populate_zones"] as Array).size(), 1, "one populate zone")
	var pz: Dictionary = t["populate_zones"][0]
	assert_eq(pz["biome_type"], "meadow_steppe-meadow", "biome_type")
	assert_eq(pz["biome_index"], 3, "biome_index")
	assert_eq(pz["coverage"], "partial", "coverage")
	assert_almost_eq(pz["density"], 0.75, 1e-4, "float prop")
	assert_eq(pz["undergrowth"], "fern", "string prop")
	pack.close()


func test_linear_cum_lengths_survive_clipping() -> void:
	# The whole point of storing cum_length_m per point: a clipped piece must
	# report its position along the PARENT feature, not restart at zero.
	var pack = _open()
	var t := pack.decode_tile(pack.read_tile(8, 14), _m_per_deg)
	var lf: Dictionary = t["linear_features"][0]
	var cum: PackedFloat64Array = lf["_cum_lengths"]
	assert_eq(cum.size(), 3, "one cumulative length per point")
	assert_almost_eq(cum[0], 400.0, 1e-3, "piece does NOT start at 0")
	assert_almost_eq(cum[2], 1000.0, 1e-3, "last point keeps parent distance")
	assert_almost_eq(lf["_total_length"], 1500.0, 1e-3,
			"total length is the parent's, longer than the piece")
	assert_true(lf.get("_river_prepared", false),
			"marked prepared so prepare_zone() will not recompute from the clip")
	pack.close()


func test_road_along_m_survives_clipping() -> void:
	var pack = _open()
	var t := pack.decode_tile(pack.read_tile(8, 14), _m_per_deg)
	var rd: Dictionary = t["roads"][0]
	var cum: PackedFloat64Array = rd["_cum_lengths"]
	assert_almost_eq(cum[0], 800.0, 1e-3, "road piece keeps its parent offset")
	assert_almost_eq(cum[1], 1100.0, 1e-3, "and its second point")
	assert_true(rd.get("_road_hw_converted", false),
			"half_width_deg pre-converted, so RoadTerrain.prepare_zone() skips it")
	assert_almost_eq(rd["half_width_deg"], 3.0 / _m_per_deg, 1e-12,
			"half width converted to degrees exactly once")
	pack.close()


func test_derived_degree_fields_skipped_without_m_per_deg() -> void:
	var pack = _open()
	var t := pack.decode_tile(pack.read_tile(8, 14), 0.0)
	var lf: Dictionary = t["linear_features"][0]
	assert_false(lf.has("half_width_start_deg"), "no degree fields without radius")
	assert_false(lf.get("_river_prepared", false), "left for prepare_zone()")
	pack.close()


func test_populate_zone_emits_both_outline_keys() -> void:
	# PlanetChunk._zone_outline() accepts either, but consumers are split:
	# per-vertex containment reads `vertices`, older cliff code read `polygon`.
	var pack = _open()
	var t := pack.decode_tile(pack.read_tile(8, 14), _m_per_deg)
	var pz: Dictionary = t["populate_zones"][0]
	var verts: Array = pz["vertices"]
	var poly: PackedVector2Array = pz["polygon"]
	assert_eq(verts.size(), 4, "4 vertices")
	assert_eq(poly.size(), 4, "4 polygon points")
	for i in 4:
		assert_almost_eq(float(verts[i][0]), poly[i].x, 1e-9, "lon[%d] agrees" % i)
		assert_almost_eq(float(verts[i][1]), poly[i].y, 1e-9, "lat[%d] agrees" % i)
	pack.close()


func test_kind_mask_skips_blocks() -> void:
	var pack = _open()
	var raw := pack.read_tile(8, 14)
	var only_roads := pack.decode_tile(raw, _m_per_deg, ModifierPackScript.MASK_ROAD)
	assert_eq((only_roads["roads"] as Array).size(), 1, "roads decoded")
	assert_eq((only_roads["craters"] as Array).size(), 0, "craters skipped")
	assert_eq((only_roads["populate_zones"] as Array).size(), 0, "zones skipped")
	assert_eq((only_roads["linear_features"] as Array).size(), 0, "linears skipped")

	var no_roads := pack.decode_tile(raw, _m_per_deg,
			ModifierPackScript.MASK_ALL & ~ModifierPackScript.MASK_ROAD)
	assert_eq((no_roads["roads"] as Array).size(), 0, "roads skipped")
	assert_eq((no_roads["craters"] as Array).size(), 1, "craters still decoded")
	pack.close()


func test_decode_empty_payload_is_safe() -> void:
	var pack = _open()
	var t := pack.decode_tile(PackedByteArray(), _m_per_deg)
	assert_eq((t["roads"] as Array).size(), 0, "empty payload → no records")
	assert_eq(t["_raw_bytes"], 0, "raw byte count reported")
	pack.close()


func test_raw_bytes_reported_for_lru_accounting() -> void:
	var pack = _open()
	var raw := pack.read_tile(8, 14)
	var t := pack.decode_tile(raw, _m_per_deg)
	assert_eq(t["_raw_bytes"], raw.size(), "payload size passed through")
	pack.close()


# ── Cross-check against the Python encoder ─────────────────────────────

## SHA-256 of the canonical tile below. tools/qgis/export/planet/dsmp.py builds
## the same tile from the same values and test/unit/test_modifier_pack_py.py
## asserts this exact string. If the two encoders ever disagree — a reordered
## field, a lost padding byte, a different rounding rule — one of the two suites
## goes red instead of the game silently misreading packs.
const CANONICAL_TILE_SHA256 := \
	"48a8bbc56e8a7627a45e56ca417f4b0ea3d88f5672cc56760c39dd56cdebf0c5"


## One record of each kind with fixed values — no nside/ipix dependence.
func _canonical_tile() -> PackedByteArray:
	var crater := PackedByteArray()
	_put_s32(crater, _e7(-39.4109184))
	_put_s32(crater, _e7(24.7707499))
	_put_f32(crater, 1234.5)
	_put_f32(crater, 98.75)

	var linear := PackedByteArray()
	_put_u16(linear, 0)          # type_sid
	_put_u16(linear, 1)          # profile_sid
	_put_u8(linear, 1)           # flags: has depth_override
	_put_u8(linear, 0)
	_put_u16(linear, 0)
	_put_f32(linear, 40.0)
	_put_f32(linear, 90.0)
	_put_f32(linear, 0.0004)
	_put_f32(linear, 1500.0)
	_put_f32(linear, 7.5)
	_put_u32(linear, 42)
	_put_u32(linear, 3)
	_put_point(linear, -1.0, 2.0, 400.0)
	_put_point(linear, -0.99, 2.01, 700.0)
	_put_point(linear, -0.98, 2.02, 1000.0)

	var radial := PackedByteArray()
	_put_s32(radial, _e7(10.5))
	_put_s32(radial, _e7(-20.25))
	_put_f32(radial, 50.0)
	_put_f32(radial, 12.5)
	_put_u16(radial, 2)
	_put_u16(radial, 3)

	var populate := PackedByteArray()
	_put_u16(populate, 7)        # biome_type_sid
	_put_u8(populate, ModifierPackScript.COVERAGE_PARTIAL)
	_put_u8(populate, 2)         # prop_count
	_put_s32(populate, 3)        # biome_index
	_put_u16(populate, 4)        # vertex_count
	_put_u16(populate, 0)
	_put_u16(populate, 8)        # density
	_put_u8(populate, 0)
	_put_u8(populate, 0)
	_put_f32(populate, 0.75)
	_put_u16(populate, 9)        # undergrowth
	_put_u8(populate, 1)
	_put_u8(populate, 0)
	_put_u32(populate, 10)       # "fern"
	for v in [Vector2(5.0, 6.0), Vector2(5.1, 6.0), Vector2(5.1, 6.1), Vector2(5.0, 6.1)]:
		_put_s32(populate, _e7(v.x))
		_put_s32(populate, _e7(v.y))

	var road := PackedByteArray()
	_put_u16(road, 4)
	_put_u16(road, 5)
	_put_u16(road, 6)
	_put_u16(road, 2)            # lanes
	_put_f32(road, 6.0)
	_put_f32(road, 2400.0)
	_put_u32(road, 1042)
	_put_u32(road, 2)
	_put_point(road, 3.0, 4.0, 800.0)
	_put_point(road, 3.005, 4.0, 1100.0)

	var kinds := [
		[ModifierPackScript.KIND_CRATER, 1, crater],
		[ModifierPackScript.KIND_LINEAR, 1, linear],
		[ModifierPackScript.KIND_RADIAL, 1, radial],
		[ModifierPackScript.KIND_POPULATE, 1, populate],
		[ModifierPackScript.KIND_ROAD, 1, road],
	]
	var out := PackedByteArray()
	_put_u16(out, 1)
	_put_u16(out, kinds.size())
	for k in kinds:
		_put_u8(out, k[0])
		_put_u8(out, 0)
		_put_u16(out, k[1])
		_put_u32(out, (k[2] as PackedByteArray).size())
	for k in kinds:
		out.append_array(k[2] as PackedByteArray)
	return out


func test_canonical_tile_matches_python_encoder() -> void:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(_canonical_tile())
	var hex := ctx.finish().hex_encode()
	assert_eq(hex, CANONICAL_TILE_SHA256,
			"GDScript and Python must encode the canonical tile identically")


func test_canonical_tile_decodes_to_expected_records() -> void:
	# Proves the SHA above is pinned to a tile that actually round-trips,
	# not just to an arbitrary byte string.
	var pack = _open()
	var t := pack.decode_tile(_canonical_tile(), _m_per_deg)
	assert_almost_eq(float((t["craters"] as Array)[0]["lon"]), -39.4109184, 1e-7, "crater lon")
	assert_almost_eq(float((t["linear_features"] as Array)[0]["depth_override"]),
			7.5, 1e-6, "linear depth_override")
	assert_almost_eq(float((t["radial_features"] as Array)[0]["lat"]), -20.25, 1e-7, "radial lat")
	assert_eq(int((t["roads"] as Array)[0]["feature_id"]), 1042, "road feature_id")
	assert_eq(int((t["populate_zones"] as Array)[0]["biome_index"]), 3, "biome_index")
	pack.close()


# ── Coordinate precision ───────────────────────────────────────────────

func test_coord_precision_is_about_one_centimetre() -> void:
	# i32 @ 1e-7 deg. float32 would lose ~0.85 m at this longitude.
	var lon := -179.9999999
	var enc := _e7(lon)
	var dec := enc * ModifierPackScript.COORD_SCALE
	var err_deg: float = absf(dec - lon)
	var err_m := err_deg * _m_per_deg
	assert_lt(err_m, 0.02, "round-trip error under 2 cm (got %f m)" % err_m)


# ── Concurrency ────────────────────────────────────────────────────────

var _thread_results: Array = []
var _thread_mutex := Mutex.new()


func _reader_thread(seed_ipix: int) -> void:
	var pack = ModifierPackScript.new()
	pack.preload_max_bytes = 0          # force the per-thread FileAccess path
	if not pack.open(PACK_PATH):
		return
	var ok := true
	for i in 64:
		var ipix := ((seed_ipix + i) * SPARSE_STRIDE) % (12 * 32 * 32)
		var raw := pack.read_tile(32, ipix)
		if raw.size() == 0:
			ok = false
			break
		var t := pack.decode_tile(raw, _m_per_deg)
		var cr: Dictionary = (t["craters"] as Array)[0]
		if absf(float(cr["radius_m"]) - _marker(32, ipix)) > 1e-2:
			ok = false
			break
	pack.close()
	_thread_mutex.lock()
	_thread_results.append(ok)
	_thread_mutex.unlock()


func test_concurrent_reads_from_threads() -> void:
	_thread_results = []
	var threads: Array[Thread] = []
	for t in 4:
		var th := Thread.new()
		th.start(_reader_thread.bind(t * 97))
		threads.append(th)
	for th in threads:
		th.wait_to_finish()
	assert_eq(_thread_results.size(), 4, "all 4 threads reported")
	for r in _thread_results:
		assert_true(r, "every concurrent read decoded to the expected marker")


func test_shared_pack_read_from_many_threads() -> void:
	# The production shape: ONE ModifierPack shared by every worker task, with
	# the preload disabled so all reads go through per-thread file handles.
	var pack = _open(0)
	_thread_results = []
	var threads: Array[Thread] = []
	for t in 4:
		var th := Thread.new()
		th.start(func() -> void:
			var ok := true
			for i in 64:
				var ipix := ((t * 53 + i) * SPARSE_STRIDE) % (12 * 32 * 32)
				var raw := pack.read_tile(32, ipix)
				if raw.size() == 0:
					ok = false
					break
				var dec := pack.decode_tile(raw, _m_per_deg)
				var rd: Dictionary = (dec["roads"] as Array)[0]
				if int(rd["feature_id"]) != ipix + 1000:
					ok = false
					break
			_thread_mutex.lock()
			_thread_results.append(ok)
			_thread_mutex.unlock())
		threads.append(th)
	for th in threads:
		th.wait_to_finish()
	assert_eq(_thread_results.size(), 4, "all 4 threads reported")
	for r in _thread_results:
		assert_true(r, "shared-instance concurrent reads are exact")
	pack.close()


func test_preloaded_and_file_paths_agree() -> void:
	var preloaded = _open()          # default budget: whole blob in RAM
	var streamed = _open(0)          # nothing preloaded: every read hits the file
	for ipix in [0, 7, 14, 700]:
		var a := preloaded.read_tile(32, ipix)
		var b := streamed.read_tile(32, ipix)
		assert_eq(a.size(), b.size(), "same size for n32 p%d" % ipix)
		assert_true(a == b, "byte-identical for n32 p%d" % ipix)
	preloaded.close()
	streamed.close()
