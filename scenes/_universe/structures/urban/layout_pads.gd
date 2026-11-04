class_name LayoutPads
extends RefCounted
## The TerrainPads placed straight under a village or city layout's root (not inside a building): an
## area of the layout to level on its own (the mine's yard, a square). A layout never spawns them — they
## belong to no networked item — so the server and every client read them from the layout file, as
## LayoutRoads reads the roads, and register them with the village's ground (PlanetTerrain), through
## the village bed's frame: the same record on every machine.

## In the uuid of every layout area's record: how the village roads tell an area from a building.
const UUID_TAG := "|pad|"

static var _cache: Dictionary = {}


## [{name, box: Transform3D (the marker box in the layout's frame, scale included), size: Vector3 (the
## box's own size), apron, h_offset}] of the layout [param scene_path] (res:// or not).
static func of(scene_path: String) -> Array:
	var path := scene_path if scene_path.begins_with("res://") else "res://" + scene_path
	if _cache.has(path):
		return _cache[path]
	var out: Array = []
	var packed := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if packed != null:
		var layout: Node = packed.instantiate()
		out = of_layout(layout)
		layout.free()
	_cache[path] = out
	return out


## The root pads of an instantiated [param layout] (not in the tree), as [method of] returns them.
static func of_layout(layout: Node) -> Array:
	var out: Array = []
	for n: Node in layout.get_children():
		if not n is TerrainPad:
			continue
		var t: Dictionary = (n as TerrainPad).template_relative_to(layout)
		if t.is_empty():
			continue
		out.append({"name": str(n.name), "box": (t["rel"] as Transform3D) * (t["box_local"] as Transform3D),
				"size": t["box_size"], "apron": float(t["apron"]), "h_offset": float(t["h_offset"])})
	return out


## The pad records (PadBed.record) of [param pads] laid on the village bed [param bed], whose centre is
## the layout point [param centre]: layout +X is the bed's +X, layout +Z its −Y.
static func to_records(pads: Array, bed: Dictionary, centre: Vector2, m_per_deg: float) -> Array:
	var out: Array = []
	for p: Dictionary in pads:
		var box: Transform3D = p["box"]
		var size: Vector3 = p["size"]
		var at := Vector2(box.origin.x, box.origin.z) - centre
		var lonlat := HEALPix.vec2lonlat(PadBed.dir_at(bed, at.x, -at.y, m_per_deg))
		var x_axis := box.basis.x
		var yaw := float(bed["yaw"]) + atan2(-x_axis.z, x_axis.x)
		var half := Vector2(0.5 * size.x * box.basis.x.length(), 0.5 * size.z * box.basis.z.length())
		out.append(PadBed.record("%s%s%s" % [str(bed["uuid"]), UUID_TAG, p["name"]], lonlat.x, lonlat.y, yaw,
				half.x, half.y, float(p["apron"]), float(p["h_offset"])))
	return out
