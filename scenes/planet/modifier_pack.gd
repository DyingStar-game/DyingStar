@tool
class_name ModifierPack
extends RefCounted
## Runtime reader for per-chunk terrain-modifier archives (terrainmodifier.pack,
## format DSMP v1) produced by tools/qgis/link_modifiers.py.
##
## Where heights.pack (DSHP) stores a DENSE grid of fixed-size elevation tiles,
## this pack stores SPARSE, variable-size vector tiles: roads, craters, linear
## features (rivers / lava / dry beds / canyons), radial features (caves,
## fumaroles, volcanoes) and biome populate zones. Most HEALPix pixels contain
## nothing, so a dense index-free layout is impossible — each level carries a
## sorted index of only its non-empty tiles.
##
## The geometry inside a tile is ALREADY CLIPPED to that tile and decimated for
## that level. A chunk reads its own tile and draws it verbatim; it never walks
## a global centerline. That is what makes it impossible for two chunks at
## different LODs to both render the same road.
##
## On-disk layout (little-endian; see tools/qgis/export/planet/dsmp.py for the
## authoritative spec):
##   magic        "DSMP" (4B)
##   version      u32 = 1
##   level_count  u32
##   flags        u32   bit0 FLAG_TILES_ZSTD (v1: always 0)
##   index_start  u32   absolute offset of the index region (16B aligned)
##   blob_start   u32   absolute offset of the tile blob    (16B aligned)
##   json_len     u32
##   reserved     u32 = 0
##   manifest     json_len bytes (verbatim manifest.json, UTF-8)
##   … pad to 16B
##   level directory: level_count × 16B, ascending nside:
##       u32 nside | u32 entry_count | u64 index_offset (relative to index_start)
##   … pad to index_start
##   index: per level, entry_count × 16B, SORTED ASCENDING BY ipix:
##       u32 ipix | u64 offset (relative to blob_start) | u32 size
##   … pad to blob_start
##   blob: tile payloads back to back, no per-tile alignment.
##
## Tile payload:
##   u16 tile_version = 1 | u16 kind_count
##   kind directory, kind_count × 8B, ascending kind:
##       u8 kind | u8 reserved | u16 record_count | u32 block_bytes
##   then the kind blocks, in the same order.
##
## Record layouts (all coordinates i32 in 1e-7 deg; padding keeps f32/i32
## fields 4-byte aligned):
##   CRATER   16B  i32 lon | i32 lat | f32 radius_m | f32 depth_m
##   RADIAL   20B  i32 lon | i32 lat | f32 radius_m | f32 depth_m
##                 u16 type_sid | u16 profile_sid
##   LINEAR        u16 type_sid | u16 profile_sid | u8 flags | u8 rsv | u16 pad
##                 f32 width_start_m | f32 width_end_m
##                 f32 half_width_max_deg | f32 total_length_m
##                 [f32 depth_override]        (only when flags bit0)
##                 u32 feature_id | u32 point_count
##                 point_count × { i32 lon | i32 lat | f32 cum_length_m }
##   ROAD          u16 road_type_sid | u16 surface_sid | u16 name_sid
##                 u16 lanes (0xFFFF = unset)
##                 f32 width_m (TOTAL width) | f32 total_length_m
##                 u32 feature_id | u32 point_count
##                 point_count × { i32 lon | i32 lat | f32 along_m }
##   POPULATE      u16 biome_type_sid | u8 coverage | u8 prop_count
##                 i32 biome_index | u16 vertex_count | u16 rsv
##                 prop_count × { u16 key_sid | u8 vtype | u8 pad | u32 value }
##                 coverage == point   : i32 lon | i32 lat
##                 coverage == partial : vertex_count × { i32 lon | i32 lat }
##
## Lookup is a binary search performed IN PLACE on the index bytes
## (PackedByteArray.decode_u32) — a level may hold millions of entries and
## materialising them as a Dictionary would cost ~100 bytes of Variant per entry
## plus an O(n) build on the main thread inside open().
##
## Threading model — identical to HeightPack, and for the same reason (mesh and
## collision generation run on WorkerThreadPool tasks):
##   · The header, level directory and the WHOLE index region are read once at
##     open(); index lookups are pure memory reads, no I/O, no locking.
##   · A prefix of the tile blob is preloaded (see PRELOAD_MAX_BYTES); reads
##     that fall inside it are pure slices.
##   · Everything else uses ONE FileAccess PER CALLING THREAD, keyed by thread
##     id, so concurrent seeks never interleave and the read path needs no
##     mutex. A mutex guards only handle-dictionary inserts.
##   · open() and close() must run on the main thread while no worker task is
##     reading (PlanetTerrain drains tasks before teardown).

const MAGIC := "DSMP"
const VERSION := 1

## Reserved: per-tile zstd compression. v1 packs never set it.
const FLAG_TILES_ZSTD := 1

## Bytes of the tile blob preloaded into RAM at open(). Unlike HeightPack's
## fixed PRELOAD_MAX_NSIDE, a byte budget is used here because tile sizes are
## data-dependent, not tile_res²·4. The linker writes the blob level by level
## ascending, so a prefix is exactly "the coarsest levels".
const PRELOAD_MAX_BYTES := 32 * 1024 * 1024

## Effective preload budget, overridable before open(). Tests lower it to force
## reads through the per-thread FileAccess path; production leaves the default.
var preload_max_bytes: int = PRELOAD_MAX_BYTES

## Record kinds. Must match dsmp.py.
const KIND_CRATER := 1
const KIND_LINEAR := 2
const KIND_RADIAL := 3
const KIND_POPULATE := 4
const KIND_ROAD := 5

## Bit masks for decode_tile()'s kind_mask (1 << kind).
const MASK_CRATER := 1 << KIND_CRATER
const MASK_LINEAR := 1 << KIND_LINEAR
const MASK_RADIAL := 1 << KIND_RADIAL
const MASK_POPULATE := 1 << KIND_POPULATE
const MASK_ROAD := 1 << KIND_ROAD
const MASK_ALL := MASK_CRATER | MASK_LINEAR | MASK_RADIAL | MASK_POPULATE | MASK_ROAD

## Coordinates are stored as int32 in units of 1e-7 degree (~1.1 cm).
const COORD_SCALE := 1.0e-7

## u16 string id meaning "absent".
const SID_NONE := 0xFFFF

## Fixed record sizes, in bytes.
const CRATER_SIZE := 16
const RADIAL_SIZE := 20
## Bytes per polyline point: i32 lon | i32 lat | f32 along.
const POINT_SIZE := 12

## Populate zone coverage codes.
const COVERAGE_FULL := 0
const COVERAGE_PARTIAL := 1
const COVERAGE_POINT := 2

var _path: String = ""
var _level_count: int = 0
var _flags: int = 0
var _index_start: int = 0
var _blob_start: int = 0
var _manifest: Dictionary = {}
var _strings: PackedStringArray = PackedStringArray()
## nside -> {"base": byte offset into _index_blob, "count": entry_count}
var _levels: Dictionary = {}
var _levels_sorted: PackedInt64Array = PackedInt64Array()
## The whole index region, searched in place.
var _index_blob: PackedByteArray = PackedByteArray()
## Prefix of the tile blob (coarse levels).
var _preloaded: PackedByteArray = PackedByteArray()
var _blob_size: int = 0
## Per-thread FileAccess handles: thread id -> FileAccess.
var _handles: Dictionary = {}
var _handles_mutex: Mutex = Mutex.new()


## Open a pack and parse its header, level directory and index.
## Returns true on success. Call from the main thread before any worker reads.
func open(res_path: String) -> bool:
	close()
	var fa := FileAccess.open(res_path, FileAccess.READ)
	if fa == null:
		return false
	if fa.get_length() < 32:
		push_warning("ModifierPack: %s is too small to be a pack" % res_path)
		return false
	if fa.get_buffer(4).get_string_from_ascii() != MAGIC:
		push_warning("ModifierPack: bad magic in %s" % res_path)
		return false
	var version := fa.get_32()
	if version != VERSION:
		push_warning("ModifierPack: unsupported version %d in %s" % [version, res_path])
		return false
	_level_count = fa.get_32()
	_flags = fa.get_32()
	_index_start = fa.get_32()
	_blob_start = fa.get_32()
	var json_len := fa.get_32()
	fa.get_32()  # reserved
	if _flags & FLAG_TILES_ZSTD:
		push_warning("ModifierPack: %s uses per-tile compression, "
				% res_path + "which this reader does not implement")
		return false

	var manifest_txt := fa.get_buffer(json_len).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(manifest_txt)
	_manifest = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	var raw_strings: Array = _manifest.get("strings", [])
	_strings = PackedStringArray()
	_strings.resize(raw_strings.size())
	for i in raw_strings.size():
		_strings[i] = String(raw_strings[i])

	var file_len := fa.get_length()
	if _index_start < 32 or _blob_start < _index_start or _blob_start > file_len:
		push_warning("ModifierPack: %s has an inconsistent header "
				% res_path + "(index_start=%d blob_start=%d len=%d)"
				% [_index_start, _blob_start, file_len])
		return false

	# Level directory sits between the manifest and index_start.
	@warning_ignore("integer_division")
	var dir_start: int = (32 + json_len + 15) / 16 * 16
	if dir_start + _level_count * 16 > _index_start:
		push_warning("ModifierPack: %s level directory overruns the index region"
				% res_path)
		return false
	fa.seek(dir_start)
	var dir_bytes := fa.get_buffer(_level_count * 16)

	# Index region, read whole and searched in place.
	var index_bytes := _blob_start - _index_start
	fa.seek(_index_start)
	_index_blob = fa.get_buffer(index_bytes)

	_levels = {}
	var nsides: Array[int] = []
	for i in _level_count:
		var nside := dir_bytes.decode_u32(i * 16)
		var count := dir_bytes.decode_u32(i * 16 + 4)
		var idx_off := dir_bytes.decode_u64(i * 16 + 8)
		if idx_off + count * 16 > index_bytes:
			push_warning("ModifierPack: %s level n%d index overruns the region"
					% [res_path, nside])
			close()
			return false
		_levels[nside] = {"base": idx_off, "count": count}
		nsides.append(nside)
	nsides.sort()
	_levels_sorted = PackedInt64Array(nsides)

	# Preload a prefix of the blob (the coarse levels).
	_blob_size = file_len - _blob_start
	var preload_end: int = mini(_blob_size, maxi(preload_max_bytes, 0))
	if preload_end > 0:
		fa.seek(_blob_start)
		_preloaded = fa.get_buffer(preload_end)

	_path = res_path
	fa.close()
	return true


func close() -> void:
	_handles_mutex.lock()
	for tid: int in _handles:
		(_handles[tid] as FileAccess).close()
	_handles.clear()
	_handles_mutex.unlock()
	_path = ""
	_manifest = {}
	_strings = PackedStringArray()
	_levels = {}
	_levels_sorted = PackedInt64Array()
	_index_blob = PackedByteArray()
	_preloaded = PackedByteArray()
	_level_count = 0
	_blob_size = 0


func is_open() -> bool:
	return _path != ""


func get_path() -> String:
	return _path


## manifest.json embedded in the pack.
func get_manifest() -> Dictionary:
	return _manifest


## Baked pyramid levels, ascending.
func get_levels() -> PackedInt64Array:
	return _levels_sorted


## Deepest nside at which [param kind] was baked, from manifest["kind_max_nside"].
## Returns 0 when the kind is absent from this pack.
func max_nside_for_kind(kind: int) -> int:
	var caps: Dictionary = _manifest.get("kind_max_nside", {})
	return int(caps.get(kind_name(kind), 0))


## Canonical manifest key for a record kind.
static func kind_name(kind: int) -> String:
	match kind:
		KIND_CRATER: return "crater"
		KIND_LINEAR: return "linear"
		KIND_RADIAL: return "radial"
		KIND_POPULATE: return "populate"
		KIND_ROAD: return "road"
	return ""


## True when this pack holds a (non-empty) tile for [param ipix] at [param nside].
func has_tile(nside: int, ipix: int) -> bool:
	return _find_entry(nside, ipix).x >= 0


## Every non-empty ipix at [param nside], ascending.
##
## Enumerating a level any other way means probing 12*nside² pixels — 12.5
## million at n1024. Reads straight off the index, so it is O(entry_count).
## For tools and tests; the chunk path only ever asks for its own tile.
func get_tile_ipix(nside: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var lvl: Variant = _levels.get(nside)
	if lvl == null:
		return out
	var base: int = int((lvl as Dictionary)["base"])
	var count: int = int((lvl as Dictionary)["count"])
	out.resize(count)
	for i in count:
		out[i] = _index_blob.decode_u32(base + i * 16)
	return out


## Raw payload bytes of one tile. Empty when the level is not baked or the tile
## holds nothing. Thread-safe and lock-free.
func read_tile(nside: int, ipix: int) -> PackedByteArray:
	if _path == "":
		return PackedByteArray()
	var e := _find_entry(nside, ipix)
	if e.x < 0:
		return PackedByteArray()
	var off: int = e.x
	var size: int = e.y
	if off + size <= _preloaded.size():
		return _preloaded.slice(off, off + size)
	var fa := _thread_handle()
	if fa == null:
		return PackedByteArray()
	fa.seek(_blob_start + off)
	return fa.get_buffer(size)


## Binary search over the level's sorted (ipix, offset, size) triples, performed
## directly on the index bytes so no Variant is ever allocated.
## Returns Vector2i(offset, size), or Vector2i(-1, 0) when absent.
func _find_entry(nside: int, ipix: int) -> Vector2i:
	var lvl: Variant = _levels.get(nside)
	if lvl == null:
		return Vector2i(-1, 0)
	var base: int = int((lvl as Dictionary)["base"])
	var count: int = int((lvl as Dictionary)["count"])
	var lo := 0
	var hi := count
	while lo < hi:
		@warning_ignore("integer_division")
		var mid: int = (lo + hi) / 2
		if _index_blob.decode_u32(base + mid * 16) < ipix:
			lo = mid + 1
		else:
			hi = mid
	if lo >= count or _index_blob.decode_u32(base + lo * 16) != ipix:
		return Vector2i(-1, 0)
	return Vector2i(
		_index_blob.decode_u64(base + lo * 16 + 4),
		_index_blob.decode_u32(base + lo * 16 + 12))


## Lazily open (and cache) a FileAccess for the calling thread. Each thread owns
## its handle exclusively, so seek+read never interleave across threads.
func _thread_handle() -> FileAccess:
	var tid := OS.get_thread_caller_id()
	_handles_mutex.lock()
	var fa: FileAccess = _handles.get(tid)
	if fa == null:
		fa = FileAccess.open(_path, FileAccess.READ)
		if fa != null:
			_handles[tid] = fa
	_handles_mutex.unlock()
	return fa


# ── Decoding ────────────────────────────────────────────────────────────

## Resolve a u16 string id through the pack's string table.
func _sid(i: int) -> String:
	if i == SID_NONE or i < 0 or i >= _strings.size():
		return ""
	return _strings[i]


## Decode a tile payload into per-kind arrays.
##
## [param m_per_deg] = planet_radius * PI / 180. Used to fill the derived
## degree-space fields that BiomeQuery.get_cross_section_t() and the road ribbon
## builder read, so the per-zone prepare_zone() helpers can be skipped. Passing
## 0.0 leaves those fields unset.
##
## [param kind_mask] selects which kinds to decode (see MASK_*). Blocks outside
## the mask are skipped without being parsed — the road ribbon path never pays
## for biome polygons, and the server collision path never pays for roads.
##
## Returns {"craters", "linear_features", "radial_features", "populate_zones",
## "roads", "_raw_bytes"}. Every element matches the schema the runtime already
## consumes, so callers need no field renaming.
func decode_tile(bytes: PackedByteArray, m_per_deg: float = 0.0,
		kind_mask: int = MASK_ALL) -> Dictionary:
	var out := {
		"craters": [],
		"linear_features": [],
		"radial_features": [],
		"populate_zones": [],
		"roads": [],
		"_raw_bytes": bytes.size(),
	}
	if bytes.size() < 4:
		return out
	var tile_version := bytes.decode_u16(0)
	if tile_version != 1:
		push_warning("ModifierPack: unsupported tile version %d" % tile_version)
		return out
	var kind_count := bytes.decode_u16(2)
	var dir_off := 4
	var block_off := 4 + kind_count * 8
	for i in kind_count:
		var e := dir_off + i * 8
		if e + 8 > bytes.size():
			break
		var kind := bytes.decode_u8(e)
		var record_count := bytes.decode_u16(e + 2)
		var block_bytes := bytes.decode_u32(e + 4)
		var start := block_off
		block_off += block_bytes
		if block_off > bytes.size():
			push_warning("ModifierPack: tile block for kind %d overruns payload" % kind)
			break
		if not (kind_mask & (1 << kind)):
			continue
		match kind:
			KIND_CRATER:
				out["craters"] = _decode_craters(bytes, start, record_count)
			KIND_RADIAL:
				out["radial_features"] = _decode_radials(bytes, start, record_count)
			KIND_LINEAR:
				out["linear_features"] = _decode_linears(
						bytes, start, record_count, m_per_deg)
			KIND_ROAD:
				out["roads"] = _decode_roads(bytes, start, record_count, m_per_deg)
			KIND_POPULATE:
				out["populate_zones"] = _decode_populate(bytes, start, record_count)
	return out


func _decode_craters(b: PackedByteArray, off: int, count: int) -> Array:
	var out: Array = []
	out.resize(count)
	for i in count:
		var p := off + i * CRATER_SIZE
		out[i] = {
			"lon": b.decode_s32(p) * COORD_SCALE,
			"lat": b.decode_s32(p + 4) * COORD_SCALE,
			"radius_m": b.decode_float(p + 8),
			"depth_m": b.decode_float(p + 12),
		}
	return out


func _decode_radials(b: PackedByteArray, off: int, count: int) -> Array:
	var out: Array = []
	out.resize(count)
	for i in count:
		var p := off + i * RADIAL_SIZE
		out[i] = {
			"lon": b.decode_s32(p) * COORD_SCALE,
			"lat": b.decode_s32(p + 4) * COORD_SCALE,
			"radius_m": b.decode_float(p + 8),
			"depth_m": b.decode_float(p + 12),
			"type": _sid(b.decode_u16(p + 16)),
			"profile": _sid(b.decode_u16(p + 18)),
		}
	return out


## Read point_count × {i32 lon_e7, i32 lat_e7, f32 along} into a centerline and
## its cumulative-length array.
##
## The cumulative lengths are stored PER POINT rather than recomputed from the
## centerline, because this piece is clipped: recomputing would restart at 0 in
## every tile, so a river would snap back to its start width and a road's
## asphalt UVs would jump at every chunk boundary.
func _decode_polyline(b: PackedByteArray, off: int, count: int) -> Array:
	var cl := PackedVector2Array()
	cl.resize(count)
	var cum := PackedFloat64Array()
	cum.resize(count)
	for i in count:
		var p := off + i * POINT_SIZE
		cl[i] = Vector2(
			b.decode_s32(p) * COORD_SCALE,
			b.decode_s32(p + 4) * COORD_SCALE)
		cum[i] = b.decode_float(p + 8)
	return [cl, cum]


func _decode_linears(b: PackedByteArray, off: int, count: int,
		m_per_deg: float) -> Array:
	var out: Array = []
	var p := off
	for _i in count:
		if p + 24 > b.size():
			break
		var type_sid := b.decode_u16(p)
		var profile_sid := b.decode_u16(p + 2)
		var flags := b.decode_u8(p + 4)
		# p + 5 : u8 reserved, p + 6 : u16 padding — keeps the f32s 4-aligned.
		var width_start_m := b.decode_float(p + 8)
		var width_end_m := b.decode_float(p + 12)
		var half_width_max_deg := b.decode_float(p + 16)
		var total_length_m := b.decode_float(p + 20)
		p += 24
		var depth_override := 0.0
		var has_depth := bool(flags & 1)
		if has_depth:
			depth_override = b.decode_float(p)
			p += 4
		var feature_id := b.decode_u32(p)
		var point_count := b.decode_u32(p + 4)
		p += 8
		var poly := _decode_polyline(b, p, point_count)
		p += point_count * POINT_SIZE

		var zone := {
			"type": _sid(type_sid),
			"profile": _sid(profile_sid),
			"feature_id": feature_id,
			"centerline": poly[0],
			"_cum_lengths": poly[1],
			"_total_length": total_length_m,
			"width_start_m": width_start_m,
			"width_end_m": width_end_m,
			"width_start": width_start_m,
			"width_end": width_end_m,
			"half_width_max_deg": half_width_max_deg,
		}
		if has_depth:
			zone["depth_override"] = depth_override
		if m_per_deg > 0.0:
			# Same derived fields MaritimeRiverRiverTerrain.prepare_zone() would
			# compute — set here so it skips the zone and does NOT recompute
			# _cum_lengths from the clipped centerline.
			zone["half_width_start_deg"] = (width_start_m * 0.5) / m_per_deg
			zone["half_width_end_deg"] = (width_end_m * 0.5) / m_per_deg
			zone["_river_prepared"] = true
		out.append(zone)
	return out


func _decode_roads(b: PackedByteArray, off: int, count: int,
		m_per_deg: float) -> Array:
	var out: Array = []
	var p := off
	for _i in count:
		if p + 24 > b.size():
			break
		var road_type := _sid(b.decode_u16(p))
		var surface := _sid(b.decode_u16(p + 2))
		var road_name := _sid(b.decode_u16(p + 4))
		var lanes_raw := b.decode_u16(p + 6)
		var width_m := b.decode_float(p + 8)
		var total_length_m := b.decode_float(p + 12)
		var feature_id := b.decode_u32(p + 16)
		var point_count := b.decode_u32(p + 20)
		p += 24
		var poly := _decode_polyline(b, p, point_count)
		p += point_count * POINT_SIZE

		# width_m is the TOTAL width (export_roads.py semantics); halve once
		# here so no consumer has to guess. This is also what ends the
		# metres-vs-degrees ambiguity of the old `half_width_deg`, which
		# BiomeQuery filled with width/2 in METRES and RoadTerrain.prepare_zone()
		# then overwrote with degrees.
		var half_width_m := width_m * 0.5
		var road := {
			"road_type": road_type,
			"surface": surface,
			"name": road_name,
			"feature_id": feature_id,
			"width": width_m,
			"width_m": width_m,
			"half_width_m": half_width_m,
			"centerline": poly[0],
			"_cum_lengths": poly[1],
			"_total_length": total_length_m,
		}
		if lanes_raw != SID_NONE:
			road["lanes"] = lanes_raw
		if m_per_deg > 0.0:
			road["half_width_deg"] = half_width_m / m_per_deg
			road["_road_hw_converted"] = true
		out.append(road)
	return out


func _decode_populate(b: PackedByteArray, off: int, count: int) -> Array:
	var out: Array = []
	var p := off
	for _i in count:
		if p + 12 > b.size():
			break
		var biome_type := _sid(b.decode_u16(p))
		var coverage_code := b.decode_u8(p + 2)
		var prop_count := b.decode_u8(p + 3)
		var biome_index := b.decode_s32(p + 4)
		var vertex_count := b.decode_u16(p + 8)
		# p + 10 : u16 reserved — keeps biome_index 4-aligned.
		p += 12

		var zone := {
			"biome_type": biome_type,
			"biome_index": biome_index,
			"coverage": _coverage_name(coverage_code),
		}
		for _pi in prop_count:
			var key := _sid(b.decode_u16(p))
			var vtype := b.decode_u8(p + 2)
			if key != "":
				match vtype:
					0: zone[key] = b.decode_float(p + 4)
					1: zone[key] = _sid(b.decode_u16(p + 4))
					2: zone[key] = b.decode_s32(p + 4)
			p += 8

		if coverage_code == COVERAGE_POINT:
			zone["lon"] = b.decode_s32(p) * COORD_SCALE
			zone["lat"] = b.decode_s32(p + 4) * COORD_SCALE
			p += 8
		elif coverage_code == COVERAGE_PARTIAL:
			# Emit BOTH outline keys: per-vertex containment and the recipe
			# exports use `vertices`, some older paths read `polygon`.
			# See PlanetChunk._zone_outline().
			var verts: Array = []
			verts.resize(vertex_count)
			var packed := PackedVector2Array()
			packed.resize(vertex_count)
			for vi in vertex_count:
				var q := p + vi * 8
				var lon_v := b.decode_s32(q) * COORD_SCALE
				var lat_v := b.decode_s32(q + 4) * COORD_SCALE
				verts[vi] = [lon_v, lat_v]
				packed[vi] = Vector2(lon_v, lat_v)
			zone["vertices"] = verts
			zone["polygon"] = packed
			p += vertex_count * 8
		out.append(zone)
	return out


static func _coverage_name(code: int) -> String:
	match code:
		COVERAGE_FULL: return "full"
		COVERAGE_PARTIAL: return "partial"
		COVERAGE_POINT: return "point"
	return "partial"
