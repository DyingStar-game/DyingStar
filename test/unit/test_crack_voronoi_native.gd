extends GutTest

## The crack network's Voronoi in C# (CrackVoronoiNative) against its GDScript twin and across machines.
##
## Its distance carves the corundum ground of every chunk and every server collision shape, and moves the
## rim vertices (crack_rim_snap). The hash under it, fract(sin(dot) × 43758.5453123), turns the last bit
## of a sine into a slightly different value — and the last bit of a sine is NOT the same everywhere.
## Measured over the 4844 values of fixtures/crack_voronoi_linux.b64 (made on Fedora, glibc 2.43):
##   GitHub's Ubuntu 24.04 (glibc 2.39), C# and GDScript alike    5 values off by an ulp
##   Windows, C# (.NET's Math.Sin)                               402 values off
##   Windows, GDScript (the Windows Godot build's sin)          3784 values off
## The .NET sines drift by an ulp: the C# stays within 8e-9 of the reference on Windows (the largest, a
## carve in metres, the profile's slope amplifying the edge distance's drift). The Windows GODOT build's
## sine is worse: it gives up precision on the large arguments this hash feeds it (~1e7), and its
## GDScript Voronoi sits 1.6e-6 away from the C# on the same machine. So on Windows the C# is what
## brings a client's cracks onto the server's; the GDScript there is not a reference at all.
## What is held here:
## - on ONE machine where the engine and .NET share the system libm (Linux), the C# equals the GDScript
##   bit for bit — the C# is the GDScript, faster;
## - on any machine, every C# value stays within [constant ACROSS_MACHINES] of the reference: a libm's
##   ulps, amplified at most by the crack profile — while a point landing in another cell, or a rim
##   vertex moved differently, would be off by 0.1 to metres.
## Bit-identical cracks across machines would need an integer hash (as MountainNoiseCore does), which
## redraws the network: a decision of its own, not a test.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_voronoi_native.gd

## How far a C# value may drift from the reference on another machine: cell units (1 cell = 220 m),
## unit-normal components, and metres of carve. Measured: 5e-13 on GitHub's Ubuntu, 8.2e-9 on Windows.
const ACROSS_MACHINES: float = 1.0e-7

const RADIUS: float = TestCrackVoronoiPoints.RADIUS
const SPACING: float = TestCrackVoronoiPoints.SPACING


func after_each() -> void:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true


func _voronoi(x: Vector3, native: bool) -> Vector4:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = native
	var v: Vector4 = ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(x)
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
	return v


## Every Voronoi point (sphere, then boundaries) and query, in the reference file's order.
func _values(native: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var points := TestCrackVoronoiPoints.sphere_points()
	points.append_array(TestCrackVoronoiPoints.boundary_points())
	for x: Vector3 in points:
		var v: Vector4 = _voronoi(x, native)
		out.append_array([v.x, v.y, v.z, v.w])
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = native
	for d: Vector3 in TestCrackVoronoiPoints.query_dirs():
		var s := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, SPACING, 12.0, 3.0, 4.5)
		var o := ArideDesertCorundumPlateauTerrain.crack_offset(d, RADIUS, SPACING, 12.0, 40.0, 3.0)
		out.append_array([s.x, s.y, s.z, s.w, o])
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
	return out


## How many values of [param got] differ from [param want], and the first one that does.
func _diff(got: PackedFloat64Array, want: PackedFloat64Array) -> Array:
	var differ: int = 0
	var first: String = ""
	for i: int in range(mini(got.size(), want.size())):
		if got[i] != want[i]:
			differ += 1
			if first == "":
				first = "value %d: %s, reference %s" % [i, String.num(got[i], 14), String.num(want[i], 14)]
	return [differ, first]


func test_the_assembly_is_there() -> void:
	ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(Vector3.ONE)
	# A boolean, not assert_not_null: GUT cannot print a C# object and fails on trying.
	assert_true(ArideDesertCorundumPlateauTerrain._voronoi_native != null,
			"CrackVoronoiNative.cs must load, or the tests below compare the GDScript with itself")


## The reference file is there and matches the points asked about.
func test_the_linux_values_are_there() -> void:
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var points: int = TestCrackVoronoiPoints.sphere_points().size() \
			+ TestCrackVoronoiPoints.boundary_points().size()
	assert_eq(want.size(), points * 4 + TestCrackVoronoiPoints.query_dirs().size() * 5)


## On every machine, the C# stays within [constant ACROSS_MACHINES] of the reference — the libm's ulps,
## never a different cell or a different edge.
func test_the_csharp_stays_within_a_hair_of_the_reference() -> void:
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var got: PackedFloat64Array = _values(true)
	var worst: float = 0.0
	var where: int = -1
	for i: int in range(mini(got.size(), want.size())):
		var d: float = absf(got[i] - want[i])
		if d > worst:
			worst = d
			where = i
	assert_lte(worst, ACROSS_MACHINES, "largest drift %s at value %d" % [String.num_scientific(worst), where])


## And where the engine and .NET share the system libm, the C# IS the GDScript: bit for bit. On Windows
## they do not, and the engine's sine is the less precise of the two (see above): the gap is reported,
## not held — it measures the Windows Godot build, not the twin.
func test_the_csharp_is_the_gdscript_on_this_machine() -> void:
	var csharp: PackedFloat64Array = _values(true)
	var gdscript: PackedFloat64Array = _values(false)
	if OS.get_name() == "Windows":
		var worst: float = 0.0
		for i: int in range(mini(csharp.size(), gdscript.size())):
			worst = maxf(worst, absf(csharp[i] - gdscript[i]))
		pending("Windows: the engine's sin is not the libm .NET uses; GDScript to C# gap %s (the C# is "
				% String.num_scientific(worst) + "held to the reference instead)")
		return
	var got: Array = _diff(csharp, gdscript)
	assert_eq(got[0], 0, "C# and GDScript equal bit for bit: %s" % got[1])
