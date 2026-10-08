class_name DustGround
extends RefCounted
## The real ground around the camera, as a small height grid the wind's dust layer lies on
## (aerial_perspective.gdshader, dust_ground*). Without it the layer measured its height from a flat
## plane through the ground under the camera: seen from above, hills rose out of it and hollows filled
## to the camera's level, with sharp contour lines (2026-10-08). A first fix guessed the ground from
## the depth buffer and drew 2x2-pixel stairs on every silhouette: the screen pass only sees the end
## of each ray, never the ground under it on the way.
##
## The grid is SIZE x SIZE cells of CELL_M around an anchor laid on the ground under the camera, in
## the planet's own frame (the tangent plane there: east, north, up). Each texel holds the height of
## the real ground (PlanetData.crack_aware_surface_dist: relief and canyons) over that tangent plane.
## Everything the shader gets is relative to the anchor, so no astronomic coordinate reaches float32.
##
## The ground query reads the streamed terrain tiles and is the dearest thing a client asks, so the
## grid is built a few rows at a time within BUDGET_MS a frame, never on a worker (the tile caches are
## not thread safe). The grid in use stays on screen until the next one is complete, then both swap
## at once: texture and frame together.

const SIZE: int = 128
const CELL_M: float = 5.5
## How far (m, along the ground) the camera goes from the anchor before a new grid is started.
const REBUILD_M: float = 40.0
## Time spent building per frame, ms.
const BUDGET_MS: float = 1.5

## The grid in use: its anchor and tangent frame (planet-local), the heights' highest point over
## that plane, and whether there is one at all.
var ready: bool = false
var anchor: Vector3 = Vector3.ZERO
var east: Vector3 = Vector3.RIGHT
var north: Vector3 = Vector3.FORWARD
var up: Vector3 = Vector3.UP
var top_m: float = 0.0
var texture: ImageTexture = null
## The last complete build: ms of query time and samples, for the dust probe.
var last_build_ms: float = 0.0

var _heights: PackedFloat32Array = PackedFloat32Array()
var _next_anchor: Vector3 = Vector3.ZERO
var _next_east: Vector3 = Vector3.RIGHT
var _next_north: Vector3 = Vector3.FORWARD
var _next_up: Vector3 = Vector3.UP
var _row: int = -1  # the row being built; -1 = no build running
var _build_us: int = 0


## Keep the grid around [param ground_point] (planet-local, the ground under the camera): start a
## new build when it has moved REBUILD_M from the anchor, and spend up to BUDGET_MS on the one
## running. [param ground_radius] gives the distance from the planet's centre of the ground along a
## unit direction (PlanetData.crack_aware_surface_dist). Returns true when a new grid was swapped in.
func update(ground_point: Vector3, ground_radius: Callable, budget_ms: float = BUDGET_MS) -> bool:
	if _row < 0 and (not ready or _along_ground(ground_point, anchor) > REBUILD_M):
		_start(ground_point)
	if _row < 0:
		return false
	var deadline: int = Time.get_ticks_usec() + int(budget_ms * 1000.0)
	while _row < SIZE:
		var t0: int = Time.get_ticks_usec()
		_build_row(_row, ground_radius)
		_build_us += Time.get_ticks_usec() - t0
		_row += 1
		if Time.get_ticks_usec() >= deadline:
			break
	if _row < SIZE:
		return false
	_swap()
	return true


## Half the grid's width, m.
static func half_m() -> float:
	return SIZE * CELL_M * 0.5


## The planet-local point of cell ([param i], [param j]) on the tangent plane at [param at].
static func cell_point(at: Vector3, e: Vector3, n: Vector3, i: int, j: int) -> Vector3:
	var u: float = (i + 0.5) * CELL_M - half_m()
	var v: float = (j + 0.5) * CELL_M - half_m()
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
static func ground_at(heights: PackedFloat32Array, e: Vector3, n: Vector3, q: Vector3) -> float:
	var x: float = (q.dot(e) + half_m()) / CELL_M - 0.5
	var y: float = (q.dot(n) + half_m()) / CELL_M - 0.5
	if x < 0.0 or y < 0.0 or x > SIZE - 1 or y > SIZE - 1:
		return NAN
	var i: int = mini(int(x), SIZE - 2)
	var j: int = mini(int(y), SIZE - 2)
	var fx: float = x - i
	var fy: float = y - j
	var a: float = lerpf(heights[j * SIZE + i], heights[j * SIZE + i + 1], fx)
	var b: float = lerpf(heights[(j + 1) * SIZE + i], heights[(j + 1) * SIZE + i + 1], fx)
	return lerpf(a, b, fy)


func _start(ground_point: Vector3) -> void:
	_next_anchor = ground_point
	var f: Array = tangent_frame(ground_point)
	_next_east = f[0]
	_next_north = f[1]
	_next_up = f[2]
	_heights.resize(SIZE * SIZE)
	_row = 0
	_build_us = 0


func _build_row(j: int, ground_radius: Callable) -> void:
	for i in SIZE:
		var p: Vector3 = cell_point(_next_anchor, _next_east, _next_north, i, j)
		var dir: Vector3 = p.normalized()
		var ground: Vector3 = dir * float(ground_radius.call(dir))
		_heights[j * SIZE + i] = (ground - _next_anchor).dot(_next_up)


func _swap() -> void:
	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RF, _heights.to_byte_array())
	if texture == null or texture.get_size() != Vector2(SIZE, SIZE):
		texture = ImageTexture.create_from_image(image)
	else:
		texture.update(image)
	anchor = _next_anchor
	east = _next_east
	north = _next_north
	up = _next_up
	var highest: float = -INF
	for h: float in _heights:
		highest = maxf(highest, h)
	top_m = highest
	last_build_ms = _build_us / 1000.0
	ready = true
	_row = -1


## Distance along the ground between two planet-local points (the chord: the grid is a few hundred
## metres, curvature is millimetres there).
static func _along_ground(a: Vector3, b: Vector3) -> float:
	return a.distance_to(b)
