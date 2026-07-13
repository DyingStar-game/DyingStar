extends GutTest
## GUT test suite for HeightPack (scenes/planet/height_pack.gd) — the dense
## DSHP v1 elevation-tile archive reader — and its integration into
## PlanetData.load_chunk_heightmap().
##
## A synthetic pack is generated in user:// with tile_res=2 and pyramid
## levels n1…n32. PRELOAD_MAX_NSIDE is 16, so levels n1…n16 exercise the
## in-memory preload path while n32 exercises the per-thread FileAccess
## path. Every tile is filled with a per-tile marker value so reads can be
## verified exactly.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gdir=res://test/unit -gtest=test_height_pack.gd

const HeightPackScript := preload("res://scenes/planet/height_pack.gd")

const TILE_RES := 2
const NSIDE_MIN := 1
const NSIDE_MAX := 32
const PACK_DIR := "user://test_height_pack_chunks"
const PACK_PATH := PACK_DIR + "/heights.pack"

var _levels: Array[int] = []


## Marker value stored in every float of tile (nside, ipix).
func _tile_value(nside: int, ipix: int) -> float:
	return float(nside * 100000 + ipix)


func _manifest_json() -> String:
	return JSON.stringify({
		"planet_name": "testpack",
		"radius": 1000.0,
		"nside": NSIDE_MAX,
		"chunk_export_depth": 5,
		"tile_res": TILE_RES,
		"format": "r32_f32_normalized",
		"pyramid": true,
		"nside_min": NSIDE_MIN,
		"nside_max": NSIDE_MAX,
		"height_offset": 0.0,
		"max_height": 1.0,
		"packed": true,
		"pack_file": "heights.pack",
	})


## Write a valid DSHP v1 pack (same layout as tools/qgis/export_elevation.py).
func _write_pack() -> void:
	DirAccess.make_dir_recursive_absolute(PACK_DIR)
	var f := FileAccess.open(PACK_PATH, FileAccess.WRITE)
	assert(f != null)
	var manifest := _manifest_json().to_utf8_buffer()
	var raw_len := 32 + manifest.size()
	@warning_ignore("integer_division")
	var blob_start := (raw_len + 15) / 16 * 16
	f.store_buffer("DSHP".to_ascii_buffer())
	f.store_32(1)            # version
	f.store_32(TILE_RES)
	f.store_32(NSIDE_MIN)
	f.store_32(NSIDE_MAX)
	f.store_32(0)            # flags
	f.store_32(blob_start)
	f.store_32(manifest.size())
	f.store_buffer(manifest)
	for _i in blob_start - raw_len:
		f.store_8(0)
	for nside in _levels:
		for ipix in 12 * nside * nside:
			var v := _tile_value(nside, ipix)
			for _px in TILE_RES * TILE_RES:
				f.store_float(v)
	f.close()


func before_all() -> void:
	_levels = []
	var ns := NSIDE_MIN
	while ns <= NSIDE_MAX:
		_levels.append(ns)
		ns *= 2
	_write_pack()


func after_all() -> void:
	DirAccess.remove_absolute(PACK_PATH)
	DirAccess.remove_absolute(PACK_DIR)


# ===================================================================
# 1. HeightPack reader
# ===================================================================


func test_open_parses_header_and_manifest() -> void:
	var pack := HeightPackScript.new()
	assert_true(pack.open(PACK_PATH), "pack should open")
	assert_true(pack.is_open())
	var mani := pack.get_manifest()
	assert_eq(str(mani.get("planet_name")), "testpack")
	assert_eq(int(mani.get("tile_res")), TILE_RES)
	pack.close()
	assert_false(pack.is_open())


func test_open_rejects_bad_magic() -> void:
	var bad_path := PACK_DIR + "/bad.pack"
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_buffer("NOPE".to_ascii_buffer())
	f.store_32(1)
	f.close()
	var pack := HeightPackScript.new()
	assert_false(pack.open(bad_path), "bad magic must be rejected")
	DirAccess.remove_absolute(bad_path)


func test_read_tile_every_level() -> void:
	var pack := HeightPackScript.new()
	assert_true(pack.open(PACK_PATH))
	# First / middle / last tile of every level. Levels ≤ PRELOAD_MAX_NSIDE
	# hit the preloaded buffer; n32 goes through the per-thread FileAccess.
	for nside in _levels:
		var npix := 12 * nside * nside
		@warning_ignore("integer_division")
		var picks: Array[int] = [0, npix / 2, npix - 1]
		for ipix in picks:
			var buf := pack.read_tile(nside, ipix)
			assert_eq(buf.size(), TILE_RES * TILE_RES * 4,
					"tile n%d/f%d size" % [nside, ipix])
			var floats := buf.to_float32_array()
			for v in floats:
				assert_almost_eq(v, _tile_value(nside, ipix), 0.001,
						"tile n%d/f%d content" % [nside, ipix])
	pack.close()


func test_read_tile_out_of_range() -> void:
	var pack := HeightPackScript.new()
	assert_true(pack.open(PACK_PATH))
	assert_eq(pack.read_tile(3, 0).size(), 0, "nside not a baked level")
	assert_eq(pack.read_tile(64, 0).size(), 0, "nside above nside_max")
	assert_eq(pack.read_tile(1, 12).size(), 0, "ipix past end of level")
	assert_eq(pack.read_tile(1, -1).size(), 0, "negative ipix")
	pack.close()


func test_concurrent_reads_from_threads() -> void:
	var pack := HeightPackScript.new()
	assert_true(pack.open(PACK_PATH))
	# 4 threads × 64 reads on the fine (non-preloaded) level. Per-thread
	# handles mean no shared file position — every read must be exact.
	var threads: Array[Thread] = []
	var results: Array = []
	results.resize(4)
	for t in 4:
		var th := Thread.new()
		threads.append(th)
		th.start(func():
			var errors := 0
			for i in 64:
				var ipix := (t * 3000 + i * 47) % (12 * 32 * 32)
				var buf := pack.read_tile(32, ipix)
				if buf.size() != TILE_RES * TILE_RES * 4 \
						or not is_equal_approx(
							buf.to_float32_array()[0], _tile_value(32, ipix)):
					errors += 1
			return errors)
	var total_errors := 0
	for t in 4:
		total_errors += threads[t].wait_to_finish()
	assert_eq(total_errors, 0, "all threaded reads exact")
	pack.close()


# ===================================================================
# 2. PlanetData integration
# ===================================================================


func test_planet_data_reads_from_pack() -> void:
	var pd := PlanetData.new()
	pd.chunk_heightmaps_dir = PACK_DIR
	# No loose manifest.json in PACK_DIR → must fall back to the manifest
	# embedded in heights.pack.
	assert_true(pd.apply_chunk_manifest(), "manifest applied from pack")
	assert_eq(pd.export_nside, NSIDE_MAX)
	assert_eq(pd.export_nside_min, NSIDE_MIN)
	assert_eq(pd.chunk_heightmap_res, TILE_RES)
	assert_true(pd.chunk_is_pyramid)
	# Coarse (preloaded) and fine (file-handle) tiles decode to FORMAT_RF
	# images carrying the exact marker values.
	for nside: int in [NSIDE_MIN, NSIDE_MAX]:
		var ipix := 12 * nside * nside - 1
		var img := pd.load_chunk_heightmap(ipix, nside)
		assert_not_null(img, "image for n%d/f%d" % [nside, ipix])
		if img == null:
			continue
		assert_eq(img.get_format(), Image.FORMAT_RF)
		assert_eq(img.get_width(), TILE_RES)
		assert_almost_eq(img.get_pixel(0, 0).r, _tile_value(nside, ipix),
				0.001, "decoded height n%d/f%d" % [nside, ipix])


func test_planet_data_missing_tile_dir_falls_back_to_null() -> void:
	var pd := PlanetData.new()
	pd.chunk_heightmaps_dir = "user://does_not_exist_chunks"
	assert_false(pd.apply_chunk_manifest(), "no pack, no manifest → false")
	assert_null(pd.load_chunk_heightmap(0, 1), "no source → null")
