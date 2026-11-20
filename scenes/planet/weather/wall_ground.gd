class_name WallGround
extends RefCounted
## The ground under one dust wall, as its volume needs it: a small map of the terrain's height across the
## wall's box, so the dust stands on the relief (down in the plains, up on the plateaus) instead of on a
## flat floor. Read from the planet's heightmap on a worker, again every now and then as the wall runs.
##
## Heights are metres over the planet's reference sphere: the same whatever the wall is passing over. A map
## stays where it was read, on the ground: the wall slides over it (shift_m) until the next one is read, so
## the relief under the dust does not move with the wall. It is read MARGIN times as wide as the box for that.
##
## Until the first map is read the ground is taken flat (flat), with FLAT_REACH_M of room either way.

## The map's size: places along the front, and from the box's back to its leading face.
const SIZE := Vector2i(64, 24)
## The heightmap's level the heights are read at (the plateaus and valleys, not the rocks: as
## ClimateWeather.RELIEF_NSIDE).
const NSIDE := 256
## How long a map is kept before it is read again (s), and how much wider than the box it is read: the wall
## runs well inside that margin in that time.
const KEPT_S := 8.0
const MARGIN := 1.25
const FLAT_REACH_M := 1500.0

## The map (R: metres over the reference sphere); the lowest and the highest ground in it; what it spans on
## the ground (m: along the front, along the wall's way).
var texture: ImageTexture
var low := -FLAT_REACH_M
var high := FLAT_REACH_M
var span := Vector2.ONE

var _heights := PackedFloat32Array()
var _read := false
var _task := -1
var _read_at := -INF
## Where the map in use was read: its middle (the body's frame, on the reference sphere), and its two axes.
var _middle := Vector3.ZERO
var _across := Vector3.RIGHT
var _way := Vector3.BACK


func _init() -> void:
	texture = ImageTexture.create_from_image(_image(1, 1, PackedFloat32Array([0.0])))


## Before the first map: the ground everywhere at [param height] (the wall's middle's).
func flat(height: float) -> void:
	if _read:
		return
	low = height - FLAT_REACH_M
	high = height + FLAT_REACH_M
	texture.update(_image(1, 1, PackedFloat32Array([height])))


## Reads the map again when it is due, on a worker. [param data]: the planet; [param middle]: the middle of
## the box, in the body's frame, on the reference sphere; [param across], [param way]: unit, along the front
## and along the wall's way; [param size]: the box's length and depth (m); [param now]: seconds.
func refresh(data: PlanetData, middle: Vector3, across: Vector3, way: Vector3, size: Vector2, now: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if now - _read_at < KEPT_S:
		return
	_read_at = now
	var over := size * MARGIN
	_task = WorkerThreadPool.add_task(func() -> void:
		var heights := PackedFloat32Array()
		heights.resize(SIZE.x * SIZE.y)
		var nside := data.sample_nside_for(NSIDE)
		for j in SIZE.y:
			var z := ((j + 0.5) / SIZE.y - 0.5) * over.y
			for i in SIZE.x:
				var x := ((i + 0.5) / SIZE.x - 0.5) * over.x
				heights[j * SIZE.x + i] = data.sample_height_for_direction((middle + across * x + way * z).normalized(),
						-1, -1, Vector2i(-1, -1), null, nside)
		_use.call_deferred(heights, middle, across, way, over))


func _use(heights: PackedFloat32Array, middle: Vector3, across: Vector3, way: Vector3, over: Vector2) -> void:
	_heights = heights
	_middle = middle
	_across = across
	_way = way
	span = over
	_read = true
	low = INF
	high = -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	# A new texture, not the old one resized: a material holding a texture whose size changed under it read
	# nothing from it (2026-11-19: the wall vanished as soon as its first map came).
	texture = ImageTexture.create_from_image(_image(SIZE.x, SIZE.y, heights))


static func _image(width: int, height: int, values: PackedFloat32Array) -> Image:
	return Image.create_from_data(width, height, false, Image.FORMAT_RF, values.to_byte_array())


## How far the box's middle now ([param middle], as refresh's) is from the map's, metres along the front and
## along the wall's way: what the volume adds to a place of the box to find it on the map.
func shift_m(middle: Vector3) -> Vector2:
	var moved := middle - _middle
	return Vector2(moved.dot(_across), moved.dot(_way)) if _read else Vector2.ZERO


## The ground's height at a point of the body's frame (whatever its own height), metres over the reference
## sphere; the flat ground's before the first map.
func height_at(point: Vector3) -> float:
	if not _read:
		return low + FLAT_REACH_M
	var from := point - _middle
	var i := clampi(int((from.dot(_across) / span.x + 0.5) * SIZE.x), 0, SIZE.x - 1)
	var j := clampi(int((from.dot(_way) / span.y + 0.5) * SIZE.y), 0, SIZE.y - 1)
	return _heights[j * SIZE.x + i]


## Waits for the read under way, if any (before the planet goes).
func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
