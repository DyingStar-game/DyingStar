class_name ItemDefs
extends RefCounted
## The network definitions of every prop type, read from res://items_def/<type>_def.json (copied from
## ../horizonserver by the DyingStar editor plugin). The server only needs one number per type: the
## distance of its zone-6 channel — the one carrying `scenename`, i.e. how far away a client is allowed
## to know the object exists. Out in space, where there is no terrain chunk to follow, an item is
## created when a viewer comes within [method load_radius] of it and freed beyond [method unload_radius].

const DIR := "res://items_def"
## The channel whose distance says "how far this object exists for someone".
const EXISTENCE_ZONE := 6

static var _zone6: Dictionary = {}   # type -> float (m)
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_warning("[ItemDefs] %s is missing: every space item stays loaded" % DIR)
		return
	for file in dir.get_files():
		if not file.ends_with("_def.json"):
			continue
		var text := FileAccess.get_file_as_string(DIR + "/" + file)
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			push_warning("[ItemDefs] %s is not a JSON object, skipped" % file)
			continue
		var d := existence_distance(parsed)
		if d > 0.0:
			_zone6[file.trim_suffix("_def.json")] = d
	if _zone6.is_empty():
		push_warning("[ItemDefs] no definition read from %s: every space item stays loaded" % DIR)


## The zone-6 channel distance of one parsed definition; the largest channel distance when it has no
## zone 6; 0 when it has no channel at all.
static func existence_distance(def: Dictionary) -> float:
	var best := 0.0
	for c in def.get("channels", []):
		if not (c is Dictionary):
			continue
		var dist := float((c as Dictionary).get("distance", 0.0))
		if int((c as Dictionary).get("zone", -1)) == EXISTENCE_ZONE:
			return dist
		best = maxf(best, dist)
	return best


## Zone-6 distance of [param type] in metres, 0 when the type has no definition.
static func zone6_distance(type: String) -> float:
	_ensure_loaded()
	return float(_zone6.get(type, 0.0))


## Load radius (m) for [param type]: `factor` × its zone-6 distance. 0 = unknown type (keep it loaded).
static func load_radius(type: String, factor: float) -> float:
	return zone6_distance(type) * factor


## Unload radius (m) for [param type]: `factor` × its zone-6 distance. 0 = unknown type.
static func unload_radius(type: String, factor: float) -> float:
	return zone6_distance(type) * factor


## Test hook: forget what was read.
static func reset() -> void:
	_zone6.clear()
	_loaded = false
