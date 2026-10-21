extends GutTest
## ChunkDiskCache's trusted files: a cache file checked once (or published from a good tile) is not
## checked again in the next sessions, until the cache version changes.

const BASE := "user://test_chunk_cache_trusted/"
const FILE := "hp_n64_p12_lod0_mesh.res"


func after_each() -> void:
	ChunkDiskCache._clear_dir(BASE)
	ChunkDiskCache._trusted_lists.clear()  # a new session reads trusted.txt, as the game would


func test_a_trusted_file_stays_trusted_in_the_next_session() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	assert_false(cache.is_trusted(BASE + "planet/" + FILE))
	cache.trust(BASE + "planet/" + FILE)
	assert_true(cache.is_trusted(BASE + "planet/" + FILE))
	cache.save_trusted(true)
	ChunkDiskCache._trusted_lists.clear()
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
	ChunkDiskCache._trusted_lists.clear()
	assert_false(ChunkDiskCache.new("planet", "v1", BASE).is_trusted(BASE + "planet/" + FILE))


## The menu stage's planet and the game's are two caches of one folder: what one trusts, the other
## does, and neither's writing erases the other's.
func test_two_caches_of_one_planet_share_their_list() -> void:
	var menu := ChunkDiskCache.new("planet", "v1", BASE)
	var game := ChunkDiskCache.new("planet", "v1", BASE)
	game.trust(BASE + "planet/" + FILE)
	assert_true(menu.is_trusted(BASE + "planet/" + FILE))
	menu.save_trusted(true)
	ChunkDiskCache._trusted_lists.clear()
	assert_true(ChunkDiskCache.new("planet", "v1", BASE).is_trusted(BASE + "planet/" + FILE),
			"the menu's write kept the game's file")


func test_writes_are_spaced_out() -> void:
	var cache := ChunkDiskCache.new("planet", "v1", BASE)
	cache.trust(BASE + "planet/" + FILE)
	cache.save_trusted()  # just opened: within TRUSTED_SAVE_MS of the load
	assert_false(FileAccess.file_exists(BASE + "planet/" + ChunkDiskCache.TRUSTED_FILE))
	cache.save_trusted(true)
	assert_true(FileAccess.file_exists(BASE + "planet/" + ChunkDiskCache.TRUSTED_FILE))
