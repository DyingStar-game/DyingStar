@tool
class_name HeightPack
extends RefCounted
## Runtime reader for dense elevation-tile packs (heights.pack, format DSHP v1)
## produced by tools/qgis/export_elevation.py.
##
## The pack holds every .r32 pyramid tile of one planet in a single file. Tiles
## are fixed-size (tile_res² float32) and dense (every ipix exists at every
## level), so no index is stored — a tile's offset is pure arithmetic:
##
##     offset(nside, ipix) = blob_start + level_base[nside] + ipix * tile_size
##
## On-disk layout (little-endian, see export_elevation.py for the authoritative spec):
##   magic      "DSHP" (4B)
##   version    u32 = 1
##   tile_res   u32
##   nside_min  u32
##   nside_max  u32
##   flags      u32 (reserved)
##   blob_start u32
##   json_len   u32 + manifest.json bytes (verbatim)
##   blob: levels ascending (nside_min … nside_max, powers of two), tiles in
##         ipix order, each tile_res²·4 bytes raw float32.
##
## Threading model — designed for WorkerThreadPool mesh/collision tasks:
##   · Coarse levels (nside ≤ preload_max_nside) are read into memory once at
##     open(); reads from them are pure slices — no I/O, no locking.
##   · Fine levels use ONE FileAccess PER CALLING THREAD (lazily opened, keyed
##     by thread id), so concurrent reads never share a file position and need
##     no mutex on the read path. A mutex guards only handle-dictionary inserts.
##   · open() and close() must run on the main thread while no worker tasks
##     are reading (PlanetTerrain drains tasks before teardown).

const MAGIC := "DSHP"
const VERSION := 1
## Levels with nside ≤ this are fully preloaded into RAM at open().
## n1…n16 for tile_res=25 is ~10 MB per planet: every far/orbit LOD read
## becomes a memory slice instead of disk I/O.
const PRELOAD_MAX_NSIDE := 16

var _path: String = ""
var _tile_res: int = 0
var _tile_size: int = 0
var _nside_min: int = 0
var _nside_max: int = 0
var _blob_start: int = 0
var _manifest: Dictionary = {}
## nside -> byte offset of that level's first tile, relative to blob_start.
var _level_base: Dictionary = {}
var _total_blob_size: int = 0
## Coarse levels (nside ≤ PRELOAD_MAX_NSIDE) as one contiguous buffer.
var _preloaded: PackedByteArray = PackedByteArray()
## Per-thread FileAccess handles: thread id -> FileAccess.
var _handles: Dictionary = {}
var _handles_mutex: Mutex = Mutex.new()


## Open a pack and parse its header. Returns true on success.
## Call from the main thread before any worker task reads tiles.
func open(res_path: String) -> bool:
	close()
	var fa := FileAccess.open(res_path, FileAccess.READ)
	if fa == null:
		return false
	if fa.get_buffer(4).get_string_from_ascii() != MAGIC:
		push_warning("HeightPack: bad magic in %s" % res_path)
		return false
	var version := fa.get_32()
	if version != VERSION:
		push_warning("HeightPack: unsupported version %d in %s" % [version, res_path])
		return false
	_tile_res = fa.get_32()
	_nside_min = fa.get_32()
	_nside_max = fa.get_32()
	fa.get_32()  # flags (reserved)
	_blob_start = fa.get_32()
	var json_len := fa.get_32()
	var manifest_txt := fa.get_buffer(json_len).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(manifest_txt)
	_manifest = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	_tile_size = _tile_res * _tile_res * 4

	# Level base offsets (levels are ascending powers of two).
	_level_base = {}
	var base := 0
	var ns := _nside_min
	while ns <= _nside_max:
		_level_base[ns] = base
		base += 12 * ns * ns * _tile_size
		ns *= 2
	_total_blob_size = base
	if fa.get_length() < _blob_start + _total_blob_size:
		push_warning("HeightPack: %s truncated (%d < %d bytes)"
				% [res_path, fa.get_length(), _blob_start + _total_blob_size])
		close()
		return false

	# Preload coarse levels in one sequential read.
	var preload_end := 0
	ns = _nside_min
	while ns <= mini(_nside_max, PRELOAD_MAX_NSIDE):
		preload_end = int(_level_base[ns]) + 12 * ns * ns * _tile_size
		ns *= 2
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
	_level_base = {}
	_preloaded = PackedByteArray()


func is_open() -> bool:
	return _path != ""


## Manifest.json embedded in the pack (same content as the loose file).
func get_manifest() -> Dictionary:
	return _manifest


## Raw tile bytes (tile_res² float32) for [param ipix] at pyramid level
## [param nside]. Empty array if out of range. Thread-safe, lock-free:
## coarse levels slice the preloaded buffer; fine levels read through a
## per-thread FileAccess handle.
func read_tile(nside: int, ipix: int) -> PackedByteArray:
	if _path == "" or not _level_base.has(nside):
		return PackedByteArray()
	if ipix < 0 or ipix >= 12 * nside * nside:
		return PackedByteArray()
	var off: int = int(_level_base[nside]) + ipix * _tile_size
	if off + _tile_size <= _preloaded.size():
		return _preloaded.slice(off, off + _tile_size)
	var fa := _thread_handle()
	if fa == null:
		return PackedByteArray()
	fa.seek(_blob_start + off)
	return fa.get_buffer(_tile_size)


## Lazily open (and cache) a FileAccess for the calling thread. Each thread
## owns its handle exclusively, so seek+read never interleave across threads.
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
