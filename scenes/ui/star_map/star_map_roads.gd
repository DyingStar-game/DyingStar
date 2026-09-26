class_name StarMapRoads
extends MeshInstance3D
## The roads and railways of ONE body, drawn over its ground.
##
## Read straight from the terrain's own modifier pack rather than from anything the chart keeps: these
## are the very lines the game carves its road beds along, so a road on this map is where a road is.
## The pack stores, per HEALPix tile and per level, the piece of each feature that crosses it — so
## asking for the tiles the ground is drawing returns exactly the roads in view, already clipped, with
## nothing to cull and nothing counted twice.
##
## Lines rather than ribbons. A road is 6 m wide and a trail narrower; at any height where the whole
## network reads, a true-to-width ribbon is thinner than a pixel, and one widened until it shows is no
## longer telling you the width. A line says "there is a road here", which is what a map is for.

## Where a body's modifier pack lives, beside its height tiles.
const PACK_PATH: String = "%s/%s_chunks/terrainmodifier.pack"

## How far the lines float over the ground, as a fraction of the body's drawn radius.
##
## They have to clear the surface the chart DRAWS, which is not the surface the road was surveyed on:
## the mesh samples the height field at 24 points across a tile, so between two samples the drawn
## ground wanders from the true one by whatever the terrain does in between. Laid flat, a road would
## dip in and out of the hillside. Three hundredths of a thousandth is about 190 m on Tarsis III —
## invisible from anywhere the whole network is being read, and still clear of that wander.
const LIFT: float = 3.0e-5

## What each kind of way is drawn in. Bright enough to hold against sunlit ground, and distinct from
## one another rather than merely from the terrain: the point of showing a railway is that it is not a
## road.
const COLOURS: Dictionary = {
	"highway": Color(1.0, 0.94, 0.78),
	"road": Color(0.98, 0.80, 0.55),
	"trail": Color(0.80, 0.66, 0.50),
	"railway": Color(0.72, 0.86, 1.0),
}
const UNKNOWN_COLOUR: Color = Color(0.85, 0.85, 0.85)

var body_key: String = ""

var _pack: ModifierPack = null
var _drawn: Dictionary = {}
var _material: StandardMaterial3D = null


func _ready() -> void:
	_material = StandardMaterial3D.new()
	# Unshaded, because a line has no surface to be lit: shaded, the far side of a planet would carry
	# roads that fade out exactly where the ground does, which is the one place a map still has to read.
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	material_override = _material


## Draw the ways crossing [param tiles], which are the ground's own tiles, keyed as [StarMapGround]
## keys them.
##
## Does nothing at all when the set has not changed, which is most frames: the tiles come from a
## decision taken four times a second at most, and reading a pack is disk work.
func refresh(tiles: Dictionary) -> void:
	if tiles == _drawn:
		return
	_drawn = tiles.duplicate()
	if not _open():
		mesh = null
		return
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	for id: int in tiles:
		_gather(StarMapGround.id_nside(id), StarMapGround.id_ipix(id), points, colours)
	if points.is_empty():
		mesh = null
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_COLOR] = colours
	var built := ArrayMesh.new()
	built.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh = built


## Let go of the body, and of the file handle that goes with it.
func clear() -> void:
	_drawn.clear()
	mesh = null
	if _pack != null:
		_pack.close()
		_pack = null


func _exit_tree() -> void:
	clear()


# ---------------------------------------------------------------------------

## The pack for this body, opened once. A body with no pack is an ordinary answer — most of them have
## none — and it is remembered as such so the disk is not searched again every quarter second.
func _open() -> bool:
	if _pack != null:
		return _pack.is_open()
	if body_key == "":
		return false
	_pack = ModifierPack.new()
	if not _pack.open(PACK_PATH % [StarMapRelief.EXPORT_ROOT, body_key]):
		return false
	return true


## Every way crossing one tile, appended as line segments.
func _gather(nside: int, ipix: int, points: PackedVector3Array,
		colours: PackedColorArray) -> void:
	if not _pack.has_tile(nside, ipix):
		return
	var tile: Dictionary = _pack.decode_tile(
			_pack.read_tile(nside, ipix), 0.0, ModifierPack.MASK_ROAD)
	for entry: Variant in (tile["roads"] as Array):
		var road: Dictionary = entry
		var line: PackedVector2Array = road["centerline"]
		if line.size() < 2:
			continue
		var tint: Color = COLOURS.get(str(road.get("road_type", "")), UNKNOWN_COLOUR)
		var previous: Vector3 = _on_ground(line[0])
		for i: int in range(1, line.size()):
			var next: Vector3 = _on_ground(line[i])
			points.append(previous)
			points.append(next)
			colours.append(tint)
			colours.append(tint)
			previous = next


## One surveyed point, put on the ground the chart is drawing.
##
## The pack stores lon/lat in DEGREES, which is what [method HEALPix.lonlat2vec] takes — the two agree,
## and it is worth saying so here because the neighbouring call in this file's own tests once did not.
func _on_ground(lonlat: Vector2) -> Vector3:
	var dir: Vector3 = HEALPix.lonlat2vec(lonlat.x, lonlat.y)
	return dir * (StarMapRelief.MESH_RADIUS
			* (StarMapRelief.surface_factor(body_key, dir) + LIFT))
