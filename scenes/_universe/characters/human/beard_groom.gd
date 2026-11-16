class_name BeardGroom
extends RefCounted

## Grows a beard from its settings (BeardCut) on the face (HairHead's beard zones), in the game: a shell of
## stubble and, past SHELL_ONLY_BELOW, short hairs riding the skin (they move with the face's expressions),
## as the HumanAssetData that HumanBuilder takes. The rules are tools/character/hair_groom/groom.py's
## (beard_hairs, skinned_strands): roots drawn where the beard grows, combed down the cheeks and the chin and
## sideways under the nose, kept off the skin. Deterministic; one set of assets per distinct beard, cached.

## Guide hairs of a full beard at density 0.5 (each then gets CHILDREN hairs around it).
const GUIDES: int = 1100
const CHILDREN: int = 4
const CAPACITY: int = 16
## How thick a beard grows in each zone (BeardCut.ZONES order: moustache, chin, cheeks, neck), times its cut's
## coverage there.
const ZONE_THICKNESS: Array[float] = [1.25, 0.8, 0.55, 0.55]
## Levels of detail of the hairs (error in m, share kept): groom.CARD_LODS.
const LODS: Array = [0.004, 0.5, 0.010, 0.25, 0.025, 0.125]

static var _cache: Dictionary = {}  # beard key -> Array[HumanAssetData]
static var _order: Array[String] = []
static var _mutex := Mutex.new()

var _head: HairHead
var _rng := RandomNumberGenerator.new()


## The assets of [param cut]: [shell, hairs] (hairs absent for a stubble), made on first use (any thread).
static func assets_for(cut: BeardCut) -> Array[HumanAssetData]:
	var key: String = cut.key()
	_mutex.lock()
	var found: Variant = _cache.get(key)
	if found != null:
		_order.erase(key)
		_order.append(key)
		_mutex.unlock()
		return found
	_mutex.unlock()
	var made: Array[HumanAssetData] = BeardGroom.new(HairHead.shared()).grow(cut)
	_mutex.lock()
	if _cache.has(key):
		made = _cache[key]
	else:
		_cache[key] = made
		_order.append(key)
		while _order.size() > CAPACITY:
			_cache.erase(_order.pop_front())
	_mutex.unlock()
	return made


func _init(head: HairHead) -> void:
	_head = head


func grow(cut: BeardCut) -> Array[HumanAssetData]:
	_rng.seed = hash(cut.key())
	var density := PackedFloat32Array()
	var under_nose := PackedFloat32Array()
	density.resize(_head.beard_vertex.size())
	under_nose.resize(density.size())
	for v in density.size():
		var d: float = 0.0
		for z in BeardCut.ZONES.size():
			d = maxf(d, _head.beard_zones[v * 4 + z] * cut.coverage(z) * ZONE_THICKNESS[z])
		# The sides of the mouth (in the chin's zone, beside the lips) join the moustache to the chin.
		var p: Vector3 = _head.beard_position[v]
		var mouth_side: float = smoothstep(0.018, 0.026, absf(p.x)) * smoothstep(0.048, 0.036, absf(p.x))
		if mouth_side > 0.0 and _head.beard_zones[v * 4 + 1] > 0.0:
			d = minf(d, lerpf(0.0, 1.0, cut.connect) + (1.0 - mouth_side))
		density[v] = d
		under_nose[v] = _head.beard_zones[v * 4]
	# First the skin's shade under the beard, then its stubble or its hairs over it.
	var out: Array[HumanAssetData] = [_shell(cut, density, true)]
	if cut.shell_only():
		out.append(_shell(cut, density, false))
	else:
		var hairs: HumanAssetData = _hairs(cut, density, under_nose)
		if hairs != null:
			out.append(hairs)
	return out


## The face's triangles where the beard grows, lifted off the skin. [param shade]: the skin seen through the
## beard (style "scalp", human_hair_scalp.gdshader), one layer as opaque as the beard is dense. Else a
## stubble's hairs seen end-on (style "shell", human_hair_shell.gdshader): its cap of dots (no more than the
## shell's cap_share of them, over the shade: a whole cap drew a black block over the lip), then the tips, then
## the layer between.
func _shell(cut: BeardCut, density: PackedFloat32Array, shade: bool) -> HumanAssetData:
	var heights: PackedFloat32Array = [0.0] if shade else [0.0, 1.0, 0.5]  # the cap and the tips: from afar enough
	var height: float = clampf(cut.hair_length(), 0.0012, 0.004)
	var first: float = 0.0003
	var over: float = 0.0 if cut.shell_only() else 1.0  # hairs lie over it
	var cover: float = clampf(cut.density * 1.6, 0.0, 1.0)
	var render: int = _head.beard_shell_vertex.size()
	var asset := HumanAssetData.new()
	asset.kind = &"beard"
	asset.part = 0
	asset.id = StringName("beard_" + cut.key())
	asset.gender = &"male"
	asset.style = &"scalp" if shade else &"shell"
	asset.albedo = load("res://assets/_universe/characters/human/hair/hair_shell.png")
	asset.scale_pairs = PackedInt32Array([-1, -1, -1, -1, -1, -1])
	asset.scale_ref = PackedFloat32Array([1.0, 1.0, 1.0])
	var tris := PackedInt32Array()
	for t in _head.beard_shell_index.size() / 3:
		var any: bool = false
		for j in 3:
			any = any or density[_head.beard_shell_vertex[_head.beard_shell_index[t * 3 + j]]] > 0.004
		if any:
			tris.append_array(_head.beard_shell_index.slice(t * 3, t * 3 + 3))
	for layer in heights.size():
		var t: float = heights[layer]
		# The shade under a stubble's cap, not level with it (they would fight for the same depth).
		var lift: float = first * 0.5 if shade else first + (height - first) * t
		for r in render:
			var v: int = _head.beard_shell_vertex[r]
			var compact: int = _head.beard_vertex[v]
			asset.refs.append_array([compact, compact, compact])
			asset.weights.append_array([1.0, 0.0, 0.0])
			asset.offsets.append(_head.beard_normal[v] * lift)
			asset.vertex.append(layer * render + r)
			asset.uv.append(_head.beard_shell_uv[r])
			asset.tangent.append_array(_head.beard_shell_tangent.slice(r * 4, r * 4 + 4))
			asset.bones.append_array([_head.head_bone, 0, 0, 0])
			asset.bone_weights.append_array([1.0, 0.0, 0.0, 0.0])
			asset.color.append(Color(over, _rng.randf(), t, density[v] * cover))
	for layer in heights.size():
		for k in tris.size():
			asset.index.append(tris[k] + layer * render)
	if heights.size() > 1:
		asset.lods = PackedFloat32Array([0.008, 1.0 / heights.size()])
	return asset


func _hairs(cut: BeardCut, density: PackedFloat32Array, under_nose: PackedFloat32Array) -> HumanAssetData:
	var tris: PackedInt32Array = _head.beard_triangles
	var tri_count: int = tris.size() / 3
	var cumulative := PackedFloat64Array()
	cumulative.resize(tri_count)
	var total: float = 0.0
	var full: float = 0.0
	for t in tri_count:
		var a: Vector3 = _head.beard_position[tris[t * 3]]
		var area: float = (_head.beard_position[tris[t * 3 + 1]] - a).cross(_head.beard_position[tris[t * 3 + 2]] - a).length()
		total += area * (density[tris[t * 3]] + density[tris[t * 3 + 1]] + density[tris[t * 3 + 2]]) / 3.0
		full += area
		cumulative[t] = total
	if total <= 0.0:
		return null
	var hair: float = cut.hair_length()
	var count: int = roundi(GUIDES * total / full * 1.6 * lerpf(0.5, 1.5, cut.density))
	var seg: int = clampi(3 + int(hair / 0.025), 3, 8)
	var n: int = seg + 1
	var strands: Array[PackedVector3Array] = []
	var roots: Array = []  # [i0, i1, i2, bary, normal, root density, layer]
	for _s in count:
		var t: int = mini(cumulative.bsearch(_rng.randf() * total), tri_count - 1)
		var r1: float = sqrt(_rng.randf())
		var r2: float = _rng.randf()
		var bary := Vector3(1.0 - r1, r1 * (1.0 - r2), r1 * r2)
		var i0: int = tris[t * 3]
		var i1: int = tris[t * 3 + 1]
		var i2: int = tris[t * 3 + 2]
		var root: Vector3 = _head.beard_position[i0] * bary.x + _head.beard_position[i1] * bary.y + _head.beard_position[i2] * bary.z
		var normal: Vector3 = (_head.beard_normal[i0] * bary.x + _head.beard_normal[i1] * bary.y + _head.beard_normal[i2] * bary.z).normalized()
		var root_density: float = density[i0] * bary.x + density[i1] * bary.y + density[i2] * bary.z
		var nose: bool = under_nose[i0] * bary.x + under_nose[i1] * bary.y + under_nose[i2] * bary.z > 0.5
		var side: float = 1.0 if root.x >= 0.0 else -1.0
		var comb: Vector3 = (Vector3(side * 1.3, -0.55, 0.05) if nose else Vector3(side * 0.25, -1.0, 0.1)).normalized()
		var length: float = hair * (0.75 if nose else 1.0) * _rng.randf_range(0.65, 1.1)
		var layer: float = _rng.randf()
		var clear: float = 0.0008 + 0.0035 * layer
		var direction: Vector3 = (normal * 0.4 + comb * 0.6).normalized()
		var point: Vector3 = root
		var strand := PackedVector3Array([root])
		for k in seg:
			var t_along: float = float(k + 1) / seg
			# A long beard hangs; its bottom gathers to a point, or stays square.
			var hang: float = smoothstep(0.03, 0.1, hair) * t_along
			var gather := Vector3.ZERO
			if cut.shape == BeardCut.Shape.POINTED:
				gather = Vector3(-point.x * 12.0, -0.3, 0.0) * hang
			elif cut.shape == BeardCut.Shape.SQUARE:
				gather = Vector3(0.0, -0.6, 0.0) * hang
			var want: Vector3 = direction * 0.6 + comb * 0.45 + Vector3.DOWN * hang + gather \
					+ Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()) * 0.14
			var previous: Vector3 = point
			point += want.normalized() * length / seg
			var s: Array = _head.surface(point)
			if float(s[0]) < clear:
				point += (s[1] as Vector3) * (clear - float(s[0]))
			direction = (point - previous).normalized()
			strand.append(point)
		strands.append(strand)
		roots.append([i0, i1, i2, bary, normal, root_density, layer])
	return _skinned(cut, strands, roots, n, hair)


## The hairs as strips riding the skin (groom.skinned_strands): CHILDREN around each grown strand, two
## vertices per point, every vertex tied to its root's triangle.
func _skinned(cut: BeardCut, strands: Array[PackedVector3Array], roots: Array, n: int, hair: float) -> HumanAssetData:
	var asset := HumanAssetData.new()
	asset.kind = &"beard"
	asset.part = 1
	asset.id = StringName("beard_" + cut.key())
	asset.gender = &"male"
	asset.style = &"hairs"
	asset.scale_pairs = PackedInt32Array([-1, -1, -1, -1, -1, -1])
	asset.scale_ref = PackedFloat32Array([1.0, 1.0, 1.0])
	var blocks: Array[PackedInt32Array] = []
	for s in strands.size():
		var r: Array = roots[s]
		var compact := PackedInt32Array([_head.beard_vertex[r[0]], _head.beard_vertex[r[1]], _head.beard_vertex[r[2]]])
		var bary: Vector3 = r[3]
		var root_point: Vector3 = strands[s][0]
		for child in CHILDREN:
			var shift: Vector3 = Vector3.ZERO if child == 0 else Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()) * 0.0012
			var g: float = _rng.randf()
			var first: int = asset.vertex.size()
			var arc: float = 0.0
			var previous: Vector3 = strands[s][0] + shift
			for k in n:
				var p: Vector3 = strands[s][k] + shift
				if k > 0:
					p += Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()) * 0.0005
				arc += p.distance_to(previous)
				previous = p
				var along: Vector3 = (strands[s][mini(k + 1, n - 1)] - strands[s][maxi(k - 1, 0)]).normalized()
				for side in 2:
					asset.refs.append_array(compact)
					asset.weights.append_array([bary.x, bary.y, bary.z])
					asset.offsets.append(p - root_point)
					asset.vertex.append(asset.vertex.size())
					asset.uv.append(Vector2(side, float(k) / (n - 1)))
					asset.tangent.append_array([along.x, along.y, along.z, 1.0])
					asset.normal_fixed.append(r[4])
					asset.bones.append_array([_head.head_bone, 0, 0, 0])
					asset.bone_weights.append_array([1.0, 0.0, 0.0, 0.0])
					asset.color.append(Color(clampf(arc / (hair * 1.15), 0.0, 1.0), g, r[6], r[5]))
			var block := PackedInt32Array()
			for k in n - 1:
				var b: int = first + k * 2
				block.append_array([b, b + 2, b + 1, b + 1, b + 2, b + 3])
			blocks.append(block)
	# Any first share of the triangles is a fair sample of the hairs (the levels of detail are prefixes).
	for k in range(blocks.size() - 1, 0, -1):
		var j: int = _rng.randi() % (k + 1)
		var tmp: PackedInt32Array = blocks[k]
		blocks[k] = blocks[j]
		blocks[j] = tmp
	for block in blocks:
		asset.index.append_array(block)
	asset.lods = PackedFloat32Array(LODS)
	return asset
