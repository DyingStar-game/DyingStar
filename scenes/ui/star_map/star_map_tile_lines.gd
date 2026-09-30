class_name StarMapTileLines
extends MeshInstance3D
## Lines drawn over the ground of ONE body, laid tile by tile: the roads, the canyons.
##
## What the two have in common is everything but the lines themselves. They cover the tiles the ground
## is drawing, so they change when the view does; laying a tile's lines means asking the height field
## where each point stands, which is too slow for the frame, so it happens on a worker; and the wanted
## set changes by a handful of tiles at a time, so what was laid is kept. That life cycle is here, once.
## A kind of line says only whether it has anything to draw ([method _available]) and how one tile is
## laid ([method _laying]).

## How far the lines float over the ground, as a fraction of the body's drawn radius.
##
## They are laid on the surface the chart DRAWS ([StarMapDrawnTile]), and still have to clear it: a
## piece of line is straight where the ground under it is two facets meeting at a fold, and the depth
## buffer at these distances does not tell two things apart that are a few metres from one another.
## Three hundredths of a thousandth is about 190 m on Tarsis III — invisible from anywhere a whole
## network is being read.
const LIFT: float = 3.0e-5
## How many tiles' worth of lines are kept. A little over two views of
## [constant StarMapRelief.PATCH_TILES_MAX], so zooming out and back in finds both levels still there.
const SEGMENTS_KEPT: int = 1024

var body_key: String = ""

var _drawn: Dictionary = {}
## The lines of each tile already laid on the ground, id -> [points, colours]. The expensive half of a
## refresh is not concatenating lines, it is working out where they go — and the wanted set changes by
## a handful of tiles, so almost all of it is the same as last time.
var _segments: Dictionary = {}
## What the lines are drawn with, and what the strips laid beside them are: see [method _ready].
var _material: StandardMaterial3D = null
var _strip_material: StandardMaterial3D = null
## The worker laying the tiles not seen yet, or -1, and the slot it fills: id -> [points, colours].
## While it runs, whatever [method _laying] captured is the worker's alone.
var _task: int = -1
var _job: Dictionary = {}
## New segments arrived since the mesh was last put together.
var _dirty: bool = false
## Lines laid before the last [method lay_again], drawn for a tile until it is laid afresh.
var _outdated: Dictionary = {}
## The worker in flight was started before the last [method lay_again]: what it brings is not kept.
var _job_outdated: bool = false


func _ready() -> void:
	_material = StandardMaterial3D.new()
	# Unshaded, because a line has no surface to be lit: shaded, the far side of a planet would carry
	# lines that fade out exactly where the ground does, which is the one place a map still has to read.
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	# Blended, though nothing here is see-through: what is blended is drawn after the ground, without
	# writing to the depth buffer, in the order its priority says. That order is the only thing that
	# can put one of these over another. They lie on the same ground a few tens of metres apart at
	# most, which the depth buffer cannot tell apart at these distances: left to it, a line over a strip
	# came out in dashes and a strip over a strip in blocks. Against the GROUND the depth still decides,
	# so the far side of the planet hides what is on it.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = _priority()
	# The strips are seen from above whichever way their corners were wound.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# The strips under the lines: the same, drawn just before.
	_strip_material = _material.duplicate()
	_strip_material.render_priority = _priority() - 1


## Draw the lines crossing [param tiles], which are the ground's own tiles, keyed as [StarMapGround]
## keys them.
##
## Does nothing at all when the set has not changed, which is most frames: the tiles come from a
## decision taken four times a second at most.
func refresh(tiles: Dictionary) -> void:
	_harvest()
	if tiles == _drawn and not _dirty:
		return
	_drawn = tiles.duplicate()
	if not _available():
		mesh = null
		return
	if _segments.size() + _outdated.size() > SEGMENTS_KEPT and _task < 0:
		_segments.clear()  # crude, and rare: one refresh pays for its whole view again
		_outdated.clear()
	_start_missing()
	_assemble()


## Wait for the lines still being laid and draw them. For a caller that needs the mesh NOW — a test;
## the chart itself just refreshes again next frame.
func finish() -> void:
	if _task >= 0:
		_take()
	if _dirty:
		_assemble()


## Lay everything again: something every tile's lines depend on has changed. What is on screen stays
## there, tile by tile, until its replacement is laid — emptying the view for the time that takes would
## blink the whole network off at each change.
func lay_again() -> void:
	_outdated.merge(_segments, true)
	_segments.clear()
	_job_outdated = _task >= 0
	_dirty = true


## Let go of the body.
func clear() -> void:
	_wait()
	_job = {}
	_job_outdated = false
	_dirty = false
	_drawn.clear()
	_segments.clear()
	_outdated.clear()
	mesh = null
	_release()


# ---------------------------------------------------------------------------
# What a kind of line answers
# ---------------------------------------------------------------------------

## Is there anything to draw on this body at all? Asked at every change of view; remember a no.
func _available() -> bool:
	return false


## How one tile is laid: a Callable taking a tile id and returning [code][points, colours][/code], the
## two ends of each segment in the body's frame and a colour for each. Two more entries,
## [code][..., corners, colours][/code], are triangles drawn with them: what gives a line a width on
## the ground, where it has one worth showing.
##
## Asked once per batch, on the main thread, and that is where it must resolve whatever needs one — a
## planet's data, a noise built on first use. The second element says whether the Callable may then
## run on a worker: it may when it holds everything it reads and touches nothing of the node.
func _laying() -> Array:
	return [Callable(), false]


## Where this kind of line is drawn among the others, higher over lower: its lines at this priority,
## its strips just under. Two apart from one kind to the next, so the strips of one never share a
## priority with the lines of another.
func _priority() -> int:
	return 0


## Let go of whatever [method _available] opened.
func _release() -> void:
	pass


# ---------------------------------------------------------------------------

## Queue the tiles of the current view that have nothing laid yet.
func _start_missing() -> void:
	if _task >= 0:
		return  # what the worker does not cover is asked for on a later refresh
	var missing: Array[int] = []
	for id: int in _drawn:
		if not _segments.has(id):
			missing.append(id)
	if missing.is_empty():
		return
	var how: Array = _laying()
	var lay: Callable = how[0]
	if not bool(how[1]):
		for id: int in missing:
			_segments[id] = lay.call(id)
		_dirty = true
		return
	var slot: Dictionary = {}
	_job = slot
	_task = WorkerThreadPool.add_task(func() -> void:
		for id: int in missing:
			slot[id] = lay.call(id))


## Take in what the worker has finished, if it has.
func _harvest() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		_take()


## Wait for the worker — at once when it is done — and take its lines in. Its id is gone once waited on,
## so nothing may ask about it again: is_task_completed on a spent id does not answer "done".
func _take() -> void:
	_wait()
	# Laid the old way while [method lay_again] was being asked for: not kept, so it is laid afresh.
	if not _job_outdated:
		for id: int in _job:
			_segments[id] = _job[id]
			_outdated.erase(id)
	_job_outdated = false
	_job = {}
	_dirty = true


func _wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Put the mesh together from the lines laid so far for the current view.
func _assemble() -> void:
	_dirty = false
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	# And what a kind of line laid beside them to give them a width, if it did.
	var faces := PackedVector3Array()
	var face_colours := PackedColorArray()
	for id: int in _drawn:
		# As laid now, or failing that as laid before the last lay_again.
		var cached: Array = _segments.get(id, _outdated.get(id, []))
		if cached.is_empty():
			continue
		points.append_array(cached[0])
		colours.append_array(cached[1])
		if cached.size() >= 4:
			faces.append_array(cached[2])
			face_colours.append_array(cached[3])
	if points.is_empty():
		mesh = null
		return
	var built := ArrayMesh.new()
	_add_surface(built, Mesh.PRIMITIVE_LINES, points, colours, _material)
	if not faces.is_empty():
		_add_surface(built, Mesh.PRIMITIVE_TRIANGLES, faces, face_colours, _strip_material)
	mesh = built


static func _add_surface(to: ArrayMesh, primitive: Mesh.PrimitiveType, points: PackedVector3Array,
		colours: PackedColorArray, material: Material) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_COLOR] = colours
	to.add_surface_from_arrays(primitive, arrays)
	to.surface_set_material(to.get_surface_count() - 1, material)


# On deletion, NOT on leaving the tree: the chart takes this off its sphere every time it is opened and
# hangs it back on the new one, and clearing there would throw the lines away with each F2.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	_wait()
	_release()


## A line from [param from] to [param to], two directions on the body, cut into pieces no longer than
## [param step] (an angle at the body's centre) and each end put on the ground by [param place].
##
## Cut, because a line between two points far apart is a CHORD: it runs straight through the curve of
## the planet and under whatever relief stands between its ends. The export gives a railway across a
## hundred-km tile in a handful of points, and between them the line was under the ground.
static func add_line(points: PackedVector3Array, colours: PackedColorArray, from: Vector3,
		to: Vector3, step: float, place: Callable, colour: Color) -> void:
	var pieces: int = maxi(1, ceili(from.angle_to(to) / maxf(step, 1.0e-9)))
	var previous: Vector3 = place.call(from)
	for n: int in range(1, pieces + 1):
		var next: Vector3 = place.call(from.slerp(to, float(n) / float(pieces)))
		points.append(previous)
		points.append(next)
		colours.append(colour)
		colours.append(colour)
		previous = next


## One stretch of line as a strip with a width on the ground, two triangles, for the triangles a
## kind of line may lay beside its lines ([method _laying]). [param from] and [param to]
## are its ends ON the drawn ground; [param half_width] half its width as an angle at the body's
## centre. Each end runs half a width past its point, so two stretches meeting at an angle overlap
## instead of leaving a notch.
static func add_ribbon(corners: PackedVector3Array, from: Vector3, to: Vector3,
		half_width: float) -> void:
	var up: Vector3 = (from + to).normalized()
	var along: Vector3 = (to - from)
	along = (along - up * along.dot(up)).normalized()
	if along == Vector3.ZERO:
		return
	var across: Vector3 = up.cross(along)
	var from_r: float = from.length()
	var to_r: float = to.length()
	var from_dir: Vector3 = from / from_r - along * half_width
	var to_dir: Vector3 = to / to_r + along * half_width
	var a: Vector3 = (from_dir - across * half_width).normalized() * from_r
	var b: Vector3 = (from_dir + across * half_width).normalized() * from_r
	var c: Vector3 = (to_dir + across * half_width).normalized() * to_r
	var d: Vector3 = (to_dir - across * half_width).normalized() * to_r
	corners.append_array(PackedVector3Array([a, b, c, a, c, d]))
