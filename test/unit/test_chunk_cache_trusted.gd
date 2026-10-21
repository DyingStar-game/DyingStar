extends GutTest
## ChunkDiskCache's trusted files: a cache file checked once (or published from a good tile) is not
## checked again in the next sessions, until the cache version changes.

const BASE := "user://test_chunk_cache_trusted/"
const FILE := "hp_n64_p12_lod0_mesh.res"


func after_each() -> void:
	ChunkDiskCache._clear_dir(BASE)


func test_a_trusted_file_stays_trusted_in_the_next_session() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	assert_false(cache.is_trusted(BASE + "planet/" + FILE))
	cache.trust(BASE + "planet/" + FILE)
	assert_true(cache.is_trusted(BASE + "planet/" + FILE))
	cache.save_trusted(true)
	var next := ChunkDiskCache.new("planet", "v1", BASE)
	assert_true(next.is_trusted(BASE + "planet/" + FILE), "read back from trusted.txt")


func test_a_new_version_trusts_nothing() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	cache.trust(BASE + "planet/" + FILE)
	cache.save_trusted(true)
	var next := ChunkDiskCache.new("planet", "v2", BASE)
	assert_false(next.is_trusted(BASE + "planet/" + FILE), "cleared with the files")


func test_a_stale_file_is_trusted_no_more() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	cache.trust(BASE + "planet/" + FILE)
	cache.save_trusted(true)
	cache.distrust(BASE + "planet/" + FILE)
	cache.save_trusted(true)
	assert_false(ChunkDiskCache.new("planet", "v1", BASE).is_trusted(BASE + "planet/" + FILE))


func test_writes_are_spaced_out() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	cache.trust(BASE + "planet/" + FILE)
	cache.save_trusted()  # just opened: within TRUSTED_SAVE_MS of the load
	assert_false(FileAccess.file_exists(BASE + "planet/" + ChunkDiskCache.TRUSTED_FILE))
	cache.save_trusted(true)
	assert_true(FileAccess.file_exists(BASE + "planet/" + ChunkDiskCache.TRUSTED_FILE))
