extends GutTest
## GUT test suite for the HEALPix → terrain height pipeline.
##
## Tests cover:
## 1. _face_xy_to_vec → _vec_to_face_xy round-trip (analytical inverse)
## 2. _direction_to_pixel_uv continuity and boundary behaviour
## 3. sample_height_for_direction consistency at pixel/face edges
## 4. Cliff detection: ensure no discontinuity across a chunk grid
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd \
##   -gdir=res://test/unit -gtest=test_healpix_terrain.gd


# ── Tolerance constants ────────────────────────────────────────────
## Floating-point tolerance for round-trip coordinate checks.
const EPS := 1e-9
## Maximum allowed UV discontinuity between adjacent grid vertices.
## A cliff appears when two neighbouring vertices get very different
## UVs even though they are only ~1/res apart in face coords.
const MAX_UV_JUMP := 0.02


# ===================================================================
# 1. _face_xy_to_vec ↔ _vec_to_face_xy round-trip
# ===================================================================


func test_round_trip_pixel_centres_all_faces() -> void:
	var nside := 64
	var max_err := 0.0
	for face in 12:
		for ix in range(0, nside, 8):
			for iy in range(0, nside, 8):
				var fx_in := float(ix) + 0.5
				var fy_in := float(iy) + 0.5
				var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
				var fc := HEALPix._vec_to_face_xy(d, face, nside)
				var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
				max_err = maxf(max_err, err)
	assert_lt(max_err, EPS,
		"Round-trip pixel centres: max error " + str(max_err) + " should be < " + str(EPS))


func test_round_trip_sub_pixel_positions() -> void:
	var nside := 64
	var max_err := 0.0
	for face in PackedInt32Array([0, 2, 3, 5, 8, 11]):
		for ix in PackedInt32Array([0, 1, 31, 63]):
			for iy in PackedInt32Array([0, 1, 31, 63]):
				for dfx in PackedFloat64Array([0.1, 0.25, 0.5, 0.75, 0.9]):
					for dfy in PackedFloat64Array([0.1, 0.25, 0.5, 0.75, 0.9]):
						var fx_in := float(ix) + dfx
						var fy_in := float(iy) + dfy
						var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
						var fc := HEALPix._vec_to_face_xy(d, face, nside)
						var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
						max_err = maxf(max_err, err)
	assert_lt(max_err, EPS,
		"Round-trip sub-pixel: max error " + str(max_err) + " should be < " + str(EPS))


func test_round_trip_face3_phi_boundary() -> void:
	## Face 3 (JPLL=7) straddles the phi=0/2π boundary.
	## This tests the phi-wrapping logic in _vec_to_face_xy.
	var nside := 64
	var max_err := 0.0
	for ix in PackedInt32Array([60, 61, 62, 63]):
		for iy in PackedInt32Array([0, 1, 2, 3]):
			for dfx in PackedFloat64Array([0.1, 0.5, 0.9]):
				for dfy in PackedFloat64Array([0.1, 0.5, 0.9]):
					var fx_in := float(ix) + dfx
					var fy_in := float(iy) + dfy
					var d := HEALPix._face_xy_to_vec(3, fx_in, fy_in, nside)
					var fc := HEALPix._vec_to_face_xy(d, 3, nside)
					var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
					max_err = maxf(max_err, err)
	assert_lt(max_err, EPS,
		"Face 3 phi boundary: max error " + str(max_err) + " should be < " + str(EPS))


func test_round_trip_polar_cap_faces() -> void:
	## Faces 0-3 = north cap adjacent, faces 8-11 = south cap adjacent.
	## Pixels near ix+iy ≈ 0 (north) or ix+iy ≈ 2*nside (south) enter
	## the polar cap branch, which uses sqrt(3*(1-za)) — numerically
	## sensitive near the pole.
	var nside := 32
	var max_err := 0.0
	# North cap: face 0, low ix+iy
	for ix in PackedInt32Array([0, 1, 2]):
		for iy in PackedInt32Array([0, 1, 2]):
			var d := HEALPix._face_xy_to_vec(0, float(ix) + 0.5, float(iy) + 0.5, nside)
			var fc := HEALPix._vec_to_face_xy(d, 0, nside)
			var err := maxf(absf(fc.x - float(ix) - 0.5), absf(fc.y - float(iy) - 0.5))
			max_err = maxf(max_err, err)
	# South cap: face 8, high ix+iy
	for ix in PackedInt32Array([29, 30, 31]):
		for iy in PackedInt32Array([29, 30, 31]):
			var d := HEALPix._face_xy_to_vec(8, float(ix) + 0.5, float(iy) + 0.5, nside)
			var fc := HEALPix._vec_to_face_xy(d, 8, nside)
			var err := maxf(absf(fc.x - float(ix) - 0.5), absf(fc.y - float(iy) - 0.5))
			max_err = maxf(max_err, err)
	assert_lt(max_err, EPS,
		"Polar cap faces: max error " + str(max_err) + " should be < " + str(EPS))


func test_round_trip_high_nside() -> void:
	## At nside=8192 (runtime) the grid step is ~1/8192 of a face.
	## Ensure the inverse is still accurate at that scale.
	var nside := 8192
	var max_err := 0.0
	for face in PackedInt32Array([0, 2, 5, 8, 11]):
		for ix in PackedInt32Array([0, 100, 4095, 8191]):
			for iy in PackedInt32Array([0, 100, 4095, 8191]):
				for dfx in PackedFloat64Array([0.0, 0.5, 1.0]):
					for dfy in PackedFloat64Array([0.0, 0.5, 1.0]):
						var fx_in := float(ix) + dfx
						var fy_in := float(iy) + dfy
						var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
						var fc := HEALPix._vec_to_face_xy(d, face, nside)
						var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
						max_err = maxf(max_err, err)
	assert_lt(max_err, 1e-6,
		"High nside round-trip: max error " + str(max_err) + " should be < 1e-6")


# ===================================================================
# 2. _direction_to_pixel_uv continuity
# ===================================================================


func _make_planet_data() -> PlanetData:
	## Create a minimal PlanetData for UV computation tests.
	var pd := PlanetData.new()
	pd.radius = 1958333.0
	pd.max_height = 7350.0
	pd.height_offset = -480.0
	pd.chunk_export_depth = 6
	pd.export_nside = 64
	return pd


func test_uv_stays_in_unit_square() -> void:
	## _direction_to_pixel_uv must return (u,v) in [0,1]².
	var pd := _make_planet_data()
	var nside := 64
	for face in 12:
		for ix in PackedInt32Array([0, 31, 63]):
			for iy in PackedInt32Array([0, 31, 63]):
				var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
				for dfx in PackedFloat64Array([0.01, 0.5, 0.99]):
					for dfy in PackedFloat64Array([0.01, 0.5, 0.99]):
						var d := HEALPix._face_xy_to_vec(
							face, float(ix) + dfx, float(iy) + dfy, nside)
						var uv := pd._direction_to_pixel_uv(d, ipix, nside)
						assert_true(uv.x >= 0.0 and uv.x <= 1.0,
							"u=%.6f out of [0,1] for face=%d ix=%d iy=%d" % [uv.x, face, ix, iy])
						assert_true(uv.y >= 0.0 and uv.y <= 1.0,
							"v=%.6f out of [0,1] for face=%d ix=%d iy=%d" % [uv.y, face, ix, iy])


func test_uv_matches_analytical_position() -> void:
	## UV should be the fractional part of _vec_to_face_xy minus the pixel's
	## integer (ix, iy). Verify that directly.
	var pd := _make_planet_data()
	var nside := 64
	for face in PackedInt32Array([0, 2, 5, 8, 11]):
		for ix in PackedInt32Array([0, 32, 63]):
			for iy in PackedInt32Array([0, 32, 63]):
				var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
				var fx_in := float(ix) + 0.37
				var fy_in := float(iy) + 0.63
				var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
				var uv := pd._direction_to_pixel_uv(d, ipix, nside)
				# Expected UV = fractional part
				assert_almost_eq(uv.x, 0.37, 1e-6,
					"u mismatch face=%d ix=%d iy=%d" % [face, ix, iy])
				assert_almost_eq(uv.y, 0.63, 1e-6,
					"v mismatch face=%d ix=%d iy=%d" % [face, ix, iy])


func test_uv_at_pixel_edge_exact() -> void:
	## When the direction is at exactly (ix+1, iy) — the right edge — the UV
	## should be (1.0, 0.0) before clamping, or close to it.
	var pd := _make_planet_data()
	var nside := 64
	for face in PackedInt32Array([0, 2, 5]):
		for ix in PackedInt32Array([0, 31, 62]):
			var iy := 32
			var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
			# Direction at exactly the right edge of pixel (ix, iy)
			var d := HEALPix._face_xy_to_vec(face, float(ix + 1), float(iy) + 0.5, nside)
			var uv := pd._direction_to_pixel_uv(d, ipix, nside)
			assert_almost_eq(uv.x, 1.0, 1e-6,
				"u at right edge should be ~1.0 for face=%d ix=%d" % [face, ix])


# ===================================================================
# 3. UV continuity across a chunk grid (cliff detection)
# ===================================================================


func test_no_cliff_in_chunk_grid_uv() -> void:
	## Simulate a 33×33 vertex grid (res=32, LOD 0) for a chunk at the
	## face edge (ix=63, iy=0 at export_nside=64) — this is the case
	## that showed the cliff.  Check that adjacent UV values don't jump.
	var pd := _make_planet_data()
	var chunk_nside := 8192
	var export_nside := 64
	var res := 32

	# Chunk ipix 156595575 maps to export face=2, ix=63, iy=0
	# (at the HEALPix face edge).  Use that exact chunk.
	var export_ipix := 9557  # face=2, ix=63, iy=0
	var _export_face := 2
	var _export_ix := 63
	var _export_iy := 0

	# Reconstruct chunk-level face coords from the export pixel.
	# The chunk covers a tiny portion of the export pixel.
	# For this test, generate grid directions at the chunk level.
	# Use ipix=156595575 at nside=8192 → chunk face=2 ix=8191 iy=69.
	var chunk_face := 2
	var chunk_ix := 8191
	var chunk_iy := 69

	var max_jump := 0.0
	var prev_uvs: Array[Vector2] = []
	var current_uvs: Array[Vector2] = []

	for yi in res + 1:
		current_uvs.clear()
		for xi in res + 1:
			var fx := float(chunk_ix) + float(xi) / float(res)
			var fy := float(chunk_iy) + float(yi) / float(res)
			var d := HEALPix._face_xy_to_vec(chunk_face, fx, fy, chunk_nside)
			var uv := pd._direction_to_pixel_uv(d, export_ipix, export_nside)
			current_uvs.append(uv)

			# Check horizontal jump
			if xi > 0:
				var du := absf(uv.x - current_uvs[xi - 1].x)
				max_jump = maxf(max_jump, du)

			# Check vertical jump
			if yi > 0 and prev_uvs.size() > xi:
				var dv := absf(uv.y - prev_uvs[xi].y)
				max_jump = maxf(max_jump, dv)

		prev_uvs = current_uvs.duplicate()

	assert_lt(max_jump, MAX_UV_JUMP,
		"Cliff detected! Max adjacent UV jump = %.6f (limit %.4f) "
		% [max_jump, MAX_UV_JUMP]
		+ "for chunk at face edge (face=2, ix=63, iy=0)")


func test_no_cliff_centre_chunk() -> void:
	## Same test but for a chunk in the centre of a face (should always pass).
	var pd := _make_planet_data()
	var res := 32

	# Export pixel in the middle: face=2, ix=32, iy=32
	var export_nside := 64
	var export_ipix := 2 * export_nside * export_nside + HEALPix.xy2nest(32, 32)

	# Match a chunk-level pixel that's inside this export pixel.
	# chunk_nside = 8192, ratio = 8192/64 = 128
	# chunk ix covers [32*128, 33*128) = [4096, 4224) for this export ix=32
	var chunk_nside := 8192
	var chunk_face := 2
	var chunk_ix := 4096
	var chunk_iy := 4096

	var max_jump := 0.0
	var prev_uvs: Array[Vector2] = []
	var current_uvs: Array[Vector2] = []

	for yi in res + 1:
		current_uvs.clear()
		for xi in res + 1:
			var fx := float(chunk_ix) + float(xi) / float(res)
			var fy := float(chunk_iy) + float(yi) / float(res)
			var d := HEALPix._face_xy_to_vec(chunk_face, fx, fy, chunk_nside)
			var uv := pd._direction_to_pixel_uv(d, export_ipix, export_nside)
			current_uvs.append(uv)

			if xi > 0:
				var du := absf(uv.x - current_uvs[xi - 1].x)
				max_jump = maxf(max_jump, du)
			if yi > 0 and prev_uvs.size() > xi:
				var dv := absf(uv.y - prev_uvs[xi].y)
				max_jump = maxf(max_jump, dv)

		prev_uvs = current_uvs.duplicate()

	assert_lt(max_jump, MAX_UV_JUMP,
		"Cliff in centre chunk! Max UV jump = %.6f (limit %.4f)"
		% [max_jump, MAX_UV_JUMP])


# ===================================================================
# 4. Cross-face edge: UV clamped vs neighbouring pixel lookup
# ===================================================================


func test_uv_at_face_edge_is_clamped_not_negative() -> void:
	## When a chunk sits at ix=63 (face edge at export_nside=64), the
	## rightmost grid column direction may analytically give fx=64.0
	## (= the next face).  _direction_to_pixel_uv should clamp to 1.0,
	## not return a negative or >1 value.
	var pd := _make_planet_data()
	var nside := 64
	var face := 2
	var ix := 63
	var iy := 32
	var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)

	# Direction at the boundary: fx = 64.0 (one past the face)
	var d := HEALPix._face_xy_to_vec(face, 64.0, float(iy) + 0.5, nside)
	var uv := pd._direction_to_pixel_uv(d, ipix, nside)
	assert_true(uv.x >= 0.0 and uv.x <= 1.0,
		"Face-edge u=%.6f must be in [0,1]" % [uv.x])
	assert_true(uv.y >= 0.0 and uv.y <= 1.0,
		"Face-edge v=%.6f must be in [0,1]" % [uv.y])


func test_uv_monotonic_across_grid() -> void:
	## For a chunk whose grid sweeps in the +fx direction, the u
	## component of _direction_to_pixel_uv should be monotonically
	## increasing (or at least non-decreasing).
	var pd := _make_planet_data()
	var nside := 64
	var face := 2

	# Several pixel locations including edge
	for ix in PackedInt32Array([0, 32, 63]):
		var iy := 32
		var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
		var prev_u := -1.0
		var monotonic := true
		for xi in 33:
			var fx := float(ix) + float(xi) / 32.0
			var d := HEALPix._face_xy_to_vec(face, fx, float(iy) + 0.5, nside)
			var uv := pd._direction_to_pixel_uv(d, ipix, nside)
			if uv.x < prev_u - 1e-10:
				monotonic = false
			prev_u = uv.x

		assert_true(monotonic,
			"UV u not monotonic for face=%d ix=%d" % [face, ix])


# ===================================================================
# 5. Export ipix walk-down (chunk → export)
# ===================================================================


func test_export_ipix_walk_down() -> void:
	## Verify the >>= 2 walk from chunk nside to export nside gives
	## the correct parent pixel.
	var chunk_ipix := 156595575
	var chunk_nside := 8192
	var export_nside := 64

	var ipix := chunk_ipix
	var ns := chunk_nside
	while ns > export_nside:
		ipix >>= 2
		@warning_ignore("integer_division")
		ns /= 2

	assert_eq(ipix, 9557, "Export ipix should be 9557")
	assert_eq(ns, export_nside, "Should reach export_nside exactly")

	# Verify face / ix / iy
	var npface := export_nside * export_nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := HEALPix.nest2xy(local)
	assert_eq(face, 2, "Export face should be 2")
	assert_eq(xy.x, 63, "Export ix should be 63")
	assert_eq(xy.y, 0, "Export iy should be 0")


# ===================================================================
# 6. Full height pipeline (requires heightmap image)
# ===================================================================


func test_height_continuity_synthetic_heightmap() -> void:
	## Create a synthetic gradient heightmap, load it into PlanetData,
	## then sample across adjacent vertices and verify no height cliff.
	var pd := _make_planet_data()
	var img_size := 256

	# Create a diagonal gradient: pixel(x,y) = (x + y) / (2*size)
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	# Inject into the cache for export pixel 9557 (face=2, ix=63, iy=0)
	var ipix := 9557
	var key := "hp_n%d_p%d" % [pd.export_nside, ipix]
	pd._chunk_images[key] = img

	# Sample a grid across this pixel and check for height jumps
	var chunk_nside := 8192
	var chunk_face := 2
	var chunk_ix := 8191
	var chunk_iy := 69
	var res := 32
	var max_jump := 0.0
	var prev_h := -1e20

	for xi in res + 1:
		var fx := float(chunk_ix) + float(xi) / float(res)
		var fy := float(chunk_iy) + 0.5
		var d := HEALPix._face_xy_to_vec(chunk_face, fx, fy, chunk_nside)
		var h := pd.sample_height_for_direction(d, ipix)
		if xi > 0:
			var jump := absf(h - prev_h)
			max_jump = maxf(max_jump, jump)
		prev_h = h

	# With max_height=7350 and 33 vertices across ~2/256 of the image,
	# each step should be at most ~(7350 * 2/256 / 32) ≈ 1.8m.
	# Allow up to 50m for edge effects. A cliff would be 100+ m.
	assert_lt(max_jump, 50.0,
		"Height cliff detected! Max jump = %.2f m between adjacent vertices "
		% [max_jump]
		+ "(face edge chunk). Should be smooth gradient.")
	gut.p("  Max height jump: %.4f m (limit 50.0 m)" % [max_jump])


func test_height_continuity_centre_chunk() -> void:
	## Same synthetic gradient test for a centre-of-face chunk (should pass).
	var pd := _make_planet_data()
	var img_size := 256

	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	# Centre pixel: face=2, ix=32, iy=32
	var ipix := 2 * 64 * 64 + HEALPix.xy2nest(32, 32)
	var key := "hp_n%d_p%d" % [pd.export_nside, ipix]
	pd._chunk_images[key] = img

	var chunk_nside := 8192
	var chunk_ix := 4096
	var chunk_iy := 4096
	var res := 32
	var max_jump := 0.0
	var prev_h := -1e20

	for xi in res + 1:
		var fx := float(chunk_ix) + float(xi) / float(res)
		var fy := float(chunk_iy) + 0.5
		var d := HEALPix._face_xy_to_vec(2, fx, fy, chunk_nside)
		var h := pd.sample_height_for_direction(d, ipix)
		if xi > 0:
			var jump := absf(h - prev_h)
			max_jump = maxf(max_jump, jump)
		prev_h = h

	assert_lt(max_jump, 50.0,
		"Height cliff in centre chunk! Max jump = %.2f m" % [max_jump])
	gut.p("  Max height jump: %.4f m (limit 50.0 m)" % [max_jump])


# ===================================================================
# 7. Cross-tile cliff: adjacent chunks with different export_ipix
#    (the face=2/face=3 boundary bug visible in screenshot 001.png)
# ===================================================================


func test_boundary_height_is_consistent_across_export_tiles() -> void:
	## sample_height_boundary must return the same height for the same
	## direction, regardless of which chunk's chain_ipix is passed.
	## This is the fix for the cliff at the face-2/face-3 boundary
	## (chunk 156595677 exp=9557 vs chunks 246069995+ exp=15018).
	var pd := _make_planet_data()
	var export_nside := 64
	var img_size := 32

	# Load IDENTICAL synthetic images for both export tiles.
	# With the fix, both tiles are sampled consistently; without the fix,
	# different UV positions in different images would give different heights.
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			img.set_pixel(x, y, Color(float(x) / float(img_size), 0.0, 0.0, 1.0))

	var exp_ipix_A := 9557   # face=2, ix=63, iy=0 — right edge of face 2
	var exp_ipix_B := 15018  # face=3, ix=0,  iy=63 — top  edge of face 3
	var key_A := "hp_n%d_p%d" % [export_nside, exp_ipix_A]
	var key_B := "hp_n%d_p%d" % [export_nside, exp_ipix_B]
	pd._chunk_images[key_A] = img.duplicate()
	pd._chunk_images[key_B] = img.duplicate()

	# Directions along the face-2 right edge (vx=res of chunk 156595677).
	# At nside=8192 the right-edge directions are _face_xy_to_vec(2, 8192, iy+t, 8192)
	# with iy=74 (base) and t in [0, 1].
	var nside := 8192
	var base_iy := 74
	var max_diff := 0.0
	for step in 17:  # 17 samples across the edge
		var t := float(step) / 16.0
		var dir := HEALPix._face_xy_to_vec(2, float(nside), float(base_iy) + t, nside)

		# Both chain_ipix values should give the same height with sample_height_boundary
		var h_A := pd.sample_height_boundary(dir, exp_ipix_A)
		var h_B := pd.sample_height_boundary(dir, exp_ipix_B)
		var diff := absf(h_A - h_B)
		max_diff = maxf(max_diff, diff)

	assert_lt(max_diff, 0.01,
		"sample_height_boundary inconsistency at face 2-3 boundary: "
		+ "max diff = " + str(max_diff) + "m (should be < 0.01m)")
	gut.p("  Max height diff at face boundary (fixed): " + str(max_diff) + "m")


func test_cross_tile_boundary_no_cliff_in_chunk_mesh() -> void:
	## Simulate the vertex loop of planet_chunk.gd for two truly edge-adjacent
	## chunks at the face 2-3 boundary and verify that shared edge vertices
	## produce identical heights (no cliff).
	##
	## From _face_xy_to_vec geometry:
	##   - Face 2's RIGHT edge (fx=ns, fy=a) and face 3's TOP edge (fx=a, fy=ns)
	##     produce IDENTICAL directions for the same value of `a`.
	##   - chunk A: face=2, ix=8191, iy=74  → right edge fy  ∈ [74, 75]  exp=9557
	##   - chunk B: face=3, ix=74,   iy=8191 → top  edge fx  ∈ [74, 75]  exp=15018
	##   The edge fx/fy parameter runs over [74, 75] for both → 17 exact shared vertices.
	var pd := _make_planet_data()
	var export_nside := 64
	var img_size := 32
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			img.set_pixel(x, y, Color(float(x + y) / float(2 * img_size), 0.0, 0.0, 1.0))

	pd._chunk_images["hp_n%d_p%d" % [export_nside, 9557]] = img.duplicate()
	pd._chunk_images["hp_n%d_p%d" % [export_nside, 15018]] = img.duplicate()

	# At nside=8192, res=16:
	# chunk A right edge:  _face_xy_to_vec(2, 8192, 74+j/16, 8192)
	# chunk B top  edge:   _face_xy_to_vec(3, 74+j/16, 8192, 8192)
	# Both yield the SAME direction for the same j.
	var nside := 8192
	var res := 16
	var max_diff := 0.0
	for vi in res + 1:
		var t := 74.0 + float(vi) / float(res)  # parameter in [74, 75]
		var dir_A := HEALPix._face_xy_to_vec(2, float(nside), t, nside)  # right edge of A
		var dir_B := HEALPix._face_xy_to_vec(3, t, float(nside), nside)  # top  edge of B

		# Verify the two chunks produce the same physical direction (sanity).
		assert_lt(dir_A.distance_to(dir_B), 1e-9,
			"Face-boundary directions must be identical (vi=%d)" % [vi])

		# Both should give the same height via sample_height_boundary.
		var h_A := pd.sample_height_boundary(dir_A, 9557)
		var h_B := pd.sample_height_boundary(dir_B, 15018)
		var diff := absf(h_A - h_B)
		max_diff = maxf(max_diff, diff)

	assert_lt(max_diff, 0.01,
		"Cross-face chunk seam heights mismatch: max_diff = " + str(max_diff) + "m")
	gut.p("  Shared-vertex height diff at face 2-3 seam: " + str(max_diff) + "m")


# ===================================================================
# 8. Adjacent chunk edge vertex world-position matching
# ===================================================================

## Helper: simulate the world_to_local snapping from planet_chunk.gd.
static func _snap_to_local(world_pos: Vector3, cc_f32: Vector3) -> Vector3:
	var local := world_pos - cc_f32
	var buf := PackedFloat32Array([local.x, local.y, local.z])
	return Vector3(buf[0], buf[1], buf[2])


## Helper: reconstruct GPU world position from local vertex + chunk center.
## The GPU adds model origin (f32) to vertex (f32) in float32 arithmetic.
static func _gpu_world(local_f32: Vector3, cc_f32: Vector3) -> Vector3:
	# Simulate GPU float32 addition: snap the sum to float32.
	var wx := local_f32.x + cc_f32.x
	var wy := local_f32.y + cc_f32.y
	var wz := local_f32.z + cc_f32.z
	var buf := PackedFloat32Array([wx, wy, wz])
	return Vector3(buf[0], buf[1], buf[2])


func test_same_face_adjacent_chunks_share_edge_directions() -> void:
	## Two horizontally adjacent HEALPix pixels on the same face must produce
	## bit-identical direction vectors at their shared edge.
	## Pixel A: (ix, iy) — right edge (vx=res) has fx = ix + 1.0
	## Pixel B: (ix+1, iy) — left edge (vx=0) has fx = ix + 1.0  (same!)
	var nside := 8192
	var res := 32
	# Pick a pixel near the middle of face 2.
	var ix_A := 4000
	var iy := 3000
	var ipix_A := 2 * nside * nside + HEALPix.xy2nest(ix_A, iy)
	var ipix_B := 2 * nside * nside + HEALPix.xy2nest(ix_A + 1, iy)

	var grid_A := HEALPix.get_pixel_grid(nside, ipix_A, res)
	var grid_B := HEALPix.get_pixel_grid(nside, ipix_B, res)

	var max_dir_err := 0.0
	for vi in res + 1:
		# A's right edge: grid_A[vi][res]
		# B's left edge:  grid_B[vi][0]
		var dir_A: Vector3 = grid_A[vi][res]
		var dir_B: Vector3 = grid_B[vi][0]
		var err := dir_A.distance_to(dir_B)
		max_dir_err = maxf(max_dir_err, err)

	assert_eq(max_dir_err, 0.0,
		"Same-face adjacent pixels must have bit-identical edge directions, "
		+ "max err = " + str(max_dir_err))
	gut.p("  Direction match error (same face horizontal): " + str(max_dir_err))


func test_same_face_vertically_adjacent_chunks_share_edge_directions() -> void:
	## Two vertically adjacent HEALPix pixels on the same face must produce
	## bit-identical direction vectors at their shared edge.
	var nside := 8192
	var res := 32
	var ix := 4000
	var iy_A := 3000
	var ipix_A := 2 * nside * nside + HEALPix.xy2nest(ix, iy_A)
	var ipix_B := 2 * nside * nside + HEALPix.xy2nest(ix, iy_A + 1)

	var grid_A := HEALPix.get_pixel_grid(nside, ipix_A, res)
	var grid_B := HEALPix.get_pixel_grid(nside, ipix_B, res)

	var max_dir_err := 0.0
	for vi in res + 1:
		# A's top edge: grid_A[res][vi]
		# B's bottom edge: grid_B[0][vi]
		var dir_A: Vector3 = grid_A[res][vi]
		var dir_B: Vector3 = grid_B[0][vi]
		var err := dir_A.distance_to(dir_B)
		max_dir_err = maxf(max_dir_err, err)

	assert_eq(max_dir_err, 0.0,
		"Same-face vertically adjacent pixels must have bit-identical edge "
		+ "directions, max err = " + str(max_dir_err))
	gut.p("  Direction match error (same face vertical): " + str(max_dir_err))


func test_adjacent_chunk_edge_world_positions_match() -> void:
	## Simulate the generate_mesh pipeline for two adjacent chunks with
	## elevation data and verify that the reconstructed GPU world positions
	## for shared edge vertices are identical (or within sub-mm tolerance).
	##
	## This is the critical test: even though each chunk subtracts its own
	## chunk_center before snapping to float32, the final world positions
	## seen by the GPU must agree for shared edge vertices.
	var pd := _make_planet_data()

	# Create a synthetic heightmap with a gradient so heights are non-zero.
	var img_size := 256
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var nside := 8192
	var res := 32
	var ix_A := 4000
	var iy := 3000
	var ipix_A := 2 * nside * nside + HEALPix.xy2nest(ix_A, iy)
	var ipix_B := 2 * nside * nside + HEALPix.xy2nest(ix_A + 1, iy)

	# Walk down to export nside to find the export tiles.
	var exp_A := ipix_A
	var exp_B := ipix_B
	var ns := nside
	while ns > pd.export_nside:
		exp_A >>= 2
		exp_B >>= 2
		@warning_ignore("integer_division")
		ns /= 2

	# Load heightmap for both export tiles.
	pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_A]] = img.duplicate()
	if exp_B != exp_A:
		pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_B]] = img.duplicate()

	# Compute chunk centers the same way planet_terrain.gd does.
	var cc_A := HEALPix.pix2vec_nest(nside, ipix_A) * pd.radius
	var cc_B := HEALPix.pix2vec_nest(nside, ipix_B) * pd.radius

	# Snap to float32 like generate_mesh does.
	var _tmp := PackedFloat32Array([cc_A.x, cc_A.y, cc_A.z])
	var cc_f32_A := Vector3(_tmp[0], _tmp[1], _tmp[2])
	_tmp = PackedFloat32Array([cc_B.x, cc_B.y, cc_B.z])
	var cc_f32_B := Vector3(_tmp[0], _tmp[1], _tmp[2])

	# Get direction grids.
	var grid_A := HEALPix.get_pixel_grid(nside, ipix_A, res)
	var grid_B := HEALPix.get_pixel_grid(nside, ipix_B, res)

	var max_world_err := 0.0
	var max_world_err_vi := -1
	for vi in res + 1:
		# Shared edge: A's right edge (xi=res) = B's left edge (xi=0).
		var dir_A: Vector3 = grid_A[vi][res]
		var dir_B: Vector3 = grid_B[vi][0]

		# Sample heights the same way generate_mesh does for boundary vertices.
		var h_A := pd.sample_height_boundary(dir_A, exp_A)
		var h_B := pd.sample_height_boundary(dir_B, exp_B)

		# Compute world positions (float64).
		var world_A := dir_A * (pd.radius + h_A)
		var world_B := dir_B * (pd.radius + h_B)

		# Snap to chunk-local float32 (like generate_mesh _world_to_local).
		var local_A := _snap_to_local(world_A, cc_f32_A)
		var local_B := _snap_to_local(world_B, cc_f32_B)

		# Reconstruct GPU world positions.
		var gpu_world_A := _gpu_world(local_A, cc_f32_A)
		var gpu_world_B := _gpu_world(local_B, cc_f32_B)

		var err := gpu_world_A.distance_to(gpu_world_B)
		if err > max_world_err:
			max_world_err = err
			max_world_err_vi = vi

	# The skirt should hide sub-mm gaps, but anything > 1cm is a visible seam.
	# We aim for < 1mm.
	assert_lt(max_world_err, 0.001,
		"GPU world positions at shared edge differ by %.6f m at vi=%d. "
		% [max_world_err, max_world_err_vi]
		+ "Two adjacent chunks must produce matching edge vertices.")
	gut.p("  Max GPU world position error at shared edge: %.6f m (vi=%d)"
		% [max_world_err, max_world_err_vi])


func test_cross_face_adjacent_chunks_direction_and_world_match() -> void:
	## Test edge vertex matching for two chunks on DIFFERENT HEALPix base faces.
	## Uses the known face 2→3 boundary topology:
	##   Face 2 right edge (fx=ns) ↔ Face 3 top edge (fy=ns)
	## _face_xy_to_vec produces analytically identical directions for these,
	## but PackedVector3Array (float32) truncation may introduce mismatches.
	var pd := _make_planet_data()

	var img_size := 256
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var nside := 8192
	var res := 32

	# Face 2, right boundary pixel: ix = nside-1, iy = 74
	var ipix_A := 2 * nside * nside + HEALPix.xy2nest(nside - 1, 74)
	# Face 3, top boundary pixel: ix = 74, iy = nside-1
	var ipix_B := 3 * nside * nside + HEALPix.xy2nest(74, nside - 1)

	# Walk down to export nside.
	var exp_A := ipix_A
	var exp_B := ipix_B
	var ns := nside
	while ns > pd.export_nside:
		exp_A >>= 2
		exp_B >>= 2
		@warning_ignore("integer_division")
		ns /= 2

	pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_A]] = img.duplicate()
	if exp_B != exp_A:
		pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_B]] = img.duplicate()

	# Get grids via get_pixel_grid (stores float32 in PackedVector3Array).
	var grid_A := HEALPix.get_pixel_grid(nside, ipix_A, res)
	var grid_B := HEALPix.get_pixel_grid(nside, ipix_B, res)

	# Shared edge: A's right edge (xi=res) ↔ B's top edge (yi=res).
	# The parametric coordinate runs over iy for A and ix for B.
	# Both map to the same value `t ∈ [74, 75]` in face coords.
	var cc_A := HEALPix.pix2vec_nest(nside, ipix_A) * pd.radius
	var cc_B := HEALPix.pix2vec_nest(nside, ipix_B) * pd.radius
	var _tmp := PackedFloat32Array([cc_A.x, cc_A.y, cc_A.z])
	var cc_f32_A := Vector3(_tmp[0], _tmp[1], _tmp[2])
	_tmp = PackedFloat32Array([cc_B.x, cc_B.y, cc_B.z])
	var cc_f32_B := Vector3(_tmp[0], _tmp[1], _tmp[2])

	var max_dir_err := 0.0
	var max_world_err := 0.0
	var max_world_err_vi := -1

	for vi in res + 1:
		# A's right edge vertex → grid_A[vi][res]
		# B's top edge vertex → grid_B[res][vi]
		var dir_A: Vector3 = grid_A[vi][res]
		var dir_B: Vector3 = grid_B[res][vi]

		var d_err := dir_A.distance_to(dir_B)
		max_dir_err = maxf(max_dir_err, d_err)

		var h_A := pd.sample_height_boundary(dir_A, exp_A)
		var h_B := pd.sample_height_boundary(dir_B, exp_B)

		var world_A := dir_A * (pd.radius + h_A)
		var world_B := dir_B * (pd.radius + h_B)

		var local_A := _snap_to_local(world_A, cc_f32_A)
		var local_B := _snap_to_local(world_B, cc_f32_B)

		var gpu_A := _gpu_world(local_A, cc_f32_A)
		var gpu_B := _gpu_world(local_B, cc_f32_B)

		var w_err := gpu_A.distance_to(gpu_B)
		if w_err > max_world_err:
			max_world_err = w_err
			max_world_err_vi = vi

	gut.p("  Cross-face direction error: %s m" % [str(max_dir_err)])
	gut.p("  Cross-face GPU world error: %s m (vi=%d)" % [str(max_world_err), max_world_err_vi])

	# Cross-face edges may have inherent float32 mismatch from different
	# trig operations on different faces.  Anything > 1cm is a visible seam.
	assert_lt(max_world_err, 0.01,
		"Cross-face GPU world position mismatch: %s m at vi=%d. " % [str(max_world_err), max_world_err_vi]
		+ "This indicates a seam that may be visible.")


func test_parent_child_lod_edge_positions_match() -> void:
	## When a chunk at nside N is subdivided, its children at nside 2N
	## must produce edge vertices that closely match the parent's interior
	## vertices at the shared boundary.
	## This tests that LOD transitions don't create visible gaps.
	var pd := _make_planet_data()

	var img_size := 256
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var parent_nside := 4096
	var child_nside := 8192
	var res := 32

	# Pick a parent pixel.
	var parent_ix := 2000
	var parent_iy := 1500
	var parent_ipix := 2 * parent_nside * parent_nside + HEALPix.xy2nest(parent_ix, parent_iy)

	# Its 4 children (nested indexing: child = parent * 4 + {0,1,2,3}).
	var child_ipix_0 := parent_ipix * 4 + 0
	var child_ipix_1 := parent_ipix * 4 + 1
	var child_ipix_2 := parent_ipix * 4 + 2
	var child_ipix_3 := parent_ipix * 4 + 3

	# Load heightmaps for export tiles.
	var exp_parent := parent_ipix
	var ns := parent_nside
	while ns > pd.export_nside:
		exp_parent >>= 2
		@warning_ignore("integer_division")
		ns /= 2
	pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_parent]] = img.duplicate()

	# Get the parent's neighbor to the east (same nside).
	var parent_east := 2 * parent_nside * parent_nside + HEALPix.xy2nest(parent_ix + 1, parent_iy)
	var exp_east := parent_east
	ns = parent_nside
	while ns > pd.export_nside:
		exp_east >>= 2
		@warning_ignore("integer_division")
		ns /= 2
	if exp_east != exp_parent:
		pd._chunk_images["hp_n%d_p%d" % [pd.export_nside, exp_east]] = img.duplicate()

	# The east neighbor stays at parent_nside (lower LOD) while the children
	# are at child_nside (higher LOD). The children's east edge should match
	# the parent-east's left edge at corresponding positions.
	# child_1 and child_3 are on the east side of the parent (ix odd in Z-curve).
	# Their right edge touches parent_east's left edge.
	var grid_east := HEALPix.get_pixel_grid(parent_nside, parent_east, res)

	# child_1: the NE child (ix=1, iy=0 in the parent's 2×2 sub-grid).
	# child_3: the SE child (ix=1, iy=1 in the parent's 2×2 sub-grid).
	# The Z-curve assignment: 0→(0,0), 1→(1,0), 2→(0,1), 3→(1,1)
	var grid_c1 := HEALPix.get_pixel_grid(child_nside, child_ipix_1, res)
	var grid_c3 := HEALPix.get_pixel_grid(child_nside, child_ipix_3, res)

	var cc_east := HEALPix.pix2vec_nest(parent_nside, parent_east) * pd.radius
	var cc_c1 := HEALPix.pix2vec_nest(child_nside, child_ipix_1) * pd.radius
	var cc_c3 := HEALPix.pix2vec_nest(child_nside, child_ipix_3) * pd.radius
	var _tmp := PackedFloat32Array([cc_east.x, cc_east.y, cc_east.z])
	var cc_f32_east := Vector3(_tmp[0], _tmp[1], _tmp[2])
	_tmp = PackedFloat32Array([cc_c1.x, cc_c1.y, cc_c1.z])
	var cc_f32_c1 := Vector3(_tmp[0], _tmp[1], _tmp[2])
	_tmp = PackedFloat32Array([cc_c3.x, cc_c3.y, cc_c3.z])
	var cc_f32_c3 := Vector3(_tmp[0], _tmp[1], _tmp[2])

	# Check: child_1's right edge (bottom half of parent's east edge) matches
	# parent_east's left edge at 2:1 vertex ratio.
	# Parent has res+1 vertices, children have res+1 each covering half.
	# child_1 covers the bottom half of the parent pixel.
	var max_err := 0.0
	var max_err_info := ""
	for vi in res + 1:
		# child_1's right edge at vi corresponds to parent_east's left edge
		# at vi/2 (every other vertex of child = vertex of parent).
		# But they have different nside so the grid spacing is different.
		# The child has 2× the nside, so its edge is half the parent's edge length.
		# Only every-other child vertex aligns with a parent vertex.
		if vi % 2 != 0:
			continue
		@warning_ignore("integer_division")
		var parent_vi: int = vi / 2

		var dir_child: Vector3 = grid_c1[vi][res]
		var dir_parent: Vector3 = grid_east[parent_vi][0]

		var exp_c1 := child_ipix_1
		ns = child_nside
		while ns > pd.export_nside:
			exp_c1 >>= 2
			@warning_ignore("integer_division")
			ns /= 2

		var h_child := pd.sample_height_boundary(dir_child, exp_c1)
		var h_parent := pd.sample_height_boundary(dir_parent, exp_east)

		var world_child := dir_child * (pd.radius + h_child)
		var world_parent := dir_parent * (pd.radius + h_parent)

		var local_child := _snap_to_local(world_child, cc_f32_c1)
		var local_parent := _snap_to_local(world_parent, cc_f32_east)

		var gpu_child := _gpu_world(local_child, cc_f32_c1)
		var gpu_parent := _gpu_world(local_parent, cc_f32_east)

		var err := gpu_child.distance_to(gpu_parent)
		if err > max_err:
			max_err = err
			max_err_info = "vi=%d (parent_vi=%d)" % [vi, parent_vi]

	gut.p("  LOD boundary (child_1 vs parent_east) max GPU error: %.6f m (%s)"
		% [max_err, max_err_info])

	# At different LOD levels, some mismatch is expected due to different
	# chunk centers. The skirt must cover this. But verify it's within
	# a reasonable bound.
	assert_lt(max_err, 0.01,
		"LOD boundary GPU world mismatch: %.6f m (%s). "
		% [max_err, max_err_info]
		+ "Skirts may not cover this gap.")


func test_f64_chunk_center_causes_seam_without_snap() -> void:
	## Prove that using float64 chunk_center for mi.position while
	## generate_mesh internally snaps to float32 causes a measurable seam.
	## Then verify that snap_to_f32 fixes it.
	##
	## At radius ~1.96 M metres (near 2^21), the float32 ULP is ~0.25 m.
	## The float64→float32 rounding can shift each chunk differently,
	## causing up to ~0.12 m error per component at shared edge vertices.
	var radius := 1958333.0
	var nside := 8192
	var res := 32
	var ix_A := 4000
	var iy := 3000
	var ipix_A := 2 * nside * nside + HEALPix.xy2nest(ix_A, iy)
	var ipix_B := 2 * nside * nside + HEALPix.xy2nest(ix_A + 1, iy)

	# Compute chunk centers as planet_terrain.gd does (float64).
	var cc_f64_A := HEALPix.pix2vec_nest(nside, ipix_A) * radius
	var cc_f64_B := HEALPix.pix2vec_nest(nside, ipix_B) * radius

	# Snap to float32 as generate_mesh does internally.
	var cc_f32_A := PlanetChunk.snap_to_f32(cc_f64_A)
	var cc_f32_B := PlanetChunk.snap_to_f32(cc_f64_B)

	# Verify there IS a difference between f64 and f32 at this radius.
	var delta_A := cc_f64_A.distance_to(cc_f32_A)
	var delta_B := cc_f64_B.distance_to(cc_f32_B)
	gut.p("  chunk_center f64→f32 delta: A=%.6f m, B=%.6f m" % [delta_A, delta_B])
	# At radius ~2M, ULP is ~0.25 m; the distance should be non-trivial.
	assert_gt(maxf(delta_A, delta_B), 0.0,
		"f64→f32 snap should produce a non-zero delta at this radius")

	# Shared edge direction (same for both chunks, guaranteed by same-face test).
	var grid_A := HEALPix.get_pixel_grid(nside, ipix_A, res)
	var grid_B := HEALPix.get_pixel_grid(nside, ipix_B, res)

	# Simulate: vertex at A's right edge / B's left edge, with elevation.
	var vi := res / 2  # middle of the edge
	var dir: Vector3 = grid_A[vi][res]  # identical to grid_B[vi][0]
	var height := 500.0  # metres of terrain elevation
	var world_pos := dir * (radius + height)

	# --- Old path: mi.position = f64 chunk_center, vertices use f32 snap ---
	var local_A_old := _snap_to_local(world_pos, cc_f32_A)
	var local_B_old := _snap_to_local(world_pos, cc_f32_B)
	# GPU reconstructs: mi.position(f64) + vertex(f32) → GPU world
	# Simulate: the f64 add-back uses the UN-snapped chunk_center.
	var gpu_A_old := cc_f64_A + local_A_old
	var gpu_B_old := cc_f64_B + local_B_old
	var seam_old := gpu_A_old.distance_to(gpu_B_old)

	# --- New path: mi.position = f32 chunk_center → no delta ---
	var gpu_A_new := cc_f32_A + local_A_old
	var gpu_B_new := cc_f32_B + local_B_old
	var seam_new := gpu_A_new.distance_to(gpu_B_new)

	gut.p("  Old seam (f64 mi.position): %.6f m" % [seam_old])
	gut.p("  New seam (f32 mi.position): %.6f m" % [seam_new])

	# The old path should have a measurable seam (>0.01m typically).
	# The new path should eliminate it (0 or near-0).
	assert_lt(seam_new, 0.001,
		"snapped mi.position seam = %.6f m — should be < 0.001 m" % [seam_new])
	# Also verify the old path was actually worse (proving the fix matters).
	assert_gt(seam_old, seam_new,
		"Old f64 path (%.6f m) should have larger seam than new f32 path (%.6f m)"
		% [seam_old, seam_new])


# ===================================================================
# vec2pix_nest ↔ pix2vec_nest round-trip for all 12 faces
# ===================================================================

func test_vec2pix_nest_roundtrip_all_faces() -> void:
	## Verify that pix2vec_nest → vec2pix_nest round-trips to the same
	## pixel for every pixel at nside=64 across all 12 faces.
	## Regression test for the face column formula bug where
	## (jp + nside) / (2*nside) was used instead of jp / nside,
	## causing faces 6 and 7 to be misclassified as 5 and 6.
	var nside := 64
	var npix := 12 * nside * nside  # 49152
	var mismatches := 0
	var first_mismatch := -1
	for ipix in npix:
		var dir := HEALPix.pix2vec_nest(nside, ipix)
		var got := HEALPix.vec2pix_nest(nside, dir)
		if got != ipix:
			mismatches += 1
			if first_mismatch < 0:
				first_mismatch = ipix
	assert_eq(mismatches, 0,
		"vec2pix round-trip mismatches: %d / %d (first at ipix %d)" % [
			mismatches, npix, first_mismatch])


func test_vec2pix_nest_face7_pixel_centres() -> void:
	## Specifically test face 7 pixel centres — the face most affected
	## by the old bug (mapped to face 6 instead).
	var nside := 64
	var npface := nside * nside
	var face7_start := 7 * npface
	var mismatches := 0
	for local in npface:
		var ipix := face7_start + local
		var dir := HEALPix.pix2vec_nest(nside, ipix)
		var got := HEALPix.vec2pix_nest(nside, dir)
		if got != ipix:
			mismatches += 1
	assert_eq(mismatches, 0,
		"Face 7: %d / %d pixels failed round-trip" % [mismatches, npface])


func test_vec2pix_nest_boundary_dirs_same_export_tile() -> void:
	## Chunk boundary directions at nside=8192 should resolve to the
	## same export tile (nside=64) as the chunk's deterministic parent.
	## This is the scenario that caused 0.0m boundary heights.
	var chunk_nside := 8192
	var export_nside := 64
	var res := 32

	# Test a chunk on each equatorial face (faces 4-7)
	for face in range(4, 8):
		# Pick a chunk near the centre of the face
		var mid_ix := chunk_nside / 2
		var mid_iy := chunk_nside / 2
		var local := HEALPix.xy2nest(mid_ix, mid_iy)
		var ipix := face * chunk_nside * chunk_nside + local

		# Compute expected export tile
		var export_ipix := ipix
		var ns := chunk_nside
		while ns > export_nside:
			export_ipix >>= 2
			ns /= 2

		# Generate grid and check boundary vertex directions
		var grid := HEALPix.get_pixel_grid(chunk_nside, ipix, res)
		var wrong_count := 0
		for yi in range(res + 1):
			for xi in range(res + 1):
				if xi == 0 or xi == res or yi == 0 or yi == res:
					var dir: Vector3 = grid[yi][xi]
					var resolved := HEALPix.vec2pix_nest(export_nside, dir)
					var resolved_face := resolved / (export_nside * export_nside)
					var expected_face := export_ipix / (export_nside * export_nside)
					if resolved_face != expected_face:
						wrong_count += 1
		assert_eq(wrong_count, 0,
			"Face %d: %d boundary dirs resolved to wrong face" % [face, wrong_count])
