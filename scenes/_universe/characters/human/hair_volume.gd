class_name HairVolume
extends RefCounted

## How much light a head of hair stops, voxel by voxel: its hairs' cross-section per unit of volume (an
## extinction, 1/m), in the frame of the style's mesh (the neutral head). A head of hair is rigid and shared
## by everyone wearing its style, so this is made once per style, with its mesh (HairStrands.mesh_of), and the
## hair shader marches it towards each light: the hairs under the surface of the hair sit in the shadow of
## those above them, as on a real head, where the hairs alone draw a flat, evenly lit mass.
##
## Also the light the hair lets in from all around (ambient occlusion): the mean, over the six axes, of the
## hair's optical depth from outside to each voxel -- a running sum along each axis, no ray marching.
##
## Read-only data in, arrays out: built on the body bakes' worker threads; its texture is made on first use.

## Cells along the longest side of the hair's box: a head of hair some 1-2 cm per cell.
const RESOLUTION: int = 32
## Cells of empty room kept around the hair (a voxel's blur reaches one over).
const MARGIN: int = 1

## Corner of the volume, in the mesh's frame (m).
var origin: Vector3
## Size of the volume (m): origin + size is the far corner.
var size: Vector3
## Cells along x, y and z.
var dims: Vector3i
## Side of a cell (m).
var cell: float
## Two floats per cell, x fastest then y then z: R = the extinction (1/m), G = the optical depth from outside,
## averaged over the six axes (no unit).
var data: PackedFloat32Array

var _texture: ImageTexture3D


## The volume of the hairs of a strand mesh (HairStrands.build's arrays): [param points] hairs' points, two
## vertices each, [param size] points per hair, [param width] a hair's width (m). A hair the shader discards
## for the root's density (COLOR: ident > density * 1.4 + 0.1) stops no light.
## In C# (HairGroomNative.Density) when it is there; [param native] false: these loops, its reference.
static func build(pos: PackedVector3Array, col: PackedColorArray, size: int, width: float, native: bool = true) -> HairVolume:
	var v := HairVolume.new()
	var twin: Object = HairGroom.native_twin() if native else null
	if twin != null and twin.has_method(&"Density"):
		var got: Array = twin.call(&"Density", pos, col, size, width, RESOLUTION, MARGIN)
		if not got.is_empty():
			v.origin = got[0]
			v.size = got[1]
			v.dims = got[2]
			v.cell = got[3]
			v.data = got[4]
		return v
	var count: int = pos.size() / (2 * size) if size > 1 else 0
	if count == 0:
		return v
	var lo := pos[0]
	var hi := pos[0]
	for i in range(0, pos.size(), 2):
		lo = lo.min(pos[i])
		hi = hi.max(pos[i])
	var extent: Vector3 = hi - lo
	v.cell = maxf(maxf(extent.x, maxf(extent.y, extent.z)) / float(RESOLUTION - 2 * MARGIN), 0.001)
	v.dims = Vector3i(ceili(extent.x / v.cell) + 2 * MARGIN, ceili(extent.y / v.cell) + 2 * MARGIN,
			ceili(extent.z / v.cell) + 2 * MARGIN).clamp(Vector3i.ONE, Vector3i.ONE * RESOLUTION)
	v.origin = lo - Vector3.ONE * (MARGIN * v.cell)
	v.size = Vector3(v.dims) * v.cell
	var nx: int = v.dims.x
	var nxy: int = v.dims.x * v.dims.y
	var cells: int = nxy * v.dims.z
	var sigma := PackedFloat32Array()
	sigma.resize(cells)
	var per_cell: float = width / (v.cell * v.cell * v.cell)
	var inv: float = 1.0 / v.cell
	var top := v.dims - Vector3i.ONE
	for h in count:
		var base: int = h * size * 2
		if col[base].g > col[base].a * 1.4 + 0.1:
			continue
		var prev: Vector3 = pos[base]
		for k in range(1, size):
			var p: Vector3 = pos[base + k * 2]
			var at := Vector3i(((prev + p) * 0.5 - v.origin) * inv).clamp(Vector3i.ZERO, top)
			sigma[at.x + at.y * nx + at.z * nxy] += prev.distance_to(p) * per_cell
			prev = p
	sigma = _blur(sigma, v.dims)
	var depth: PackedFloat32Array = _depth_from_outside(sigma, v.dims, v.cell)
	v.data.resize(cells * 2)
	for i in cells:
		v.data[i * 2] = sigma[i]
		v.data[i * 2 + 1] = depth[i]
	return v


## The extinction at a point of the mesh's frame (1/m; nearest cell, for tests and tools).
func extinction_at(p: Vector3) -> float:
	if data.is_empty():
		return 0.0
	var at := Vector3i(((p - origin) / cell).floor())
	if at.x < 0 or at.y < 0 or at.z < 0 or at.x >= dims.x or at.y >= dims.y or at.z >= dims.z:
		return 0.0
	return data[(at.x + at.y * dims.x + at.z * dims.x * dims.y) * 2]


## The ambient light's share that reaches a point of the mesh's frame, 0..1 (nearest cell), at [param scale]
## the shader's extinction_scale.
func ambient_at(p: Vector3, scale: float = 1.0) -> float:
	if data.is_empty():
		return 1.0
	var at := Vector3i(((p - origin) / cell).floor()).clamp(Vector3i.ZERO, dims - Vector3i.ONE)
	return exp(-scale * data[(at.x + at.y * dims.x + at.z * dims.x * dims.y) * 2 + 1])


## The volume as a 3D texture (RG float), made on first call: on the main thread (a material's).
func texture() -> ImageTexture3D:
	if _texture != null or data.is_empty():
		return _texture
	var slices: Array[Image] = []
	var slice_floats: int = dims.x * dims.y * 2
	for z in dims.z:
		var floats: PackedFloat32Array = data.slice(z * slice_floats, (z + 1) * slice_floats)
		slices.append(Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RGF, floats.to_byte_array()))
	_texture = ImageTexture3D.new()
	_texture.create(Image.FORMAT_RGF, dims.x, dims.y, dims.z, false, slices)
	return _texture


## A [1, 2, 1] / 4 blur along each axis: a hair's cross-section spread over the cells around it, so the
## shadows have no cell edges.
static func _blur(src: PackedFloat32Array, dims: Vector3i) -> PackedFloat32Array:
	var a := src
	var steps: Array[int] = [1, dims.x, dims.x * dims.y]
	var counts: Array[int] = [dims.x, dims.y, dims.z]
	for axis in 3:
		var b := PackedFloat32Array()
		b.resize(a.size())
		var step: int = steps[axis]
		var n: int = counts[axis]
		for i in a.size():
			var k: int = (i / step) % n
			var here: float = a[i]
			var before: float = a[i - step] if k > 0 else 0.0
			var after: float = a[i + step] if k < n - 1 else 0.0
			b[i] = 0.5 * here + 0.25 * (before + after)
		a = b
	return a


## Optical depth from outside to each cell's centre along the six axes (running sums of extinction x cell),
## folded into one depth whose exp(-depth) is the six directions' mean transmittance.
static func _depth_from_outside(sigma: PackedFloat32Array, dims: Vector3i, cell: float) -> PackedFloat32Array:
	var cells: int = sigma.size()
	var light := PackedFloat32Array()
	light.resize(cells)
	var steps: Array[int] = [1, dims.x, dims.x * dims.y]
	var counts: Array[int] = [dims.x, dims.y, dims.z]
	for axis in 3:
		var step: int = steps[axis]
		var n: int = counts[axis]
		for i in cells:
			if (i / step) % n != 0:
				continue
			# A line along this axis from cell i: summed from each end, half a cell short of each centre.
			var tau: float = 0.0
			for k in n:
				var c: int = i + k * step
				light[c] += exp(-(tau + 0.5 * sigma[c] * cell))
				tau += sigma[c] * cell
			tau = 0.0
			for k in range(n - 1, -1, -1):
				var c: int = i + k * step
				light[c] += exp(-(tau + 0.5 * sigma[c] * cell))
				tau += sigma[c] * cell
	var depth := PackedFloat32Array()
	depth.resize(cells)
	for i in cells:
		depth[i] = -log(maxf(light[i] / 6.0, 1e-6))
	return depth
