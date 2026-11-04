class_name LayoutData
extends RefCounted
## Everything the terrain reads from a village or city layout scene, read in ONE instantiation: its
## footprint (LayoutFootprint), the roads drawn in it (LayoutRoads), the areas it levels on its own
## (LayoutPads) and its fences (LayoutFences). A village registration needs all four, and each
## reader instantiating the scene on its own cost four instantiations of a scene of a hundred
## buildings for one village.
##
## Read from the scene without adding it to the tree, the way poi_villages.gd reads a layout, and
## remembered per scene: a layout does not change while the game runs.

static var _cache: Dictionary = {}


## {footprint: Dictionary (LayoutFootprint.of_layout), roads: Array (LayoutRoads.of_layout), pads:
## Array (LayoutPads.of_layout), fences: Array (LayoutFences.of_layout)} of the layout
## [param scene_path] (res:// or not); every part empty when the scene cannot be read.
static func of(scene_path: String) -> Dictionary:
	var path := scene_path if scene_path.begins_with("res://") else "res://" + scene_path
	if _cache.has(path):
		return _cache[path]
	var out := {"footprint": {}, "roads": [], "pads": [], "fences": []}
	var packed := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if packed != null:
		var layout: Node = packed.instantiate()
		out = {"footprint": LayoutFootprint.of_layout(layout), "roads": LayoutRoads.of_layout(layout),
				"pads": LayoutPads.of_layout(layout), "fences": LayoutFences.of_layout(layout)}
		layout.free()
	_cache[path] = out
	return out
