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
	if data == null or data.radius <= 0.0:
		var key: String = body_key
		return [func(id: int) -> Array:
			return _lay_tile(pack, StarMapGround.id_nside(id), StarMapGround.id_ipix(id),
					func(dir: Vector3) -> Vector3:
						return dir * (StarMapRelief.MESH_RADIUS
								* (StarMapRelief.surface_factor(key, dir) + LIFT))), false]
	return [func(id: int) -> Array:
		# The ground THAT TILE draws, which costs nothing until a way asks where it stands.
		var tile := StarMapDrawnTile.new(data, StarMapGround.id_nside(id), StarMapGround.id_ipix(id))
		return _lay_tile(pack, tile.nside, tile.ipix, func(dir: Vector3) -> Vector3:
			return tile.place(dir, LIFT)), true]


func _release() -> void:
	if _pack != null:
		_pack.close()
		_pack = null


# ---------------------------------------------------------------------------

## Every way crossing one tile, as line segments, each surveyed point put on the ground by
## [param place]. Static and handed everything, because it may run on a worker.
##
## The pack stores lon/lat in DEGREES, which is what [method HEALPix.lonlat2vec] takes — the two agree,
## and it is worth saying so here because the neighbouring call in this file's own tests once did not.
static func _lay_tile(pack: ModifierPack, nside: int, ipix: int, place: Callable) -> Array:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	if not pack.has_tile(nside, ipix):
		return [points, colours]
	var tile: Dictionary = pack.decode_tile(pack.read_tile(nside, ipix), 0.0, ModifierPack.MASK_ROAD)
	# One step of the tile's mesh, as an angle: no piece of a way is drawn longer than that.
	var step: float = HEALPix.pixel_angular_size(nside) / float(StarMapGround.GRID_RES)
	for entry: Variant in (tile["roads"] as Array):
		var road: Dictionary = entry
		var line: PackedVector2Array = road["centerline"]
		if line.size() < 2:
			continue
		var kind: String = str(road.get("road_type", ""))
		var tint: Color = COLOURS.get(kind, UNKNOWN_COLOUR)
		# How far since the last sleeper, carried from one stretch of the way to the next so they
		# stay evenly spaced round a bend.
		var since_sleeper: float = 0.0
		var previous: Vector3 = HEALPix.lonlat2vec(line[0].x, line[0].y)
		for i: int in range(1, line.size()):
			var next: Vector3 = HEALPix.lonlat2vec(line[i].x, line[i].y)
			add_line(points, colours, previous, next, step, place, tint)
			if kind == RAILWAY:
				since_sleeper = _add_sleepers(points, colours, previous, next, step, since_sleeper,
						place, tint)
			previous = next
	return [points, colours]


## The sleepers of a stretch of railway: short strokes across the line, which is how a map has always
## said "railway" and what tells it from a road when both are a pixel wide. Sized on the tile's own
## step, so they are the same few pixels at every height — a tile is drawn at the level where its step
## is a few pixels.
##
## Returns how far past the last sleeper the stretch ends, for the next one to carry on from.
static func _add_sleepers(points: PackedVector3Array, colours: PackedColorArray, from: Vector3,
		to: Vector3, step: float, since: float, place: Callable, tint: Color) -> float:
	var length: float = from.angle_to(to)
	var every: float = step * SLEEPER_EVERY
	if length <= 0.0 or every <= 0.0:
		return since
	var across: Vector3 = from.cross(to).normalized()
	var at: float = every - since
	while at <= length:
		var on_line: Vector3 = from.slerp(to, at / length)
		points.append(place.call((on_line - across * (step * SLEEPER_HALF)).normalized()))
		points.append(place.call((on_line + across * (step * SLEEPER_HALF)).normalized()))
		colours.append(tint)
		colours.append(tint)
		at += every
	return length - (at - every)
