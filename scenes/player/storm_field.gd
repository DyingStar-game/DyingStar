class_name StormField
extends RefCounted
## The storms around the camera as the far dust volume sees them (aerial_perspective.gdshader,
## storm_*): a regional grid of the storm dust's extinction and of the ground it stands on, so a dust
## storm tens of kilometres away is a wall on the horizon, a valley it filled is veiled, and from a
## ship it is a brown carpet below. The near layer (DustGround, the first 300 m) cannot show any of
## it, and the sky's old storm knob thickened the whole veil around the observer at once: a storm
## existed on screen only once you were in it.
##
## The same numbers as everything else: WeatherSampler's systems (their dust optical depth τ) spread
## over WeatherSampler.DUST_LAYER_M of air over the ground, the convention the sampler's visibility
## already uses. So the visibility inside the volume is the one the weather debug prints.
##
## SIZE x SIZE cells of CELL_M around an anchor (planet-local, the ground under the camera), on the
## tangent frame there. Two textures: the ground over the sphere through the anchor (m; red the real
## ground, green the storm's lid ground, smoothed over LID_CELLS) and the storm extinction (1/m).
## The ground reads the streamed terrain tiles: built on the main thread within a budget, once per
## anchor. The dust moves with the systems: recomputed on a worker every
## REFRESH_S from a copy of the systems (the sampler's sums are pure). A new anchor swaps in only once
## both of its textures are complete, frame and textures together.

const SIZE: int = 128
const CELL_M: float = 4000.0
## How far (m) the camera goes from the anchor before a new grid is started.
const REBUILD_M: float = 50000.0
## How often (s) the dust is recomputed for the anchor in use.
const REFRESH_S: float = 10.0
## Main-thread time spent on the ground per frame, ms.
const BUDGET_MS: float = 1.0
## The storm's lid follows the ground averaged over this many cells each way (5 = 44 km across):
## the top of the air the wind stirs is far smoother than the relief. Valleys fill deeper, hills
## drown, and only real peaks rise out of it. Draped 1 km over every hill, it read wrong from a ship.
const LID_CELLS: int = 5

## The grid in use (planet-local anchor and frame), its textures and what the shader needs to bound
## its march: the highest ground over the anchor's sphere and the strongest extinction.
var ready: bool = false
var anchor: Vector3 = Vector3.ZERO
var east: Vector3 = Vector3.RIGHT
var north: Vector3 = Vector3.FORWARD
var up: Vector3 = Vector3.UP
var ground_top_m: float = 0.0
var beta_max: float = 0.0
var ground_texture: ImageTexture = null
var dust_texture: ImageTexture = null
## The storm dust's colour per cell (RGB albedo): the ground it stands on, mixed over LID_CELLS.
var albedo_texture: ImageTexture = null
## The last ground build's query time (ms), for the dust probe.
var last_ground_ms: float = 0.0

var _next: Dictionary = {}  # the anchor being built: {anchor, east, north, up, ground, row, us}
var _task: int = -1
var _task_result: PackedFloat32Array = PackedFloat32Array()
var _task_lid: PackedFloat32Array = PackedFloat32Array()
var _task_albedo: PackedFloat32Array = PackedFloat32Array()
var _task_for_next: bool = false
var _refresh_at: float = 0.0


## Keep the grid around [param ground_point] (planet-local): [param ground_radius] gives the ground's
## distance from the centre along a unit direction, [param dust_job] returns the systems' extinction
## sampler as a Callable(dir) -> 1/m that is safe to run on a worker (see dust_sampler), and
## [param ground_colour] the ground's colour along a direction (GroundLook.colour_at; none = a pale
## ochre). Returns true when the textures changed.
func update(ground_point: Vector3, ground_radius: Callable, dust_job: Callable, now_s: float,
		budget_ms: float = BUDGET_MS, ground_colour: Callable = Callable()) -> bool:
	var changed: bool = _collect(now_s)
	if _next.is_empty() and (not ready or ground_point.distance_to(anchor) > REBUILD_M):
		_start(ground_point)
	if not _next.is_empty():
		if int(_next["row"]) < SIZE:
			_build_ground(ground_radius, ground_colour, budget_ms)
		# The new anchor's dust as soon as its ground is done and no other job runs (a refresh still
		# running is collected first, then dropped: see _collect).
		if int(_next["row"]) >= SIZE and _task < 0:
			_launch(dust_job, _next, true)
	elif ready and _task < 0 and now_s >= _refresh_at:
		_launch(dust_job, {"anchor": anchor, "east": east, "north": north}, false)
	return changed


## A Callable(dir) -> storm extinction (1/m) over [param profile] for [param systems] (copies of the
## state Dictionaries) and the debug [param override]: the sampler's summed dust τ over DUST_LAYER_M.
## Pure, so a worker can run it.
static func dust_sampler(profile: ClimateProfile, systems: Array, override: Dictionary) -> Callable:
	return func(dir: Vector3) -> float:
		var tau: float = 0.0
		if override.has("dust_tau"):
			tau = float(override["dust_tau"])
		else:
			var ll: Vector2 = HEALPix.vec2lonlat(dir)
			for s: Dictionary in systems:
				tau += float(WeatherSampler.contribution(profile, s, ll.x, ll.y)["dust_tau"])
		return tau / WeatherSampler.DUST_LAYER_M


## Half the grid's width, m.
static func half_m() -> float:
	return SIZE * CELL_M * 0.5


## The planet-local point of cell ([param i], [param j]) on the tangent plane at [param at].
static func cell_point(at: Vector3, e: Vector3, n: Vector3, i: int, j: int) -> Vector3:
	return at + e * ((i + 0.5) * CELL_M - half_m()) + n * ((j + 0.5) * CELL_M - half_m())


## The height (m) of [param q] (planet-local, relative to the anchor at radius [param r]) over the
## sphere through the anchor, in the form the shader uses: no difference of two big radii.
static func altitude_over_anchor(q: Vector3, u: Vector3, r: float) -> float:
	var w: float = q.dot(u)
	var s2: float = q.length_squared() - w * w
	return (2.0 * r * w + w * w + s2) / (sqrt((r + w) * (r + w) + s2) + r)


func _start(ground_point: Vector3) -> void:
	var f: Array = DustGround.tangent_frame(ground_point)
	var heights := PackedFloat32Array()
	heights.resize(SIZE * SIZE)
	var colours := PackedColorArray()
	colours.resize(SIZE * SIZE)
	_next = {"anchor": ground_point, "east": f[0], "north": f[1], "up": f[2], "ground": heights,
			"colour": colours, "row": 0, "us": 0}


func _build_ground(ground_radius: Callable, ground_colour: Callable, budget_ms: float) -> void:
	var deadline: int = Time.get_ticks_usec() + int(budget_ms * 1000.0)
	var a: Vector3 = _next["anchor"]
	var r: float = a.length()
	var heights: PackedFloat32Array = _next["ground"]
	var colours: PackedColorArray = _next["colour"]
	while int(_next["row"]) < SIZE:
		var t0: int = Time.get_ticks_usec()
		var j: int = _next["row"]
		for i in SIZE:
			var dir: Vector3 = cell_point(a, _next["east"], _next["north"], i, j).normalized()
			heights[j * SIZE + i] = float(ground_radius.call(dir)) - r
			colours[j * SIZE + i] = ground_colour.call(dir) if ground_colour.is_valid() else WeatherSky.BLOW_FALLBACK_COLOUR
		_next["us"] = int(_next["us"]) + Time.get_ticks_usec() - t0
		_next["row"] = j + 1
		if Time.get_ticks_usec() >= deadline:
			break
	_next["ground"] = heights
	_next["colour"] = colours


func _launch(dust_job: Callable, frame: Dictionary, for_next: bool) -> void:
	var a: Vector3 = frame["anchor"]
	var e: Vector3 = frame["east"]
	var n: Vector3 = frame["north"]
	_task_for_next = for_next
	_task_result = PackedFloat32Array()
	_task_lid = PackedFloat32Array()
	_task_albedo = PackedFloat32Array()
	var colours: PackedColorArray = (frame["colour"] as PackedColorArray).duplicate() if for_next \
			else PackedColorArray()
	# A new anchor's lid (the smoothed ground) is worked out here too: a few hundred thousand sums,
	# a visible hitch on the main thread.
	var ground: PackedFloat32Array = (frame["ground"] as PackedFloat32Array).duplicate() if for_next \
			else PackedFloat32Array()
	_task = WorkerThreadPool.add_task(func() -> void:
		var out := PackedFloat32Array()
		out.resize(SIZE * SIZE)
		for j in SIZE:
			for i in SIZE:
				out[j * SIZE + i] = float(dust_job.call(cell_point(a, e, n, i, j).normalized()))
		if not ground.is_empty():
			_task_lid = smoothed(ground, LID_CELLS)
		if not colours.is_empty():
			_task_albedo = dust_albedo(colours)
		_task_result = out)


## Take a finished dust job: either the last piece of a new anchor (swap everything) or a refresh of
## the one in use (the dust texture only). True when the textures changed.
func _collect(now_s: float) -> bool:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_refresh_at = now_s + REFRESH_S
	var dust: PackedFloat32Array = _task_result
	if dust.size() != SIZE * SIZE:
		return false
	if _task_for_next:
		if _next.is_empty():
			return false
		var ground: PackedFloat32Array = _next["ground"]
		var lid: PackedFloat32Array = _task_lid if _task_lid.size() == SIZE * SIZE else ground
		ground_texture = _texture2(ground_texture, ground, lid)
		anchor = _next["anchor"]
		east = _next["east"]
		north = _next["north"]
		up = _next["up"]
		ground_top_m = _max_of(lid)
		if _task_albedo.size() == SIZE * SIZE * 3:
			var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBF, _task_albedo.to_byte_array())
			if albedo_texture == null:
				albedo_texture = ImageTexture.create_from_image(image)
			else:
				albedo_texture.update(image)
		last_ground_ms = int(_next["us"]) / 1000.0
		_next = {}
	elif _next.size() > 0:
		return false  # a refresh finished after a new anchor began: that anchor's own job follows
	dust_texture = _texture(dust_texture, dust)
	beta_max = _max_of(dust)
	ready = true
	return true


## The storm dust's albedo per cell (RGB, interleaved): the ground's colour mixed over LID_CELLS each
## way (a storm is the ground it lifted, stirred over tens of km), then made a dust albedo the way the
## near layer does (WeatherSky.blow_albedo_of). Tinted by the ground UNDER THE OBSERVER instead, the
## whole storm turned white over a corundum plateau and yellow over sand as you flew (2026-10-08).
static func dust_albedo(colours: PackedColorArray) -> PackedFloat32Array:
	var channels: Array = []
	for c in 3:
		var one := PackedFloat32Array()
		one.resize(SIZE * SIZE)
		for k in SIZE * SIZE:
			one[k] = colours[k][c]
		channels.append(smoothed(one, LID_CELLS))
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE * 3)
	for k in SIZE * SIZE:
		var a: Vector3 = WeatherSky.blow_albedo_of(Color(channels[0][k], channels[1][k], channels[2][k]))
		out[3 * k] = a.x
		out[3 * k + 1] = a.y
		out[3 * k + 2] = a.z
	return out


## [param data] (SIZE x SIZE) averaged over a square of (2 [param radius] + 1) cells, edges clamped:
## two separable box passes.
static func smoothed(data: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var pass1 := PackedFloat32Array()
	pass1.resize(SIZE * SIZE)
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	var span: float = 2.0 * radius + 1.0
	for j in SIZE:
		for i in SIZE:
			var s: float = 0.0
			for k in range(-radius, radius + 1):
				s += data[j * SIZE + clampi(i + k, 0, SIZE - 1)]
			pass1[j * SIZE + i] = s / span
	for j in SIZE:
		for i in SIZE:
			var s: float = 0.0
			for k in range(-radius, radius + 1):
				s += pass1[clampi(j + k, 0, SIZE - 1) * SIZE + i]
			out[j * SIZE + i] = s / span
	return out


## A two-channel texture: [param r] the ground, [param g] the storm's lid ground (smoothed).
static func _texture2(tex: ImageTexture, r: PackedFloat32Array, g: PackedFloat32Array) -> ImageTexture:
	var both := PackedFloat32Array()
	both.resize(SIZE * SIZE * 2)
	for k in SIZE * SIZE:
		both[2 * k] = r[k]
		both[2 * k + 1] = g[k]
	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGF, both.to_byte_array())
	if tex == null:
		return ImageTexture.create_from_image(image)
	tex.update(image)
	return tex


static func _texture(tex: ImageTexture, data: PackedFloat32Array) -> ImageTexture:
	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RF, data.to_byte_array())
	if tex == null:
		return ImageTexture.create_from_image(image)
	tex.update(image)
	return tex


static func _max_of(data: PackedFloat32Array) -> float:
	var m: float = -INF
	for v: float in data:
		m = maxf(m, v)
	return m
