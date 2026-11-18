class_name LayoutData
extends RefCounted
## Everything the terrain reads from a village or city layout scene, read in ONE instantiation: its
## footprint (LayoutFootprint), the roads drawn in it (LayoutRoads), the areas it levels on its own
## (LayoutPads) and its fences (LayoutFences), and the meshes of its neon signs for Warmup. A village
## registration needs the first four, and each
## reader instantiating the scene on its own cost four instantiations of a scene of a hundred
## buildings for one village.
##
## Read from the scene without adding it to the tree, the way poi_villages.gd reads a layout, and
## remembered per scene: a layout does not change while the game runs.

static var _cache: Dictionary = {}


## {footprint: Dictionary (LayoutFootprint.of_layout), roads: Array (LayoutRoads.of_layout), pads:
## Array (LayoutPads.of_layout), fences: Array (LayoutFences.of_layout), signs: Array (NeonSign.mesh_params,
## once each)} of the layout
## [param scene_path] (res:// or not); every part empty when the scene cannot be read or instantiated.
static func of(scene_path: String) -> Dictionary:
	var path := scene_path if scene_path.begins_with("res://") else "res://" + scene_path
	if _cache.has(path):
		return _cache[path]
	var packed := load(path) as PackedScene if ResourceLoader.exists(path) else null
	var out := of_scene(packed, path)
	_cache[path] = out
	return out


## The parts of [method of] read from [param packed] (loaded from [param path], for the error), every part
## empty when it is null or does not instantiate. A null layout must never reach the readers: in a release
## build, a method called on a null typed node crashes the game instead of raising an error (a player's
## game crashed at the menu's warm-up, 2026-11-18, on a layout that did not instantiate).
static func of_scene(packed: PackedScene, path: String) -> Dictionary:
	var out := {"footprint": {}, "roads": [], "pads": [], "fences": [], "signs": []}
	if packed == null:
		return out
	var layout: Node = packed.instantiate()
	if layout == null:
		push_error("[LayoutData] %s does not instantiate: its ground, roads, pads, fences and signs are left empty" % path)
		return out
	out = {"footprint": LayoutFootprint.of_layout(layout), "roads": LayoutRoads.of_layout(layout),
			"pads": LayoutPads.of_layout(layout), "fences": LayoutFences.of_layout(layout),
			"signs": _signs_of(layout)}
	layout.free()
	return out


## What the neon signs of [param layout] draw, each different one once (client only: the server draws none).
static func _signs_of(layout: Node) -> Array:
	if OS.has_feature("dedicated_server"):
		return []
	var seen := {}
	for sign_node: Node in layout.find_children("*", "NeonSign", true, false):
		var params: Dictionary = (sign_node as NeonSign).mesh_params()
		seen["%s|%s|%s" % [params["text"], params["pixel_size"], params["depth"]]] = params
	return seen.values()
