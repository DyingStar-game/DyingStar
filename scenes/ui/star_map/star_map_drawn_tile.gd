class_name StarMapDrawnTile
extends RefCounted
## Where the ground of ONE tile is DRAWN, for whatever is laid over it: the roads, the canyons.
##
## Not where the ground is. The chart draws a tile as a mesh of [constant StarMapGround.GRID_RES] steps
## a side, flat between its vertices; at the coarse levels a step is kilometres, and the true ground
## under a point between four vertices can stand hundreds of metres above or below the facet drawn
## there. A line laid on the true ground went in and out of the drawn one and showed in pieces — the
## railway seen from six hundred km was a row of dashes. So a point is put where the MESH is: on the
## facet it falls in, cut along the same diagonal [method StarMapRelief.build_tile] cuts it.
##
## One per tile and per laying, on a worker: it keeps the vertices it has been asked about, since the
## points of a line keep falling between the same few.

var nside: int
var ipix: int
## Ground covered by one step of the mesh, in metres.
var pitch: float
## The tile's frame, mountains and canyons prepared, for a caller that has its own questions to ask of
## the sampler about this tile. Made on first use: most tiles carry nothing to lay.
var frame: PlanetData.TileFrame:
	get:
		if frame == null:
			frame = _data.make_tile_frame()
			_data.prepare_mountain_frame(frame, nside, ipix)
			CrackCarve.prepare_frame(_data, frame, nside, ipix)
		return frame

var _data: PlanetData
var _grid_res: int
var _grid: Array[PackedVector3Array] = []
## Height of each vertex asked about so far, by its index in the grid, in metres.
var _heights: Dictionary = {}


func _init(data: PlanetData, tile_nside: int, tile_ipix: int,
		grid_res: int = StarMapGround.GRID_RES) -> void:
	_data = data
	nside = tile_nside
	ipix = tile_ipix
	_grid_res = grid_res
	pitch = StarMapRelief.tile_pitch(data.radius, nside, grid_res)


## [param dir] on the drawn ground, [param lift] clear of it (a fraction of the body's radius), in the
## body's frame and in the mesh's own units.
func place(dir: Vector3, lift: float) -> Vector3:
	return dir * (StarMapRelief.MESH_RADIUS
			* (1.0 + StarMapRelief.EXAGGERATION * metres_at(dir) / _data.radius + lift))


## How high the drawn ground stands at [param dir], in metres: read off the facet of the mesh the point
## falls in. A point outside the tile is answered from its nearest edge.
func metres_at(dir: Vector3) -> float:
	var uv: Vector2 = _data._direction_to_pixel_uv(dir, ipix, nside) * float(_grid_res)
	var vx: int = clampi(int(uv.x), 0, _grid_res - 1)
	var vy: int = clampi(int(uv.y), 0, _grid_res - 1)
	return facet_height(_vertex(vx, vy), _vertex(vx + 1, vy), _vertex(vx, vy + 1),
			_vertex(vx + 1, vy + 1), uv.x - float(vx), uv.y - float(vy))


## The height at ([param fx], [param fy]) of one quad of the mesh, from the heights of its four
## corners — 00, 10 (one step along x), 01 (one along y), 11 — cut the way the mesh cuts it: along
## whichever diagonal the ground is flatter across ([method StarMapRelief._add_patch_indices]).
static func facet_height(h00: float, h10: float, h01: float, h11: float, fx: float, fy: float) -> float:
	if absf(h10 - h01) <= absf(h00 - h11):
		if fx + fy <= 1.0:
			return h00 + fx * (h10 - h00) + fy * (h01 - h00)
		return h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fy) * (h10 - h11)
	if fx >= fy:
		return h00 + fx * (h10 - h00) + fy * (h11 - h10)
	return h00 + fx * (h11 - h01) + fy * (h01 - h00)


## The height of one vertex of the mesh: the game's sampler at the tile's level and pitch, as the mesh
## is built — less the canyons, which a line crosses or follows from above.
func _vertex(vx: int, vy: int) -> float:
	var at: int = vy * (_grid_res + 1) + vx
	if _heights.has(at):
		return _heights[at]
	if _grid.is_empty():
		_grid = HEALPix.get_pixel_grid(nside, ipix, _grid_res)
	var metres: float = _data.sample_height_for_direction(_grid[vy][vx], -1, -1, Vector2i(-1, -1),
			null, nside, frame, pitch, CrackCarve.NONE)
	_heights[at] = metres
	return metres
