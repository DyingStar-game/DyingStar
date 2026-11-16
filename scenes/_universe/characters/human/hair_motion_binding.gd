class_name HairMotionBinding
extends RefCounted

## What a head of hair needs to move (HairMotion), made once per style with its mesh (HairStrands): the few guide
## strands that are simulated, and how every guide follows them.
##
## The mesh stays shared by everyone who wears the style: an avatar's hair moves in the strands shader, by the
## displacements of the simulated strands written in its row of the hair_motion_rows texture (HairMotion). Each guide
## (and so each of the hairs made around it) follows the two simulated strands nearest it, past the length from its
## root that stays put (HumanAssetData.strand_free). A style none of whose guides may move has no binding: it costs
## nothing.

## Simulated strands per style (at most 64: two indices share one float in the binding).
const SIM_GUIDES: int = 48
## Points of a simulated strand the shader reads: evenly spaced over its free part, from where it stops staying put
## (pinned there) to its tip.
const SAMPLES: int = 8
## Points of a simulated strand at rest, evenly spaced along its whole length, root to tip: the simulation takes its
## SAMPLES from them for whatever fixed length it is given.
const DENSE: int = 24
## strand_free codes: never moves; that many times the shaders' fixed_length (the code is negative).
const RIGID: float = 99.0
const GLOBAL_FIXED: float = -1.0
## How far from its root a tail moves (m): it swings from its tie.
const TAIL_FIXED: float = 0.02
## How far from its root a bun's hair moves (m): it only quivers.
const BUN_FIXED: float = 0.03
## How far from its root a fringe moves (m): it is short.
const FRINGE_FIXED: float = 0.015
## How far from its root a loose cut's hair stays put (m; the shaders' fixed_length). Chosen on the hair motion bench
## (2026-11-16, 3 / 5 / 7 / 10 cm): from 7 cm the top of a long straight cut stays still and a wavy one's barely stirs
## (3 cm), with three quarters of the hair's length still free; shorter, the parting lifted at every turn of the head.
const FIXED_LENGTH: float = 0.07
## Over how far past the fixed length the motion comes in (m).
const FREE_BLEND: float = 0.05
## How far a hair may swing from where it lies (m): the room its mesh's bounds keep for it.
const MAX_SWING: float = 0.25
## Guides per row of the binding texture.
const TEXTURE_WIDTH: int = 256
const NATIVE_PATH: String = "res://scenes/_universe/characters/human/native/HairMotionNative.cs"

static var _native: Object = null  # HairMotionNative for Bind, made on the main thread (adopt_native)
static var _mutex := Mutex.new()

## The style's guides.
var guides: int = 0
## Per simulated strand: the guide it is.
var sims := PackedInt32Array()
## Per simulated strand, DENSE points at rest, in the mesh's frame (root first).
var sim_rest := PackedVector3Array()
## Per simulated strand: its strand_free code, and its length (m).
var sim_free := PackedFloat32Array()
var sim_length := PackedFloat32Array()
## Per guide, 4 floats: its length (m), its strand_free code, the two simulated strands it follows (a * 64 + b),
## the weight of the first.
var binding := PackedFloat32Array()

var _texture: ImageTexture = null


## A fresh C# twin when DyingStar.dll carries it, else null. Main thread (C# objects are made there).
static func native_instance() -> Object:
	var script: Script = NativeScript.load_usable(NATIVE_PATH, ["Bind", "Step", "SetAvatar"])
	return script.new() if script != null else null


## Keep [param native] (native_instance(), main thread) for the bake workers.
static func adopt_native(native: Object) -> void:
	_mutex.lock()
	if _native == null:
		_native = native
	_mutex.unlock()


## The binding of [param asset]'s guides (any thread), or null when none of them may move; by the C# twin when
## there is one and [param native] (~100x faster, the same numbers).
static func build(asset: HumanAssetData, native: bool = true) -> HairMotionBinding:
	var n: int = asset.strand_size
	if n < 2 or asset.strand_free.is_empty():
		return null
	var count: int = asset.strand_points.size() / n
	if asset.strand_free.size() != count:
		return null
	_mutex.lock()
	var twin: Object = _native if native else null
	_mutex.unlock()
	if twin != null:
		var got: Array = twin.call("Bind", asset.strand_points, n, asset.strand_free, SIM_GUIDES, FIXED_LENGTH, DENSE)
		if got.is_empty():
			return null
		var made := HairMotionBinding.new()
		made.guides = count
		made.sims = got[0]
		made.sim_rest = got[1]
		made.sim_free = got[2]
		made.sim_length = got[3]
		made.binding = got[4]
		return made
	var length := PackedFloat32Array()
	length.resize(count)
	var features := PackedVector3Array()  # root, middle, tip per guide
	features.resize(count * 3)
	var movable := PackedInt32Array()
	for k in count:
		var line: PackedVector3Array = asset.strand_points.slice(k * n, (k + 1) * n)
		var along: PackedVector3Array = _resample(line, 3)
		length[k] = _length(line)
		for j in 3:
			features[k * 3 + j] = along[j]
		if length[k] > free_length(asset.strand_free[k], FIXED_LENGTH * 0.5) + 0.01:
			movable.append(k)
	if movable.is_empty():
		return null
	var b := HairMotionBinding.new()
	b.guides = count
	b.sims = _farthest(features, movable, length)
	for s in b.sims:
		b.sim_rest.append_array(_resample(asset.strand_points.slice(s * n, (s + 1) * n), DENSE))
		b.sim_free.append(asset.strand_free[s])
		b.sim_length.append(length[s])
	b.binding.resize(count * 4)
	for k in count:
		b.binding[k * 4] = length[k]
		b.binding[k * 4 + 1] = asset.strand_free[k]
		if asset.strand_free[k] >= RIGID:
			b.binding[k * 4 + 3] = 1.0
			continue
		var best := [INF, 0]
		var second := [INF, 0]
		for i in b.sims.size():
			var d: float = _feature_distance(features, k, b.sims[i])
			if d < best[0]:
				second = best
				best = [d, i]
			elif d < second[0]:
				second = [d, i]
		if second[0] == INF:
			second = best
		var da: float = sqrt(best[0])
		var db: float = sqrt(second[0])
		b.binding[k * 4 + 2] = float(int(best[1]) * 64 + int(second[1]))
		b.binding[k * 4 + 3] = db / (da + db) if da + db > 1e-9 else 1.0
	return b


## How far from its root a guide with strand_free [param code] stays put (m), with the shaders' [param fixed].
static func free_length(code: float, fixed: float) -> float:
	return fixed * -code if code < 0.0 else code


## The binding as a texture (RGBA float, TEXTURE_WIDTH guides a row): made on first call (main thread).
func texture() -> ImageTexture:
	if _texture == null:
		var height: int = maxi(1, ceili(float(guides) / TEXTURE_WIDTH))
		var data := PackedFloat32Array()
		data.resize(TEXTURE_WIDTH * height * 4)
		for i in binding.size():
			data[i] = binding[i]
		var image := Image.create_from_data(TEXTURE_WIDTH, height, false, Image.FORMAT_RGBAF, data.to_byte_array())
		_texture = ImageTexture.create_from_image(image)
	return _texture


## [param count] points evenly spaced along the polyline [param line], its root first and its tip last.
static func _resample(line: PackedVector3Array, count: int) -> PackedVector3Array:
	var total: float = _length(line)
	var out := PackedVector3Array()
	out.resize(count)
	var seg: int = 0
	var walked: float = 0.0
	for j in count:
		var want: float = total * float(j) / float(count - 1)
		while seg < line.size() - 2 and walked + line[seg].distance_to(line[seg + 1]) < want:
			walked += line[seg].distance_to(line[seg + 1])
			seg += 1
		var span: float = line[seg].distance_to(line[seg + 1])
		var t: float = clampf((want - walked) / span, 0.0, 1.0) if span > 1e-9 else 0.0
		out[j] = line[seg].lerp(line[seg + 1], t)
	return out


static func _length(line: PackedVector3Array) -> float:
	var total: float = 0.0
	for i in line.size() - 1:
		total += line[i].distance_to(line[i + 1])
	return total


static func _feature_distance(features: PackedVector3Array, a: int, b: int) -> float:
	var d: float = 0.0
	for j in 3:
		d += features[a * 3 + j].distance_squared_to(features[b * 3 + j])
	return d


## SIM_GUIDES of the [param movable] guides, each the farthest (root, middle and tip) from those already taken,
## the longest first: they span the head of hair, its tail with it.
static func _farthest(features: PackedVector3Array, movable: PackedInt32Array, length: PackedFloat32Array) -> PackedInt32Array:
	var taken := PackedInt32Array()
	if movable.size() <= SIM_GUIDES:
		return movable.duplicate()
	var first: int = movable[0]
	for k in movable:
		if length[k] > length[first]:
			first = k
	taken.append(first)
	var nearest := PackedFloat32Array()
	nearest.resize(movable.size())
	for i in movable.size():
		nearest[i] = _feature_distance(features, movable[i], first)
	while taken.size() < SIM_GUIDES:
		var far: int = 0
		for i in movable.size():
			if nearest[i] > nearest[far]:
				far = i
		var pick: int = movable[far]
		taken.append(pick)
		for i in movable.size():
			nearest[i] = minf(nearest[i], _feature_distance(features, movable[i], pick))
	return taken
