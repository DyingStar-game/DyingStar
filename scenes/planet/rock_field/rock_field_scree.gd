@tool
class_name RockFieldScree
## The loose rocks of a rocky_terrain field (RockFieldRelief) on the finest
## chunks: blocks of half a metre to a few metres, more on the steep slopes
## (scree at the foot of the ledges), as MultiMeshes of three low-poly blocks.
##
## CLIENT and editor only, like the grass and the fumarole vents: decoration,
## no collision on either side, so the client and the server cannot disagree
## about them. Their places are a pure function of the chunk (integer hash of
## its quads), so every client sees the same scree.
##
## Two halves, so almost nothing of it runs on the main thread:
##   · [method place] then [method pack], in the chunk WORKER
##     (PlanetChunk.generate_mesh), from the chunk's own grid — positions,
##     normals and the rock mask (CUSTOM1) interpolated over each quad — into
##     the mesh's "rock_scree" meta: one ready MultiMesh buffer per variant,
##     which the disk cache keeps with the mesh;
##   · [method build], on the main thread when the chunk is shown, hands the
##     buffers to the MultiMeshes (12 ms → a copy, for 4000 rocks).
##
## Colour: the ground's own baked vertex colour under the rock (the rock tint
## RockImpurity baked into the chunk), darkened by GROUND_TEXTURE_SHADE — the
## terrain shader multiplies that colour by its texture, so the raw colour
## alone reads as a white pebble on a beige ground.

## Rocks per 100 m² at full intensity, per level (flat … very rugged).
const DENSITY: Array[float] = [0.6, 1.2, 2.0, 3.0, 4.0]
## The density × (1 + this × steepness) — scree gathers on the slopes.
const SLOPE_BOOST := 2.0
## A rock's size is this share of the field's small-block size, × [0.25, 1.6]
## (skewed: pebbles are many, boulders few).
const SIZE_OF_DETAIL := 0.25
## A rock is sunk this share of its size into the ground (bilinear quad vs
## the triangles, and a slope under a flat block).
const SINK := 0.08
## No scree on a chunk coarser than this pitch (m): only the finest LOD shows it.
const MAX_PITCH_M := 40.0
## At most this many rocks per chunk: past it the density is scaled down over
## the whole chunk (never cut off row by row).
const MAX_ROCKS := 4000
## Floats per rock out of [method place]: position xyz (chunk-local), normal xyz, size, yaw,
## ground colour rgb.
const STRIDE := 11
## The ground's vertex colour × this ≈ the colour the terrain shader shows:
## terrain_biome.tres multiplies COLOR by albedo_multiplier = 0.4 (the detail
## texture averages ~1).
const GROUND_TEXTURE_SHADE := 0.42
## Floats per instance in a MultiMesh buffer (3D transform rows + colour).
const BUFFER_STRIDE := 16
## Mesh variants (the yaw hash picks one).
const VARIANTS := 3

static var _meshes: Array[ArrayMesh] = []
static var _material: StandardMaterial3D = null


## The scree of a chunk grid: [param verts] / [param normals] / [param colors]
## hold the (res + 1)² grid vertices first (chunk-local; colors may be empty =
## white), [param rock] the CUSTOM1 quadruples of the same vertices, [param up] the
## chunk centre's direction (the reference of the steepness). Pure;
## [param seed_id] makes it the chunk's own.
static func place(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, rock: PackedFloat32Array, res: int, seed_id: int,
		up: Vector3) -> PackedFloat32Array:
	var stride := res + 1
	# Pass 1: the expected count of every quad, and the chunk's scale.
	var expected := PackedFloat32Array()
	expected.resize(res * res)
	var total := 0.0
	for yi in res:
		for xi in res:
			var i00 := yi * stride + xi
			var i10 := i00 + 1
			var i01 := i00 + stride
			var i11 := i01 + 1
			var amt := (rock[i00 * 4] + rock[i10 * 4] + rock[i01 * 4] + rock[i11 * 4]) * 0.25
			if amt <= 0.01:
				continue
			var level := clampi(int(round(rock[i00 * 4 + 2])) % 8, 0, DENSITY.size() - 1)
			var area := (verts[i10] - verts[i00]).cross(verts[i01] - verts[i00]).length()
			var n_avg := (normals[i00] + normals[i10] + normals[i01] + normals[i11]).normalized()
			var steep := clampf(1.0 - absf(n_avg.dot(up)), 0.0, 1.0)
			var e := DENSITY[level] * amt * (1.0 + SLOPE_BOOST * steep) * area / 100.0
			expected[yi * res + xi] = e
			total += e
	var scale := minf(1.0, float(MAX_ROCKS) / total) if total > 0.0 else 0.0
	# Pass 2: the rocks.
	var out := PackedFloat32Array()
	for yi in res:
		for xi in res:
			var e := expected[yi * res + xi] * scale
			if e <= 0.0:
				continue
			var i00 := yi * stride + xi
			var i10 := i00 + 1
			var i01 := i00 + stride
			var i11 := i01 + 1
			var detail := rock[i00 * 4 + 1]
			var count := int(e)
			if MountainNoise.cell(xi, yi, seed_id, 101) < e - float(count):
				count += 1
			for k in count:
				var u := MountainNoise.cell(xi, yi, seed_id * 7 + k, 103)
				var v := MountainNoise.cell(xi, yi, seed_id * 7 + k, 107)
				var p := verts[i00].lerp(verts[i10], u).lerp(verts[i01].lerp(verts[i11], u), v)
				var nrm := normals[i00].lerp(normals[i10], u).lerp(
						normals[i01].lerp(normals[i11], u), v).normalized()
				var w := MountainNoise.cell(xi, yi, seed_id * 7 + k, 109)
				var size := detail * SIZE_OF_DETAIL * (0.25 + 1.35 * w * w)
				var yaw := MountainNoise.cell(xi, yi, seed_id * 7 + k, 113)
				var col := Color.WHITE
				if not colors.is_empty():
					col = colors[i00].lerp(colors[i10], u).lerp(colors[i01].lerp(colors[i11], u), v)
				out.append_array([p.x, p.y, p.z, nrm.x, nrm.y, nrm.z, size, yaw,
						col.r, col.g, col.b])
	return out


## [method place]'s rocks as one MultiMesh buffer per variant (TRANSFORM_3D +
## colours: the 3×4 transform row by row, then the shade). Pure; the worker
## stores the result in the mesh's "rock_scree" meta.
static func pack(rocks: PackedFloat32Array) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	for v in VARIANTS:
		out.append(PackedFloat32Array())
	for i in rocks.size() / STRIDE:
		var o := i * STRIDE
		var p := Vector3(rocks[o], rocks[o + 1], rocks[o + 2])
		var up := Vector3(rocks[o + 3], rocks[o + 4], rocks[o + 5])
		var size := rocks[o + 6]
		var yaw := rocks[o + 7]
		var ref := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var bx := up.cross(ref).normalized().rotated(up, yaw * TAU)
		var bz := bx.cross(up).normalized()
		bx *= size
		var by := up * (size * 0.6)
		bz *= size
		var org := p - up * (SINK * size)
		var shade := GROUND_TEXTURE_SHADE * (0.8 + 0.3 * fposmod(yaw * 7.31, 1.0))
		out[_variant(yaw)].append_array([bx.x, by.x, bz.x, org.x, bx.y, by.y, bz.y, org.y,
				bx.z, by.z, bz.z, org.z, rocks[o + 8] * shade, rocks[o + 9] * shade,
				rocks[o + 10] * shade, 1.0])
	return out


## The scree node of a chunk mesh carrying the "rock_scree" meta, positioned at
## [param center] (planet-local, the chunk's centre); null without it.
static func build(mesh: Mesh, center: Vector3) -> Node3D:
	if mesh == null or not mesh.has_meta("rock_scree"):
		return null
	var buffers: Array = mesh.get_meta("rock_scree")
	if buffers.size() != VARIANTS:
		return null
	_ensure_meshes()
	var root: Node3D = null
	for v in VARIANTS:
		var buf: PackedFloat32Array = buffers[v]
		var count := buf.size() / BUFFER_STRIDE
		if count == 0:
			continue
		if root == null:
			root = Node3D.new()
			root.name = "RockScree"
			root.position = center
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _meshes[v]
		mm.instance_count = count
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Rocks%d" % v
		mmi.multimesh = mm
		mmi.material_override = _material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mmi)
	return root


static func _variant(yaw: float) -> int:
	return clampi(int(yaw * VARIANTS), 0, VARIANTS - 1)


## Three low-poly blocks (an icosahedron, its vertices pushed by an integer
## hash, then flattened by the caller's basis): angular, ~20 faces each.
static func _ensure_meshes() -> void:
	if not _meshes.is_empty():
		return
	var t := (1.0 + sqrt(5.0)) * 0.5
	var base: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9],
			[5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6],
			[3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for v in VARIANTS:
		var pts: Array[Vector3] = []
		for i in base.size():
			var k := 0.7 + 0.6 * MountainNoise.cell(i, v, 0, 211)
			pts.append(base[i].normalized() * 0.5 * k)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in faces:
			var a: Vector3 = pts[f[0]]
			var b: Vector3 = pts[f[1]]
			var c: Vector3 = pts[f[2]]
			# Godot's front faces wind clockwise seen from outside: the
			# winding normal must point INTO the rock; the shading one out.
			var nrm := (b - a).cross(c - a).normalized()
			if nrm.dot(a + b + c) > 0.0:
				var tmp := b
				b = c
				c = tmp
			else:
				nrm = -nrm
			for p in [a, b, c]:
				st.set_normal(nrm)
				st.add_vertex(p)
		_meshes.append(st.commit())
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.95
