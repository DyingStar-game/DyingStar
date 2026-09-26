class_name StarMapGround
extends Node3D
## The relief tiles of ONE body, and their whole life cycle. Nothing else lives here.
##
## It replaces a single mesh that was rebuilt wholesale every time anything changed. That design could
## not be made to work: a rebuild cost hundreds of milliseconds, the camera guard it produced moved the
## camera, the moved camera changed the level, and the level changed asked for another rebuild. The
## chart spent its life rebuilding and never settled.
##
## The shape of the answer is the game's own, in [PlanetTerrain]: a set of tiles keyed by
## [code](nside, ipix)[/code], a WANTED set recomputed from scratch on a slow clock, and a world that is
## only ever changed BY THE DIFFERENCE. Moving the camera a little then costs the few tiles that came
## into view, not the whole planet.
##
## Deliberately NOT ported from the game: the 2:1 balance pass and the edge-stitch masks. Those exist so
## a player can walk across a seam; a chart is looked at, and skirts are enough.

## How often the wanted set may be recomputed, on the WALL clock.
##
## Two clocks, as [PlanetTerrain] does: the decision is paced in real time, the harvest runs every
## rendered frame. Pacing the decision on frames instead means a slow frame replays the traversal more
## often, which makes the next frame slower still.
const DECIDE_EVERY_MS: int = 250
## How many tiles may be building at once. Three keeps a core free for the frame and bounds the
## worst-case wait when the level changes.
const MAX_IN_FLIGHT: int = 3
## How long one frame may spend turning finished meshes into nodes. A count alone does not bound
## anything — tiles differ by an order of magnitude in cost — so the budget is in milliseconds, and at
## least one tile is always taken so the queue cannot stall.
const ASSEMBLE_BUDGET_MS: float = 4.0
## Subdivisions per tile edge. A tile carries 32 samples a side, so 24 costs a little smoothing and a
## third of the vertices.
const GRID_RES: int = 24

## Which body this ground belongs to. Set once by the chart; everything else about the body — its
## radius, how fine its tiles go — is read from its manifest by [StarMapRelief], so there is one
## description of a body and not two.
var body_key: String = ""

## Tiles on screen, by id. The id packs the level and the pixel into one int — see [method tile_id] —
## which is what makes the diff, the ancestor test and the dictionary lookups all trivial.
var _active: Dictionary = {}
## Tiles being built, id -> {"task": int, "slot": Array}. The slot is a one-element array the worker
## writes into: no shared field, so no race to reason about.
var _in_flight: Dictionary = {}
## Tiles wanted but not yet queued, nearest first.
var _pending: Array[int] = []
## The wanted set of the moment, as a set of ids.
var _desired: Dictionary = {}
## The level everything is currently aiming at, and when the next decision is allowed.
var _level: int = 0
var _decide_at_ms: int = 0
var _material: StandardMaterial3D = null


## Print what the ground is doing, to the client log. On while the rewrite is being validated: the
## criterion for the first step is that this goes SILENT when nothing moves. Set to false before the
## branch is committed.
const DEBUG_GROUND: bool = false


func _say(what: String) -> void:
	if DEBUG_GROUND:
		print("[Sol] %s : %s" % [body_key, what])


## Pack a level and a pixel into one integer key.
##
## The whole reason the rest of this file is short. Godot's ints are 64-bit, nside never exceeds 2^13
## and ipix never exceeds 12·nside², so the two fit side by side with room to spare — and then a parent
## is a shift, a child is an add, and "is this the same tile" is an integer compare.
static func tile_id(nside: int, ipix: int) -> int:
	return (nside << 32) | ipix


static func id_nside(id: int) -> int:
	return id >> 32


static func id_ipix(id: int) -> int:
	return id & 0xFFFFFFFF


func _ready() -> void:
	_material = StandardMaterial3D.new()
	# The tiles carry no vertex colours yet, so Godot hands the shader white and the body's own colour
	# comes through. That is what the chart wants until the ground learns its real colour.
	mesh_material()


## The material every tile is drawn with. One instance for all of them: they differ in geometry only.
func mesh_material(colour: Color = Color.WHITE) -> void:
	if _material == null:
		_material = StandardMaterial3D.new()
	_material.albedo_color = colour
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.metallic = 0.0
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED


## Is anything drawn yet? The chart hides the smooth sphere only once the ground can replace it.
func has_tiles() -> bool:
	return not _active.is_empty()


## The level everything is currently drawn at. The camera guard and the scale bar must measure the
## ground at THIS level, or they answer about a surface the screen is not showing.
func level() -> int:
	return _level


## How many of the wanted tiles are drawn, and how many are wanted. The readout shows them filling in,
## which is what separates "still working" from "stuck".
##
## Numbers, not a sentence. A sentence built here would be built in one language and would have to be
## poured into a translated format string somewhere else, which is exactly how this went wrong once: the
## ground handed the readout a string, the string landed in a %d hole, and Godot's formatter failed
## sixty times a second while silently abandoning the rest of the function that called it.
func tiles_up() -> int:
	return _active.size()


func tiles_wanted() -> int:
	return _desired.size()


## Drive the ground: harvest what is finished, then — at most four times a second — decide again.
##
## [param centre_dir] is where the camera is, as a direction in the BODY's own frame; [param altitude_m]
## how high above its ground. Negative altitude means the body is not being watched, and the ground
## falls back to the whole globe.
func refresh(centre_dir: Vector3, altitude_m: float) -> void:
	_harvest()
	var now: int = Time.get_ticks_msec()
	if now < _decide_at_ms:
		_pump()
		return
	_decide_at_ms = now + DECIDE_EVERY_MS
	_decide(centre_dir, altitude_m)
	_pump()


## Throw everything away — the body changed, or the chart closed.
func clear() -> void:
	for id: int in _in_flight:
		WorkerThreadPool.wait_for_task_completion(int((_in_flight[id] as Dictionary)["task"]))
	_in_flight.clear()
	_pending.clear()
	_desired.clear()
	_active.clear()
	_level = 0
	for child: Node in get_children():
		child.queue_free()


# ---------------------------------------------------------------------------
# Deciding
# ---------------------------------------------------------------------------

## Recompute the wanted set, then change the world only where it differs.
##
## The wanted set is rebuilt from nothing every time, which is cheap and, more importantly, stateless:
## there is no accumulated notion of what ought to be on screen that could drift out of step with what
## is. Everything expensive is in the diff, and the diff is empty when nothing moved.
func _decide(centre_dir: Vector3, altitude_m: float) -> void:
	# The level and its tiles come back together, from the one place that owns that arithmetic. Deciding
	# the level here and fetching the tiles there is how the ground drawn and the ground measured came
	# apart once, and nothing complains when they do.
	var plan: Dictionary = StarMapRelief.plan_patch(body_key, centre_dir, altitude_m, _level)
	var tiles: PackedInt32Array = plan["tiles"]
	if tiles.is_empty():
		return  # no data for this body at all; whatever is on screen stays there
	var level: int = int(plan["level"])
	if DEBUG_GROUND:
		# get_child_count() beside _active.size() is the discriminator: equal and large while the screen
		# shows one tile means the nodes exist and are not being DRAWN, which is a different fault
		# entirely from the bookkeeping being wrong.
		_say("decision: altitude %.0f km, n%d, %d voulues, %d actives, %d noeuds"
				% [altitude_m / 1000.0, level, tiles.size(), _active.size(), get_child_count()])
	_level = level
	_desired.clear()
	for ipix: int in tiles:
		_desired[tile_id(level, ipix)] = true

	# Queue what is missing, nearest the camera first. Only the DIFFERENCE is sorted: sorting the whole
	# wanted set every quarter second is work proportional to the view, not to what changed.
	var fresh: Array[int] = []
	for id: int in _desired:
		if not _active.has(id) and not _in_flight.has(id) and not _pending.has(id):
			fresh.append(id)
	if not fresh.is_empty():
		var centre: Vector3 = centre_dir.normalized()
		fresh.sort_custom(func(a: int, b: int) -> bool:
			return HEALPix.pix2vec_nest(id_nside(a), id_ipix(a)).dot(centre) \
					> HEALPix.pix2vec_nest(id_nside(b), id_ipix(b)).dot(centre))
		_pending.append_array(fresh)

	# And drop what is no longer wanted — but only once whatever replaces it is actually on screen.
	# Removing eagerly opens a hole for as long as the replacement takes to build, which at a level
	# change is every tile at once.
	for id: int in _active.keys():
		if _desired.has(id) or not _may_drop(id):
			continue
		var node: Node = _active[id]
		_active.erase(id)
		if is_instance_valid(node):
			node.queue_free()
	# A tile that is neither wanted nor superseded stays; one that was queued and is no longer wanted
	# never gets built.
	var keep: Array[int] = []
	for id: int in _pending:
		if _desired.has(id):
			keep.append(id)
	_pending = keep


## May this tile, which nothing wants any more, be taken off screen yet?
##
## Only ever asked about tiles that have fallen out of the wanted set, and there are three cases. They
## are not symmetric, and getting any of them wrong is visible: too eager opens a hole in the body, too
## lazy leaves two surfaces stacked on the same ground, shimmering against each other.
##
## - At the level being drawn, the tile has simply left the VIEW, and nothing is coming to replace it
##   because nothing needs to. It goes at once.
## - FINER than the level being drawn — the chart coarsened — one ancestor covers it, so wait for that
##   one ancestor.
## - COARSER — the chart refined — its four children cover it, so wait for all four. Dropping it with
##   three of them up opens a hole for as long as the fourth takes to build.
##
## The first case used to answer "wait", because this was written to answer a question about REPLACEMENT
## while the caller was asking one about REMOVAL. Nothing replaces a tile that has merely gone out of
## view, so nothing ever let it go: measured in game at 187 tiles on screen for 84 wanted while panning
## at one level, 332 for 12 after pulling back to the globe, and growing for as long as the camera moved.
func _may_drop(id: int) -> bool:
	if _level <= 0:
		return false
	var mine: int = id_nside(id)
	if mine == _level:
		return true
	if mine > _level:
		var ipix: int = id_ipix(id)
		var level: int = mine
		while level > _level:
			@warning_ignore("integer_division")
			level /= 2
			ipix = ipix >> 2
		return _active.has(tile_id(_level, ipix))
	@warning_ignore("integer_division")
	var ratio: int = _level / mine
	if ratio > 2:
		# More than one step apart, so the covering set is sixteen tiles or more. Rather than walk it,
		# wait for the queue to drain: a jump of two levels at once is rare and a moment of an extra
		# surface is cheaper than the bookkeeping.
		return _pending.is_empty() and _in_flight.is_empty()
	for k: int in range(4):
		var child: int = tile_id(_level, id_ipix(id) * 4 + k)
		if _desired.has(child) and not _active.has(child):
			return false
	return true


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

## Start as many queued tiles as the budget allows.
func _pump() -> void:
	while _in_flight.size() < MAX_IN_FLIGHT and not _pending.is_empty():
		var id: int = _pending.pop_front()
		if _active.has(id) or _in_flight.has(id) or not _desired.has(id):
			continue
		# A one-element array the worker writes into, and nothing else is shared. The old design kept
		# the result in a field of the owner, which meant every build raced against the next request.
		var slot: Array = [null]
		var key: String = body_key
		var nside: int = id_nside(id)
		var ipix: int = id_ipix(id)
		var task: int = WorkerThreadPool.add_task(func() -> void:
			slot[0] = StarMapRelief.build_tile(key, nside, ipix, GRID_RES))
		_in_flight[id] = {"task": task, "slot": slot}


## Turn finished meshes into nodes, within a time budget.
func _harvest() -> void:
	if _in_flight.is_empty():
		return
	var started: int = Time.get_ticks_usec()
	var taken: int = 0
	for id: int in _in_flight.keys():
		if taken > 0 and float(Time.get_ticks_usec() - started) / 1000.0 > ASSEMBLE_BUDGET_MS:
			break
		var job: Dictionary = _in_flight[id]
		var task: int = int(job["task"])
		if not WorkerThreadPool.is_task_completed(task):
			continue
		# Waited on although it is finished: that is what publishes the worker's writes to this thread.
		WorkerThreadPool.wait_for_task_completion(task)
		_in_flight.erase(id)
		taken += 1
		var mesh: ArrayMesh = (job["slot"] as Array)[0] as ArrayMesh
		if mesh == null or not _desired.has(id):
			continue  # no data for that tile, or the view moved on while it was building
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = _material
		add_child(node)
		_active[id] = node
		_say("n%d f%d bati (%d/%d, %d en vol)" % [
				id_nside(id), id_ipix(id), _active.size(), _desired.size(), _in_flight.size()])
