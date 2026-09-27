class_name TestCrackVoronoiPoints
extends RefCounted
## The points test_crack_voronoi_native.gd asks the crack Voronoi about, and the reference file holding
## what one machine answered there (Fedora, glibc 2.43, GDScript path). A reference to stay CLOSE to, not
## to equal: libms differ in the last bit of a sine — see test_crack_voronoi_native.gd.
## The points are deterministic on every platform: an integer RNG, IEEE arithmetic and sqrt only — no
## sine — so every machine asks about exactly the same points.

const RADIUS: float = 6356000.0
const SPACING: float = 220.0
## Voronoi and crack queries, computed on the reference machine by the GDScript path.
const REFERENCE: String = "res://test/unit/fixtures/crack_voronoi_linux.b64"


## Cell-scale points all over the sphere, where the chunks ask.
static func sphere_points() -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var out := PackedVector3Array()
	for i: int in range(500):
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		out.append(d * (RADIUS / SPACING))
	return out


## On and 1e-12 either side of cell boundaries, where floor() and the closest-cell comparisons turn.
static func boundary_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	for ix: int in range(-3, 4):
		for k: int in range(16):
			var x := Vector3(float(ix) + 1000.0, -20000.0 + float(k) * 0.25, 13.0 - float(k) * 1.0e-9)
			out.append_array([x, x + Vector3(1.0e-12, 0, 0), x - Vector3(0, 1.0e-12, 0)])
	return out


## Unit directions for crack_rim_snap and crack_offset.
static func query_dirs() -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var out := PackedVector3Array()
	for i: int in range(300):
		out.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized())
	return out


## The reference values, in the order the three lists above give them: 4 doubles per Voronoi point,
## then 5 (snap xyzw, offset) per query direction.
static func linux_values() -> PackedFloat64Array:
	var f := FileAccess.open(REFERENCE, FileAccess.READ)
	if f == null:
		return PackedFloat64Array()
	var raw: PackedByteArray = Marshalls.base64_to_raw(f.get_as_text().strip_edges())
	f.close()
	return raw.to_float64_array()
