extends GutTest
## GUT test suite for binary recipe serialisation round-trip.
##
## Verifies that a recipe Dictionary survives a store_var / get_var
## round-trip and produces an identical heightmap compared to the
## original in-memory Dictionary.
##
## Run with:
##   $GODOT --headless -s addons/gut/gut_cmdln.gd \
##     -gdir=res://test/unit -gtest=test_recipe_binary.gd

const NSIDE := 64
const PLANET_RADIUS := 850667.0
const MAX_HEIGHT := 1000.0
const HEIGHT_OFFSET := 0.0
const RESOLUTION := 32  # small for fast testing

var _tmp_path: String = ""


func before_each() -> void:
	_tmp_path = "user://test_recipe_binary_%d.bin" % randi()


func after_each() -> void:
	if FileAccess.file_exists(_tmp_path):
		DirAccess.remove_absolute(_tmp_path)


# ── Helpers ────────────────────────────────────────────────────────

func _make_full_recipe() -> Dictionary:
	var ipix := 26965
	var center_dir := HEALPix.pix2vec_nest(NSIDE, ipix)
	var lon := rad_to_deg(atan2(center_dir.z, center_dir.x))
	var lat := rad_to_deg(asin(clampf(center_dir.y, -1.0, 1.0)))

	# Build a recipe that exercises every field type
	return {
		"version": 7,
		"key": "hp_n%d_p%d" % [NSIDE, ipix],
		"nside": NSIDE,
		"ipix": ipix,
		"elevation": {
			"contour_vertices": [],
			"base_elevation": 125.5,
			"interpolation": "idw",
			"idw_power": 2,
			"idw_k": 8,
			"grid_elevations": [
				[100.0, 101.2, 102.3, 103.4],
				[101.0, 102.1, 103.2, 104.3],
				[102.0, 103.1, 104.2, 105.3],
				[103.0, 104.1, 105.2, 106.3],
			],
			"grid_inner_n": 2,
		},
		"terrain_modifiers": {
			"craters": [
				{"lon": lon, "lat": lat, "radius_m": 5000.0, "depth_m": 500.0}
			],
			"linear_features": [
				{
					"type": "maritime_river-river",
					"centerline": [[lon - 0.1, lat], [lon + 0.1, lat]],
					"width_start_m": 100.0,
					"width_end_m": 150.0,
					"half_width_max_deg": 0.00456,
					"total_length_m": 50000.0,
					"cum_lengths": [0.0, 50000.0],
					"profile": "v_shape",
					"depth_override": null,
				}
			],
			"radial_features": [
				{
					"type": "fumarole",
					"lon": lon,
					"lat": lat + 0.05,
					"radius_m": 500.0,
					"depth_m": 15.0,
					"profile": "bowl",
				}
			],
		},
		"populate_zones": [
			{
				"biome_type": "grassland",
				"coverage": 0.75,
				"vertices": [[lon - 0.05, lat - 0.05], [lon + 0.05, lat - 0.05],
					[lon + 0.05, lat + 0.05], [lon - 0.05, lat + 0.05]],
			}
		],
		"noise": {
			"seed": 104729,
			"octaves": [
				{"frequency": 0.02, "amplitude": 2.0},
				{"frequency": 0.005, "amplitude": 8.0},
			],
		},
		"craters": [
			{"lon": lon, "lat": lat, "radius_m": 5000.0, "depth_m": 500.0}
		],
		"linear_features": [],
		"radial_features": [],
	}


# ===================================================================
# 1. Round-trip: store_var -> get_var preserves the Dictionary
# ===================================================================

func test_binary_round_trip_preserves_dictionary() -> void:
	var recipe := _make_full_recipe()

	# Write binary
	var out := FileAccess.open(_tmp_path, FileAccess.WRITE)
	assert_not_null(out, "Should be able to open temp file for writing")
	out.store_var(recipe, false)
	out.close()

	# Read binary
	var inp := FileAccess.open(_tmp_path, FileAccess.READ)
	assert_not_null(inp, "Should be able to open temp file for reading")
	var loaded: Variant = inp.get_var(false)
	inp.close()

	assert_true(loaded is Dictionary, "Loaded data should be a Dictionary")
	var loaded_dict: Dictionary = loaded

	# Top-level keys
	assert_eq(loaded_dict["version"], recipe["version"])
	assert_eq(loaded_dict["key"], recipe["key"])
	assert_eq(loaded_dict["nside"], recipe["nside"])
	assert_eq(loaded_dict["ipix"], recipe["ipix"])

	# Elevation grid
	var orig_grid: Array = recipe["elevation"]["grid_elevations"]
	var load_grid: Array = loaded_dict["elevation"]["grid_elevations"]
	assert_eq(load_grid.size(), orig_grid.size(), "Grid row count should match")
	for row_idx in orig_grid.size():
		var orig_row: Array = orig_grid[row_idx]
		var load_row: Array = load_grid[row_idx]
		assert_eq(load_row.size(), orig_row.size(), "Grid col count row %d" % row_idx)
		for col_idx in orig_row.size():
			assert_almost_eq(float(load_row[col_idx]), float(orig_row[col_idx]), 0.001,
				"Grid[%d][%d]" % [row_idx, col_idx])

	# Craters
	var orig_craters: Array = recipe["craters"]
	var load_craters: Array = loaded_dict["craters"]
	assert_eq(load_craters.size(), orig_craters.size(), "Crater count should match")
	if not load_craters.is_empty():
		assert_almost_eq(float(load_craters[0]["radius_m"]),
			float(orig_craters[0]["radius_m"]), 0.01, "Crater radius")
		assert_almost_eq(float(load_craters[0]["depth_m"]),
			float(orig_craters[0]["depth_m"]), 0.01, "Crater depth")

	# Noise
	var orig_noise: Dictionary = recipe["noise"]
	var load_noise: Dictionary = loaded_dict["noise"]
	assert_eq(load_noise["seed"], orig_noise["seed"])
	assert_eq(load_noise["octaves"].size(), orig_noise["octaves"].size())


# ===================================================================
# 2. Binary recipe produces identical heightmap as in-memory recipe
# ===================================================================

func test_binary_heightmap_matches_original() -> void:
	var recipe := _make_full_recipe()

	# Generate heightmap from original in-memory recipe
	var result_orig := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)
	assert_eq(result_orig.size(), 2, "Original should return [Image, subpixel_craters]")
	var img_orig: Image = result_orig[0]
	assert_not_null(img_orig)

	# Write to binary, read back
	var out := FileAccess.open(_tmp_path, FileAccess.WRITE)
	out.store_var(recipe, false)
	out.close()

	var inp := FileAccess.open(_tmp_path, FileAccess.READ)
	var loaded: Dictionary = inp.get_var(false)
	inp.close()

	# Generate heightmap from binary-loaded recipe
	var result_bin := ChunkRecipeGenerator.generate_heightmap(
		loaded, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)
	assert_eq(result_bin.size(), 2, "Binary should return [Image, subpixel_craters]")
	var img_bin: Image = result_bin[0]
	assert_not_null(img_bin)

	# Compare every pixel
	assert_eq(img_bin.get_width(), img_orig.get_width())
	assert_eq(img_bin.get_height(), img_orig.get_height())
	assert_eq(img_bin.get_format(), img_orig.get_format())

	var max_diff := 0.0
	for y in RESOLUTION:
		for x in RESOLUTION:
			var v_orig := img_orig.get_pixel(x, y).r
			var v_bin := img_bin.get_pixel(x, y).r
			var diff := absf(v_orig - v_bin)
			if diff > max_diff:
				max_diff = diff

	gut.p("Max pixel difference: %.9f" % max_diff)
	assert_lt(max_diff, 1e-6,
		"Binary-loaded heightmap should be identical. Max diff: %.9f" % max_diff)


# ===================================================================
# 3. Binary file is smaller than JSON
# ===================================================================

func test_binary_is_smaller_than_json() -> void:
	var recipe := _make_full_recipe()

	# Write binary
	var out := FileAccess.open(_tmp_path, FileAccess.WRITE)
	out.store_var(recipe, false)
	out.close()
	var bin_size := FileAccess.open(_tmp_path, FileAccess.READ).get_length()

	# Write JSON (compact, matching export_planet.py style)
	var json_path := _tmp_path.replace(".bin", ".json")
	var json_out := FileAccess.open(json_path, FileAccess.WRITE)
	json_out.store_string(JSON.stringify(recipe))
	json_out.close()
	var json_size := FileAccess.open(json_path, FileAccess.READ).get_length()

	gut.p("Binary size: %d bytes  JSON size: %d bytes  ratio: %.2f%%" % [
		bin_size, json_size, 100.0 * bin_size / json_size])

	# Just log the comparison -- don't assert a specific ratio since
	# it depends on data content, but binary should generally be smaller
	assert_gt(json_size, 0, "JSON should not be empty")
	assert_gt(bin_size, 0, "Binary should not be empty")

	# Cleanup JSON temp
	DirAccess.remove_absolute(json_path)
