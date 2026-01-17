#!/usr/bin/env -S godot --headless --script
## Standalone test runner for HEALPix terrain pipeline.
## Run with:  godot --headless --script test/unit/run_healpix_tests.gd
##
## This avoids autoload dependencies (GameOrchestrator etc.) that
## crash in headless mode.  Each test prints PASS/FAIL and a summary.
extends SceneTree

const EPS := 1e-9
const MAX_UV_JUMP := 0.02

var _pass_count := 0
var _fail_count := 0
var _current_test := ""


func _init() -> void:
	print("=== HEALPix Terrain Pipeline Tests ===\n")

	_run("test_round_trip_pixel_centres_all_faces")
	_run("test_round_trip_sub_pixel_positions")
	_run("test_round_trip_face3_phi_boundary")
	_run("test_round_trip_polar_cap_faces")
	_run("test_round_trip_high_nside")
	_run("test_uv_stays_in_unit_square")
	_run("test_uv_matches_analytical_position")
	_run("test_uv_at_pixel_edge_exact")
	_run("test_no_cliff_in_chunk_grid_uv")
	_run("test_no_cliff_centre_chunk")
	_run("test_uv_at_face_edge_is_clamped_not_negative")
	_run("test_uv_monotonic_across_grid")
	_run("test_export_ipix_walk_down")
	_run("test_height_continuity_synthetic_heightmap")
	_run("test_height_continuity_centre_chunk")

	print("\n=== Summary: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		print("FAILURES DETECTED")
	else:
		print("ALL TESTS PASSED")
	quit()


func _run(method: String) -> void:
	_current_test = method
	call(method)


func _assert(condition: bool, msg: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s — %s" % [_current_test, msg])
	else:
		_fail_count += 1
		print("  FAIL: %s — %s" % [_current_test, msg])


func _make_planet_data() -> PlanetData:
	var pd := PlanetData.new()
	pd.radius = 1958333.0
	pd.max_height = 7350.0
	pd.height_offset = -480.0
	pd.chunk_export_depth = 6
	pd.export_nside = 64
	return pd


# ===================================================================
# 1. Round-trip tests
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
	_assert(max_err < EPS,
		"max error %.2e (limit %.2e)" % [max_err, EPS])


func test_round_trip_sub_pixel_positions() -> void:
	var nside := 64
	var max_err := 0.0
	for face in [0, 2, 3, 5, 8, 11]:
		for ix in [0, 1, 31, 63]:
			for iy in [0, 1, 31, 63]:
				for dfx in [0.1, 0.25, 0.5, 0.75, 0.9]:
					for dfy in [0.1, 0.25, 0.5, 0.75, 0.9]:
						var fx_in := float(ix) + dfx
						var fy_in := float(iy) + dfy
						var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
						var fc := HEALPix._vec_to_face_xy(d, face, nside)
						var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
						max_err = maxf(max_err, err)
	_assert(max_err < EPS,
		"max error %.2e (limit %.2e)" % [max_err, EPS])


func test_round_trip_face3_phi_boundary() -> void:
	var nside := 64
	var max_err := 0.0
	for ix in [60, 61, 62, 63]:
		for iy in [0, 1, 2, 3]:
			for dfx in [0.1, 0.5, 0.9]:
				for dfy in [0.1, 0.5, 0.9]:
					var fx_in := float(ix) + dfx
					var fy_in := float(iy) + dfy
					var d := HEALPix._face_xy_to_vec(3, fx_in, fy_in, nside)
					var fc := HEALPix._vec_to_face_xy(d, 3, nside)
					var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
					max_err = maxf(max_err, err)
	_assert(max_err < EPS,
		"max error %.2e (limit %.2e)" % [max_err, EPS])


func test_round_trip_polar_cap_faces() -> void:
	var nside := 32
	var max_err := 0.0
	for ix in [0, 1, 2]:
		for iy in [0, 1, 2]:
			var d := HEALPix._face_xy_to_vec(0, float(ix) + 0.5, float(iy) + 0.5, nside)
			var fc := HEALPix._vec_to_face_xy(d, 0, nside)
			var err := maxf(absf(fc.x - float(ix) - 0.5), absf(fc.y - float(iy) - 0.5))
			max_err = maxf(max_err, err)
	for ix in [29, 30, 31]:
		for iy in [29, 30, 31]:
			var d := HEALPix._face_xy_to_vec(8, float(ix) + 0.5, float(iy) + 0.5, nside)
			var fc := HEALPix._vec_to_face_xy(d, 8, nside)
			var err := maxf(absf(fc.x - float(ix) - 0.5), absf(fc.y - float(iy) - 0.5))
			max_err = maxf(max_err, err)
	_assert(max_err < EPS,
		"max error %.2e (limit %.2e)" % [max_err, EPS])


func test_round_trip_high_nside() -> void:
	var nside := 8192
	var max_err := 0.0
	for face in [0, 2, 5, 8, 11]:
		for ix in [0, 100, 4095, 8191]:
			for iy in [0, 100, 4095, 8191]:
				for dfx in [0.0, 0.5, 1.0]:
					for dfy in [0.0, 0.5, 1.0]:
						var fx_in := float(ix) + dfx
						var fy_in := float(iy) + dfy
						var d := HEALPix._face_xy_to_vec(face, fx_in, fy_in, nside)
						var fc := HEALPix._vec_to_face_xy(d, face, nside)
						var err := maxf(absf(fc.x - fx_in), absf(fc.y - fy_in))
						max_err = maxf(max_err, err)
	_assert(max_err < 1e-6,
		"max error %.2e (limit 1e-6)" % [max_err])


# ===================================================================
# 2. _direction_to_pixel_uv tests
# ===================================================================


func test_uv_stays_in_unit_square() -> void:
	var pd := _make_planet_data()
	var nside := 64
	var ok := true
	for face in 12:
		for ix in [0, 31, 63]:
			for iy in [0, 31, 63]:
				var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
				for dfx in [0.01, 0.5, 0.99]:
					for dfy in [0.01, 0.5, 0.99]:
						var d := HEALPix._face_xy_to_vec(
							face, float(ix) + dfx, float(iy) + dfy, nside)
						var uv := pd._direction_to_pixel_uv(d, ipix, nside)
						if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
							ok = false
	_assert(ok, "all UVs in [0,1]²")


func test_uv_matches_analytical_position() -> void:
	var pd := _make_planet_data()
	var nside := 64
	var max_err := 0.0
	for face in [0, 2, 5, 8, 11]:
		for ix in [0, 32, 63]:
			for iy in [0, 32, 63]:
				var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
				var d := HEALPix._face_xy_to_vec(face, float(ix) + 0.37, float(iy) + 0.63, nside)
				var uv := pd._direction_to_pixel_uv(d, ipix, nside)
				max_err = maxf(max_err, maxf(absf(uv.x - 0.37), absf(uv.y - 0.63)))
	_assert(max_err < 1e-6,
		"max UV error %.2e (limit 1e-6)" % [max_err])


func test_uv_at_pixel_edge_exact() -> void:
	var pd := _make_planet_data()
	var nside := 64
	var max_err := 0.0
	for face in [0, 2, 5]:
		for ix in [0, 31, 62]:
			var iy := 32
			var ipix := face * nside * nside + HEALPix.xy2nest(ix, iy)
			var d := HEALPix._face_xy_to_vec(face, float(ix + 1), float(iy) + 0.5, nside)
			var uv := pd._direction_to_pixel_uv(d, ipix, nside)
			max_err = maxf(max_err, absf(uv.x - 1.0))
	_assert(max_err < 1e-6,
		"max edge error %.2e (limit 1e-6)" % [max_err])


# ===================================================================
# 3. Cliff detection in chunk UV grid
# ===================================================================


func test_no_cliff_in_chunk_grid_uv() -> void:
	var pd := _make_planet_data()
	var res := 32
	var export_ipix := 9557  # face=2, ix=63, iy=0 (face edge!)
	var chunk_face := 2
	var chunk_ix := 8191
	var chunk_iy := 69
	var chunk_nside := 8192

	var max_jump := 0.0
	var prev_uvs: Array[Vector2] = []
	var current_uvs: Array[Vector2] = []

	for yi in res + 1:
		current_uvs.clear()
		for xi in res + 1:
			var fx := float(chunk_ix) + float(xi) / float(res)
			var fy := float(chunk_iy) + float(yi) / float(res)
			var d := HEALPix._face_xy_to_vec(chunk_face, fx, fy, chunk_nside)
			var uv := pd._direction_to_pixel_uv(d, export_ipix, pd.export_nside)
			current_uvs.append(uv)
			if xi > 0:
				max_jump = maxf(max_jump, absf(uv.x - current_uvs[xi - 1].x))
			if yi > 0 and prev_uvs.size() > xi:
				max_jump = maxf(max_jump, absf(uv.y - prev_uvs[xi].y))
		prev_uvs = current_uvs.duplicate()

	_assert(max_jump < MAX_UV_JUMP,
		"face-edge chunk: max UV jump = %.6f (limit %.4f)" % [max_jump, MAX_UV_JUMP])


func test_no_cliff_centre_chunk() -> void:
	var pd := _make_planet_data()
	var res := 32
	var export_nside := 64
	var export_ipix := 2 * export_nside * export_nside + HEALPix.xy2nest(32, 32)
	var chunk_nside := 8192
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
			var d := HEALPix._face_xy_to_vec(2, fx, fy, chunk_nside)
			var uv := pd._direction_to_pixel_uv(d, export_ipix, export_nside)
			current_uvs.append(uv)
			if xi > 0:
				max_jump = maxf(max_jump, absf(uv.x - current_uvs[xi - 1].x))
			if yi > 0 and prev_uvs.size() > xi:
				max_jump = maxf(max_jump, absf(uv.y - prev_uvs[xi].y))
		prev_uvs = current_uvs.duplicate()

	_assert(max_jump < MAX_UV_JUMP,
		"centre chunk: max UV jump = %.6f (limit %.4f)" % [max_jump, MAX_UV_JUMP])


# ===================================================================
# 4. Face edge boundary
# ===================================================================


func test_uv_at_face_edge_is_clamped_not_negative() -> void:
	var pd := _make_planet_data()
	var nside := 64
	var ipix := 2 * nside * nside + HEALPix.xy2nest(63, 32)
	var d := HEALPix._face_xy_to_vec(2, 64.0, 32.5, nside)
	var uv := pd._direction_to_pixel_uv(d, ipix, nside)
	_assert(uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0,
		"clamped UV = (%.6f, %.6f)" % [uv.x, uv.y])


func test_uv_monotonic_across_grid() -> void:
	var pd := _make_planet_data()
	var nside := 64
	var all_monotonic := true
	for ix in [0, 32, 63]:
		var iy := 32
		var ipix := 2 * nside * nside + HEALPix.xy2nest(ix, iy)
		var prev_u := -1.0
		for xi in 33:
			var fx := float(ix) + float(xi) / 32.0
			var d := HEALPix._face_xy_to_vec(2, fx, float(iy) + 0.5, nside)
			var uv := pd._direction_to_pixel_uv(d, ipix, nside)
			if uv.x < prev_u - 1e-10:
				all_monotonic = false
			prev_u = uv.x
	_assert(all_monotonic, "u is monotonically increasing across grid for face=2")


# ===================================================================
# 5. Export ipix walk-down
# ===================================================================


func test_export_ipix_walk_down() -> void:
	var chunk_ipix := 156595575
	var chunk_nside := 8192
	var export_nside := 64
	var ipix := chunk_ipix
	var ns := chunk_nside
	while ns > export_nside:
		ipix >>= 2
		@warning_ignore("integer_division")
		ns /= 2
	var ok := (ipix == 9557 and ns == export_nside)
	if ok:
		var npface := export_nside * export_nside
		@warning_ignore("integer_division")
		var face := ipix / npface
		var local := ipix % npface
		var xy := HEALPix.nest2xy(local)
		ok = (face == 2 and xy.x == 63 and xy.y == 0)
	_assert(ok, "chunk 156595575 → export 9557 (face=2, ix=63, iy=0)")


# ===================================================================
# 6. Full height pipeline with synthetic heightmap
# ===================================================================


func test_height_continuity_synthetic_heightmap() -> void:
	var pd := _make_planet_data()
	var img_size := 256
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var ipix := 9557  # face=2, ix=63, iy=0
	var key := "hp_n%d_p%d" % [pd.export_nside, ipix]
	pd._chunk_images[key] = img

	var chunk_face := 2
	var chunk_ix := 8191
	var chunk_iy := 69
	var chunk_nside := 8192
	var res := 32
	var max_jump := 0.0
	var prev_h := -1e20

	for xi in res + 1:
		var fx := float(chunk_ix) + float(xi) / float(res)
		var d := HEALPix._face_xy_to_vec(chunk_face, fx, float(chunk_iy) + 0.5, chunk_nside)
		var h := pd.sample_height_for_direction(d, ipix)
		if xi > 0:
			max_jump = maxf(max_jump, absf(h - prev_h))
		prev_h = h

	_assert(max_jump < 50.0,
		"face-edge chunk: max height jump = %.4f m (limit 50.0)" % [max_jump])


func test_height_continuity_centre_chunk() -> void:
	var pd := _make_planet_data()
	var img_size := 256
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RF)
	for y in img_size:
		for x in img_size:
			var val := (float(x) + float(y)) / (2.0 * float(img_size))
			img.set_pixel(x, y, Color(val, 0, 0, 1))

	var ipix := 2 * 64 * 64 + HEALPix.xy2nest(32, 32)
	var key := "hp_n%d_p%d" % [pd.export_nside, ipix]
	pd._chunk_images[key] = img

	var chunk_ix := 4096
	var chunk_iy := 4096
	var res := 32
	var max_jump := 0.0
	var prev_h := -1e20

	for xi in res + 1:
		var fx := float(chunk_ix) + float(xi) / float(res)
		var d := HEALPix._face_xy_to_vec(2, fx, float(chunk_iy) + 0.5, 8192)
		var h := pd.sample_height_for_direction(d, ipix)
		if xi > 0:
			max_jump = maxf(max_jump, absf(h - prev_h))
		prev_h = h

	_assert(max_jump < 50.0,
		"centre chunk: max height jump = %.4f m (limit 50.0)" % [max_jump])
