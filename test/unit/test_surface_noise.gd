extends GutTest

## SurfaceNoise feeds terrain HEIGHTS (BiomeRelief) as well as colours, on the client and on the server,
## and chunk caches bake what it returns. A faster path is only acceptable if it returns the very same
## bits.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_surface_noise.gd


func test_hash1_is_bit_for_bit_hash3_x() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260927
	var differ: int = 0
	for i: int in range(20000):
		# Lattice cells as vnoise builds them: floor() of a direction scaled by radius / wavelength, so
		# anything from a few cells to millions.
		var scale: float = pow(10.0, rng.randf_range(0.0, 7.0))
		var c: Vector3 = (Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				* scale).floor()
		if SurfaceNoise.hash1(c) != SurfaceNoise.hash3(c).x:
			differ += 1
	assert_eq(differ, 0, "hash1 must be exactly hash3(c).x")
