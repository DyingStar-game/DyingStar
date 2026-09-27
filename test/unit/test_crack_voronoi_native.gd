extends GutTest

## The crack network's Voronoi in C# (CrackVoronoiNative) against the GDScript it replaces, BIT FOR BIT.
##
## Its distance carves the corundum ground of every chunk and every server collision shape, and moves
## the rim vertices (crack_rim_snap): an ulp of difference is a different surface. The hash under it,
## fract(sin(dot) × 43758.5453123), turns the last bit of a sine into a different cell, so this is also
## the test that Math.Sin agrees with the engine's sin on the machine running it.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_voronoi_native.gd

const RADIUS: float = 6356000.0
const SPACING: float = 220.0


func after_each() -> void:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true


func _both(x: Vector3) -> Array:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
	var fast: Vector4 = ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(x)
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = false
	var slow: Vector4 = ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(x)
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
	return [fast, slow]


func test_the_assembly_is_there() -> void:
	ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(Vector3.ONE)
	# A boolean, not assert_not_null: GUT cannot print a C# object and fails on trying.
	assert_true(ArideDesertCorundumPlateauTerrain._voronoi_native != null,
			"CrackVoronoiNative.cs must load, or the tests below compare the GDScript with itself")


## Points where the chunks ask: a unit direction scaled to cells, all over the sphere.
func test_the_voronoi_is_identical_all_over_the_sphere() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var differ: int = 0
	var first: String = ""
	for i: int in range(4000):
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var got: Array = _both(d * (RADIUS / SPACING))
		if got[0] != got[1]:
			differ += 1
			if first == "":
				first = "%s: C# %s, GDScript %s" % [str(d), str(got[0]), str(got[1])]
	assert_eq(differ, 0, "every point equal: %s" % first)


## On and next to cell boundaries, where floor() and the "closest cell" comparisons turn.
func test_the_voronoi_is_identical_on_cell_boundaries() -> void:
	var differ: int = 0
	for ix: int in range(-3, 4):
		for k: int in range(50):
			var x := Vector3(float(ix) + 1000.0, -20000.0 + float(k) * 0.25, 13.0 - float(k) * 1.0e-9)
			for probe: Vector3 in [x, x + Vector3(1.0e-12, 0, 0), x - Vector3(0, 1.0e-12, 0)]:
				var got: Array = _both(probe)
				if got[0] != got[1]:
					differ += 1
	assert_eq(differ, 0)


## And what the chunks actually call: the rim snap and the carve, both through the Voronoi.
func test_the_crack_queries_are_identical() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var differ: int = 0
	for i: int in range(1500):
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
		var snap_a := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, SPACING, 12.0, 3.0, 4.5)
		var off_a := ArideDesertCorundumPlateauTerrain.crack_offset(d, RADIUS, SPACING, 12.0, 40.0, 3.0)
		ArideDesertCorundumPlateauTerrain.use_native_voronoi = false
		var snap_b := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, SPACING, 12.0, 3.0, 4.5)
		var off_b := ArideDesertCorundumPlateauTerrain.crack_offset(d, RADIUS, SPACING, 12.0, 40.0, 3.0)
		if snap_a != snap_b or off_a != off_b:
			differ += 1
	assert_eq(differ, 0)
