class_name GarmentLibrary
extends RefCounted

## The garments the game can dress a body in: each its own imported file (GarmentFormat.path_of), loaded the
## first time it is worn and kept, with its topology made once (the builder's bakes run on two workers at a
## time: everything here is behind one mutex, and what it hands out is only read afterwards).

static var _mutex: Mutex = Mutex.new()
static var _assets: Dictionary = {}  # garment id -> HumanAssetData (null: missing, said once)
static var _topology: Dictionary = {}  # HumanAssetData instance id -> [index clockwise, bones int32]


## The garment [param id] (its catalogue id), loaded once; null when it has no file (the error is pushed once).
static func asset(id: String) -> HumanAssetData:
	_mutex.lock()
	var known: bool = _assets.has(id)
	var found: HumanAssetData = _assets.get(id)
	_mutex.unlock()
	if known:
		return found
	var path: String = GarmentFormat.path_of(id)
	var loaded: HumanAssetData = null
	if ResourceLoader.exists(path):
		loaded = load(path) as HumanAssetData
	if loaded == null:
		push_error("garment '%s': no imported %s" % [id, path])
	_mutex.lock()
	if not _assets.has(id):
		_assets[id] = loaded
		if loaded != null:
			_topology[loaded.get_instance_id()] = HumanBuilder.topology_of(loaded)
	found = _assets[id]
	_mutex.unlock()
	return found


## The garments worn by [param appearance], inside out (the order they are drawn in); missing files left out.
static func worn(appearance: CharacterAppearance) -> Array[HumanAssetData]:
	var out: Array[HumanAssetData] = []
	for entry: Dictionary in appearance.worn_garments():
		var a: HumanAssetData = asset(String(entry["id"]))
		if a != null:
			out.append(a)
	return out


## [index clockwise, bones int32] of a garment this library loaded, or [] for another asset.
static func topology(a: HumanAssetData) -> Array:
	_mutex.lock()
	var out: Array = _topology.get(a.get_instance_id(), [])
	_mutex.unlock()
	return out


## Per garment vertex of [param a], 1 when it hangs only on skin hidden by a garment worn over it ([param over]:
## per compact body vertex, 1 when hidden): a trouser leg inside a boot, a T-shirt under a jacket. A triangle of it
## with one such corner is not drawn, as the body's own (HumanMorph.visible_triangles).
static func hidden_under(a: HumanAssetData, over: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(a.offsets.size())
	for v in out.size():
		var all_hidden: bool = true
		for k in 3:
			if a.weights[v * 3 + k] > 1e-4 and over[a.refs[v * 3 + k]] == 0:
				all_hidden = false
				break
		out[v] = 1 if all_hidden else 0
	return out
