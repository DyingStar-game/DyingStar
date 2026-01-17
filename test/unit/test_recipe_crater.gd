extends GutTest
## GUT test suite for crater heightmap generation.
##
## Verifies that ChunkRecipeGenerator correctly bakes crater
## depressions into the heightmap image, and that PlanetData
## denormalizes them to negative height values.
##
## Run with:
##   $GODOT --headless -s addons/gut/gut_cmdln.gd \
##     -gdir=res://test/unit -gtest=test_recipe_crater.gd

const TARSIS_RECIPE_DIR := "res://assets/qgis/.export/tarsis_5_1_chunks/"
const NSIDE := 64
const PLANET_RADIUS := 850667.0
const MAX_HEIGHT := 1000.0
const HEIGHT_OFFSET := 0.0
const RESOLUTION := 32  # small for fast testing


# ── Helpers ────────────────────────────────────────────────────────

## Build a minimal synthetic recipe with a single crater at the pixel center.
func _make_synthetic_recipe(hp_nside: int, hp_ipix: int,
		crater_radius_m: float, crater_depth_m: float) -> Dictionary:
	var center_dir := HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	var lonlat := _dir_to_lonlat(center_dir)
	return {
		"version": 7,
		"key": "hp_n%d_p%d" % [hp_nside, hp_ipix],
		"nside": hp_nside,
		"ipix": hp_ipix,
		"elevation": {
			"contour_vertices": [],
			"base_elevation": 0.0,
			"interpolation": "idw",
			"idw_power": 2,
			"idw_k": 8,
			"grid_elevations": [],
			"grid_inner_n": 0,
		},
		"terrain_modifiers": [],
		"populate_zones": [],
		"noise": {},
		"craters": [
			{
				"lon": lonlat.x,
				"lat": lonlat.y,
				"radius_m": crater_radius_m,
				"depth_m": crater_depth_m,
			}
		],
		"linear_features": [],
		"radial_features": [],
	}


## Load a recipe file from the tarsis_5_1 export.
func _load_real_recipe(ipix: int) -> Dictionary:
	var key := "hp_n%d_p%d" % [NSIDE, ipix]
	var base_face := ipix / (NSIDE * NSIDE)
	var path := TARSIS_RECIPE_DIR + "base_%d/%s.recipe.json" % [base_face, key]
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	return json.data


func _dir_to_lonlat(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var lon := rad_to_deg(atan2(d.z, d.x))
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	return Vector2(lon, lat)


# ===================================================================
# 1. Synthetic recipe: single crater at pixel center
# ===================================================================

func test_synthetic_crater_center_is_depressed() -> void:
	## A single large crater placed exactly at the pixel center should
	## produce a negative normalized value at the center pixel of the
	## generated heightmap.
	var ipix := 26965  # equatorial belt, face 6
	var crater_r := 5000.0  # 5 km radius — large enough for any resolution
	var crater_d := 500.0   # 500 m depth

	var recipe := _make_synthetic_recipe(NSIDE, ipix, crater_r, crater_d)
	var result := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

	assert_eq(result.size(), 2, "generate_heightmap should return [Image, subpixel_craters]")
	var img: Image = result[0]
	assert_not_null(img, "Heightmap image should not be null")
	assert_eq(img.get_width(), RESOLUTION)
	assert_eq(img.get_height(), RESOLUTION)
	assert_eq(img.get_format(), Image.FORMAT_RF, "Image should be FORMAT_RF")

	# Sample the center pixel — should show crater depression
	var cx := RESOLUTION / 2
	var cy := RESOLUTION / 2
	var center_val := img.get_pixel(cx, cy).r
	gut.p("Center pixel normalized value: %.6f" % center_val)
	gut.p("Denormalized height: %.2f m" % (center_val * MAX_HEIGHT + HEIGHT_OFFSET))

	# Crater center should push height negative, so normalized < 0
	assert_lt(center_val, 0.0,
		"Center pixel should be negative (crater depression). Got: %.6f" % center_val)

	# The depression should be close to -depth_m / max_height = -0.5
	# (exact value depends on pixel position vs crater center)
	assert_lt(center_val, -0.3,
		"Center pixel should be significantly depressed. Got: %.6f" % center_val)


func test_synthetic_crater_rim_is_elevated() -> void:
	## Pixels at the crater rim should have a slight positive offset
	## (rim uplift = depth * 0.04 = 20 m for depth=500 m).
	var ipix := 26965
	var crater_r := 5000.0
	var crater_d := 500.0

	var recipe := _make_synthetic_recipe(NSIDE, ipix, crater_r, crater_d)
	var result := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

	var img: Image = result[0]
	assert_not_null(img)

	# Check multiple pixels — at least some should be positive (rim)
	# and some should be negative (bowl)
	var has_negative := false
	var has_positive := false
	var min_val := 999.0
	var max_val := -999.0
	for y in RESOLUTION:
		for x in RESOLUTION:
			var v := img.get_pixel(x, y).r
			if v < min_val:
				min_val = v
			if v > max_val:
				max_val = v
			if v < -0.01:
				has_negative = true
			if v > 0.001:
				has_positive = true

	gut.p("Heightmap range: min=%.6f max=%.6f" % [min_val, max_val])
	gut.p("Min denormalized: %.2f m  Max denormalized: %.2f m" % [
		min_val * MAX_HEIGHT + HEIGHT_OFFSET,
		max_val * MAX_HEIGHT + HEIGHT_OFFSET])
	assert_true(has_negative, "Should have negative pixels (crater bowl)")
	assert_true(has_positive, "Should have positive pixels (crater rim uplift)")


func test_synthetic_crater_edge_is_zero() -> void:
	## Pixels far from the crater (outside rim_outer) should be at
	## base elevation (normalized ≈ 0.0 since base_elev=0, height_offset=0).
	var ipix := 26965
	# Use a small crater so that most of the chunk is unaffected
	var crater_r := 500.0   # 500 m radius
	var crater_d := 200.0

	var recipe := _make_synthetic_recipe(NSIDE, ipix, crater_r, crater_d)
	var result := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

	var img: Image = result[0]
	assert_not_null(img)

	# Corner pixels should be unaffected (far from center crater)
	var corner_val := img.get_pixel(0, 0).r
	gut.p("Corner pixel (0,0) normalized: %.6f" % corner_val)
	assert_almost_eq(corner_val, 0.0, 0.01,
		"Corner pixel should be near zero (unaffected by small crater)")


# ===================================================================
# 2. Real recipe from tarsis_5_1
# ===================================================================

func test_real_recipe_has_crater_depression() -> void:
	## The real tarsis_5_1 recipe for pixel 26965 has 638 craters.
	## The generated heightmap should contain negative values.
	var recipe := _load_real_recipe(26965)
	if recipe.is_empty():
		pending("Recipe file for tarsis_5_1 ipix=26965 not found — skipping")
		return

	var craters: Array = recipe.get("craters", [])
	gut.p("Recipe has %d craters" % craters.size())
	assert_gt(craters.size(), 0, "Recipe should have craters")

	var result := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

	var img: Image = result[0]
	assert_not_null(img, "Real recipe heightmap should not be null")

	# Scan for min/max and negative values
	var min_val := 999.0
	var max_val := -999.0
	var negative_count := 0
	var positive_count := 0
	for y in RESOLUTION:
		for x in RESOLUTION:
			var v := img.get_pixel(x, y).r
			if v < min_val:
				min_val = v
			if v > max_val:
				max_val = v
			if v < -0.001:
				negative_count += 1
			if v > 0.001:
				positive_count += 1

	gut.p("Real heightmap range: min=%.6f max=%.6f" % [min_val, max_val])
	gut.p("Min denormalized: %.2f m  Max denormalized: %.2f m" % [
		min_val * MAX_HEIGHT + HEIGHT_OFFSET,
		max_val * MAX_HEIGHT + HEIGHT_OFFSET])
	gut.p("Negative pixels: %d / %d" % [negative_count, RESOLUTION * RESOLUTION])
	gut.p("Positive pixels: %d / %d" % [positive_count, RESOLUTION * RESOLUTION])

	assert_true(min_val < 0.0,
		"Real recipe should produce negative heightmap values (craters). Min=%.6f" % min_val)


# ===================================================================
# 3. Denormalization round-trip
# ===================================================================

func test_denormalization_preserves_negative_height() -> void:
	## Verify that the normalization→denormalization round-trip
	## preserves negative heights (crater bowls).
	var height_m := -500.0  # crater center at -500 m
	var normalized := (height_m - HEIGHT_OFFSET) / MAX_HEIGHT  # (-500 - 0) / 1000 = -0.5
	var denorm := normalized * MAX_HEIGHT + HEIGHT_OFFSET       # -0.5 * 1000 + 0 = -500

	gut.p("height=%.1f → normalized=%.6f → denormalized=%.1f" % [height_m, normalized, denorm])
	assert_almost_eq(denorm, height_m, 0.01,
		"Round-trip should preserve the original height")
	assert_lt(normalized, 0.0, "Normalized should be negative")
	assert_lt(denorm, 0.0, "Denormalized should be negative")


# ===================================================================
# 4. Subpixel vs baked crater split
# ===================================================================

func test_subpixel_craters_are_small() -> void:
	## generate_heightmap should return sub-pixel craters as the second
	## element — these are craters too small to resolve in the heightmap.
	var ipix := 26965

	# One large crater (should be baked) + one tiny crater (should be subpixel)
	var center_dir := HEALPix.pix2vec_nest(NSIDE, ipix)
	var lonlat := _dir_to_lonlat(center_dir)
	var recipe := {
		"version": 7,
		"key": "test",
		"nside": NSIDE,
		"ipix": ipix,
		"elevation": {
			"contour_vertices": [],
			"base_elevation": 0.0,
			"interpolation": "idw",
			"idw_power": 2,
			"idw_k": 8,
			"grid_elevations": [],
			"grid_inner_n": 0,
		},
		"terrain_modifiers": [],
		"populate_zones": [],
		"noise": {},
		"craters": [
			{ "lon": lonlat.x, "lat": lonlat.y, "radius_m": 5000.0, "depth_m": 500.0 },
			{ "lon": lonlat.x + 0.01, "lat": lonlat.y, "radius_m": 5.0, "depth_m": 2.0 },
		],
		"linear_features": [],
		"radial_features": [],
	}

	var result := ChunkRecipeGenerator.generate_heightmap(
		recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

	assert_eq(result.size(), 2)
	var subpixel: Array = result[1]
	gut.p("Subpixel craters returned: %d" % subpixel.size())

	# The tiny 5m-radius crater should be in subpixel list
	assert_eq(subpixel.size(), 1,
		"One crater (5m radius) should be sub-pixel at this resolution")
	if subpixel.size() > 0:
		assert_almost_eq(float(subpixel[0]["radius_m"]), 5.0, 0.1)


# ===================================================================
# 5. Duplicate craters in recipe
# ===================================================================

func test_real_recipe_duplicate_craters() -> void:
	## Check if the real recipe has duplicate craters (same lon/lat/radius).
	## Duplicates cause double-depth crater application.
	var recipe := _load_real_recipe(26965)
	if recipe.is_empty():
		pending("Recipe file not found — skipping")
		return

	var craters: Array = recipe.get("craters", [])
	var seen := {}
	var duplicates := 0
	for cr in craters:
		var key := "%.6f_%.6f_%.1f" % [float(cr["lon"]), float(cr["lat"]), float(cr["radius_m"])]
		if seen.has(key):
			duplicates += 1
		else:
			seen[key] = true

	gut.p("Total craters: %d, Unique: %d, Duplicates: %d" % [
		craters.size(), seen.size(), duplicates])

	if duplicates > 0:
		gut.p("WARNING: Recipe has %d duplicate craters — depth will be doubled!" % duplicates)

	# This is informational — flag it but don't fail the test
	# since the fix is in the export pipeline, not the generator.
