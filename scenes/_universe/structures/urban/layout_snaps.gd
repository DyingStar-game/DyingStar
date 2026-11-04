class_name LayoutSnaps
extends RefCounted
## What the QGIS road export needs to know of every village and city layout: its footprint
## (LayoutFootprint), which no road may cross, and its RoadSnaps, where the roads may join it.
## Written to EXPORT_PATH by tools/planettech/layout_snaps_export.gd and read by
## tools/planettech/qgis/export/planet/village_snaps.py; test_layout_snaps checks the file is current.

const EXPORT_PATH := "res://assets/qgis/export/layout_snaps.json"
## The folders whose scenes are POI layouts (a poi_village's spawn_scene).
const LAYOUT_DIRS := [
	"res://scenes/_universe/structures/urban/villages",
	"res://scenes/_universe/structures/urban/cities",
]


## {<scene path without res://>: entry} for every layout of LAYOUT_DIRS, sorted by path.
static func all() -> Dictionary:
	var paths: Array[String] = []
	for dir: String in LAYOUT_DIRS:
		for file: String in DirAccess.get_files_at(dir):
			if file.ends_with(".tscn"):
				paths.append(dir.path_join(file))
	paths.sort()
	var out := {}
	for path: String in paths:
		var entry := of(path)
		if not entry.is_empty():
			out[path.trim_prefix("res://")] = entry
	return out


## {footprint: {cx, cz, hx, hz}, snaps: [{name, kind, position: [x, y, z], forward: [x, y, z]}]} of the
## layout [param path], in its own frame (metres; forward = the snap's −Z, the way the road leaves),
## {} when it spawns nothing.
static func of(path: String) -> Dictionary:
	var packed := load(path) as PackedScene
	if packed == null:
		return {}
	var layout: Node = packed.instantiate()
	var fp := LayoutFootprint.of_layout(layout)
	var snaps: Array = []
	for snap: Node in layout.find_children("*", "RoadSnap", true, false):
		var xf := LayoutLine.frame_in(snap, layout)
		var fwd := -xf.basis.z.normalized()
		snaps.append({"name": str(layout.get_path_to(snap)), "kind": (snap as RoadSnap).kind_name(),
				"position": _round3(xf.origin), "forward": _round3(fwd)})
	layout.free()
	if fp.is_empty():
		return {}
	snaps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
	var centre: Vector2 = fp["centre"]
	var half: Vector2 = fp["half"]
	return {"footprint": {"cx": centre.x, "cz": centre.y, "hx": half.x, "hz": half.y}, "snaps": snaps}


## The JSON text of [method all], as the export writes it.
static func to_json() -> String:
	return JSON.stringify(all(), "\t", true) + "\n"


## [param v] as a JSON array, to the centimetre: the file stays stable across tiny float drifts.
static func _round3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]
