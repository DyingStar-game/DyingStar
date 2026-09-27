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
## How many tiles' worth of projected ways are kept. A little over two views of
## [constant StarMapRelief.PATCH_TILES_MAX], so zooming out and back in finds both levels still there.
const SEGMENTS_KEPT: int = 1024

var body_key: String = ""

var _pack: ModifierPack = null
var _drawn: Dictionary = {}
## The ways of each tile already read and laid on the ground, id -> [points, colours]. The expensive
## half of a refresh is not concatenating lines, it is decoding the pack and asking the height field
## where every vertex stands — and the wanted set changes by a handful of tiles, so almost all of it is
## the same as last time.
var _segments: Dictionary = {}
var _material: StandardMaterial3D = null
## The worker laying the ways of tiles not seen yet, or -1, and the slot it fills: id -> [points,
## colours]. Laying a way means sampling the game's height field at every surveyed point — 80 to 150 µs
## a point, over a thousand points for a view around the mining villages — so on the main thread a new
## view cost 110 to 200 ms in one frame. While it runs, the pack is the worker's alone.
var _task: int = -1
var _job: Dictionary = {}
## New segments arrived since the mesh was last put together.
var _dirty: bool = false


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
	_harvest()
	if tiles == _drawn and not _dirty:
		return
	_drawn = tiles.duplicate()
	if not _open():
		mesh = null
		return
	if _segments.size() > SEGMENTS_KEPT and _task < 0:
		_segments.clear()  # crude, and rare: one refresh pays for its whole view again
	_start_missing()
	_assemble()


## Wait for the ways still being laid and draw them. For a caller that needs the mesh NOW — a test;
## the chart itself just refreshes again next frame.
func finish() -> void:
	if _task >= 0:
		_take()
	if _dirty:
		_assemble()


## Queue the tiles of the current view that have no ways laid yet — on a worker when the body's
## PlanetData is there to sample, on this thread otherwise, where the chart's own reading is cheap.
func _start_missing() -> void:
	if _task >= 0:
		return  # the pack is the worker's; what it does not cover is asked for on a later refresh
	var missing: Array[int] = []
	for id: int in _drawn:
		if not _segments.has(id):
			missing.append(id)
	if missing.is_empty():
		return
	var data: PlanetData = StarMapTiles.for_body(body_key).data
	if data == null or data.radius <= 0.0:
		for id: int in missing:
			var own_points := PackedVector3Array()
			var own_colours := PackedColorArray()
			_gather(StarMapGround.id_nside(id), StarMapGround.id_ipix(id), own_points, own_colours)
			_segments[id] = [own_points, own_colours]
		_dirty = true
		return
	var slot: Dictionary = {}
	var pack: ModifierPack = _pack
	_job = slot
	_task = WorkerThreadPool.add_task(func() -> void:
		for id: int in missing:
			slot[id] = _lay_tile(pack, data, StarMapGround.id_nside(id), StarMapGround.id_ipix(id)))


## Take in what the worker has finished, if it has.
func _harvest() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		_take()


## Wait for the worker — at once when it is done — and take its ways in. Its id is gone once waited on,
## so nothing may ask about it again: is_task_completed on a spent id does not answer "done".
func _take() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	for id: int in _job:
		_segments[id] = _job[id]
	_job = {}
	_dirty = true


## Put the mesh together from the ways laid so far for the current view.
func _assemble() -> void:
	_dirty = false
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	for id: int in _drawn:
		if not _segments.has(id):
			continue
		var cached: Array = _segments[id]
		points.append_array(cached[0])
		colours.append_array(cached[1])
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
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_job = {}
	_dirty = false
	_drawn.clear()
	_segments.clear()
	mesh = null
	if _pack != null:
		_pack.close()
		_pack = null


# On deletion, NOT on leaving the tree: the chart takes this off its sphere every time it is opened and
# hangs it back on the new one, and clearing there would throw the ways away with each F2.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
	if _pack != null:
		_pack.close()
		_pack = null


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


## Every way crossing one tile, laid on the ground THAT TILE draws: the game's sampler at the tile's own
## level and pitch, through one TileFrame, exactly as [method StarMapRelief.build_tile] builds it. Static
## and handed everything, because it runs on a worker.
static func _lay_tile(pack: ModifierPack, data: PlanetData, nside: int, ipix: int) -> Array:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	if not pack.has_tile(nside, ipix):
		return [points, colours]
	var tile: Dictionary = pack.decode_tile(pack.read_tile(nside, ipix), 0.0, ModifierPack.MASK_ROAD)
	var roads: Array = tile["roads"]
	if roads.is_empty():
		return [points, colours]
	var frame: PlanetData.TileFrame = data.make_tile_frame()
	data.prepare_mountain_frame(frame, nside, ipix)
	var pitch: float = data.radius * HEALPix.pixel_angular_size(nside) / float(StarMapGround.GRID_RES)
	for entry: Variant in roads:
		var road: Dictionary = entry
		var line: PackedVector2Array = road["centerline"]
		if line.size() < 2:
			continue
		var tint: Color = COLOURS.get(str(road.get("road_type", "")), UNKNOWN_COLOUR)
		var previous: Vector3 = _on_sampled_ground(data, frame, nside, pitch, line[0])
		for i: int in range(1, line.size()):
			var next: Vector3 = _on_sampled_ground(data, frame, nside, pitch, line[i])
			points.append(previous)
			points.append(next)
			colours.append(tint)
			colours.append(tint)
			previous = next
	return [points, colours]


static func _on_sampled_ground(data: PlanetData, frame: PlanetData.TileFrame, nside: int,
		pitch: float, lonlat: Vector2) -> Vector3:
	var dir: Vector3 = HEALPix.lonlat2vec(lonlat.x, lonlat.y)
	# No crack: a road crosses a chasm on its bridge, not down its floor.
	var metres: float = data.sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null,
			nside, frame, pitch, CrackCarve.NONE)
	return dir * (StarMapRelief.MESH_RADIUS
			* (1.0 + StarMapRelief.EXAGGERATION * metres / data.radius + LIFT))


## One surveyed point, put on the ground the chart is drawing.
##
## The pack stores lon/lat in DEGREES, which is what [method HEALPix.lonlat2vec] takes — the two agree,
## and it is worth saying so here because the neighbouring call in this file's own tests once did not.
func _on_ground(lonlat: Vector2) -> Vector3:
	var dir: Vector3 = HEALPix.lonlat2vec(lonlat.x, lonlat.y)
	return dir * (StarMapRelief.MESH_RADIUS
			* (StarMapRelief.surface_factor(body_key, dir) + LIFT))
