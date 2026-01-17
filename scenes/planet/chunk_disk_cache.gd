class_name ChunkDiskCache
extends RefCounted
## Manages on-disk caching of generated terrain chunk meshes and collision
## shapes.
##
## Client visual meshes are stored under [code]user://chunk_cache/<planet>/[/code].
## Server pre-baked collision shapes are stored under
## [code]user://prebaked_collision/<planet>/[/code].
##
## A [code]version.txt[/code] file stores a hash of key planet parameters.
## When those parameters change (re-export, radius tweak, etc.), the cache
## for that planet is automatically invalidated on next load.
##
## Pass [code]--clean-chunks-cache[/code] on the command line to wipe the
## client visual mesh cache ([code]user://chunk_cache/[/code]) on startup.

## Cache root for client visual meshes.
const BASE_DIR := "user://chunk_cache/"
## Cache root for server pre-baked collision shapes.
const SERVER_COLLISION_BASE_DIR := "user://prebaked_collision/"

## Number of resources loaded from disk cache.
var cache_hits: int = 0
## Number of resources saved to disk cache.
var cache_saves: int = 0

var _planet_dir: String
var _enabled: bool = true


## [param base_dir] selects the root folder.
## Use [constant BASE_DIR] for client meshes (default) or
## [constant SERVER_COLLISION_BASE_DIR] for server collision prebakes.
func _init(planet_name: String, version_hash: String,
		base_dir: String = BASE_DIR) -> void:
	if planet_name.is_empty():
		_enabled = false
		return

	_planet_dir = base_dir + planet_name + "/"

	# Handle --clean-chunks-cache CLI argument
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if "--clean-chunks-cache" in args:
		clean_all_cache()

	DirAccess.make_dir_recursive_absolute(_planet_dir)
	_validate_version(version_hash)


func _validate_version(version_hash: String) -> void:
	var version_path := _planet_dir + "version.txt"
	if FileAccess.file_exists(version_path):
		var f := FileAccess.open(version_path, FileAccess.READ)
		if f:
			var stored := f.get_as_text().strip_edges()
			f.close()
			if stored == version_hash:
				print("[ChunkDiskCache] Cache valid for '%s'" % _planet_dir)
				return
		print("[ChunkDiskCache] Version mismatch — clearing cache for '%s'" % _planet_dir)
	else:
		print("[ChunkDiskCache] No existing cache — creating '%s'" % _planet_dir)

	_clear_dir(_planet_dir)
	DirAccess.make_dir_recursive_absolute(_planet_dir)
	var f := FileAccess.open(version_path, FileAccess.WRITE)
	if f:
		f.store_string(version_hash)
		f.close()


## Remove all client visual mesh caches for all planets.
static func clean_all_cache() -> void:
	print("[ChunkDiskCache] Cleaning ALL chunk cache at '%s'" % BASE_DIR)
	_clear_dir(BASE_DIR)


## Remove all server pre-baked collision caches for all planets.
static func clean_server_collision_cache() -> void:
	print("[ChunkDiskCache] Cleaning ALL prebaked collision cache at '%s'" % SERVER_COLLISION_BASE_DIR)
	_clear_dir(SERVER_COLLISION_BASE_DIR)


## Recursively remove a directory and all its contents.
static func _clear_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir():
			_clear_dir(path.path_join(fname))
		else:
			dir.remove(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


# ── Path helpers ──────────────────────────────────────────────────

func _res_path(chunk_key: String, lod: int, suffix: String) -> String:
	return "%s%s_lod%d_%s.res" % [_planet_dir, chunk_key, lod, suffix]


# ── Mesh cache ────────────────────────────────────────────────────

func has_mesh(chunk_key: String, lod: int) -> bool:
	if not _enabled:
		return false
	return FileAccess.file_exists(_res_path(chunk_key, lod, "mesh"))


func load_mesh(chunk_key: String, lod: int) -> ArrayMesh:
	if not _enabled:
		return null
	var path := _res_path(chunk_key, lod, "mesh")
	if not FileAccess.file_exists(path):
		return null
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res is ArrayMesh:
		cache_hits += 1
		return res as ArrayMesh
	push_warning("[ChunkDiskCache] Failed to load mesh from '%s'" % path)
	return null


func save_mesh(chunk_key: String, lod: int, mesh: ArrayMesh) -> void:
	if not _enabled:
		return
	var path := _res_path(chunk_key, lod, "mesh")
	var err := ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	if err == OK:
		cache_saves += 1
	else:
		push_warning("[ChunkDiskCache] Failed to save mesh to '%s': %d" % [path, err])


# ── Collision shape cache (server) ────────────────────────────────

func has_collision(chunk_key: String, lod: int) -> bool:
	if not _enabled:
		return false
	return FileAccess.file_exists(_res_path(chunk_key, lod, "col"))


func load_collision(chunk_key: String, lod: int) -> ConcavePolygonShape3D:
	if not _enabled:
		return null
	var path := _res_path(chunk_key, lod, "col")
	if not FileAccess.file_exists(path):
		return null
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res is ConcavePolygonShape3D:
		cache_hits += 1
		return res as ConcavePolygonShape3D
	push_warning("[ChunkDiskCache] Failed to load collision from '%s'" % path)
	return null


func save_collision(chunk_key: String, lod: int, shape: ConcavePolygonShape3D) -> void:
	if not _enabled:
		return
	var path := _res_path(chunk_key, lod, "col")
	var err := ResourceSaver.save(shape, path, ResourceSaver.FLAG_COMPRESS)
	if err == OK:
		cache_saves += 1
	else:
		push_warning("[ChunkDiskCache] Failed to save collision to '%s': %d" % [path, err])
