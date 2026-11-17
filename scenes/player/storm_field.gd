class_name StormField
extends RefCounted
## The weather around the camera as the cloud layer sees it (cloud_layer.gdshaderinc, cloud_grid /
## cloud_ground): a regional grid of the storm dust's extinction, of the cloud sea's thickness and of
## the ground they stand on, so a dust storm tens of kilometres away is a wall on the horizon, a valley
## it filled is veiled, and from a ship it is a brown carpet below. The near layer (DustGround, the
## first 300 m) cannot show any of it, and the sky's old storm knob thickened the whole veil around the
## observer at once: a storm existed on screen only once you were in it.
##
## The same numbers as everything else: WeatherSampler's systems (their dust optical depth τ) spread
## over WeatherSampler.DUST_LAYER_M of air over the ground, the convention the sampler's visibility
## already uses. So the visibility inside the volume is the one the weather debug prints.
##
## SIZE x SIZE cells of CELL_M around an anchor (planet-local, the ground under the camera), on the
## tangent frame there. Two textures: the ground over the sphere through the anchor (m; red the real
## ground, green the storm's lid ground, smoothed over LID_CELLS) and the weather (red the storm
## extinction, 1/m; green the cloud sea's thickness factor). The ground reads the streamed terrain
## tiles: built on the main thread within a budget, once per anchor. The dust moves with the systems:
## recomputed on a worker every REFRESH_S from a copy of the systems (the sampler's sums are pure). A new
## anchor swaps in only once both of its textures are complete, frame and textures together.
## The dust's COLOUR is not here any more: the planet map (CloudPlanetMap) gives it everywhere.

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
## The corundum cloud sea's thickness factor from the weather (1 = the profile's calibrated veil): a
## system's pressure anomaly of -DECK_PRESSURE_PA doubles it (a depression gathers the dust), +that
## much thins it; clamped to [DECK_MIN, DECK_MAX] (a thin sea under the anticyclones, deep banks under
## the lows). The floor used to be 0.1: under a high the sea was torn to the bare ground, a few white
## slabs over a dark plain, and read as a bug from 9 km up (2026-10-09). A high settles the dust, it
## does not sweep a valley clean: half the calibrated veil at most.
const DECK_PRESSURE_PA: float = 1500.0
const DECK_MIN: float = 0.5
const DECK_MAX: float = 2.5
## The share of the grid's ground under its "low ground" (ground_low_m): low enough that a valley's
## worth of lowland still lets the sky show the veil over it, high enough to ignore a canyon.
const GROUND_LOW_SHARE: float = 0.2

## The grid in use (planet-local anchor and frame), its textures and what the shader needs to bound
## its march: the highest lid ground and the lowest ground over the anchor's sphere, and the strongest
## extinction.
var ready: bool = false
var anchor: Vector3 = Vector3.ZERO
var east: Vector3 = Vector3.RIGHT
var north: Vector3 = Vector3.FORWARD
var up: Vector3 = Vector3.UP
var ground_top_m: float = 0.0
var ground_lowest_m: float = 0.0
## The lid ground of the grid in use (m over the anchor's sphere, SIZE x SIZE): what the volume's
## storm top stands on, read back by lid_at so the light around the eye agrees with what is drawn.
var lid_heights: PackedFloat32Array = PackedFloat32Array()
## The real ground of the grid in use (m over the anchor's sphere, SIZE x SIZE), for the probe.
var ground_heights: PackedFloat32Array = PackedFloat32Array()
## The cloud sea's weather factor per cell of the grid in use (SIZE x SIZE, 1 = calibrated).
var deck_factors: PackedFloat32Array = PackedFloat32Array()
## The grid's low ground (m over the anchor's sphere): GROUND_LOW_SHARE of its cells lie under it.
var ground_low_m: float = 0.0
var beta_max: float = 0.0
var ground_texture: ImageTexture = null
var dust_texture: ImageTexture = null
## The last ground build's query time (ms), for the dust probe.
var last_ground_ms: float = 0.0

var _next: Dictionary = {}  # the anchor being built: {anchor, east, north, up, ground, row, us}
var _task: int = -1
## What the running worker job hands back. Its own object, held by the job's closure: the worker
## never writes into this StormField, which may be freed while the job runs (the game quitting
## mid-job crashed the client in ntdll, 2026-10-08). And a StormField waits for its job before going.
var _job: JobResult = null
var _task_for_next: bool = false
var _refresh_at: float = 0.0


class JobResult extends RefCounted:
	var dust: PackedFloat32Array = PackedFloat32Array()
	var deck: PackedFloat32Array = PackedFloat32Array()
	var lid: PackedFloat32Array = PackedFloat32Array()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


## Keep the grid around [param ground_point] (planet-local): [param ground_radius] gives the ground's
## distance from the centre along a unit direction, [param dust_job] returns the systems' extinction
## sampler as a Callable(dir) -> Vector2 that is safe to run on a worker (see dust_sampler). Returns
## true when the textures changed.
func update(ground_point: Vector3, ground_radius: Callable, dust_job: Callable, now_s: float,
		budget_ms: float = BUDGET_MS) -> bool:
	var changed: bool = _collect(now_s)
	if _next.is_empty() and (not ready or ground_point.distance_to(anchor) > REBUILD_M):
		_start(ground_point)
	if not _next.is_empty():
		if int(_next["row"]) < SIZE:
			_build_ground(ground_radius, budget_ms)
		# The new anchor's dust as soon as its ground is done and no other job runs (a refresh still
		# running is collected first, then dropped: see _collect).
		if int(_next["row"]) >= SIZE and _task < 0:
			_launch(dust_job, _next, true)
	elif ready and _task < 0 and now_s >= _refresh_at:
		_launch(dust_job, {"anchor": anchor, "east": east, "north": north}, false)
	return changed


## A Callable(dir) -> Vector2(storm extinction (1/m), cloud sea factor) over [param profile] for
## [param systems] (copies of the state Dictionaries) and the debug [param override]: the sampler's
## summed dust τ over DUST_LAYER_M, and the cloud sea's thickness from the systems' summed pressure
## anomaly (deck_factor). Pure, so a worker can run it.
static func dust_sampler(profile: ClimateProfile, systems: Array, override: Dictionary) -> Callable:
	return func(dir: Vector3) -> Vector2:
		var tau: float = 0.0
		var pressure: float = 0.0
		var ll: Vector2 = HEALPix.vec2lonlat(dir)
		for s: Dictionary in systems:
			var k: Dictionary = WeatherSampler.contribution(profile, s, ll.x, ll.y)
			tau += float(k["dust_tau"])
			pressure += float(k["pressure"])
		if override.has("dust_tau"):
			tau = float(override["dust_tau"])
		return Vector2(tau / WeatherSampler.DUST_LAYER_M, deck_factor(pressure))


## The cloud sea's thickness factor for a pressure anomaly [param pressure_pa] (see DECK_PRESSURE_PA).
static func deck_factor(pressure_pa: float) -> float:
	return clampf(1.0 - pressure_pa / DECK_PRESSURE_PA, DECK_MIN, DECK_MAX)


## Half the grid's width, m.
static func half_m() -> float:
	return SIZE * CELL_M * 0.5


## The planet-local point of cell ([param i], [param j]) on the tangent plane at [param at].
static func cell_point(at: Vector3, e: Vector3, n: Vector3, i: int, j: int) -> Vector3:
	return at + e * ((i + 0.5) * CELL_M - half_m()) + n * ((j + 0.5) * CELL_M - half_m())


## The lid ground (m over the anchor's sphere) under [param q] (planet-local, relative to the anchor),
## bilinear like the shader reads it, edges clamped; NAN before the first grid.
func lid_at(q: Vector3) -> float:
	if lid_heights.size() != SIZE * SIZE:
		return NAN
	var x: float = clampf((q.dot(east) + half_m()) / CELL_M - 0.5, 0.0, SIZE - 1.001)
	var y: float = clampf((q.dot(north) + half_m()) / CELL_M - 0.5, 0.0, SIZE - 1.001)
	var i: int = int(x)
	var j: int = int(y)
	var fx: float = x - i
	var fy: float = y - j
	var a: float = lerpf(lid_heights[j * SIZE + i], lid_heights[j * SIZE + i + 1], fx)
	var b: float = lerpf(lid_heights[(j + 1) * SIZE + i], lid_heights[(j + 1) * SIZE + i + 1], fx)
	return lerpf(a, b, fy)


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
	_next = {"anchor": ground_point, "east": f[0], "north": f[1], "up": f[2], "ground": heights, "row": 0, "us": 0}


func _build_ground(ground_radius: Callable, budget_ms: float) -> void:
	var deadline: int = Time.get_ticks_usec() + int(budget_ms * 1000.0)
	var a: Vector3 = _next["anchor"]
	var r: float = a.length()
	var heights: PackedFloat32Array = _next["ground"]
	while int(_next["row"]) < SIZE:
		var t0: int = Time.get_ticks_usec()
		var j: int = _next["row"]
		for i in SIZE:
			var dir: Vector3 = cell_point(a, _next["east"], _next["north"], i, j).normalized()
			heights[j * SIZE + i] = float(ground_radius.call(dir)) - r
		_next["us"] = int(_next["us"]) + Time.get_ticks_usec() - t0
		_next["row"] = j + 1
		if Time.get_ticks_usec() >= deadline:
			break
	_next["ground"] = heights


func _launch(dust_job: Callable, frame: Dictionary, for_next: bool) -> void:
	var a: Vector3 = frame["anchor"]
	var e: Vector3 = frame["east"]
	var n: Vector3 = frame["north"]
	_task_for_next = for_next
	var result := JobResult.new()
	_job = result
	# A new anchor's lid (the smoothed ground) is worked out here too: a few hundred thousand sums,
	# a visible hitch on the main thread.
	var ground: PackedFloat32Array = (frame["ground"] as PackedFloat32Array).duplicate() if for_next \
			else PackedFloat32Array()
	_task = WorkerThreadPool.add_task(func() -> void:
		var out := PackedFloat32Array()
		out.resize(SIZE * SIZE)
		var deck := PackedFloat32Array()
		deck.resize(SIZE * SIZE)
		for j in SIZE:
			for i in SIZE:
				var v: Vector2 = dust_job.call(StormField.cell_point(a, e, n, i, j).normalized())
				out[j * SIZE + i] = v.x
				deck[j * SIZE + i] = v.y
		result.deck = deck
		if not ground.is_empty():
			result.lid = StormField.smoothed(ground, LID_CELLS)
		result.dust = out)


## Take a finished dust job: either the last piece of a new anchor (swap everything) or a refresh of
## the one in use (the dust texture only). True when the textures changed.
func _collect(now_s: float) -> bool:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_refresh_at = now_s + REFRESH_S
	var dust: PackedFloat32Array = _job.dust
	if dust.size() != SIZE * SIZE:
		return false
	if _task_for_next:
		if _next.is_empty():
			return false
		var ground: PackedFloat32Array = _next["ground"]
		var lid: PackedFloat32Array = _job.lid if _job.lid.size() == SIZE * SIZE else ground
		ground_texture = _texture2(ground_texture, ground, lid)
		anchor = _next["anchor"]
		east = _next["east"]
		north = _next["north"]
		up = _next["up"]
		ground_top_m = _max_of(lid)
		ground_lowest_m = _min_of(ground)
		lid_heights = lid
		ground_heights = ground
		ground_low_m = StormField.quantile(ground, GROUND_LOW_SHARE)
		last_ground_ms = int(_next["us"]) / 1000.0
		_next = {}
	elif _next.size() > 0:
		return false  # a refresh finished after a new anchor began: that anchor's own job follows
	# Red the storms' extinction, green the cloud sea's weather factor.
	var deck: PackedFloat32Array = _job.deck if _job.deck.size() == SIZE * SIZE else PackedFloat32Array()
	if deck.is_empty():
		deck.resize(SIZE * SIZE)
		deck.fill(1.0)
	dust_texture = _texture2(dust_texture, dust, deck)
	deck_factors = deck
	beta_max = _max_of(dust)
	ready = true
	return true


## The value [param share] of [param values] lie under (0 = the lowest), 0 when empty.
static func quantile(values: PackedFloat32Array, share: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: PackedFloat32Array = values.duplicate()
	sorted.sort()
	return sorted[clampi(int(share * (sorted.size() - 1)), 0, sorted.size() - 1)]


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


## A two-channel texture: [param r] and [param g] interleaved.
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


static func _max_of(data: PackedFloat32Array) -> float:
	var m: float = -INF
	for v: float in data:
		m = maxf(m, v)
	return m


static func _min_of(data: PackedFloat32Array) -> float:
	var m: float = INF
	for v: float in data:
		m = minf(m, v)
	return m
