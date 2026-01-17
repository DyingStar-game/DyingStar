@tool
class_name PlanetPack
extends RefCounted
## Runtime reader for per-planet .planetpack archives produced by
## tools/qgis/pack_planet.py.
##
## On-disk layout (little-endian, see pack_planet.py for the authoritative spec):
##   magic        "DSPP"  (4B)
##   version      u32     = 1
##   entry_count  u32
##   [ entries ] * entry_count
##       path_len u16
##       path     utf-8 bytes
##       offset   u64  (from start of file)
##       size     u64
##   [ blob region ]
##
## Usage:
##     var pack := PlanetPack.new()
##     if pack.open("res://assets/qgis/export/tarsis_3.planetpack"):
##         var buf := pack.read_entry("base_0/hp_n64_p123.bin")
##         var recipe: Dictionary = bytes_to_var(buf)   # or use read_entry_var()
##
## The reader is lock-free for reads that do not overlap (per-tile recipes are
## independent). If multiple threads need to read at once, hold your own mutex
## around read_entry() — FileAccess inside a single instance is not thread-safe.

const MAGIC := "DSPP"
const VERSION := 1

var _path: String = ""
var _index: Dictionary = {}  # name -> {"off": int, "size": int}
var _fa: FileAccess = null
# Serializes seek+read on the shared FileAccess. Recipe loads happen from
# WorkerThreadPool tasks, so concurrent reads on a single FileAccess would
# otherwise interleave seeks.
var _mutex: Mutex = Mutex.new()


## Open a pack file and read its index. Returns true on success.
func open(res_path: String) -> bool:
	close()
	_fa = FileAccess.open(res_path, FileAccess.READ)
	if _fa == null:
		push_warning("PlanetPack: cannot open '%s' (err %d)" % [
			res_path, FileAccess.get_open_error()])
		return false

	_path = res_path
	var magic := _fa.get_buffer(4).get_string_from_ascii()
	if magic != MAGIC:
		push_warning("PlanetPack: bad magic '%s' in %s" % [magic, res_path])
		close()
		return false
	var version := _fa.get_32()
	if version != VERSION:
		push_warning("PlanetPack: unsupported version %d in %s" % [version, res_path])
		close()
		return false
	var count := _fa.get_32()
	_index = {}
	for i in count:
		var plen := _fa.get_16()
		var name := _fa.get_buffer(plen).get_string_from_utf8()
		var off := _fa.get_64()
		var size := _fa.get_64()
		_index[name] = {"off": off, "size": size}
	return true


func close() -> void:
	if _fa != null:
		_fa.close()
		_fa = null
	_path = ""
	_index.clear()


## True if an entry with the given pack-relative name exists.
func has_entry(name: String) -> bool:
	return _index.has(name)


## Return the raw byte payload of an entry as PackedByteArray.
## Returns an empty array if the entry is missing or the pack is closed.
func read_entry(name: String) -> PackedByteArray:
	if _fa == null:
		return PackedByteArray()
	var meta: Dictionary = _index.get(name, {})
	if meta.is_empty():
		return PackedByteArray()
	_mutex.lock()
	_fa.seek(meta["off"])
	var buf := _fa.get_buffer(meta["size"])
	_mutex.unlock()
	return buf


## Decode an entry that was written via store_var(..., full_objects=false),
## which matches tools/convert_recipes_binary.gd.
## Returns null if the entry is missing or cannot be decoded.
func read_entry_var(name: String) -> Variant:
	if _fa == null:
		return null
	var meta: Dictionary = _index.get(name, {})
	if meta.is_empty():
		return null
	# Use FileAccess.get_var directly: the payload was written with
	# FileAccess.store_var(value, false), which includes the 4-byte length
	# prefix that get_var expects. bytes_to_var does NOT understand that
	# prefix, so we must decode straight from FileAccess.
	_mutex.lock()
	_fa.seek(meta["off"])
	var data: Variant = _fa.get_var(false)
	_mutex.unlock()
	return data


## Parse an entry as UTF-8 JSON.
func read_entry_json(name: String) -> Variant:
	var buf := read_entry(name)
	if buf.is_empty():
		return null
	var txt := buf.get_string_from_utf8()
	var j := JSON.new()
	if j.parse(txt) != OK:
		push_warning("PlanetPack: JSON parse failed for '%s' in %s: %s" % [
			name, _path, j.get_error_message()])
		return null
	return j.data


func entry_count() -> int:
	return _index.size()


## Size in bytes of a packed entry (0 if missing).
func get_entry_size(name: String) -> int:
	var meta: Dictionary = _index.get(name, {})
	return int(meta.get("size", 0))


func get_path() -> String:
	return _path
