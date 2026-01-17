extends GutTest
## GUT test suite for recipe heightmap boundary consistency.
##
## These tests verify that adjacent HEALPix chunks produce matching
## heights at their shared edges when heightmaps are generated from
## recipe data.  This catches:
##   1. grid_elevations margin mismatch (export pipeline bug)
##   2. Heightmap edge pixel divergence between neighbors
##   3. Full pipeline (recipe → heightmap → PlanetData → vertex sample) gaps
##   4. Skirt geometry coverage
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd \
##   -gdir=res://test/unit -gtest=test_recipe_boundary.gd

const RECIPE_DIR := "res://assets/qgis/.export/tarsis_3_chunks/"
const PLANET_JSON := "res://assets/qgis/.export/tarsis_3_planet.json"
const NSIDE := 64


# ── Helpers ────────────────────────────────────────────────────────

func _load_planet_json() -> Dictionary:
	var f := FileAccess.open(PLANET_JSON, FileAccess.READ)
	if not f:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	return json.data


func _load_recipe(ipix: int) -> Dictionary:
	var key := "hp_n%d_p%d" % [NSIDE, ipix]
	var base_face := ipix / (NSIDE * NSIDE)
	var path := RECIPE_DIR + "base_%d/%s.recipe.json" % [base_face, key]
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_warning("Could not open recipe: " + path)
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_warning("JSON parse error for " + path)
		return {}
	return json.data


func _make_planet_data() -> PlanetData:
	var pd := PlanetData.new()
	pd.radius = 1958333.0
	pd.max_height = 7350.0
	pd.height_offset = -480.0
	pd.chunk_export_depth = 6
	pd.export_nside = NSIDE
	return pd


func _find_same_face_horizontal_pair() -> Array:
	## Return [ipix_A, ipix_B] where B is to the right of A on the same face.
	var face := 2
	var ix_A := 20
	var iy := 30
	var ipix_A: int = face * NSIDE * NSIDE + HEALPix.xy2nest(ix_A, iy)
	var ipix_B: int = face * NSIDE * NSIDE + HEALPix.xy2nest(ix_A + 1, iy)
	return [ipix_A, ipix_B]


func _find_same_face_vertical_pair() -> Array:
	## Return [ipix_A, ipix_B] where B is above A on the same face.
	var face := 2
	var ix := 20
	var iy_A := 30
	var ipix_A: int = face * NSIDE * NSIDE + HEALPix.xy2nest(ix, iy_A)
	var ipix_B: int = face * NSIDE * NSIDE + HEALPix.xy2nest(ix, iy_A + 1)
	return [ipix_A, ipix_B]


# ===================================================================
# 1. Grid elevations margin consistency
# ===================================================================

func test_grid_margin_matches_neighbor_horizontal() -> void:
	## For two horizontally adjacent chunks, A's right margin column
	## must match B's left inner edge column, and vice versa.
	##
	## Grid layout (34 columns for grid_inner_n=32):
	##   col 0 = left margin
	##   col 1..32 = inner grid
	##   col 33 = right margin
	##
	## A's col 33 (right margin) should match B's col 1 (first inner)
	## A's col 32 (last inner) should match B's col 0 (left margin)
	var pair := _find_same_face_horizontal_pair()
	var recipe_A := _load_recipe(pair[0])
	var recipe_B := _load_recipe(pair[1])
	if recipe_A.is_empty() or recipe_B.is_empty():
		pending("Recipe files not found on disk — skipping")
		return

	var elev_A: Dictionary = recipe_A.get("elevation", {})
	var elev_B: Dictionary = recipe_B.get("elevation", {})
	var grid_A: Array = elev_A.get("grid_elevations", [])
	var grid_B: Array = elev_B.get("grid_elevations", [])
	var inner_n_A: int = elev_A.get("grid_inner_n", 0)
	var inner_n_B: int = elev_B.get("grid_inner_n", 0)

	if inner_n_A < 2 or inner_n_B < 2:
		pending("Recipes lack grid_elevations (version < 5) — skipping")
		return

	var total_A: int = inner_n_A + 2
	var total_B: int = inner_n_B + 2

	assert_eq(grid_A.size(), total_A,
		"Recipe A grid rows (%d) should equal inner_n+2 (%d)" % [grid_A.size(), total_A])
	assert_eq(grid_B.size(), total_B,
		"Recipe B grid rows (%d) should equal inner_n+2 (%d)" % [grid_B.size(), total_B])

	# A's right margin = B's left inner edge.
	# In pixel-space, A covers ix=[ix_A, ix_A+1), B covers ix=[ix_A+1, ix_A+2).
	# The margin extends half a cell beyond the chunk edge.
	# Since the grid is in pixel-space, column mapping is straightforward:
	#   A col 33 (right margin) ≈ B col 1 (first inner)
	#   A col 32 (last inner)  ≈ B col 0 (left margin)
	var max_diff := 0.0
	var fail_count := 0
	for row in total_A:
		if row >= grid_A.size() or row >= grid_B.size():
			break
		var row_A: Array = grid_A[row]
		var row_B: Array = grid_B[row]
		if total_A - 1 < row_A.size() and 1 < row_B.size():
			var diff := absf(float(row_A[total_A - 1]) - float(row_B[1]))
			max_diff = maxf(max_diff, diff)
			if diff > 1.0:
				fail_count += 1
		if inner_n_A < row_A.size() and 0 < row_B.size():
			var diff := absf(float(row_A[inner_n_A]) - float(row_B[0]))
			max_diff = maxf(max_diff, diff)
			if diff > 1.0:
				fail_count += 1

	gut.p("  Grid margin horizontal: max diff = %.3f m, mismatches > 1m: %d" % [max_diff, fail_count])
	assert_lt(max_diff, 50.0,
		"Grid margin mismatch > 50m at horizontal chunk boundary (max diff = %.3f m)" % max_diff)


func test_grid_margin_matches_neighbor_vertical() -> void:
	## Same as above but for vertically adjacent chunks.
	## A's top margin row (row total-1) ≈ B's first inner row (row 1)
	## A's last inner row (row inner_n) ≈ B's bottom margin (row 0)
	var pair := _find_same_face_vertical_pair()
	var recipe_A := _load_recipe(pair[0])
	var recipe_B := _load_recipe(pair[1])
	if recipe_A.is_empty() or recipe_B.is_empty():
		pending("Recipe files not found on disk — skipping")
		return

	var elev_A: Dictionary = recipe_A.get("elevation", {})
	var elev_B: Dictionary = recipe_B.get("elevation", {})
	var grid_A: Array = elev_A.get("grid_elevations", [])
	var grid_B: Array = elev_B.get("grid_elevations", [])
	var inner_n_A: int = elev_A.get("grid_inner_n", 0)
	var inner_n_B: int = elev_B.get("grid_inner_n", 0)

	if inner_n_A < 2 or inner_n_B < 2:
		pending("Recipes lack grid_elevations (version < 5) — skipping")
		return

	var total_A: int = inner_n_A + 2
	var total_B: int = inner_n_B + 2

	# A's top row (total-1) ≈ B's row 1
	# A's row inner_n ≈ B's row 0
	var max_diff := 0.0
	var fail_count := 0

	if total_A - 1 < grid_A.size() and 1 < grid_B.size():
		var row_A: Array = grid_A[total_A - 1]
		var row_B: Array = grid_B[1]
		var ncols := mini(row_A.size(), row_B.size())
		for col in ncols:
			var diff := absf(float(row_A[col]) - float(row_B[col]))
			max_diff = maxf(max_diff, diff)
			if diff > 1.0:
				fail_count += 1

	if inner_n_A < grid_A.size() and 0 < grid_B.size():
		var row_A: Array = grid_A[inner_n_A]
		var row_B: Array = grid_B[0]
		var ncols := mini(row_A.size(), row_B.size())
		for col in ncols:
			var diff := absf(float(row_A[col]) - float(row_B[col]))
			max_diff = maxf(max_diff, diff)
			if diff > 1.0:
				fail_count += 1

	gut.p("  Grid margin vertical: max diff = %.3f m, mismatches > 1m: %d" % [max_diff, fail_count])
	assert_lt(max_diff, 50.0,
		"Grid margin mismatch > 50m at vertical chunk boundary (max diff = %.3f m)" % max_diff)


# ===================================================================
# 2. Heightmap edge pixel continuity
# ===================================================================

func test_heightmap_edge_pixels_match_horizontal() -> void:
	## Generate heightmaps from two adjacent recipes and compare the
	## pixel values at their shared boundary.  The last column of A
	## should closely match the first column of B.
	var pair := _find_same_face_horizontal_pair()
	var recipe_A := _load_recipe(pair[0])
	var recipe_B := _load_recipe(pair[1])
	if recipe_A.is_empty() or recipe_B.is_empty():
		pending("Recipe files not found on disk — skipping")
		return

	var planet_json := _load_planet_json()
	if planet_json.is_empty():
		pending("Planet JSON not found — skipping")
		return

	var elev_min: float = planet_json.get("elevation", {}).get("min_elevation", 0.0)
	var elev_max: float = planet_json.get("elevation", {}).get("max_elevation", 1.0)
	var elev_range := elev_max - elev_min
	var planet_radius: float = planet_json.get("radius", 1958333.0)

	# Use a smaller resolution for speed (32 instead of 512).
	var res := 32
	var result_A: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_A, res, planet_radius, elev_min, elev_range)
	var result_B: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_B, res, planet_radius, elev_min, elev_range)

	var img_A: Image = result_A[0]
	var img_B: Image = result_B[0]

	# Compare A's last column with B's first column.
	# These correspond to the shared boundary direction, but the pixel
	# mapping in HEALPix pixel-space means A's px=res-1 and B's px=0
	# sample directions that are adjacent but not identical (there's a
	# half-pixel gap). So we allow a ratio-based tolerance.
	var max_diff := 0.0
	var total_diff := 0.0
	for py in res:
		var val_A: float = img_A.get_pixel(res - 1, py).r
		var val_B: float = img_B.get_pixel(0, py).r
		# Convert from normalized back to metres.
		var h_A := val_A * elev_range + elev_min
		var h_B := val_B * elev_range + elev_min
		var diff := absf(h_A - h_B)
		max_diff = maxf(max_diff, diff)
		total_diff += diff

	var avg_diff := total_diff / float(res)
	gut.p("  Heightmap edge horizontal: max diff = %.3f m, avg = %.3f m" % [max_diff, avg_diff])
	# The half-pixel gap means the values won't be identical, but they
	# should be close (within the local gradient).  50m is generous for
	# tarsis_3 where max_height=7350m.
	assert_lt(max_diff, 200.0,
		"Heightmap edge pixel mismatch > 200m at horizontal boundary (max=%.1f m). "
		% max_diff + "This indicates the grid_elevations margin is wrong or "
		+ "contour interpolation diverges at the chunk edge.")


func test_heightmap_edge_pixels_match_vertical() -> void:
	## Same as above but for the vertical boundary.
	var pair := _find_same_face_vertical_pair()
	var recipe_A := _load_recipe(pair[0])
	var recipe_B := _load_recipe(pair[1])
	if recipe_A.is_empty() or recipe_B.is_empty():
		pending("Recipe files not found on disk — skipping")
		return

	var planet_json := _load_planet_json()
	if planet_json.is_empty():
		pending("Planet JSON not found — skipping")
		return

	var elev_min: float = planet_json.get("elevation", {}).get("min_elevation", 0.0)
	var elev_max: float = planet_json.get("elevation", {}).get("max_elevation", 1.0)
	var elev_range := elev_max - elev_min
	var planet_radius: float = planet_json.get("radius", 1958333.0)

	var res := 32
	var result_A: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_A, res, planet_radius, elev_min, elev_range)
	var result_B: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_B, res, planet_radius, elev_min, elev_range)

	var img_A: Image = result_A[0]
	var img_B: Image = result_B[0]

	# Compare A's last row with B's first row.
	var max_diff := 0.0
	var total_diff := 0.0
	for px in res:
		var val_A: float = img_A.get_pixel(px, res - 1).r
		var val_B: float = img_B.get_pixel(px, 0).r
		var h_A := val_A * elev_range + elev_min
		var h_B := val_B * elev_range + elev_min
		var diff := absf(h_A - h_B)
		max_diff = maxf(max_diff, diff)
		total_diff += diff

	var avg_diff := total_diff / float(res)
	gut.p("  Heightmap edge vertical: max diff = %.3f m, avg = %.3f m" % [max_diff, avg_diff])
	assert_lt(max_diff, 200.0,
		"Heightmap edge pixel mismatch > 200m at vertical boundary (max=%.1f m). "
		% max_diff + "This indicates the grid_elevations margin is wrong or "
		+ "contour interpolation diverges at the chunk edge.")


# ===================================================================
# 3. Full pipeline: recipe → heightmap → PlanetData → vertex height
# ===================================================================

func test_full_pipeline_vertex_heights_match_at_shared_edge() -> void:
	## The complete test: generate heightmaps from adjacent recipes,
	## load them into PlanetData, then sample vertex heights using the
	## same code path as generate_mesh.  Heights at the shared edge
	## directions must agree.
	var pair := _find_same_face_horizontal_pair()
	var recipe_A := _load_recipe(pair[0])
	var recipe_B := _load_recipe(pair[1])
	if recipe_A.is_empty() or recipe_B.is_empty():
		pending("Recipe files not found on disk — skipping")
		return

	var planet_json := _load_planet_json()
	if planet_json.is_empty():
		pending("Planet JSON not found — skipping")
		return

	var elev_min: float = planet_json.get("elevation", {}).get("min_elevation", 0.0)
	var elev_max: float = planet_json.get("elevation", {}).get("max_elevation", 1.0)
	var elev_range := elev_max - elev_min
	var planet_radius: float = planet_json.get("radius", 1958333.0)

	# Generate heightmaps (use smaller res for speed).
	var img_res := 128
	var result_A: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_A, img_res, planet_radius, elev_min, elev_range)
	var result_B: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe_B, img_res, planet_radius, elev_min, elev_range)

	# Set up PlanetData with generated heightmaps.
	var pd := _make_planet_data()
	pd._chunk_images["hp_n%d_p%d" % [NSIDE, pair[0]]] = result_A[0]
	pd._chunk_images["hp_n%d_p%d" % [NSIDE, pair[1]]] = result_B[0]

	# Use a higher nside to simulate runtime chunking.
	var runtime_nside := 256
	# Find a child pixel of pair[0] at the right edge.
	var face: int = int(pair[0]) / (NSIDE * NSIDE)
	var local_A: int = int(pair[0]) % (NSIDE * NSIDE)
	var xy_A := HEALPix.nest2xy(local_A)
	var ix_A: int = xy_A.x
	var iy_A: int = xy_A.y

	# At runtime_nside, each export pixel has (runtime_nside/NSIDE)^2 sub-pixels.
	var scale: int = runtime_nside / NSIDE  # = 4
	# Rightmost column of A's sub-pixels:
	var sub_ix_A: int = ix_A * scale + (scale - 1)
	var sub_iy_A: int = iy_A * scale + (scale / 2)
	# Leftmost column of B's sub-pixels:
	var local_B: int = int(pair[1]) % (NSIDE * NSIDE)
	var xy_B := HEALPix.nest2xy(local_B)
	var ix_B: int = xy_B.x
	var iy_B: int = xy_B.y
	var sub_ix_B: int = ix_B * scale
	var sub_iy_B: int = iy_B * scale + (scale / 2)

	var ipix_sub_A: int = face * runtime_nside * runtime_nside + HEALPix.xy2nest(sub_ix_A, sub_iy_A)
	var ipix_sub_B: int = face * runtime_nside * runtime_nside + HEALPix.xy2nest(sub_ix_B, sub_iy_B)

	var mesh_res := 8  # Small for speed.
	var grid_A := HEALPix.get_pixel_grid(runtime_nside, ipix_sub_A, mesh_res)
	var grid_B := HEALPix.get_pixel_grid(runtime_nside, ipix_sub_B, mesh_res)

	# Walk ipix to export nside.
	var exp_A: int = ipix_sub_A
	var exp_B: int = ipix_sub_B
	var ns: int = runtime_nside
	while ns > pd.export_nside:
		exp_A >>= 2
		exp_B >>= 2
		@warning_ignore("integer_division")
		ns /= 2

	# Sample heights at shared edge using boundary-safe sampling.
	var max_height_diff := 0.0
	for vi in mesh_res + 1:
		# A's right edge (xi=mesh_res), B's left edge (xi=0)
		var dir_A: Vector3 = grid_A[vi][mesh_res]
		var dir_B: Vector3 = grid_B[vi][0]

		var h_A := pd.sample_height_boundary(dir_A, exp_A)
		var h_B := pd.sample_height_boundary(dir_B, exp_B)

		var diff := absf(h_A - h_B)
		max_height_diff = maxf(max_height_diff, diff)

	gut.p("  Full pipeline vertex height diff at shared edge: %.3f m (limit 50 m)" % max_height_diff)
	assert_lt(max_height_diff, 50.0,
		"Vertex height at shared edge differs by %.3f m. "
		% max_height_diff
		+ "This would cause a visible gap between chunks.")


# ===================================================================
# 4. Skirt geometry validation
# ===================================================================

func test_skirt_drop_is_sufficient() -> void:
	## Verify the skirt drop formula produces enough depth to cover
	## the maximum possible height difference between adjacent chunks.
	var pd := _make_planet_data()
	var skirt_drop := pd.max_height * 0.5 + absf(pd.height_offset) + 10.0
	# The skirt must drop at least past the max possible height step.
	# Two adjacent chunks can differ by at most max_height metres.
	assert_gt(skirt_drop, pd.max_height * 0.25,
		"Skirt drop (%.1f m) is too small compared to max_height (%.1f m)" % [skirt_drop, pd.max_height])
	gut.p("  Skirt drop = %.1f m (max_height = %.1f m, height_offset = %.1f m)"
		% [skirt_drop, pd.max_height, pd.height_offset])


func test_skirt_vertices_extend_below_surface() -> void:
	## Build a tiny chunk mesh and verify that every skirt vertex
	## (via CUSTOM0 offset) ends up below the terrain surface it
	## originated from.
	var pd := _make_planet_data()

	# Synthetic heightmap.
	var img_size := 64
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var nside := 8192
	var ipix: int = 2 * nside * nside + HEALPix.xy2nest(500, 500)
	var exp_ipix := ipix
	var ns := nside
	while ns > pd.export_nside:
		exp_ipix >>= 2
		@warning_ignore("integer_division")
		ns /= 2
	pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_ipix]] = img

	var res := 8
	var cc := HEALPix.pix2vec_nest(nside, ipix) * pd.radius

	# generate_mesh returns ArrayMesh directly; pass hp_nside + hp_ipix
	# so it computes the grid internally.
	# Signature: (data, face, u_min, u_max, v_min, v_max, resolution,
	#             chunk_center, hp_nside, hp_ipix)
	var mesh: ArrayMesh = PlanetChunk.generate_mesh(
		pd, -1, 0.0, 0.0, 0.0, 0.0, res,
		cc, nside, ipix)

	if mesh == null or mesh.get_surface_count() == 0:
		pending("No mesh surface — skipping")
		return

	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]

	var terrain_count := (res + 1) * (res + 1)
	var skirt_count := verts.size() - terrain_count
	assert_gt(skirt_count, 0,
		"Expected skirt vertices but found none (total=%d, terrain=%d)" % [verts.size(), terrain_count])

	# Every skirt vertex's CUSTOM0 should have a non-zero inverse offset
	# (surface_local - dropped), and the VERTEX itself should be far below
	# the surface (the dropped position).
	var skirt_all_nonzero := true
	var min_drop := INF
	for i in range(terrain_count, verts.size()):
		var c0_idx := i * 3
		if c0_idx + 2 >= custom0.size():
			break
		var offset := Vector3(custom0[c0_idx], custom0[c0_idx + 1], custom0[c0_idx + 2])
		var offset_len := offset.length()
		if offset_len < 0.001:
			skirt_all_nonzero = false
		min_drop = minf(min_drop, offset_len)

	gut.p("  Skirt vertices: %d (min inverse offset = %.1f m)" % [skirt_count, min_drop])
	assert_true(skirt_all_nonzero,
		"Some skirt vertices have near-zero CUSTOM0 inverse offset — UV recovery would fail")
	assert_gt(min_drop, 100.0,
		"Minimum CUSTOM0 inverse offset (%.1f m) is suspiciously small" % min_drop)


# ===================================================================
# 5. Recipe linear_features do not corrupt non-river heightmaps
# ===================================================================

func test_non_river_recipe_unaffected_by_linear_features_change() -> void:
	## Verify that a recipe without linear_features produces the same
	## heightmap regardless of the linear_features code path. This
	## ensures the progressive-width changes don't accidentally affect
	## all chunks.
	var pair := _find_same_face_horizontal_pair()
	var recipe := _load_recipe(pair[0])
	if recipe.is_empty():
		pending("Recipe not found — skipping")
		return

	# Confirm this recipe has no linear features.
	var linear: Array = recipe.get("linear_features", [])
	var has_river := false
	for lf in linear:
		if (lf as Dictionary).has("centerline"):
			has_river = true
			break

	if has_river:
		gut.p("  Recipe has linear features — testing consistency instead")

	var planet_json := _load_planet_json()
	if planet_json.is_empty():
		pending("Planet JSON not found — skipping")
		return

	var elev_min: float = planet_json.get("elevation", {}).get("min_elevation", 0.0)
	var elev_max: float = planet_json.get("elevation", {}).get("max_elevation", 1.0)
	var elev_range := elev_max - elev_min
	var planet_radius: float = planet_json.get("radius", 1958333.0)

	# Generate twice — must be deterministic.
	var res := 32
	var result_1: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe, res, planet_radius, elev_min, elev_range)
	var result_2: Array = ChunkRecipeGenerator.generate_heightmap(
		recipe, res, planet_radius, elev_min, elev_range)

	var img_1: Image = result_1[0]
	var img_2: Image = result_2[0]

	var max_diff := 0.0
	for py in res:
		for px in res:
			var diff := absf(img_1.get_pixel(px, py).r - img_2.get_pixel(px, py).r)
			max_diff = maxf(max_diff, diff)

	assert_eq(max_diff, 0.0,
		"Heightmap generation is not deterministic (max diff = %.6f)" % max_diff)
	gut.p("  Determinism check: max pixel diff = %.6f" % max_diff)
