class_name HumanMorph
extends RefCounted

## The heavy loops of baking a body from the bank: target deltas summed on the basemesh, worn assets
## fitted on it, render surfaces (normals, tangents) and the triangles left visible under clothes.
##
## Each runs in C# (native/HumanMorphNative.cs, ~50x faster) when DyingStar.dll carries it, else here:
## this file is the reference -- test_human_morph_native.gd holds the two equal -- and the fallback.
## Read-only after creation (one per bank, shared): safe to call from the builder's worker threads.

const NATIVE_PATH: String = "res://scenes/_universe/characters/human/native/HumanMorphNative.cs"

static var _shared: HumanMorph = null
static var _shared_mutex := Mutex.new()

var bank: HumanBank
var _native: Object = null


## The morph of the game's bank (HumanBuilder.prepare / warm make it; made here, on the calling thread,
## if asked for before).
static func shared() -> HumanMorph:
	_shared_mutex.lock()
	if _shared == null:
		_shared = HumanMorph.new(load(HumanBank.PATH) as HumanBank, native_instance())
	var out: HumanMorph = _shared
	_shared_mutex.unlock()
	return out


static func set_shared(morph: HumanMorph) -> void:
	_shared_mutex.lock()
	_shared = morph
	_shared_mutex.unlock()


## A fresh, unconfigured instance of the C# twin when DyingStar.dll really carries it, else null. Main
## thread: C# objects are made there (one made on a worker crashed the engine at exit).
static func native_instance() -> Object:
	var script: Script = NativeScript.load_usable(NATIVE_PATH,
			["Configure", "Morph", "WithTarget", "Fit", "Surface", "SurfacePicked", "VisibleTriangles"])
	return script.new() if script != null else null


## [param native]: an unconfigured C# twin (native_instance()), or null for the GDScript loops alone.
## Configuring it -- copying the bank's targets in -- is safe on a worker.
func _init(the_bank: HumanBank, native: Object = null) -> void:
	bank = the_bank
	if native == null or bank == null:
		return
	_native = native
	_native.call("Configure", bank.base, bank.delta, bank.sparse_index, bank.target_delta_start, bank.target_count,
			bank.target_dense, bank.target_sparse_start, bank.target_scale)


func is_native() -> bool:
	return _native != null


## Compact body vertices with the targets (bank indices) at the given weights.
func morph(targets: PackedInt32Array, weights: PackedFloat32Array) -> PackedVector3Array:
	if _native != null:
		return _native.call("Morph", targets, weights)
	return morph_gd(targets, weights)


## [param points] (a baked body) with one more target added at [param weight]: a face unit's shape.
func with_target(points: PackedVector3Array, target: int, weight: float) -> PackedVector3Array:
	if _native != null:
		return _native.call("WithTarget", points, target, weight)
	return with_target_gd(points, target, weight)


## An asset's vertices fitted on a body (MakeHuman's MHCLO rule).
func fit(body: PackedVector3Array, asset: HumanAssetData) -> PackedVector3Array:
	if _native != null:
		return _native.call("Fit", body, asset.refs, asset.weights, asset.offsets, asset.scale_pairs, asset.scale_ref)
	return fit_gd(body, asset.refs, asset.weights, asset.offsets, asset.scale_pairs, asset.scale_ref)


## [positions, normals, tangents] of a render surface over source points (see surface_gd).
func surface(points: PackedVector3Array, map: PackedInt32Array, index: PackedInt32Array,
		tangent_ref: PackedFloat32Array, shift: Vector3) -> Array:
	if _native != null:
		return _native.call("Surface", points, map, index, tangent_ref, shift)
	return surface_gd(points, map, index, tangent_ref, shift)


## surface() over the whole mesh, returned for the render vertices [param picks] only (in that order).
func surface_picked(points: PackedVector3Array, map: PackedInt32Array, index: PackedInt32Array,
		tangent_ref: PackedFloat32Array, shift: Vector3, picks: PackedInt32Array) -> Array:
	if _native != null:
		return _native.call("SurfacePicked", points, map, index, tangent_ref, shift, picks)
	return surface_picked_gd(points, map, index, tangent_ref, shift, picks)


## The triangles none of whose source vertices is hidden.
func visible_triangles(index: PackedInt32Array, map: PackedInt32Array, hidden: PackedByteArray) -> PackedInt32Array:
	if _native != null:
		return _native.call("VisibleTriangles", index, map, hidden)
	return visible_triangles_gd(index, map, hidden)


# --- the reference loops -------------------------------------------------------------------------------

## A target's deltas are int16 times its scale (m), x y z per vertex; a dense target covers every compact
## vertex in order, a sparse one the vertices listed in sparse_index (uint16). Summed in doubles.
func morph_gd(targets: PackedInt32Array, weights: PackedFloat32Array) -> PackedVector3Array:
	var n: int = bank.base.size()
	var x := PackedFloat64Array()
	var y := PackedFloat64Array()
	var z := PackedFloat64Array()
	x.resize(n)
	y.resize(n)
	z.resize(n)
	for i in n:
		x[i] = bank.base[i].x
		y[i] = bank.base[i].y
		z[i] = bank.base[i].z
	for k in targets.size():
		var t: int = targets[k]
		var s: float = float(bank.target_scale[t]) * float(weights[k])
		var o: int = bank.target_delta_start[t] * 2
		var c: int = bank.target_count[t]
		var dense: bool = bank.target_dense[t] != 0
		var si: int = bank.target_sparse_start[t] * 2
		for i in c:
			var v: int = i if dense else bank.sparse_index.decode_u16(si + i * 2)
			x[v] += bank.delta.decode_s16(o) * s
			y[v] += bank.delta.decode_s16(o + 2) * s
			z[v] += bank.delta.decode_s16(o + 4) * s
			o += 6
	var out := PackedVector3Array()
	out.resize(n)
	for i in n:
		out[i] = Vector3(x[i], y[i], z[i])
	return out


func with_target_gd(points: PackedVector3Array, target: int, weight: float) -> PackedVector3Array:
	var out: PackedVector3Array = points.duplicate()
	var s: float = float(bank.target_scale[target]) * weight
	var o: int = bank.target_delta_start[target] * 2
	var dense: bool = bank.target_dense[target] != 0
	var si: int = bank.target_sparse_start[target] * 2
	for i in bank.target_count[target]:
		var v: int = i if dense else bank.sparse_index.decode_u16(si + i * 2)
		out[v] += Vector3(bank.delta.decode_s16(o), bank.delta.decode_s16(o + 2), bank.delta.decode_s16(o + 4)) * s
		o += 6
	return out


## Per asset vertex: sum of 3 weighted body references + its offset scaled per axis by the body's growth
## between that axis' two reference vertices (1 when the axis has none).
func fit_gd(body: PackedVector3Array, refs: PackedInt32Array, weights: PackedFloat32Array, offsets: PackedVector3Array,
		scale_pairs: PackedInt32Array, scale_ref: PackedFloat32Array) -> PackedVector3Array:
	var size := Vector3.ONE
	for axis in 3:
		var a: int = scale_pairs[axis * 2]
		var b: int = scale_pairs[axis * 2 + 1]
		if a >= 0 and b >= 0:
			size[axis] = absf(body[a][axis] - body[b][axis]) / scale_ref[axis]
	var out := PackedVector3Array()
	out.resize(offsets.size())
	for i in offsets.size():
		var r: int = i * 3
		out[i] = body[refs[r]] * weights[r] + body[refs[r + 1]] * weights[r + 1] + body[refs[r + 2]] * weights[r + 2] \
				+ offsets[i] * size
	return out


## Positions (points[map[i]] + shift), normals and tangents of a render surface. Normals are area-weighted
## face normals summed on the SOURCE vertices, so a UV seam (two render vertices, one source) is not a
## crease. index is clockwise, Godot's front face. The reference tangent is made perpendicular to the new
## normal, keeping its handedness.
func surface_gd(points: PackedVector3Array, map: PackedInt32Array, index: PackedInt32Array,
		tangent_ref: PackedFloat32Array, shift: Vector3) -> Array:
	var acc := PackedVector3Array()
	acc.resize(points.size())
	for t in range(0, index.size() - 2, 3):
		var a: int = map[index[t]]
		var b: int = map[index[t + 1]]
		var c: int = map[index[t + 2]]
		var face: Vector3 = (points[c] - points[a]).cross(points[b] - points[a])
		acc[a] += face
		acc[b] += face
		acc[c] += face
	var n: int = map.size()
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	pos.resize(n)
	nrm.resize(n)
	tan.resize(n * 4)
	for i in n:
		var s: int = map[i]
		pos[i] = points[s] + shift
		var nv: Vector3 = acc[s]
		nv = nv.normalized() if nv.length_squared() > 1e-40 else Vector3.UP
		nrm[i] = nv
		var tv := Vector3(tangent_ref[i * 4], tangent_ref[i * 4 + 1], tangent_ref[i * 4 + 2])
		tv -= nv * nv.dot(tv)
		if tv.length_squared() > 1e-24:
			tv = tv.normalized()
		else:
			tv = (Vector3.RIGHT if absf(nv.x) < 0.9 else Vector3.UP).cross(nv).normalized()
		tan[i * 4] = tv.x
		tan[i * 4 + 1] = tv.y
		tan[i * 4 + 2] = tv.z
		tan[i * 4 + 3] = tangent_ref[i * 4 + 3]
	return [pos, nrm, tan]


func surface_picked_gd(points: PackedVector3Array, map: PackedInt32Array, index: PackedInt32Array,
		tangent_ref: PackedFloat32Array, shift: Vector3, picks: PackedInt32Array) -> Array:
	var full: Array = surface_gd(points, map, index, tangent_ref, shift)
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	for r in picks:
		pos.append(full[0][r])
		nrm.append(full[1][r])
		tan.append_array((full[2] as PackedFloat32Array).slice(r * 4, r * 4 + 4))
	return [pos, nrm, tan]


func visible_triangles_gd(index: PackedInt32Array, map: PackedInt32Array, hidden: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	for t in range(0, index.size() - 2, 3):
		var a: int = index[t]
		var b: int = index[t + 1]
		var c: int = index[t + 2]
		if hidden[map[a]] != 0 or hidden[map[b]] != 0 or hidden[map[c]] != 0:
			continue
		out.append(a)
		out.append(b)
		out.append(c)
	return out
