class_name StarMapRoads
extends StarMapTileLines
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
##
## The life of those lines — which tiles, laid when, kept how long — is [StarMapTileLines]'s.

## Where a body's modifier pack lives, beside its height tiles.
const PACK_PATH: String = "%s/%s_chunks/terrainmodifier.pack"

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
## The kind of way drawn with sleepers across it.
const RAILWAY: String = "railway"
## A sleeper every so many steps of the tile's mesh, and half its length in the same steps.
const SLEEPER_EVERY: float = 3.0
const SLEEPER_HALF: float = 0.75

var _pack: ModifierPack = null
## The step the sleepers are sized on, for the whole view: see [method show_over]. Zero until a view
## says, and each tile then uses its own.
var _sleeper_step: float = 0.0


## The pack for this body, opened once. A body with no pack is an ordinary answer — most of them have
## none — and it is remembered as such so the disk is not searched again every quarter second.
func _available() -> bool:
	if _pack != null:
		return _pack.is_open()
	if body_key == "":
		return false
	_pack = ModifierPack.new()
	if not _pack.open(PACK_PATH % [StarMapRelief.EXPORT_ROOT, body_key]):
		return false
	return true


## On a worker when the body's PlanetData is there to sample, on this thread otherwise, where the
## chart's own reading is cheap. Laying a way means sampling the game's height field at every surveyed
## point — 80 to 150 µs a point, over a thousand points for a view around the mining villages — so on
## the main thread a new view cost 110 to 200 ms in one frame. While the worker runs, the pack is its
## alone.
func _laying() -> Array:
	var data: PlanetData = StarMapTiles.for_body(body_key).data
	var pack: ModifierPack = _pack
	var sleepers: float = _sleeper_step
	if data == null or data.radius <= 0.0:
		var key: String = body_key
		return [func(id: int) -> Array:
			return _lay_tile(pack, StarMapGround.id_nside(id), StarMapGround.id_ipix(id),
					func(dir: Vector3) -> Vector3:
						return dir * (StarMapRelief.MESH_RADIUS
								* (StarMapRelief.surface_factor(key, dir) + LIFT)), sleepers), false]
	return [func(id: int) -> Array:
		# The ground THAT TILE draws, which costs nothing until a way asks where it stands.
		var tile := StarMapDrawnTile.new(data, StarMapGround.id_nside(id), StarMapGround.id_ipix(id))
		return _lay_tile(pack, tile.nside, tile.ipix, func(dir: Vector3) -> Vector3:
			return tile.place(dir, LIFT), sleepers), true]


func _release() -> void:
	if _pack != null:
		_pack.close()
		_pack = null


## Draw the ways crossing [param tiles], with the railways' sleepers sized for a view whose finest
## ground is at [param level].
##
## ONE size for the whole view, which is why it is not each tile's own: a view mixes levels, fine under
## the camera and coarser ring by ring, and sleepers sized tile by tile doubled in length and spacing at
## every ring. When the level changes, everything laid is laid again.
func show_over(tiles: Dictionary, level: int) -> void:
	var step: float = mesh_step(level)
	if not is_equal_approx(step, _sleeper_step):
		_sleeper_step = step
		lay_again()
	refresh(tiles)


## One step of the mesh of a tile at [param nside], as an angle at the body's centre.
static func mesh_step(nside: int) -> float:
	return HEALPix.pixel_angular_size(nside) / float(StarMapGround.GRID_RES) if nside > 0 else 0.0


# ---------------------------------------------------------------------------

## Every way crossing one tile, as line segments, each surveyed point put on the ground by
## [param place]. Static and handed everything, because it may run on a worker.
##
## [param sleeper_step] sizes the railways' sleepers; zero leaves it to the tile's own step.
##
## The pack stores lon/lat in DEGREES, which is what [method HEALPix.lonlat2vec] takes — the two agree,
## and it is worth saying so here because the neighbouring call in this file's own tests once did not.
static func _lay_tile(pack: ModifierPack, nside: int, ipix: int, place: Callable,
		sleeper_step: float = 0.0) -> Array:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	if not pack.has_tile(nside, ipix):
		return [points, colours]
	var tile: Dictionary = pack.decode_tile(pack.read_tile(nside, ipix), 0.0, ModifierPack.MASK_ROAD)
	# One step of the tile's mesh, as an angle: no piece of a way is drawn longer than that.
	var step: float = mesh_step(nside)
	for entry: Variant in (tile["roads"] as Array):
		var road: Dictionary = entry
		var line: PackedVector2Array = road["centerline"]
		if line.size() < 2:
			continue
		var kind: String = str(road.get("road_type", ""))
		var tint: Color = COLOURS.get(kind, UNKNOWN_COLOUR)
		var way := PackedVector3Array()
		for at: Vector2 in line:
			way.append(HEALPix.lonlat2vec(at.x, at.y))
		for i: int in range(1, way.size()):
			add_line(points, colours, way[i - 1], way[i], step, place, tint)
		if kind == RAILWAY:
			add_sleepers(points, colours, way, sleeper_step if sleeper_step > 0.0 else step, place, tint)
	return [points, colours]


## The sleepers of a railway: short strokes across the line, which is how a map has always said
## "railway" and what tells it from a road when both are a pixel wide.
##
## [param way] is the piece of the railway one tile holds; [param step] the length they are sized on —
## [constant SLEEPER_EVERY] of it apart, [constant SLEEPER_HALF] of it to each side.
##
## Spread EVENLY over the piece, half a gap in from each end, rather than counted off from its start:
## a railway reaches the chart cut at every tile edge, and counting afresh in each tile left a gap of
## any length at each edge. Spread this way the two half gaps either side of an edge make a whole one.
## And every stroke is the same length, standing level at the height of the line: its two ends put on
## the ground one by one stood on different ground, and came out longer on a slope.
static func add_sleepers(points: PackedVector3Array, colours: PackedColorArray,
		way: PackedVector3Array, step: float, place: Callable, tint: Color) -> void:
	var length: float = 0.0
	for i: int in range(1, way.size()):
		length += way[i - 1].angle_to(way[i])
	var count: int = roundi(length / (step * SLEEPER_EVERY)) if step > 0.0 else 0
	if count <= 0:
		return
	var gap: float = length / float(count)
	var next_at: float = gap * 0.5
	var walked: float = 0.0
	for i: int in range(1, way.size()):
		var stretch: float = way[i - 1].angle_to(way[i])
		if stretch <= 0.0:
			continue
		var across: Vector3 = way[i - 1].cross(way[i]).normalized()
		while next_at <= walked + stretch:
			var on_line: Vector3 = way[i - 1].slerp(way[i], (next_at - walked) / stretch)
			var height: float = (place.call(on_line) as Vector3).length()
			points.append((on_line - across * (step * SLEEPER_HALF)).normalized() * height)
			points.append((on_line + across * (step * SLEEPER_HALF)).normalized() * height)
			colours.append(tint)
			colours.append(tint)
			next_at += gap
		walked += stretch
