class_name HairStrands
extends RefCounted

## A head of hair as hairs: thousands of thin strands, each a strip a fraction of a millimetre wide that
## the shader turns to the camera (human_hair_strands.gdshader) -- not ribbons textured with hair.
##
## A style is a set of guide strands grown on the neutral head (tools/character/hair_groom,
## HumanAssetData.strand_points). The hairs are made here, around the guides, ONCE per style -- one mesh,
## shared by everyone who wears the style, hung on the head bone unskinned (hair is rigid on a head). What
## differs per person is a transform: fit() gives the one that carries the style's roots to where they
## land on that person's scalp, so the hair follows the head's size and proportions.
##
## Read-only data in, a mesh out: mesh_of() is called from the body bakes' worker threads.

## Width of a hair's strip (m). A real hair is ~0.08 mm: a strip stands for a few.
const HAIR_WIDTH: float = 0.0008
## Levels of detail: [error (m), share of the hairs kept]. A level shows once its error is under a pixel;
## the shader keeps a hair at least a pixel wide, so fewer hairs still cover the head.
const LODS: Array = [[0.0015, 0.5], [0.004, 0.25], [0.009, 0.12], [0.02, 0.05]]

static var _meshes: Dictionary = {}  # asset instance id -> ArrayMesh
static var _lock := Mutex.new()


## The mesh of a style's hairs, made on first use (some 0.3 s; any thread).
static func mesh_of(asset: HumanAssetData) -> ArrayMesh:
	_lock.lock()
	var mesh: ArrayMesh = _meshes.get(asset.get_instance_id())
	if mesh == null:
		mesh = build(asset)
		_meshes[asset.get_instance_id()] = mesh
	_lock.unlock()
	return mesh


## Forget the mesh made for [param asset] (a grown cut no longer used: HairGroom's cache let it go).
static func forget(asset: HumanAssetData) -> void:
	_lock.lock()
	_meshes.erase(asset.get_instance_id())
	_lock.unlock()


## Forget the meshes made (tests).
static func clear() -> void:
	_lock.lock()
	_meshes.clear()
	_lock.unlock()


## Number of guide strands of a style.
static func guide_count(asset: HumanAssetData) -> int:
	return asset.strand_points.size() / maxi(asset.strand_size, 1)


## The guides' roots on the neutral head, in order.
static func neutral_roots(asset: HumanAssetData) -> PackedVector3Array:
	var roots := PackedVector3Array()
	var count: int = guide_count(asset)
	roots.resize(count)
	for k in count:
		roots[k] = asset.strand_points[k * asset.strand_size]
	return roots


## The transform that best carries [param from] to [param to] (least squares, any linear part: a head is
## wider, longer or taller than the neutral one, not only bigger). Identity when the points do not span
## space.
static func fit(from: PackedVector3Array, to: PackedVector3Array) -> Transform3D:
	var n: int = mini(from.size(), to.size())
	if n < 4:
		return Transform3D.IDENTITY
	var from_mean := Vector3.ZERO
	var to_mean := Vector3.ZERO
	for i in n:
		from_mean += from[i]
		to_mean += to[i]
	from_mean /= float(n)
	to_mean /= float(n)
	# Normal equations of to - to_mean = B (from - from_mean): B = M * inverse(S), with S the scatter of
	# `from` and M the cross scatter.
	var s := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var m := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	for i in n:
		var p: Vector3 = from[i] - from_mean
		var q: Vector3 = to[i] - to_mean
		s.x += p * p.x
		s.y += p * p.y
		s.z += p * p.z
		m.x += q * p.x
		m.y += q * p.y
		m.z += q * p.z
	if absf(s.determinant()) < 1e-18:
		return Transform3D(Basis.IDENTITY, to_mean - from_mean)
	var linear: Basis = m * s.inverse()
	return Transform3D(linear, to_mean - linear * from_mean)


## Make a style's hairs: around each guide, `children` strands -- rooted within `clump` of it, gathering
## (or spreading) towards the tip, each a little shorter or longer and straying by `frizz` -- as strips of
## two vertices per point. UV.x = the side of the strip (0 or 1), UV.y = along the hair; the tangent is the
## hair's direction; the normal points away from the skull (the hair is lit as the volume it makes);
## colour R = how far along the style's longest strand (what a shorter cut clips), G = a random value per
## hair, B = the layer, A = the density at the root.
## In C# (HairGroomNative.Hairs) when it is there; [param native] false: these loops, its reference.
static func build(asset: HumanAssetData, native: bool = true) -> ArrayMesh:
	var size: int = asset.strand_size
	var guides: int = guide_count(asset)
	var params: Dictionary = asset.strand_params
	var children: int = int(params.get("children", 4))
	var clump: float = float(params.get("clump", 0.004))
	var clump_tip: float = float(params.get("clump_tip", 0.7))
	var frizz: float = float(params.get("frizz", 0.002))
	var longest: float = maxf(float(params.get("longest", 0.1)), 0.001)
	var c: Array = params.get("centre", [0.0, 1.63, 0.0])
	var centre := Vector3(c[0], c[1], c[2])
	var seed_value: int = hash(String(asset.id))
	var twin: Object = HairGroom.native_twin() if native else null
	if twin != null:
		var got: Array = twin.call("Hairs", asset.strand_points, asset.color, size, children, clump, clump_tip, frizz, longest,
				centre, seed_value)
		return _mesh(asset, guides, children, got[0], got[1], got[2], got[3], got[4], got[5])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var points: PackedVector3Array = asset.strand_points
	var hairs: int = guides * children
	var vertex_count: int = hairs * size * 2
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var index := PackedInt32Array()
	pos.resize(vertex_count)
	nrm.resize(vertex_count)
	tan.resize(vertex_count * 4)
	uv.resize(vertex_count)
	col.resize(vertex_count)
	index.resize(hairs * (size - 1) * 6)
	var hair_points := PackedVector3Array()
	hair_points.resize(size)
	var v: int = 0
	var t: int = 0
	var last: float = float(size - 1)
	# Child after child, over all the guides: any first share of the hairs covers the whole head (LODS).
	for child in children:
		for k in guides:
			var first: int = k * size
			var root: Vector3 = points[first]
			var along: Vector3 = (points[first + 1] - root).normalized()
			var outward: Vector3 = (root - centre).normalized()
			var lateral: Vector3 = outward.cross(along)
			lateral = lateral.normalized() if lateral.length_squared() > 1e-6 else outward.cross(Vector3.UP).normalized()
			var forward: Vector3 = lateral.cross(outward)
			var angle: float = rng.randf() * TAU
			var reach: float = clump * sqrt(rng.randf()) if child > 0 else 0.0  # the first hair is the guide itself
			var offset: Vector3 = (lateral * cos(angle) + forward * sin(angle)) * reach
			var length_share: float = 0.78 + 0.26 * rng.randf() if child > 0 else 1.0
			var stray: Vector3 = (lateral * (rng.randf() - 0.5) + outward * (rng.randf() - 0.5)) * 2.0 * frizz
			var phase: float = rng.randf() * TAU
			var waves: float = 1.5 + 2.5 * rng.randf()
			var guide_length: float = 0.0
			for i in size - 1:
				guide_length += points[first + i].distance_to(points[first + i + 1])
			var info: Color = asset.color[k] if k < asset.color.size() else Color(1.0, 0.5, 0.5, 1.0)
			var ident: float = rng.randf()
			for i in size:
				var share: float = float(i) / last
				var at: float = share * length_share * last
				var lower: int = mini(int(at), size - 2)
				var p: Vector3 = points[first + lower].lerp(points[first + lower + 1], at - float(lower))
				hair_points[i] = p + offset * lerpf(1.0, clump_tip, share) + stray * share * sin(phase + share * waves)
			for i in size:
				var share: float = float(i) / last
				var p: Vector3 = hair_points[i]
				var direction: Vector3 = (hair_points[mini(i + 1, size - 1)] - hair_points[maxi(i - 1, 0)]).normalized()
				var normal: Vector3 = (p - centre).normalized()
				var colour := Color(info.r * share * length_share * guide_length / longest, ident, info.b, info.a)
				for side in 2:
					pos[v] = p
					nrm[v] = normal
					tan[v * 4] = direction.x
					tan[v * 4 + 1] = direction.y
					tan[v * 4 + 2] = direction.z
					tan[v * 4 + 3] = 1.0
					uv[v] = Vector2(float(side), share)
					col[v] = colour
					v += 1
				if i < size - 1:
					var a: int = v - 2
					index[t] = a
					index[t + 1] = a + 2
					index[t + 2] = a + 1
					index[t + 3] = a + 1
					index[t + 4] = a + 2
					index[t + 5] = a + 3
					t += 6
	return _mesh(asset, guides, children, pos, nrm, tan, uv, col, index)


static func _mesh(asset: HumanAssetData, guides: int, children: int, pos: PackedVector3Array, nrm: PackedVector3Array,
		tan: PackedFloat32Array, uv: PackedVector2Array, col: PackedColorArray, index: PackedInt32Array) -> ArrayMesh:
	var size: int = asset.strand_size
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TANGENT] = tan
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = index
	var lods: Dictionary = {}
	var per_child: int = guides * (size - 1) * 6
	for lod: Array in LODS:
		var kept: int = maxi(int(children * guides * float(lod[1])), 1) * (size - 1) * 6
		if kept < index.size() and per_child > 0:
			lods[float(lod[0])] = index.slice(0, kept)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
	mesh.surface_set_name(0, "hair:%s" % asset.id)
	# The strips have no width until the shader gives them one: room for it, and for the affine fit.
	mesh.custom_aabb = mesh.get_aabb().grow(0.01)
	return mesh
