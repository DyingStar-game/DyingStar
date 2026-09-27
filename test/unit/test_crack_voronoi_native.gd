extends GutTest

## The crack network's Voronoi in C# (CrackVoronoiNative), BIT FOR BIT against the LINUX values.
##
## Its distance carves the corundum ground of every chunk and every server collision shape, and moves
## the rim vertices (crack_rim_snap). The hash under it, fract(sin(dot) × 43758.5453123), turns the last
## bit of a sine into a different value, so what these tests really pin is the sine.
##
## The reference is Linux — glibc, the server's platform — frozen in fixtures/crack_voronoi_linux.b64,
## NOT the local GDScript. The first Windows CI run is why: the C# twin gave the Linux values there, bit
## for bit, while the GDScript on the Windows Godot build did not (0.07216454914327 against
## 0.07216454902143 on the first point, ~30 nm) — that build's sin is not glibc's. So on Windows the C#
## brings a client's cracks onto the server's, and comparing it to the local GDScript would fail it for
## being right. The C#-against-GDScript comparison runs only where the engine's own sin is the reference.
##
## Regenerate the file only on Linux, with the GDScript path, and only when the crack arithmetic changes
## on purpose (see TestCrackVoronoiPoints).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_voronoi_native.gd

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


## THE claim: the C# gives the server's values, on whatever platform runs this.
func test_the_csharp_gives_the_linux_values() -> void:
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var got: Array = _diff(_values(true), want)
	assert_eq(got[0], 0, "the C# Voronoi, rim snap and carve equal Linux bit for bit: %s" % got[1])


## And where the engine's own sin IS glibc's (Linux), the C# and the GDScript twin agree everywhere —
## the GDScript being the readable reference the C# was written from. On a platform whose engine sin
## differs (the Windows Godot build), the GDScript is not the reference, and this says so instead.
func test_the_gdscript_agrees_where_the_engine_is_the_reference() -> void:
	var want: PackedFloat64Array = TestCrackVoronoiPoints.linux_values()
	var gdscript: PackedFloat64Array = _values(false)
	var off: Array = _diff(gdscript, want)
	if int(off[0]) > 0:
		pending("the engine's sin on %s is not glibc's (%d of %d values off, e.g. %s): the GDScript is "
				% [OS.get_name(), off[0], want.size(), off[1]]
				+ "not the reference here — the C# is, see test_the_csharp_gives_the_linux_values")
		return
	var got: Array = _diff(_values(true), gdscript)
	assert_eq(got[0], 0, "C# and GDScript equal: %s" % got[1])
