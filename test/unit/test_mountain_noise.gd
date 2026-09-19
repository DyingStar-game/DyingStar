extends GutTest
## MountainNoise: the integer-hash noise behind the procedural mountains.
## The golden values come from the Python twin
## (tools/planettech/qgis/export/planet/mountain_noise.py) — matching them
## here is what proves the hash carries no libm dependency and that the two
## implementations stay in lock-step.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_mountain_noise.gd

const RADIUS := 3467000.0


func _prm(over: Dictionary = {}) -> MountainNoise.Params:
	var z := {"wavelength_m": 6000.0, "octaves": 7, "persistence": 0.45, "ridge": 0.6,
			"exponent": 1.5, "warp": 0.0, "seed": 3}
	z.merge(over, true)
	return MountainNoise.Params.from_zone(z)


func test_hash_matches_the_python_twin() -> void:
	assert_eq(MountainNoise.hash_i(0, 0, 0, 0), 3348245848)
	assert_eq(MountainNoise.hash_i(1, 2, 3, 4), 2416401439)
	assert_eq(MountainNoise.hash_i(-1, -2, -3, 7), 3867037789)
	assert_eq(MountainNoise.hash_i(123456, -654321, 42, 99), 2879151037)
	assert_eq(MountainNoise.hash_i(2147483648, -2147483648, 5, 1), 2769678470)
	assert_eq(MountainNoise.hash_i(7, 7, 7, -3), 810817105)


func test_value_noise_matches_the_python_twin() -> void:
	assert_almost_eq(MountainNoise.vnoise(Vector3(0.5, 0.5, 0.5), 0), 0.38864316791296005, 1e-14)
	assert_almost_eq(MountainNoise.vnoise(Vector3(1.25, -3.75, 2.5), 1), 0.22107108201646497, 1e-14)
	assert_almost_eq(MountainNoise.vnoise(Vector3(1000.125, 2000.375, -3000.625), 42),
			0.6301147014547613, 1e-14)
	assert_almost_eq(MountainNoise.vnoise(Vector3(-0.001, 0.999, 12.345), 7),
			0.5109848547258147, 1e-14)


func test_shape_matches_the_python_twin_at_every_pitch() -> void:
	var d := Vector3(0.3, 0.5, 0.8).normalized()
	var p := _prm()
	assert_almost_eq(MountainNoise.shape(d, RADIUS, p, 25.0), 0.36241033415342655, 1e-13)
	assert_almost_eq(MountainNoise.shape(d, RADIUS, p, 100.0), 0.35889293378224496, 1e-13)
	assert_almost_eq(MountainNoise.shape(d, RADIUS, p, 400.0), 0.35608748714742167, 1e-13)
	assert_almost_eq(MountainNoise.shape(d, RADIUS, p, 1600.0), 0.3376137534106668, 1e-13)
	assert_eq(MountainNoise.shape(d, RADIUS, p, 3000.0), -1.0, "past half the base wavelength: nothing")
	assert_almost_eq(MountainNoise.shape(d, RADIUS, _prm({"warp": 0.3}), 25.0),
			0.4770112750322795, 1e-13)


func test_noise_is_bounded_and_deterministic() -> void:
	var lo := INF
	var hi := -INF
	for i in 2000:
		var p := Vector3(sin(i * 0.37) * 50.0, cos(i * 0.53) * 50.0, sin(i * 0.11 + 1.0) * 50.0)
		var v := MountainNoise.vnoise(p, i % 5)
		assert_between(v, 0.0, 1.0)
		assert_eq(v, MountainNoise.vnoise(p, i % 5))
		lo = minf(lo, v)
		hi = maxf(hi, v)
	assert_lt(lo, 0.15)
	assert_gt(hi, 0.85)


func test_noise_is_continuous_across_a_cell_boundary() -> void:
	# A floor() that flips at the boundary must not create a step: the value
	# noise is C0 there by construction, whichever side rounding lands on.
	for seed in 4:
		for axis in 3:
			var base := Vector3(3.37, -7.61, 12.2)
			var a := base
			var b := base
			a[axis] = 5.0 - 1e-9
			b[axis] = 5.0 + 1e-9
			assert_almost_eq(MountainNoise.vnoise(a, seed), MountainNoise.vnoise(b, seed), 1e-7)


func test_lod_gate_drops_octaves_never_fades() -> void:
	var d := Vector3(-0.2, 0.9, 0.4).normalized()
	var p := _prm({"octaves": 6})
	# 6 octaves of 6000 m: 6000, 3000, 1500, 750, 375, 187.5. The gate at pitch
	# s keeps octave k iff s < wl_k / 2.
	var full := MountainNoise.shape(d, RADIUS, p, 25.0)
	var same := MountainNoise.shape(d, RADIUS, p, 90.0)   # still < 187.5/2
	assert_eq(full, same, "every octave fits on both grids → identical, not faded")
	var five := MountainNoise.shape(d, RADIUS, p, 100.0)  # drops the 187.5 m octave
	assert_ne(five, full)
	# The normaliser is the AUTHORED octave sum, so a dropped octave removes
	# only its own (zero-mean) contribution: at most 0.5·persistence⁵/norm of
	# the normalised height, before the power curve.
	var lin := _prm({"octaves": 6, "exponent": 1.0})
	var bound := 0.5 * pow(0.45, 5) / lin._norm
	assert_lt(absf(MountainNoise.shape(d, RADIUS, lin, 100.0)
			- MountainNoise.shape(d, RADIUS, lin, 25.0)), bound + 1e-12,
			"a dropped octave never rescales the surviving ones")
	assert_eq(MountainNoise.shape(d, RADIUS, p, 3000.0), -1.0)


func test_terrace_is_monotone_and_continuous() -> void:
	var prev := -INF
	for i in 2001:
		var h := i * 0.25
		var t := MountainNoise.terrace(h, 50.0, 0.2)
		assert_true(t >= prev - 1e-9, "monotone at %f" % h)
		prev = t
	assert_eq(MountainNoise.terrace(137.0, 50.0, 0.2), 100.0, "on the flat of a step")
	assert_almost_eq(MountainNoise.terrace(199.0, 50.0, 0.2), 198.6, 1e-9)
	assert_almost_eq(MountainNoise.terrace(200.0 - 1e-9, 50.0, 0.2),
			MountainNoise.terrace(200.0 + 1e-9, 50.0, 0.2), 1e-6, "continuous at the step top")
	assert_eq(MountainNoise.terrace(123.4, 0.0, 0.2), 123.4, "no step = identity")


func test_pow_fast_is_exact_on_the_preset_exponents() -> void:
	for x in [0.0, 0.1, 0.5, 0.9, 1.0]:
		assert_eq(MountainNoise.pow_fast(x, 1.0), x)
		assert_eq(MountainNoise.pow_fast(x, 2.0), x * x)
		assert_eq(MountainNoise.pow_fast(x, 1.5), x * sqrt(x))
		assert_almost_eq(MountainNoise.pow_fast(x, 2.7), pow(x, 2.7), 1e-15)


func test_params_resolve_defaults_and_clamps() -> void:
	var p := MountainNoise.Params.from_zone({"octaves": 40, "persistence": 2.0, "ridge": -1.0})
	assert_eq(p.octaves, MountainNoise.MAX_OCTAVES)
	assert_eq(p.persistence, 0.95)
	assert_eq(p.ridge, 0.0)
	assert_eq(p.amplitude_m, 300.0, "default amplitude")
	assert_gt(p._norm, 1.0)
