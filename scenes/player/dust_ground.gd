class_name DustGround
extends RefCounted
## The real ground around the camera, as a small height grid the wind's dust layer lies on
## (aerial_perspective.gdshader, dust_ground*). Without it the layer measured its height from a flat
## plane through the ground under the camera: seen from above, hills rose out of it and hollows filled
## to the camera's level, with sharp contour lines (2026-10-08). A first fix guessed the ground from
## the depth buffer and drew 2x2-pixel stairs on every silhouette: the screen pass only sees the end
## of each ray, never the ground under it on the way.
##
## Two grids are laid: this near one for the gusting layer (CELL_M), and a coarse wide one for the far
## dust (WeatherSky.FAR_CELL_M): same code, other cell and rebuild distance (new(cell_m, rebuild_m)).
##
## The grid is SIZE x SIZE cells of cell_m around an anchor laid on the ground under the camera, in
## the planet's own frame (the tangent plane there: east, north, up). Each texel holds the height of
## the real ground (PlanetData.crack_aware_surface_dist: relief and canyons) over that tangent plane.
## Everything the shader gets is relative to the anchor, so no astronomic coordinate reaches float32.
##
## The ground query reads the streamed terrain tiles and is the dearest thing a client asks, so the
## grid is built a few rows at a time within BUDGET_MS a frame, never on a worker (the tile caches are
## not thread safe). The grid in use stays on screen until the next one is complete, then both swap
## at once: texture and frame together.
##
## Moving on, the grid SLIDES: the next one is the same plane shifted by whole colour cells, so every
## cell the two share is copied (Image.blit_rect) and only the new strips are asked. Rebuilt whole, the
## near grid asked its 16384 cells every 120 m and the far one every 1.5 km: flying, both built all the
## time, some 2.5 ms of CPU a frame (2026-10-12). Past FRAME_KEEP_HALVES widths from where the plane was
## laid, it is laid again under the camera (the plane drifts off the curved ground).

## 128 cells of 16 m: the grid reaches 1 km each way, the near layer's range (WeatherSky.NEAR_LAYER_RANGE_M);
## at 5.5 m it stopped at 352 m and the layer, 6 m thick, read as nothing (2026-10-09). A layer 25 m
## thick does not need the finer cells; the queries are as many as before.
const SIZE: int = 128
const CELL_M: float = 16.0
## How far (m, along the ground) the camera goes from the anchor before a new grid is started.
const REBUILD_M: float = 120.0
## Time spent building per frame, ms.
const BUDGET_MS: float = 1.5
## The ground's colour is kept on every COLOUR_STEP-th cell each way (COLOUR_SIZE a side): the dust a
## wind lifts is the colour of the ground it lifted it from, so the haze over a far pink range is pink
## while the plain underfoot is yellow (one colour for the whole layer painted the far range in the
## plain's dust, 2026-10-12). Read on the cell nearest a colour cell's centre (half a cell off), with the
## height that cell has just asked for: no ground query of its own.
const COLOUR_STEP: int = 4
const COLOUR_SIZE: int = SIZE / COLOUR_STEP
## Past this many half-widths (half()) from where its plane was laid, a grid is laid on a new plane:
## 16 halves, 8 grid widths.
const FRAME_KEEP_HALVES: float = 16.0

## This grid's cell (m) and how far (m) the camera goes from its anchor before a new one is started.
var cell_m: float = CELL_M
var rebuild_m: float = REBUILD_M
## The grid in use: its anchor and tangent frame (planet-local), the heights' highest point over
## that plane, and whether there is one at all.
var ready: bool = false
var anchor: Vector3 = Vector3.ZERO
var east: Vector3 = Vector3.RIGHT
var north: Vector3 = Vector3.FORWARD
var up: Vector3 = Vector3.UP
var top_m: float = 0.0
var texture: ImageTexture = null
## The dust's colour over the same square (COLOUR_SIZE a side, RGB), null when no colour was asked for.
var colour_texture: ImageTexture = null
## The last complete build, for the dust probe: ms of ground queries, ms of colour reads, cells asked.
var last_build_ms: float = 0.0
var last_colour_ms: float = 0.0
var last_build_cells: int = 0
## Spent since the dust probe last read it (take_spent_us): µs of ground queries and of colour reads.
var spent_ground_us: int = 0
var spent_colour_us: int = 0

var _heights: PackedFloat32Array = PackedFloat32Array()
var _image: Image = null
var _colours: Image = null
var _frame_origin: Vector3 = Vector3.ZERO
var _next_image: Image = null
var _next_colours: Image = null
var _next_anchor: Vector3 = Vector3.ZERO
var _next_east: Vector3 = Vector3.RIGHT
var _next_north: Vector3 = Vector3.FORWARD
var _next_up: Vector3 = Vector3.UP
var _next_origin: Vector3 = Vector3.ZERO
## The block the next grid takes over from the current one: columns [_keep_i0, _keep_i1) of rows
## [_keep_j0, _keep_j1). Empty when the whole grid is asked again.
var _keep_i0: int = 0
var _keep_i1: int = 0
var _keep_j0: int = 0
var _keep_j1: int = 0
var _row: int = -1  # the row being built; -1 = no build running
var _build_us: int = 0
var _colour_us: int = 0
var _cells: int = 0


func _init(cell: float = CELL_M, rebuild: float = REBUILD_M) -> void:
	cell_m = cell
	rebuild_m = rebuild


## Keep the grid around [param ground_point] (planet-local, the ground under the camera): start a
## new build when it has moved rebuild_m from the anchor, and spend up to BUDGET_MS on the one
## running. [param ground_radius] gives the distance from the planet's centre of the ground along a
## unit direction (PlanetData.crack_aware_surface_dist); [param colour], when valid, the dust's colour
## for a unit direction and that ground radius (kept in colour_texture). Returns true when a new grid
## was swapped in.
func update(ground_point: Vector3, ground_radius: Callable, budget_ms: float = BUDGET_MS,
		colour: Callable = Callable()) -> bool:
	if _row < 0 and (not ready or _along_ground(ground_point, anchor) > rebuild_m):
		_start(ground_point, colour.is_valid())
	if _row < 0:
		return false
	var deadline: int = Time.get_ticks_usec() + int(budget_ms * 1000.0)
	while _row < SIZE:
		_build_row(_row, ground_radius, colour)
		_row += 1
		if Time.get_ticks_usec() >= deadline:
			break
	if _row < SIZE:
		return false
	_swap()
	return true


## The µs spent on ground queries and on colour reads since the last call: [ground, colour].
func take_spent_us() -> Vector2i:
	var spent := Vector2i(spent_ground_us, spent_colour_us)
	spent_ground_us = 0
	spent_colour_us = 0
	return spent


## Is a grid being built (rows still to fill) right now?
func is_building() -> bool:
	return _row >= 0


## Half the width (m) of a grid of [param cell] m cells.
static func half_m(cell: float = CELL_M) -> float:
	return SIZE * cell * 0.5


## Half this grid's width, m.
func half() -> float:
	return half_m(cell_m)


## The planet-local point of cell ([param i], [param j]) on the tangent plane at [param at], for cells of
## [param cell] m.
static func cell_point(at: Vector3, e: Vector3, n: Vector3, i: int, j: int, cell: float = CELL_M) -> Vector3:
	var u: float = (i + 0.5) * cell - half_m(cell)
	var v: float = (j + 0.5) * cell - half_m(cell)
	return at + e * u + n * v


## The tangent frame at [param at] (planet-local): [east, north, up], east along the planet's
## rotation axis cross up; any stable pair does, the shader only needs the three to match.
static func tangent_frame(at: Vector3) -> Array:
	var u: Vector3 = at.normalized()
	var axis: Vector3 = Vector3.UP if absf(u.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var e: Vector3 = axis.cross(u).normalized()
	var n: Vector3 = u.cross(e).normalized()
	return [e, n, u]


## The height (m) over the grid's tangent plane of the ground under [param q] (planet-local, relative
## to the anchor), read back bilinearly from [param heights] like the shader does; NAN off the grid.
static func ground_at(heights: PackedFloat32Array, e: Vector3, n: Vector3, q: Vector3, cell: float = CELL_M) -> float:
	var x: float = (q.dot(e) + half_m(cell)) / cell - 0.5
	var y: float = (q.dot(n) + half_m(cell)) / cell - 0.5
	if x < 0.0 or y < 0.0 or x > SIZE - 1 or y > SIZE - 1:
		return NAN
	var i: int = mini(int(x), SIZE - 2)
	var j: int = mini(int(y), SIZE - 2)
	var fx: float = x - i
	var fy: float = y - j
	var a: float = lerpf(heights[j * SIZE + i], heights[j * SIZE + i + 1], fx)
	var b: float = lerpf(heights[(j + 1) * SIZE + i], heights[(j + 1) * SIZE + i + 1], fx)
	return lerpf(a, b, fy)


## The next grid around [param ground_point]: the current plane slid by whole colour cells when it is
## still good (what the two share is copied), a new plane under the camera otherwise.
func _start(ground_point: Vector3, with_colour: bool) -> void:
	_next_image = Image.create(SIZE, SIZE, false, Image.FORMAT_RF)
	_next_colours = Image.create(COLOUR_SIZE, COLOUR_SIZE, false, Image.FORMAT_RGB8) if with_colour else null
	_keep_i0 = 0
	_keep_i1 = 0
	_keep_j0 = 0
	_keep_j1 = 0
	var slide: bool = ready and _image != null and (_colours != null or not with_colour) \
			and _frame_origin.distance_to(ground_point) < FRAME_KEEP_HALVES * half()
	if slide:
		var step_m: float = cell_m * COLOUR_STEP
		var d: Vector3 = ground_point - anchor
		var di: int = roundi(d.dot(east) / step_m) * COLOUR_STEP
		var dj: int = roundi(d.dot(north) / step_m) * COLOUR_STEP
		_next_anchor = anchor + east * (di * cell_m) + north * (dj * cell_m)
		_next_east = east
		_next_north = north
		_next_up = up
		_next_origin = _frame_origin
		# New cell (i, j) is old cell (i + di, j + dj): copy the block both grids share.
		_keep_i0 = clampi(-di, 0, SIZE)
		_keep_i1 = clampi(SIZE - di, 0, SIZE)
		_keep_j0 = clampi(-dj, 0, SIZE)
		_keep_j1 = clampi(SIZE - dj, 0, SIZE)
		if _keep_i1 > _keep_i0 and _keep_j1 > _keep_j0:
			_next_image.blit_rect(_image, Rect2i(_keep_i0 + di, _keep_j0 + dj,
					_keep_i1 - _keep_i0, _keep_j1 - _keep_j0), Vector2i(_keep_i0, _keep_j0))
			if with_colour:
				var s: int = COLOUR_STEP
				_next_colours.blit_rect(_colours, Rect2i((_keep_i0 + di) / s, (_keep_j0 + dj) / s,
						(_keep_i1 - _keep_i0) / s, (_keep_j1 - _keep_j0) / s), Vector2i(_keep_i0 / s, _keep_j0 / s))
		else:
			_keep_i1 = 0
			_keep_j1 = 0
	else:
		_next_anchor = ground_point
		var f: Array = tangent_frame(ground_point)
		_next_east = f[0]
		_next_north = f[1]
		_next_up = f[2]
		_next_origin = ground_point
	_row = 0
	_build_us = 0
	_colour_us = 0
	_cells = 0


## Ask row [param j]'s cells the current grid did not already have.
func _build_row(j: int, ground_radius: Callable, colour: Callable) -> void:
	var kept: bool = j >= _keep_j0 and j < _keep_j1
	var half_step: int = COLOUR_STEP / 2
	var colour_row: bool = colour.is_valid() and j % COLOUR_STEP == half_step
	var t0: int = Time.get_ticks_usec()
	var colour_us: int = 0
	for i in SIZE:
		if kept and i >= _keep_i0 and i < _keep_i1:
			continue
		var p: Vector3 = cell_point(_next_anchor, _next_east, _next_north, i, j, cell_m)
		var dir: Vector3 = p.normalized()
		var r: float = float(ground_radius.call(dir))
		_next_image.set_pixel(i, j, Color((dir * r - _next_anchor).dot(_next_up), 0.0, 0.0))
		_cells += 1
		if colour_row and i % COLOUR_STEP == half_step:
			var c0: int = Time.get_ticks_usec()
			_next_colours.set_pixel(i / COLOUR_STEP, j / COLOUR_STEP, colour.call(dir, r))
			colour_us += Time.get_ticks_usec() - c0
	var spent: int = Time.get_ticks_usec() - t0
	_build_us += spent - colour_us
	_colour_us += colour_us
	spent_ground_us += spent - colour_us
	spent_colour_us += colour_us


func _swap() -> void:
	_image = _next_image
	if _next_colours != null:
		_colours = _next_colours
		if colour_texture == null:
			colour_texture = ImageTexture.create_from_image(_colours)
		else:
			colour_texture.update(_colours)
	if texture == null or texture.get_size() != Vector2(SIZE, SIZE):
		texture = ImageTexture.create_from_image(_image)
	else:
		texture.update(_image)
	_heights = _image.get_data().to_float32_array()
	anchor = _next_anchor
	east = _next_east
	north = _next_north
	up = _next_up
	_frame_origin = _next_origin
	var highest: float = -INF
	for h: float in _heights:
		highest = maxf(highest, h)
	top_m = highest
	last_build_ms = _build_us / 1000.0
	last_colour_ms = _colour_us / 1000.0
	last_build_cells = _cells
	ready = true
	_row = -1


## Distance along the ground between two planet-local points (the chord: the grid is a few hundred
## metres, curvature is millimetres there).
static func _along_ground(a: Vector3, b: Vector3) -> float:
	return a.distance_to(b)
