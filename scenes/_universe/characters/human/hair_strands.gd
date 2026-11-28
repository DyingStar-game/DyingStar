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
## Levels of detail: [error (m), share of the hairs kept]. A level shows once its error is under a pixel
## (times the viewport's mesh_lod_threshold). A head of hair's shader thins its hairs out smoothly ahead of
## the level the engine draws and widens those left by as much, so the hair covers as much at any level.
const LODS: Array = [[0.0015, 0.5], [0.004, 0.25], [0.009, 0.12], [0.02, 0.05]]

## How a head of hair's vertices are stored: 20 bytes where the plain layout took 32 (video memory: 9 to 23 MiB a
## head of hair, one per avatar met, 2026-11-27). The engine's compression: the position in 16 bits over the hair's
## box (under 0.01 mm), the normal (away from the skull) in 32. No UV nor tangent: CUSTOM0 = the hair's direction
## (xyz, 8 bits a component: under half a degree) and how far along it (w, 0 root .. 1 tip); the side of the strip
## is the vertex's parity. human_hair_strands.gdshader knows the layout by its CUSTOM0 (0 in the head's eyebrows,
## lashes and beard). Not the tangent slot: the compression keeps a tangent as an angle about the normal, and a
## hair's direction is not at right angles to the skull.
const PACKED_FORMAT: int = (Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
		| (Mesh.ARRAY_CUSTOM_RGBA8_SNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT))

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


## How much light the style's hairs stop, cell by cell (HairVolume), made with its mesh; null for a style
## whose mesh is not made yet (never builds it: a material asks, on the main thread) or has no hairs.
static func volume_of(asset: HumanAssetData) -> HairVolume:
	_lock.lock()
	var mesh: ArrayMesh = _meshes.get(asset.get_instance_id())
	_lock.unlock()
	if mesh == null or not mesh.has_meta(&"hair_volume"):
		return null
	return mesh.get_meta(&"hair_volume") as HairVolume


## What a style's material needs to keep its coverage across the levels of detail (the strands shader's
## lod_* parameters): {hairs, vertices_per_hair, bounds (the hairs' box, before the room the shader gives
## them)}; empty while the mesh is not made (never builds it).
static func lod_of(asset: HumanAssetData) -> Dictionary:
	_lock.lock()
	var mesh: ArrayMesh = _meshes.get(asset.get_instance_id())
	_lock.unlock()
	if mesh == null or not mesh.has_meta(&"hair_lod"):
		return {}
	return mesh.get_meta(&"hair_lod")


## How the style's hairs move (HairMotionBinding), made with its mesh; null for a style whose mesh is not made
## yet (never builds it) or none of whose hairs move.
static func motion_of(asset: HumanAssetData) -> HairMotionBinding:
	_lock.lock()
	var mesh: ArrayMesh = _meshes.get(asset.get_instance_id())
	_lock.unlock()
	if mesh == null or not mesh.has_meta(&"hair_motion"):
		return null
	return mesh.get_meta(&"hair_motion") as HairMotionBinding


## Forget the mesh made for [param asset] (a grown cut no longer used: HairGroom's cache let it go).
static func forget(asset: HumanAssetData) -> void:
	_lock.lock()
	_meshes.erase(asset.get_instance_id())
	_lock.unlock()
	CharacterMaterials.forget_style(asset)


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


## CUSTOM0 of PACKED_FORMAT from the plain arrays: per vertex, the direction (tangent xyz) and the share along the
## hair (uv.y), as signed bytes. Any thread; the C# twin when there is one.
static func pack(tan: PackedFloat32Array, uv: PackedVector2Array, native: bool = true) -> PackedByteArray:
	var twin: Object = HairGroom.native_twin() if native else null
	if twin != null:
		return twin.call("PackStrands", tan, uv)
	var c0 := PackedByteArray()
	c0.resize(uv.size() * 4)
	for v in uv.size():
		var at: int = v * 4
		c0.encode_s8(at, _snorm(tan[at]))
		c0.encode_s8(at + 1, _snorm(tan[at + 1]))
		c0.encode_s8(at + 2, _snorm(tan[at + 2]))
		c0.encode_s8(at + 3, _snorm(uv[v].y))
	return c0


## -1..1 as a signed byte (the engine's RGBA8_SNORM reads it back as x / 127).
static func _snorm(x: float) -> int:
	return clampi(roundi(x * 127.0), -127, 127)


static func _mesh(asset: HumanAssetData, guides: int, children: int, pos: PackedVector3Array, nrm: PackedVector3Array,
		tan: PackedFloat32Array, uv: PackedVector2Array, col: PackedColorArray, index: PackedInt32Array) -> ArrayMesh:
	var size: int = asset.strand_size
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_CUSTOM0] = pack(tan, uv)
	arrays[Mesh.ARRAY_INDEX] = index
	var lods: Dictionary = {}
	var per_child: int = guides * (size - 1) * 6
	for lod: Array in LODS:
		var kept: int = maxi(int(children * guides * float(lod[1])), 1) * (size - 1) * 6
		if kept < index.size() and per_child > 0:
			lods[float(lod[0])] = index.slice(0, kept)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods, PACKED_FORMAT)
	mesh.surface_set_name(0, "hair:%s" % asset.id)
	# What the shader needs to keep the hair's coverage whatever level of detail is drawn (lod_of()).
	mesh.set_meta(&"hair_lod", {"hairs": guides * children, "guides": guides, "vertices_per_hair": size * 2,
			"bounds": mesh.get_aabb()})
	# The strips have no width until the shader gives them one: room for it, and for the affine fit -- and for
	# the hairs' swing when they move (motion_of()).
	var room: float = 0.01
	if asset.kind == &"hair":
		mesh.set_meta(&"hair_volume", HairVolume.build(pos, col, size, HAIR_WIDTH))
		var motion: HairMotionBinding = HairMotionBinding.build(asset)
		if motion != null:
			mesh.set_meta(&"hair_motion", motion)
			room = HairMotionBinding.MAX_SWING
	mesh.custom_aabb = mesh.get_aabb().grow(room)
	return mesh
