class_name LayoutFootprint
extends RefCounted
## The ground a village or city layout covers, in the layout's own frame: the rectangle around the
## levelled ground of every networked item it spawns (their TerrainPad boxes) and of the roads and fences drawn
## in it (VillageRoad, VillageFence), plus MARGIN_M. One
## answer for every reader — the village's common ground (VillageBed, through PlanetTerrain.set_poi_zone)
## and the road export that keeps the QGIS roads out of the village (tools/planettech/layout_snaps_export).
##
## Read from the scene without adding it to the tree, the way poi_villages.gd reads a layout, and
## remembered per scene (LayoutData): a layout does not change while the game runs.

## Room left around the outermost buildings (m): their aprons, and a little street.
const MARGIN_M := 10.0
## The layout reader whose spawn rules decide which items count (is_spawnable, layout_children).
const PoiVillagesScript := preload("res://scenes/_universe/structures/urban/poi_villages.gd")


## {centre: Vector2 (x, z), half: Vector2 (x, z)} of the layout [param scene_path] (res:// or not),
## {} when the scene cannot be read or spawns nothing.
static func of(scene_path: String) -> Dictionary:
	return LayoutData.of(scene_path)["footprint"]


## The footprint of an instantiated [param layout] (not in the tree), as [method of] returns it.
static func of_layout(layout: Node) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for item in layout.get_children():
		if not PoiVillagesScript.is_spawnable(item):
			continue
		var items: Array[Node] = [item]
		items.append_array(PoiVillagesScript.layout_children(item, layout))
		for it: Node in items:
			for corner: Vector3 in _ground_corners(it, layout):
				lo = Vector2(minf(lo.x, corner.x), minf(lo.y, corner.z))
				hi = Vector2(maxf(hi.x, corner.x), maxf(hi.y, corner.z))
	# The areas the layout levels on their own (a TerrainPad under its root, LayoutPads).
	for pad: Dictionary in LayoutPads.of_layout(layout):
		var box: Transform3D = pad["box"]
		var size: Vector3 = pad["size"]
		for sx: float in [-0.5, 0.5]:
			for sz: float in [-0.5, 0.5]:
				var corner := box * Vector3(size.x * sx, 0.0, size.z * sz)
				lo = Vector2(minf(lo.x, corner.x), minf(lo.y, corner.z))
				hi = Vector2(maxf(hi.x, corner.x), maxf(hi.y, corner.z))
	if lo.x <= hi.x:
		lo -= Vector2.ONE * MARGIN_M
		hi += Vector2.ONE * MARGIN_M
	# The roads drawn inside the layout (VillageRoad) stand on the village's ground too, up to their
	# very ends and no further: a road that ends on a RoadSnap ends on the footprint's edge.
	# So do its fences (VillageFence): the village's ground runs up to them. Their drawn points only
	# (LayoutLine.polyline_in, as their readers take them), not the roads' junction cuts.
	var lines: Array = LayoutRoads.lines_of(layout) + LayoutFences.of_layout(layout)
	for line: Dictionary in lines:
		for p: Vector2 in line["points"]:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	if lo.x > hi.x:
		return {}
	return {"centre": ((lo + hi) * 0.5).snappedf(PadSettings.Q_M),
			"half": ((hi - lo) * 0.5).snappedf(PadSettings.Q_M)}


## The corners of the ground [param item] levels, in [param layout]'s frame: its TerrainPad boxes
## (a spawn building's sized by its rows and cols), or its origin alone when it levels nothing
## (a heap, a field of masts).
static func _ground_corners(item: Node, layout: Node) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var to_layout := LayoutLine.frame_in(item, layout)
	for pad: Node in item.find_children("*", "TerrainPad", true, false):
		var t: Dictionary = (pad as TerrainPad).template_relative_to(item)
		if t.is_empty():
			continue
		var size: Vector3 = t["box_size"]
		var local: Transform3D = t["box_local"]
		if item is SpawnBuilding:
			var sb := item as SpawnBuilding
			var fit := SpawnBuilding.terrain_pad_box({"rows": sb.rows, "cols": sb.cols, "floors": sb.floors,
					"x_spacing": sb.x_spacing, "z_spacing": sb.z_spacing})
			size = fit["size"]
			local = fit["local"]
		var box := to_layout * (t["rel"] as Transform3D) * local
		for sx: float in [-0.5, 0.5]:
			for sz: float in [-0.5, 0.5]:
				out.append(box * Vector3(size.x * sx, 0.0, size.z * sz))
	if out.is_empty():
		out.append(to_layout.origin)
	return out
