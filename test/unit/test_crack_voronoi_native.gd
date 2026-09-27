extends GutTest

## The crack network in C# (CrackVoronoiNative) against its GDScript twin and across machines.
##
## Its distance carves the corundum ground of every chunk and every server collision shape, and moves the
## rim vertices (crack_rim_snap). It used to hash its feature points with fract(sin(dot) × 43758.5453123),
## whose last bit differs between libms: Windows sat up to 1.6e-6 off Linux in GDScript. Since the organic
## cracks (CrackNoise) the jitter is MountainNoise's integer hash and the meander and rim noise its value
## noise: no transcendental left, only IEEE + − × ÷ and sqrt, which every machine rounds the same. So:
## - on every machine, the C# equals the GDScript bit for bit;
## - on every machine, both equal the Linux reference (fixtures/crack_voronoi_linux.b64) bit for bit.
##
## Regenerate the reference on purpose only (a new network):
##   CRACK_VORONOI_WRITE=1 godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_crack_voronoi_native.gd -gexit
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_voronoi_native.gd

const RADIUS: float = TestCrackVoronoiPoints.RADIUS
const SPACING: float = TestCrackVoronoiPoints.SPACING
## tarsis_3's network (scenes/systems/tarsis/tarsis_3.tscn) and finest pitch, for the organic queries.
const ORGANIC_SPACING: float = 4000.0
const ORGANIC_WIDTH: float = 250.0
const ORGANIC_DEPTH: float = 180.0
const ORGANIC_PITCH: float = 24.3


func after_each() -> void:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = true


static func organic() -> CrackNoise:
	return CrackNoise.make(3, 80.0, 1500.0, 20.0, 400.0, ORGANIC_WIDTH, ORGANIC_PITCH)


## Every Voronoi point (sphere, then boundaries), every plain query, every organic query, in the
## reference file's order.
func _values(native: bool) -> PackedFloat64Array:
	ArideDesertCorundumPlateauTerrain.use_native_voronoi = native
	var out := PackedFloat64Array()
	var points := TestCrackVoronoiPoints.sphere_points()
	points.append_array(TestCrackVoronoiPoints.boundary_points())
	for x: Vector3 in points:
		var v: Vector4 = ArideDesertCorundumPlateauTerrain._voronoi_edge_dn(x)
		out.append_array([v.x, v.y, v.z, v.w])
	for d: Vector3 in TestCrackVoronoiPoints.query_dirs():
		var s := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, SPACING, 12.0, 3.0, 4.5)
		var o := ArideDesertCorundumPlateauTerrain.crack_offset(d, RADIUS, SPACING, 12.0, 40.0, 3.0)
		out.append_array([s.x, s.y, s.z, s.w, o])
	var nz := organic()
	for d: Vector3 in TestCrackVoronoiPoints.query_dirs():
		var s := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, ORGANIC_SPACING, ORGANIC_WIDTH,
				ORGANIC_PITCH, ORGANIC_PITCH * 1.6, nz)
		var e := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(d, RADIUS, ORGANIC_SPACING,
				ORGANIC_WIDTH, 0.0, nz)
		out.append_array([s.x, s.y, s.z, s.w, e])
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
	# A boolean, not assert_not_null: GUT cannot print a C# object and fails on trying.
	assert_true(CrackNoise.plain().native != null,
			"CrackVoronoiNative.cs must load, or the tests below compare the GDScript with itself")
	assert_true(organic().native != null, "and be configurable per network")


## The reference file is there and matches the points asked about — or, on purpose, is rewritten.
func test_the_linux_values_are_there() -> void:
	if OS.get_environment("CRACK_VORONOI_WRITE") == "1":
		var f := FileAccess.open(TestCrackVoronoiPoints.REFERENCE, FileAccess.WRITE)
		f.store_string(Marshalls.raw_to_base64(_values(false).to_byte_array()))
		f.close()
		pending("reference rewritten from the GDScript path")
		return
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var points: int = TestCrackVoronoiPoints.sphere_points().size() \
			+ TestCrackVoronoiPoints.boundary_points().size()
	assert_eq(want.size(), points * 4 + TestCrackVoronoiPoints.query_dirs().size() * 5 * 2)


## On every machine, both twins give the reference's values exactly: no sine anywhere.
func test_both_twins_give_the_reference_values() -> void:
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var csharp: Array = _diff(_values(true), want)
	assert_eq(csharp[0], 0, "C# equals the Linux reference: %s" % csharp[1])
	var gdscript: Array = _diff(_values(false), want)
	assert_eq(gdscript[0], 0, "GDScript equals the Linux reference: %s" % gdscript[1])


## The organic snap, where it matters: directions near a rim, C# against GDScript, bit for bit — and it
## does move them (non-vacuous).
func test_the_organic_snap_is_the_same_in_both() -> void:
	var nz := organic()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2718
	var near := 0
	var moved := 0
	var differ := 0
	var first := ""
	for i: int in range(20000):
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		ArideDesertCorundumPlateauTerrain.use_native_voronoi = false
		var e := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(d, RADIUS, ORGANIC_SPACING,
				ORGANIC_WIDTH, ORGANIC_PITCH, nz)
		if absf(e - ORGANIC_WIDTH * 0.5) > ORGANIC_PITCH * 2.0:
			continue
		near += 1
		var gd := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, ORGANIC_SPACING, ORGANIC_WIDTH,
				ORGANIC_PITCH, ORGANIC_PITCH * 1.6, nz)
		ArideDesertCorundumPlateauTerrain.use_native_voronoi = true
		var cs := ArideDesertCorundumPlateauTerrain.crack_rim_snap(d, RADIUS, ORGANIC_SPACING, ORGANIC_WIDTH,
				ORGANIC_PITCH, ORGANIC_PITCH * 1.6, nz)
		if Vector3(gd.x, gd.y, gd.z) != d:
			moved += 1
		if gd != cs:
			differ += 1
			if first == "":
				first = "%s: C# %s, GDScript %s" % [str(d), str(cs), str(gd)]
	assert_gt(near, 200, "directions near a rim (%d)" % near)
	assert_gt(moved, near / 2, "most of them snapped (%d of %d)" % [moved, near])
	assert_eq(differ, 0, "C# and GDScript snap alike: %s" % first)
